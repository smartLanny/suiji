import AVFAudio
import Combine
import Foundation

@MainActor
final class AudioCapture: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var error: String?
    @Published private(set) var mode: RecordingMode = .quick

    private let store: RecordingStore
    private let source: RecordingSource
    private let diagnostics: CaptureDiagnostics
    private let audioSession = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var writer: ContinuousAudioWriter?
    private var captureToken: UUID?
    private var tapInstalled = false
    private var progressMonitor = RecordingProgressMonitor()
    private var cancelPendingStart = false
    private var meterTimer: Timer?
    private var lastCapacityCheck = Date.distantPast
    private var notificationTokens: [NSObjectProtocol] = []
    private var segmentDuration: TimeInterval = 5 * 60
    private let minimumFreeBytes: Int64 = 24 * 1024 * 1024

    var onSaved: ((Recording) -> Void)?

    init(store: RecordingStore, source: RecordingSource, diagnostics: CaptureDiagnostics? = nil) {
        self.store = store
        self.source = source
        self.diagnostics = diagnostics ?? CaptureDiagnostics(root: store.root)
        super.init()
        self.diagnostics.startIfRequested { [weak self] in self?.diagnosticSnapshot() }
        observeAudioInterruptions()
        recover()
    }

    deinit {
        meterTimer?.invalidate()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    var canDiscardRecording: Bool {
        guard isRecording, mode == .quick, let writer else { return false }
        let snapshot = writer.snapshot
        return snapshot.recordingID != nil && snapshot.completedSegments == 0
            && Double(writer.receivedFrames) / writer.sampleRate <= segmentDuration
    }

    func start(intent: RecordingIntent = .note, mode: RecordingMode = .quick) async {
        guard !isRecording, !isStarting, writer == nil else { return }
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
            diagnostics.record("session_activation", details: ["outcome": "success"])
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let token = UUID()
            captureToken = token
            let testConfiguration = diagnostics.testSegmentConfiguration
            segmentDuration = testConfiguration?.duration ?? 5 * 60
            let writer = try ContinuousAudioWriter(store: store, source: source, intent: intent, mode: mode,
                                                    format: format, segmentDuration: segmentDuration,
                                                    shortSegmentDeadline: testConfiguration?.deadline) { [weak self] event in
                let occurredAt = Date()
                Task { @MainActor [weak self] in self?.handleWriterEvent(event, token: token, at: occurredAt) }
            }
            self.engine = engine
            self.writer = writer
            self.mode = mode
            elapsed = 0
            try writer.start()
            let bufferFrames = AVAudioFrameCount((format.sampleRate * 0.1).rounded())
            try input.installAudioTap(onBus: 0, bufferSize: bufferFrames, format: format) { buffer, when in
                writer.submit(buffer, at: when)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            isRecording = true
            progressMonitor.reset(at: ProcessInfo.processInfo.systemUptime)
            lastCapacityCheck = Date()
            diagnostics.record("start", details: ["mode": mode.rawValue, "backend": "continuous_engine",
                                                  "sampleRate": String(format.sampleRate),
                                                  "channels": String(format.channelCount)])
            startMeterTimer()
        } catch {
            haltInput()
            let closingError = writer?.finish(interrupted: true, message: error.localizedDescription)
            writer = nil
            captureToken = nil
            isRecording = false
            self.error = "录音未启动：\(closingError ?? error.localizedDescription)"
            deactivateAudioSession()
        }
    }

    func stop() {
        if isStarting { cancelPendingStart = true; return }
        guard isRecording || writer != nil else { return }
        finishCapture(interrupted: false, message: nil)
    }

    func clearError() { error = nil }

    func noteLifecycle(scenePhase: String, isLuminanceReduced: Bool) {
        diagnostics.noteLifecycle(scenePhase: scenePhase, isLuminanceReduced: isLuminanceReduced)
        if scenePhase == "active" { refreshMeterAndCapacity() }
    }

    func discardCurrentRecording() throws {
        guard isRecording, let writer else { throw AudioCaptureDiscardError.noCurrentRecording }
        guard mode == .quick else { throw AudioCaptureDiscardError.continuousRecordingCannotBeDiscarded }
        guard canDiscardRecording else { throw AudioCaptureDiscardError.committedSegmentsExist }
        isRecording = false
        diagnostics.record("stop", details: ["kind": "discard"])
        haltInput()
        defer {
            self.writer = nil
            captureToken = nil
            level = 0
            deactivateAudioSession()
        }
        do {
            try writer.discard()
            elapsed = 0
            mode = .quick
            error = nil
        } catch {
            elapsed = Double(writer.snapshot.writtenFrames) / writer.sampleRate
            self.error = error.localizedDescription
            throw error
        }
    }

    func mark(intent: RecordingIntent = .note) throws -> RecordingMarker {
        guard isRecording, let writer else { throw AudioCaptureMarkerError.noActiveRecording }
        guard mode == .continuous else { throw AudioCaptureMarkerError.requiresContinuousMode }
        return try writer.mark(intent: intent)
    }

    func recover() {
        guard !isStarting, !isRecording, writer == nil else { return }
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
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in continuation.resume(returning: granted) }
            }
        @unknown default: return false
        }
    }

    private func checkFreeSpace() throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: store.root.path)
        guard let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            throw AudioCaptureError.capacityUnavailable
        }
        guard freeBytes >= minimumFreeBytes else { throw AudioCaptureError.lowSpace }
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
        guard isRecording, let writer else { return }
        let snapshot = writer.snapshot
        level = snapshot.level
        elapsed = Double(writer.receivedFrames) / writer.sampleRate
        if let failure = snapshot.failure { stopWithError(failure); return }
        if progressMonitor.observe(audioTime: elapsed, at: ProcessInfo.processInfo.systemUptime) {
            diagnostics.record("progress_stalled", details: ["audioTime": String(elapsed)])
            stopWithError("录音没有继续收音，已停止并保存。请重新开始。")
            return
        }
        guard Date().timeIntervalSince(lastCapacityCheck) >= 15 else { return }
        lastCapacityCheck = Date()
        do { try checkFreeSpace() }
        catch { stopWithError("可用空间状态异常，录音已停止并保存：\(error.localizedDescription)") }
    }

    private func haltInput() {
        meterTimer?.invalidate()
        meterTimer = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine = nil
    }

    private func finishCapture(interrupted: Bool, message: String?) {
        isRecording = false
        diagnostics.record("stop", details: ["kind": interrupted ? "error" : "user",
                                             "interrupted": String(interrupted)])
        haltInput()
        if let writer {
            let closingError = writer.finish(interrupted: interrupted, message: message)
            elapsed = Double(writer.snapshot.writtenFrames) / writer.sampleRate
            error = closingError ?? message
        }
        writer = nil
        captureToken = nil
        level = 0
        deactivateAudioSession()
    }

    private func stopWithError(_ message: String) {
        guard isRecording || writer != nil else { return }
        finishCapture(interrupted: true, message: message)
    }

    private func handleWriterEvent(_ event: ContinuousAudioEvent, token: UUID, at occurredAt: Date) {
        switch event {
        case let .began(recording, timing):
            diagnostics.record("segment_begin", details: ["segmentUUID": recording.id.uuidString,
                                                           "segmentDurationSeconds": timing["segmentDurationSeconds"] ?? String(segmentDuration)], at: occurredAt)
            diagnostics.record("segment_timing", details: timing, at: occurredAt)
        case let .saved(recording, timing):
            diagnostics.record("segment_finish", details: ["segmentUUID": recording.id.uuidString,
                                                            "durationSeconds": String(recording.duration),
                                                            "outcome": recording.captureState == .interrupted ? "interrupted" : "saved"], at: occurredAt)
            diagnostics.record("segment_timing", details: timing, at: occurredAt)
            onSaved?(recording)
        case let .failed(message):
            guard captureToken == token else { return }
            diagnostics.record("encodeerror", details: ["kind": "continuous_writer"], at: occurredAt)
            stopWithError(message)
        }
    }

    private func observeAudioInterruptions() {
        let activation = NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeActiveNotification,
                                                                object: audioSession, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.diagnostics.record("session_active") }
        }
        notificationTokens.append(activation)
        let interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification,
                                                                  object: audioSession, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.handleDeactivation(notification) }
        }
        notificationTokens.append(interruption)
        let reset = NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                           object: audioSession, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.diagnostics.record("interruption", details: ["kind": "media_services_reset"])
                self?.stopWithError("音频服务已重置，录音已停止并保存。")
            }
        }
        notificationTokens.append(reset)
        let configuration = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                   object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let changed = notification.object as? AVAudioEngine, changed === self.engine else { return }
                self.diagnostics.record("interruption", details: ["kind": "engine_configuration_change"])
                self.stopWithError("麦克风音频格式改变，录音已停止并保存。请重新开始。")
            }
        }
        notificationTokens.append(configuration)
    }

    private func handleDeactivation(_ notification: Notification) {
        let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
        diagnostics.record("session_inactive", details: ["source": context.map { String($0.source.rawValue) } ?? "unknown",
                                                        "reason": context?.interruptionContext.map { String($0.reason.rawValue) } ?? "none"])
        guard isRecording || writer != nil, context?.source != .app else { return }
        let reason = context?.interruptionContext?.reason
        let message: String
        switch reason {
        case .default: message = "来电或其他应用占用音频，录音已停止并保存。"
        case .builtInMicMuted: message = "系统已静音麦克风，录音已停止并保存。"
        case .routeDisconnected: message = "录音音频设备已断开，录音已停止并保存。"
        default: message = "音频会话被系统停用，录音已停止并保存。"
        }
        diagnostics.record("interruption", details: ["kind": String(describing: reason ?? .default)])
        stopWithError(message)
    }

    private func deactivateAudioSession() { try? audioSession.setActive(false, options: .notifyOthersOnDeactivation) }

    private func diagnosticSnapshot() -> CaptureDiagnosticSnapshot {
        let snapshot = writer?.snapshot
        let rate = writer?.sampleRate ?? 1
        return CaptureDiagnosticSnapshot(recorderCurrentTime: snapshot.map { Double($0.segmentFrames) / rate },
                                         recorderIsRecording: engine.map { $0.isRunning && snapshot?.failure == nil },
                                         meterLevel: level, logicalIsRecording: isRecording, elapsedEstimate: elapsed,
                                         currentSegmentUUID: snapshot?.recordingID?.uuidString,
                                         accumulatedDuration: snapshot.map { Double($0.writtenFrames - $0.segmentFrames) / rate } ?? elapsed)
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
    case recoveredAudioUnreadable

    var errorDescription: String? {
        switch self {
        case .lowSpace: return "设备可用空间不足。"
        case .capacityUnavailable: return "无法读取设备剩余空间。"
        case .recoveredAudioUnreadable: return "音频文件没有可恢复的时长。"
        }
    }
}
