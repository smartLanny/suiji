import AVFAudio
import Combine
import Foundation

@MainActor
final class AudioCapture: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var error: String?
    @Published private(set) var mode: RecordingMode = .quick

    private let store: RecordingStore
    private let source: RecordingSource
    private var activeIntent: RecordingIntent = .note
    private let audioSession = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?
    private var recordingID: UUID?
    private var segmentStart: Date?
    private var lastKnownSegmentDuration: TimeInterval = 0
    private var accumulatedDuration: TimeInterval = 0
    private var segmentCount = 0
    private var cancelPendingStart = false
    private var meterTimer: Timer?
    private var lastCapacityCheck = Date.distantPast
    private var notificationTokens: [NSObjectProtocol] = []
    private let segmentDuration: TimeInterval = 5 * 60
    private let minimumFreeBytes: Int64 = 24 * 1024 * 1024

    var onSaved: ((Recording) -> Void)?

    init(store: RecordingStore, source: RecordingSource) {
        self.store = store
        self.source = source
        super.init()
        observeAudioInterruptions()
        recover()
    }

    deinit {
        meterTimer?.invalidate()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    var canDiscardRecording: Bool {
        isRecording && mode == .quick && recordingID != nil && segmentCount == 1 && accumulatedDuration <= 0
    }

    func start(intent: RecordingIntent = .note, mode: RecordingMode = .quick) async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        cancelPendingStart = false
        defer { isStarting = false }
        error = nil
        guard await microphonePermission() else {
            error = "麦克风权限未开启，请在系统设置中允许录音。"
            return
        }
        guard !cancelPendingStart else { return }

        do {
            try checkFreeSpace()
            try audioSession.setCategory(.record, mode: .default, options: [])
            try audioSession.setActive(true)
            activeIntent = intent
            self.mode = mode
            accumulatedDuration = 0
            segmentCount = 0
            elapsed = 0
            isRecording = true
            try beginSegment()
            startMeterTimer()
        } catch {
            isRecording = false
            self.error = "录音未启动：\(error.localizedDescription)"
            deactivateAudioSession()
        }
    }

    func stop() {
        if isStarting {
            cancelPendingStart = true
            return
        }
        guard isRecording || recordingID != nil else { return }
        isRecording = false
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        finishCurrentSegment(interrupted: false, message: nil)
        deactivateAudioSession()
    }

    func clearError() {
        error = nil
    }

    func discardCurrentRecording() throws {
        guard isRecording, let id = recordingID else { throw AudioCaptureDiscardError.noCurrentRecording }
        guard mode == .quick else { throw AudioCaptureDiscardError.continuousRecordingCannotBeDiscarded }
        guard canDiscardRecording else { throw AudioCaptureDiscardError.committedSegmentsExist }

        isRecording = false
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        let activeRecorder = recorder
        let observedDuration = max(activeRecorder?.currentTime ?? 0, lastKnownSegmentDuration)
        activeRecorder?.delegate = nil
        activeRecorder?.stop()
        let duration = min(segmentDuration, max(observedDuration, closedFileDuration(for: id)))
        recorder = nil
        segmentStart = nil
        lastKnownSegmentDuration = 0
        deactivateAudioSession()

        do {
            try store.discardDraft(id: id)
            error = nil
            clearDiscardedSession()
        } catch {
            let discardFailure = error.localizedDescription
            if let recording = store.recording(id: id),
               FileManager.default.fileExists(atPath: store.audioURL(for: recording).path) {
                let restored: Recording
                do {
                    restored = try store.finish(id: id, duration: duration, interrupted: true)
                } catch {
                    var message = "取消未成功，原声仍保留，但恢复中断记录失败：\(error.localizedDescription)"
                    do {
                        try store.recordError(id: id, message: message)
                    } catch {
                        message += "（恢复说明也未能写入索引：\(error.localizedDescription)）"
                    }
                    self.error = message
                    let remaining = store.recording(id: id)
                    clearDiscardedSession()
                    if let remaining { onSaved?(remaining) }
                    throw AudioCaptureDiscardError.cancellationFailed(message)
                }

                var message = "取消未成功，原声已作为中断记录保留：\(discardFailure)"
                do {
                    try store.recordError(id: id, message: message)
                } catch {
                    message += "（取消失败说明未能写入索引：\(error.localizedDescription)）"
                }
                self.error = message
                let saved = store.recording(id: id) ?? restored
                clearDiscardedSession()
                onSaved?(saved)
                throw AudioCaptureDiscardError.cancellationFailed(message)
            }

            var message = "取消未完成，原声已删除，但空草稿索引未清理；下次恢复时会重试：\(discardFailure)"
            do {
                try store.recordError(id: id, message: message)
            } catch {
                message += "（索引错误说明也未能写入：\(error.localizedDescription)）"
            }
            self.error = message
            let remaining = store.recording(id: id)
            clearDiscardedSession()
            if let remaining { onSaved?(remaining) }
            throw AudioCaptureDiscardError.cancellationFailed(message)
        }
    }

    private func clearDiscardedSession() {
        recordingID = nil
        accumulatedDuration = 0
        segmentCount = 0
        elapsed = 0
        activeIntent = .note
        mode = .quick
    }

    func mark(intent: RecordingIntent = .note) throws -> RecordingMarker {
        guard isRecording, let id = recordingID, let recorder else {
            throw AudioCaptureMarkerError.noActiveRecording
        }
        guard mode == .continuous else { throw AudioCaptureMarkerError.requiresContinuousMode }
        let offset = min(segmentDuration, max(recorder.currentTime, lastKnownSegmentDuration))
        guard offset.isFinite, offset >= 0 else { throw StoreError.invalidMarker }
        let marker = RecordingMarker(id: UUID(), offset: offset, intent: intent)
        try store.addMarker(id: id, marker: marker)
        return marker
    }

    func recover() {
        guard !isStarting, !isRecording, recordingID == nil else { return }
        for recording in store.all() where recording.source == source && recording.captureState == .recording {
            let url = store.audioURL(for: recording)
            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    try store.discardEmptyCapture(id: recording.id)
                    continue
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes > 0 else {
                    try store.discardEmptyCapture(id: recording.id)
                    continue
                }
                let audio = try AVAudioFile(forReading: url)
                let sampleRate = audio.processingFormat.sampleRate
                let duration = sampleRate > 0 ? Double(audio.length) / sampleRate : 0
                guard duration.isFinite, duration > 0 else { throw AudioCaptureError.recoveredAudioUnreadable }
                let saved = try store.finish(id: recording.id, duration: duration, interrupted: true)
                try store.recordError(id: recording.id, message: "录音曾意外结束，已保存可恢复的部分。")
                onSaved?(store.recording(id: recording.id) ?? saved)
            } catch {
                let message = "录音恢复失败，原声文件已保留：\(error.localizedDescription)"
                self.error = message
                try? store.recordError(id: recording.id, message: message)
            }
        }
    }

    private func microphonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func checkFreeSpace() throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: store.root.path)
        guard let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw AudioCaptureError.capacityUnavailable
        }
        guard freeBytes >= minimumFreeBytes else { throw AudioCaptureError.lowSpace }
    }

    private func beginSegment() throws {
        try checkFreeSpace()
        let recording = try store.begin(source: source, intent: activeIntent, mode: mode)
        recordingID = recording.id

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let nextRecorder = try AVAudioRecorder(url: store.audioURL(for: recording), settings: settings)
            nextRecorder.delegate = self
            nextRecorder.isMeteringEnabled = true
            guard nextRecorder.record(forDuration: segmentDuration) else {
                throw AudioCaptureError.recorderDidNotStart
            }
            recorder = nextRecorder
            segmentCount += 1
            segmentStart = Date()
            lastKnownSegmentDuration = 0
            lastCapacityCheck = Date()
        } catch {
            if let recordingID {
                do {
                    try store.discardEmptyCapture(id: recordingID)
                } catch {
                    try? store.recordError(id: recordingID, message: "录音器启动失败；未删除恢复文件：\(error.localizedDescription)")
                }
                self.recordingID = nil
            }
            throw error
        }
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMeterAndCapacity() }
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshMeterAndCapacity() {
        guard isRecording, let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (power + 60) / 60))
        let runningDuration = min(segmentDuration, max(recorder.currentTime, segmentStart.map { Date().timeIntervalSince($0) } ?? 0))
        lastKnownSegmentDuration = max(lastKnownSegmentDuration, runningDuration)
        elapsed = accumulatedDuration + lastKnownSegmentDuration

        guard Date().timeIntervalSince(lastCapacityCheck) >= 15 else { return }
        lastCapacityCheck = Date()
        do {
            try checkFreeSpace()
        } catch {
            stopWithError("可用空间状态异常，录音已停止并保存：\(error.localizedDescription)", interrupted: true)
        }
    }

    private func stopWithError(_ message: String, interrupted: Bool) {
        guard isRecording || recordingID != nil else { return }
        isRecording = false
        error = message
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        finishCurrentSegment(interrupted: interrupted, message: message)
        deactivateAudioSession()
    }

    private func finishCurrentSegment(interrupted: Bool, message: String?) {
        guard let id = recordingID else { return }
        let activeRecorder = recorder
        let observedDuration = max(activeRecorder?.currentTime ?? 0, lastKnownSegmentDuration)
        activeRecorder?.delegate = nil
        activeRecorder?.stop()
        let duration = min(segmentDuration, max(observedDuration, closedFileDuration(for: id)))
        recorder = nil
        recordingID = nil
        segmentStart = nil
        lastKnownSegmentDuration = 0

        guard duration > 0 else {
            do {
                try store.discardEmptyCapture(id: id)
            } catch {
                let message = message ?? error.localizedDescription
                self.error = message
                try? store.recordError(id: id, message: message)
            }
            return
        }
        do {
            var saved = try store.finish(id: id, duration: duration, interrupted: interrupted)
            if let message { try store.recordError(id: id, message: message) }
            accumulatedDuration += duration
            elapsed = accumulatedDuration
            if message != nil, let updated = store.recording(id: id) { saved = updated }
            onSaved?(saved)
        } catch {
            let message = message ?? error.localizedDescription
            self.error = message
            try? store.recordError(id: id, message: message)
        }
    }

    private func observeAudioInterruptions() {
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleDeactivation(notification) }
        }
        notificationTokens.append(interruption)

        let reset = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopWithError("音频服务已重置，录音已停止并保存。", interrupted: true)
            }
        }
        notificationTokens.append(reset)
    }

    private func handleDeactivation(_ notification: Notification) {
        guard isRecording || recordingID != nil else { return }
        let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
        guard context?.source != .app else { return }
        let reason = context?.interruptionContext?.reason
        let message: String
        switch reason {
        case .default:
            message = "来电或其他应用占用音频，录音已停止并保存。"
        case .builtInMicMuted:
            message = "系统已静音麦克风，录音已停止并保存。"
        case .routeDisconnected:
            message = "录音音频设备已断开，录音已停止并保存。"
        default:
            message = "音频会话被系统停用，录音已停止并保存。"
        }
        stopWithError(message, interrupted: true)
    }

    private func deactivateAudioSession() {
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let recorderID = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in self?.segmentDidFinish(recorderID: recorderID, successfully: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let recorderID = ObjectIdentifier(recorder)
        let message = error?.localizedDescription ?? AudioCaptureError.encodingFailed.localizedDescription
        Task { @MainActor [weak self] in self?.segmentDidFail(recorderID: recorderID, message: message) }
    }

    private func segmentDidFinish(recorderID: ObjectIdentifier, successfully: Bool) {
        guard let recorder, ObjectIdentifier(recorder) == recorderID, recordingID != nil else { return }
        guard successfully else {
            stopWithError(AudioCaptureError.encodingFailed.localizedDescription, interrupted: true)
            return
        }
        finishCurrentSegment(interrupted: false, message: nil)
        guard isRecording else { return }
        do {
            try beginSegment()
        } catch {
            stopWithError("已保存前一段录音，但无法继续分段：\(error.localizedDescription)", interrupted: true)
        }
    }

    private func segmentDidFail(recorderID: ObjectIdentifier, message: String) {
        guard let recorder, ObjectIdentifier(recorder) == recorderID, recordingID != nil else { return }
        stopWithError("录音编码失败：\(message)", interrupted: true)
    }

    private func closedFileDuration(for id: UUID) -> TimeInterval {
        guard let recording = store.recording(id: id),
              let audio = try? AVAudioFile(forReading: store.audioURL(for: recording)) else { return 0 }
        let sampleRate = audio.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(audio.length) / sampleRate
    }
}

