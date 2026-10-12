import Combine
import Foundation
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

@MainActor
final class CompanionSync: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status = "等待手表同步"
    var onChange: (() -> Void)?

    private nonisolated let store: RecordingStore
    private let session: WCSession
    private let queuedKey = "suiji.watch.pendingFileTransfers"
    private let retryDelay: TimeInterval = 60
    private var retryTask: Task<Void, Never>?
    private var retryScheduledDelay: TimeInterval?
    private var retryAttempt = 0
    #if os(watchOS)
    private var pendingObservation: NSKeyValueObservation?
    private static var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []

    static func registerBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        task.expirationHandler = { [weak task] in
            Task { @MainActor in
                task?.setTaskCompletedWithSnapshot(false)
                backgroundTasks.removeAll { $0 === task }
            }
        }
        backgroundTasks.append(task)
        completeBackgroundTasksIfIdle()
    }

    private static func completeBackgroundTasksIfIdle() {
        let session = WCSession.default
        guard session.activationState == .activated, !session.hasContentPending else { return }
        let tasks = backgroundTasks
        backgroundTasks.removeAll()
        tasks.forEach {
            $0.expirationHandler = nil
            $0.setTaskCompletedWithSnapshot(false)
        }
    }

    nonisolated private static func completeBackgroundTasksIfIdleAsync() {
        Task { @MainActor in completeBackgroundTasksIfIdle() }
    }
    #endif

    init(store: RecordingStore) {
        self.store = store
        self.session = WCSession.default
        super.init()
        #if os(watchOS)
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

    func enqueuePending() {
        #if os(watchOS)
        guard session.activationState == .activated else {
            status = "录音已保存在手表，等待手机接收。"
            return
        }

        let outstanding = Set(session.outstandingFileTransfers.compactMap { transfer -> String? in
            transfer.file.metadata?["recordingID"] as? String
        })
        var queued = queuedTransfers()
        let candidates = store.all().filter {
            $0.source == .watch && $0.phoneReceivedAt == nil && $0.audioDeletedAt == nil && $0.captureState != .recording
        }
        var queuedCount = 0

        for recording in candidates {
            let id = recording.id.uuidString
            if outstanding.contains(id) { continue }
            if let date = queued[id], Date().timeIntervalSince(date) < retryDelay { continue }

            let fileURL = store.audioURL(for: recording)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                status = "找不到待同步的音频文件，记录仍保留。"
                continue
            }
            do {
                let envelope = try JSONEncoder().encode(ClipEnvelope(recording: recording))
                queued[id] = Date()
                saveQueuedTransfers(queued)
                session.transferFile(fileURL, metadata: ["type": "recording", "recordingID": id, "envelope": envelope])
                queuedCount += 1
            } catch {
                queued.removeValue(forKey: id)
                saveQueuedTransfers(queued)
                status = "准备同步失败，原声仍保留：\(error.localizedDescription)"
            }
        }

        if queuedCount > 0 {
            status = "已开始同步 \(queuedCount) 段录音，原声仍保存在手表。"
        } else if candidates.isEmpty {
            status = "没有待同步的录音。"
        } else {
            status = "录音已保存在手表，等待手机接收。"
        }
        if !candidates.isEmpty { scheduleRetry(after: retryDelay) }
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
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let message = error?.localizedDescription
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
        let metadata = file.metadata ?? [:]
        guard metadata["type"] as? String == "recording",
              let idString = metadata["recordingID"] as? String,
              let id = UUID(uuidString: idString),
              let envelopeData = metadata["envelope"] as? Data else {
            Task { @MainActor [weak self] in
                self?.status = "收到无法识别的手表录音文件。"
            }
            return
        }

        do {
            let envelope = try JSONDecoder().decode(ClipEnvelope.self, from: envelopeData)
            guard envelope.id == id else { throw CompanionSyncError.invalidEnvelope }
            let imported = try store.importClip(from: file.fileURL, envelope: envelope)
            try store.acknowledge(id: imported.id)
            session.transferUserInfo(["type": "recordingReceipt", "recordingID": imported.id.uuidString])
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = "已保存一段手表录音到手机。"
                self.onChange?()
            }
        } catch {
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
        guard userInfo["type"] as? String == "recordingReceipt",
              let idString = userInfo["recordingID"] as? String,
              let id = UUID(uuidString: idString) else { return }

        #if os(watchOS)
        do {
            try store.acknowledge(id: id)
            try store.deleteDeliveredWatchAudio(id: id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.removeQueuedTransfer(idString)
                self.retryAttempt = 0
                self.status = "手机已收到录音，手表副本已释放。"
                self.onChange?()
                if !self.store.all().filter({ $0.source == .watch && $0.phoneReceivedAt == nil && $0.audioDeletedAt == nil && $0.captureState != .recording }).isEmpty {
                    self.scheduleRetry(after: self.retryDelay)
                }
            }
        } catch {
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
        defer { Self.completeBackgroundTasksIfIdleAsync() }
        guard let id = fileTransfer.file.metadata?["recordingID"] as? String else { return }
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let message {
                self.removeQueuedTransfer(id)
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
        retryTask = Task { [weak self] in
            let nanoseconds = UInt64(max(1, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.retryScheduledDelay = nil
            self.enqueuePending()
        }
    }
    #endif

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.status = "手表配对正在切换，录音仍保留。" }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
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
