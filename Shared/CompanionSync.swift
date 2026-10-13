import Combine
import Foundation
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

#if os(watchOS)
private final class BackgroundCallbackWorkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingCount = 0

    func begin() {
        lock.lock(); defer { lock.unlock() }
        pendingCount += 1
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        pendingCount = max(0, pendingCount - 1)
    }

    var hasPendingWork: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingCount > 0
    }
}

private let backgroundCallbackWorkGate = BackgroundCallbackWorkGate()

private final class BackgroundCallbackWorkToken: @unchecked Sendable {
    private let gate: BackgroundCallbackWorkGate
    private let lock = NSLock()
    private var isFinished = false

    init(gate: BackgroundCallbackWorkGate) {
        self.gate = gate
        gate.begin()
    }

    func finish() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        lock.unlock()
        gate.end()
    }

    deinit { finish() }
}
#endif

@MainActor
final class CompanionSync: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status = "等待手表同步"
    var onChange: (() -> Void)?

    private nonisolated let store: RecordingStore
    private let diagnostics: CaptureDiagnostics
    private let session: WCSession
    private let queuedKey = "suiji.watch.pendingFileTransfers"
    #if os(watchOS)
    private let retryLedgerKey = "suiji.watch.transferRetryLedger"
    private var retryLedger = TransferRetryLedger()
    #endif
    private let retryDelay: TimeInterval = 60
    private var retryTask: Task<Void, Never>?
    private var retryScheduledDelay: TimeInterval?
    private var retryAttempt = 0
    #if os(watchOS)
    private var pendingObservation: NSKeyValueObservation?
    private var receiptQueryInFlight = false
    private var lastReceiptQuery = Date.distantPast
    private var receiptQueryOffset = 0
    private struct RegisteredBackgroundTask {
        let task: WKWatchConnectivityRefreshBackgroundTask
        let diagnostics: CaptureDiagnostics
    }
    private static var backgroundTasks: [RegisteredBackgroundTask] = []

    func registerBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                self?.diagnostics.record("watch_refresh_task_expired", details: [
                    "hasContentPending": String(self?.session.hasContentPending ?? false),
                    "outstandingFileTransfers": String(self?.session.outstandingFileTransfers.count ?? 0),
                ])
                task?.setTaskCompletedWithSnapshot(false)
                Self.backgroundTasks.removeAll { $0.task === task }
            }
        }
        Self.backgroundTasks.append(RegisteredBackgroundTask(task: task, diagnostics: diagnostics))
        diagnostics.record("watch_refresh_task_registered", details: [
            "hasContentPending": String(session.hasContentPending),
            "outstandingFileTransfers": String(session.outstandingFileTransfers.count),
            "registeredTaskCount": String(Self.backgroundTasks.count),
        ])
        Self.completeBackgroundTasksIfIdle()
    }

    private static func completeBackgroundTasksIfIdle() {
        let session = WCSession.default
        guard !backgroundCallbackWorkGate.hasPendingWork,
              session.activationState == .activated, !session.hasContentPending else { return }
        let tasks = backgroundTasks
        backgroundTasks.removeAll()
        tasks.forEach { registration in
            registration.diagnostics.record("watch_refresh_task_completed", details: [
                "hasContentPending": String(session.hasContentPending),
                "outstandingFileTransfers": String(session.outstandingFileTransfers.count),
            ])
            registration.task.expirationHandler = nil
            registration.task.setTaskCompletedWithSnapshot(false)
        }
    }

    nonisolated private static func completeBackgroundTasksIfIdleAsync() {
        Task { @MainActor in completeBackgroundTasksIfIdle() }
    }
    #endif

    init(store: RecordingStore, diagnostics: CaptureDiagnostics) {
        self.store = store
        self.diagnostics = diagnostics
        self.session = WCSession.default
        super.init()
        #if os(watchOS)
        if let data = UserDefaults.standard.data(forKey: retryLedgerKey),
           let saved = try? JSONDecoder().decode(TransferRetryLedger.self, from: data) {
            retryLedger = saved
        }
        pendingObservation = session.observe(\.hasContentPending, options: [.new]) { _, _ in
            Self.completeBackgroundTasksIfIdleAsync()
        }
        #endif
    }

    func activate() {
        guard WCSession.isSupported() else {
            status = "此设备暂不支持手表同步。"
            return
        }
        session.delegate = self
        session.activate()
        #if os(watchOS)
        status = "正在准备同步。"
        #else
        status = "手机已准备好接收手表录音。"
        #endif
    }

    func recordWatchRefreshStage(_ stage: String, taskCount: Int, connectivityTaskCount: Int) {
        #if os(watchOS)
        diagnostics.record("watch_refresh_handler_stage", details: [
            "stage": stage,
            "taskCount": String(taskCount),
            "connectivityTaskCount": String(connectivityTaskCount),
            "activationState": String(describing: session.activationState),
            "hasContentPending": String(session.hasContentPending),
            "outstandingFileTransfers": String(session.outstandingFileTransfers.count),
        ])
        #endif
    }

    func enqueuePending() {
        #if os(watchOS)
        guard session.activationState == .activated else {
            status = "录音已保存在手表，等待手机接收。"
            return
        }

        reconcileReceiptsIfReachable()

        let outstandingTransfers = session.outstandingFileTransfers
        let outstanding = Set(outstandingTransfers.compactMap { transfer -> String? in
            transfer.file.metadata?["recordingID"] as? String
        })
        var queued = queuedTransfers()
        let candidates = store.all().filter {
            $0.source == .watch && $0.phoneReceivedAt == nil && $0.audioDeletedAt == nil && $0.captureState != .recording
        }
        var queuedCount = 0
        var skippedOutstandingCount = 0
        var skippedRetryDelayCount = 0
        var skippedReceiptWaitCount = 0
        var missingAudioCount = 0

        for recording in candidates {
            let id = recording.id.uuidString
            if outstanding.contains(id) {
                skippedOutstandingCount += 1
                continue
            }
            let now = Date()
            if retryLedger.isWaitingForReceipt(recordingID: id, at: now) {
                skippedReceiptWaitCount += 1
                continue
            }
            if let date = queued[id], now.timeIntervalSince(date) < retryDelay {
                skippedRetryDelayCount += 1
                continue
            }

            let fileURL = store.audioURL(for: recording)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                missingAudioCount += 1
                status = "找不到待同步的音频文件，记录仍保留。"
                continue
            }
            do {
                let envelope = try JSONEncoder().encode(ClipEnvelope(recording: recording))
                let attemptID = UUID().uuidString
                retryLedger.beginAttempt(recordingID: id, attemptID: attemptID)
                persistRetryLedger()
                queued[id] = now
                saveQueuedTransfers(queued)
                session.transferFile(fileURL, metadata: ["type": "recording", "recordingID": id,
                                                         "attemptID": attemptID, "envelope": envelope])
                queuedCount += 1
                diagnostics.record("watch_file_transfer_enqueued", details: [
                    "recordingID": id,
                    "outstandingFileTransfers": String(session.outstandingFileTransfers.count),
                ])
            } catch {
                queued.removeValue(forKey: id)
                saveQueuedTransfers(queued)
                status = "准备同步失败，原声仍保留：\(error.localizedDescription)"
            }
        }

        diagnostics.record("watch_enqueue_batch", details: [
            "candidateCount": String(candidates.count),
            "enqueuedCount": String(queuedCount),
            "skippedOutstandingCount": String(skippedOutstandingCount),
            "skippedRetryDelayCount": String(skippedRetryDelayCount),
            "skippedReceiptWaitCount": String(skippedReceiptWaitCount),
            "missingAudioCount": String(missingAudioCount),
            "outstandingBefore": String(outstandingTransfers.count),
            "outstandingAfter": String(session.outstandingFileTransfers.count),
        ])

        if queuedCount > 0 {
            status = "已开始同步 \(queuedCount) 段录音，原声仍保存在手表。"
        } else if candidates.isEmpty {
            status = "没有待同步的录音。"
        } else {
            status = "录音已保存在手表，等待手机接收。"
        }
        if store.all().contains(where: { $0.source == .watch && $0.audioDeletedAt == nil && $0.captureState != .recording }) {
            scheduleRetry(after: retryDelay)
        }
        #else
        status = "手机已准备好接收手表录音。"
        #endif
    }

    private func queuedTransfers() -> [String: Date] {
        UserDefaults.standard.dictionary(forKey: queuedKey) as? [String: Date] ?? [:]
    }

    private func saveQueuedTransfers(_ transfers: [String: Date]) {
        UserDefaults.standard.set(transfers, forKey: queuedKey)
    }

    private func removeQueuedTransfer(_ id: String) {
        var transfers = queuedTransfers()
        transfers.removeValue(forKey: id)
        saveQueuedTransfers(transfers)
        #if os(watchOS)
        retryLedger.clear(recordingID: id)
        persistRetryLedger()
        #endif
    }

    #if os(watchOS)
    private func persistRetryLedger() {
        guard let data = try? JSONEncoder().encode(retryLedger) else { return }
        UserDefaults.standard.set(data, forKey: retryLedgerKey)
    }
    #endif

    nonisolated private func recordCallbackEvent(_ event: String, occurredAt: Date,
                                                 queuedAtUptime: TimeInterval,
                                                 details: [String: String]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var eventDetails = details
            let delayMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - queuedAtUptime) * 1_000)
            eventDetails["mainActorDispatchDelayMilliseconds"] = String(Int(delayMilliseconds.rounded()))
            self.diagnostics.record(event, details: eventDetails, at: occurredAt)
        }
    }

    #if os(watchOS)
    private func reconcileReceiptsIfReachable() {
        guard session.isReachable, !receiptQueryInFlight,
              Date().timeIntervalSince(lastReceiptQuery) >= 5 else { return }
        let pendingIDs = store.all().filter {
            $0.source == .watch && $0.audioDeletedAt == nil && $0.captureState != .recording
        }.map(\.id)
        guard !pendingIDs.isEmpty else { return }
        let start = receiptQueryOffset % pendingIDs.count
        let batch = (0..<min(50, pendingIDs.count)).map { pendingIDs[(start + $0) % pendingIDs.count] }
        let requestedIDs = Set(batch)
        receiptQueryOffset = start + batch.count
        receiptQueryInFlight = true
        lastReceiptQuery = Date()
        diagnostics.record("receipt_query_started", details: [
            "requestedCount": String(requestedIDs.count),
            "outstandingFileTransfers": String(session.outstandingFileTransfers.count),
        ])
        session.sendMessage(["type": "recordingReceiptQuery", "recordingIDs": requestedIDs.map(\.uuidString)],
                            replyHandler: { [weak self] response in
            let callbackAt = Date()
            let callbackUptime = ProcessInfo.processInfo.systemUptime
            let type = response["type"] as? String
            let confirmed = (response["recordingIDs"] as? [String]).map { Set($0.compactMap(UUID.init(uuidString:))) }
            self?.recordCallbackEvent("watch_receipt_query_reply_entry", occurredAt: callbackAt,
                                      queuedAtUptime: callbackUptime,
                                      details: ["replyType": type ?? "missing",
                                                "requestedCount": String(requestedIDs.count),
                                                "confirmedCount": String(confirmed?.count ?? 0)])
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiptQueryInFlight = false
                guard type == "recordingReceiptStatus", let confirmed else {
                    self.diagnostics.record("receipt_query_failed", details: ["kind": "invalid_reply"])
                    return
                }
                let accepted = confirmed.intersection(requestedIDs)
                var applied = 0
                for id in accepted {
                    do {
                        try self.store.acceptPhoneReceipt(id: id)
                        self.didAcceptReceipt(id.uuidString)
                        applied += 1
                    } catch {
                        self.status = "手机已确认保存，手表副本处理失败：\(error.localizedDescription)"
                        self.scheduleRetry(after: self.retryDelay)
                    }
                }
                self.diagnostics.record("receipt_query_completed", details: ["confirmedCount": String(accepted.count),
                                                                              "appliedCount": String(applied)])
            }
        }, errorHandler: { [weak self] error in
            let callbackAt = Date()
            let callbackUptime = ProcessInfo.processInfo.systemUptime
            let failure = error as NSError
            let code = failure.code
            self?.recordCallbackEvent("watch_receipt_query_error_entry", occurredAt: callbackAt,
                                      queuedAtUptime: callbackUptime,
                                      details: ["errorDomain": failure.domain, "errorCode": String(code),
                                                "requestedCount": String(requestedIDs.count)])
            Task { @MainActor [weak self] in
                self?.receiptQueryInFlight = false
                self?.diagnostics.record("receipt_query_failed", details: ["code": String(code)])
            }
        })
    }

    private func didAcceptReceipt(_ id: String) {
        removeQueuedTransfer(id)
        session.outstandingFileTransfers.filter { $0.file.metadata?["recordingID"] as? String == id }.forEach { $0.cancel() }
        retryAttempt = 0
        status = "手机已收到录音，手表副本已释放。"
        onChange?()
        if store.all().contains(where: { $0.source == .watch && $0.audioDeletedAt == nil && $0.captureState != .recording }) {
            scheduleRetry(after: retryDelay)
        }
    }
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let callbackAt = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        let reachable = session.isReachable
        let outstandingCount = session.outstandingFileTransfers.count
        recordCallbackEvent("wc_reachability_callback_entry", occurredAt: callbackAt,
                            queuedAtUptime: callbackUptime,
                            details: ["reachable": String(reachable),
                                      "activationState": String(describing: session.activationState),
                                      "outstandingFileTransfers": String(outstandingCount)])
        Task { @MainActor [weak self] in self?.enqueuePending() }
    }

    #if os(iOS)
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                            replyHandler: @escaping ([String: Any]) -> Void) {
        let callbackAt = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        guard message["type"] as? String == "recordingReceiptQuery",
              let values = message["recordingIDs"] as? [String], values.count <= 50 else {
            replyHandler(["type": "recordingReceiptStatus", "recordingIDs": [String]()])
            recordCallbackEvent("phone_receipt_query_rejected", occurredAt: callbackAt,
                                queuedAtUptime: callbackUptime,
                                details: ["reason": "invalid_message"])
            return
        }
        let ids = values.compactMap(UUID.init(uuidString:))
        recordCallbackEvent("phone_receipt_query_entry", occurredAt: callbackAt,
                            queuedAtUptime: callbackUptime,
                            details: ["requestedCount": String(ids.count)])
        let confirmed = store.confirmedWatchReceiptIDs(for: ids)
        replyHandler(["type": "recordingReceiptStatus", "recordingIDs": confirmed.map(\.uuidString)])
        let answeredAt = Date()
        let answeredUptime = ProcessInfo.processInfo.systemUptime
        recordCallbackEvent("receipt_query_answered", occurredAt: answeredAt,
                            queuedAtUptime: answeredUptime,
                            details: ["requestedCount": String(ids.count),
                                      "confirmedCount": String(confirmed.count),
                                      "elapsedSinceCallbackMilliseconds": String(Int(max(0, answeredUptime - callbackUptime) * 1_000))])
    }
    #endif

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let callbackAt = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        let message = error?.localizedDescription
        let failure = error.map { $0 as NSError }
        recordCallbackEvent("wc_activation_callback_entry", occurredAt: callbackAt,
                            queuedAtUptime: callbackUptime,
                            details: ["activationState": String(describing: activationState),
                                      "errorDomain": failure?.domain ?? "none",
                                      "errorCode": failure.map { String($0.code) } ?? "0"])
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let message {
                self.status = "同步启动失败：\(message)"
            } else if activationState == .activated {
                self.status = "同步已准备好。"
                self.enqueuePending()
            } else {
                self.status = "同步尚未准备好。"
            }
            #if os(watchOS)
            Self.completeBackgroundTasksIfIdle()
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(watchOS)
        defer { Self.completeBackgroundTasksIfIdleAsync() }
        #endif
        let callbackAt = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        let metadata = file.metadata ?? [:]
        let idString = metadata["recordingID"] as? String
        let id = idString.flatMap(UUID.init(uuidString:))
        var entryDetails = ["metadataType": metadata["type"] as? String ?? "missing",
                            "hasEnvelope": String(metadata["envelope"] is Data)]
        if let id { entryDetails["recordingID"] = id.uuidString }
        recordCallbackEvent("phone_file_receive_entry", occurredAt: callbackAt,
                            queuedAtUptime: callbackUptime, details: entryDetails)
        guard metadata["type"] as? String == "recording",
              let id,
              let envelopeData = metadata["envelope"] as? Data else {
            recordCallbackEvent("phone_file_receive_rejected", occurredAt: Date(),
                                queuedAtUptime: ProcessInfo.processInfo.systemUptime,
                                details: ["stage": "metadata_validation"])
            Task { @MainActor [weak self] in
                self?.status = "收到无法识别的手表录音文件。"
            }
            return
        }

        let recordID = id.uuidString
        var stage = "decode_envelope"
        do {
            let envelope = try JSONDecoder().decode(ClipEnvelope.self, from: envelopeData)
            stage = "validate_envelope"
            guard envelope.id == id else { throw CompanionSyncError.invalidEnvelope }
            let wasAlreadyPresent = store.recording(id: id) != nil
            stage = "persist_file_and_manifest"
            let imported = try store.importClip(from: file.fileURL, envelope: envelope)
            let importedAt = Date()
            let importedUptime = ProcessInfo.processInfo.systemUptime
            recordCallbackEvent("phone_file_import_committed", occurredAt: importedAt,
                                queuedAtUptime: importedUptime,
                                details: ["recordingID": recordID,
                                          "alreadyPresent": String(wasAlreadyPresent),
                                          "elapsedSinceReceiveMilliseconds": String(Int(max(0, importedUptime - callbackUptime) * 1_000))])
            stage = "persist_phone_receipt"
            try store.acknowledge(id: imported.id)
            let acknowledgedAt = Date()
            let acknowledgedUptime = ProcessInfo.processInfo.systemUptime
            recordCallbackEvent("phone_receipt_persisted", occurredAt: acknowledgedAt,
                                queuedAtUptime: acknowledgedUptime,
                                details: ["recordingID": recordID,
                                          "elapsedSinceReceiveMilliseconds": String(Int(max(0, acknowledgedUptime - callbackUptime) * 1_000))])
            stage = "queue_watch_acknowledgement"
            session.transferUserInfo(["type": "recordingReceipt", "recordingID": imported.id.uuidString])
            let receiptTransferCount = session.outstandingUserInfoTransfers.filter {
                $0.userInfo["type"] as? String == "recordingReceipt"
            }.count
            recordCallbackEvent("phone_receipt_transfer_queued", occurredAt: Date(),
                                queuedAtUptime: ProcessInfo.processInfo.systemUptime,
                                details: ["recordingID": recordID,
                                          "outstandingReceiptTransfers": String(receiptTransferCount)])
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = "已保存一段手表录音到手机。"
                self.onChange?()
            }
        } catch {
            let failure = error as NSError
            recordCallbackEvent("phone_file_receive_failed", occurredAt: Date(),
                                queuedAtUptime: ProcessInfo.processInfo.systemUptime,
                                details: ["recordingID": recordID,
                                          "stage": stage,
                                          "errorDomain": failure.domain,
                                          "errorCode": String(failure.code),
                                          "elapsedSinceReceiveMilliseconds": String(Int(max(0, ProcessInfo.processInfo.systemUptime - callbackUptime) * 1_000))])
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.status = "手表录音未能保存：\(message)"
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        #if os(watchOS)
        defer { Self.completeBackgroundTasksIfIdleAsync() }
        #endif
        let callbackAt = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        let idString = userInfo["recordingID"] as? String
        let id = idString.flatMap(UUID.init(uuidString:))
        var entryDetails = ["type": userInfo["type"] as? String ?? "missing"]
        if let id { entryDetails["recordingID"] = id.uuidString }
        recordCallbackEvent("watch_user_info_receive_entry", occurredAt: callbackAt,
                            queuedAtUptime: callbackUptime, details: entryDetails)
        guard userInfo["type"] as? String == "recordingReceipt",
              let id else { return }

        #if os(watchOS)
        do {
            try store.acceptPhoneReceipt(id: id)
            let appliedAt = Date()
            let appliedUptime = ProcessInfo.processInfo.systemUptime
            recordCallbackEvent("watch_phone_receipt_applied", occurredAt: appliedAt,
                                queuedAtUptime: appliedUptime,
                                details: ["recordingID": id.uuidString,
                                          "elapsedSinceCallbackMilliseconds": String(Int(max(0, appliedUptime - callbackUptime) * 1_000))])
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.didAcceptReceipt(id.uuidString)
                self.diagnostics.record("receipt_received", details: ["source": "user_info"])
            }
        } catch {
            let failure = error as NSError
            recordCallbackEvent("watch_phone_receipt_apply_failed", occurredAt: Date(),
                                queuedAtUptime: ProcessInfo.processInfo.systemUptime,
                                details: ["recordingID": id.uuidString,
                                          "errorDomain": failure.domain,
                                          "errorCode": String(failure.code)])
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.status = "手机已收到录音，但手表副本仍保留：\(message)"
                self?.scheduleRetry(after: self?.retryDelay ?? 60)
            }
        }
        #endif
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        #if os(watchOS)
        let callbackWork = BackgroundCallbackWorkToken(gate: backgroundCallbackWorkGate)
        let callbackAt = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        let idString = fileTransfer.file.metadata?["recordingID"] as? String
        let id = idString.flatMap(UUID.init(uuidString:))
        let attemptID = fileTransfer.file.metadata?["attemptID"] as? String
        let failure = error.map { $0 as NSError }
        var callbackDetails = ["outcome": error == nil ? "success" : "error",
                               "outstandingFileTransfers": String(session.outstandingFileTransfers.count),
                               "progressFraction": String(fileTransfer.progress.fractionCompleted),
                               "hasAttemptID": String(attemptID != nil)]
        if let id { callbackDetails["recordingID"] = id.uuidString }
        if let failure {
            callbackDetails["errorDomain"] = failure.domain
            callbackDetails["errorCode"] = String(failure.code)
        }
        let transferSucceeded = error == nil
        let message = error?.localizedDescription
        recordCallbackEvent("watch_file_transfer_did_finish_entry", occurredAt: callbackAt,
                            queuedAtUptime: callbackUptime, details: callbackDetails)
        guard let id else {
            callbackWork.finish()
            Self.completeBackgroundTasksIfIdleAsync()
            return
        }
        let recordID = id.uuidString
        Task { @MainActor [weak self, callbackWork] in
            defer {
                callbackWork.finish()
                Self.completeBackgroundTasksIfIdle()
            }
            guard let self else {
                return
            }
            if self.store.recording(id: id)?.phoneReceivedAt != nil {
                self.removeQueuedTransfer(recordID)
                return
            }
            let completion = self.retryLedger.finishAttempt(recordingID: recordID, attemptID: attemptID,
                                                            succeeded: transferSucceeded, at: callbackAt)
            self.persistRetryLedger()
            if completion == .stale { return }
            if completion == .awaitingReceipt {
                self.diagnostics.record("watch_transfer_waiting_for_receipt", details: [
                    "waitLimitSeconds": String(Int(TransferRetryLedger.receiptWaitLimit)),
                ], at: callbackAt)
            } else if let message {
                self.removeQueuedTransfer(recordID)
                self.status = "同步暂时失败，原声仍保存在手表：\(message)"
                self.scheduleRetry(after: self.nextFailureDelay())
            }
        }
        #endif
    }

    #if os(watchOS)
    private func nextFailureDelay() -> TimeInterval {
        let delay = min(5 * pow(2, Double(retryAttempt)), 300)
        retryAttempt = min(retryAttempt + 1, 6)
        return delay
    }

    private func scheduleRetry(after delay: TimeInterval) {
        if let scheduled = retryScheduledDelay, scheduled <= delay { return }
        retryTask?.cancel()
        retryScheduledDelay = delay
        diagnostics.record("watch_retry_scheduled", details: [
            "delaySeconds": String(Int(delay.rounded())),
            "pendingCount": String(store.all().filter {
                $0.source == .watch && $0.phoneReceivedAt == nil && $0.audioDeletedAt == nil && $0.captureState != .recording
            }.count),
        ])
        retryTask = Task { [weak self] in
            let nanoseconds = UInt64(max(1, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.retryScheduledDelay = nil
            self.diagnostics.record("watch_retry_fired", details: [
                "pendingCount": String(self.store.all().filter {
                    $0.source == .watch && $0.phoneReceivedAt == nil && $0.audioDeletedAt == nil && $0.captureState != .recording
                }.count),
            ])
            self.enqueuePending()
        }
    }
    #endif

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        let callbackAt = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        recordCallbackEvent("wc_session_inactive_callback_entry", occurredAt: callbackAt,
                            queuedAtUptime: callbackUptime,
                            details: ["activationState": String(describing: session.activationState)])
        Task { @MainActor [weak self] in self?.status = "手表配对正在切换，录音仍保留。" }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        let callbackAt = Date()
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        recordCallbackEvent("wc_session_deactivated_callback_entry", occurredAt: callbackAt,
                            queuedAtUptime: callbackUptime,
                            details: ["activationState": String(describing: session.activationState)])
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.session.activate()
            self.status = "正在重新准备同步。"
        }
    }
    #endif
}

private enum CompanionSyncError: LocalizedError {
    case invalidEnvelope
    var errorDescription: String? { "手表录音信息与音频文件不匹配。" }
}