enum AudioCaptureDiscardError: LocalizedError {
    case noCurrentRecording
    case committedSegmentsExist
    case continuousRecordingCannotBeDiscarded
    case cancellationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCurrentRecording: return "当前没有可丢弃的录音。"
        case .committedSegmentsExist: return "较早的录音分段已保存，无法撤销整次录音；可以正常停止并保存当前段。"
        case .continuousRecordingCannotBeDiscarded: return "全天录音正在持续保存，不能丢弃当前分段；请正常停止录音。"
        case .cancellationFailed(let message): return message
        }
    }
}

enum AudioCaptureMarkerError: LocalizedError {
    case noActiveRecording
    case requiresContinuousMode

    var errorDescription: String? {
        switch self {
        case .noActiveRecording: return "当前没有正在录制的片段，无法添加标记。"
        case .requiresContinuousMode: return "只有连续录音中可以标记此刻。"
        }
    }
}

private enum AudioCaptureError: LocalizedError {
    case lowSpace
    case capacityUnavailable
    case recorderDidNotStart
    case encodingFailed
    case recoveredAudioUnreadable

    var errorDescription: String? {
        switch self {
        case .lowSpace: return "设备可用空间不足。"
        case .capacityUnavailable: return "无法读取设备剩余空间。"
        case .recorderDidNotStart: return "系统录音器未能启动。"
        case .encodingFailed: return "系统录音编码失败，已保存可恢复的部分。"
        case .recoveredAudioUnreadable: return "音频文件没有可恢复的时长。"
        }
    }
}
