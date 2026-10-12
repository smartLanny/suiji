import Foundation

enum StoreError: LocalizedError, Equatable {
    case missingRecording, missingAudio, invalidAudio, invalidTranscript, invalidDelivery, invalidManifest
    case draftNotDiscardable, recordingNotActive, invalidMarker, duplicateMarker
    var errorDescription: String? {
        switch self {
        case .missingRecording: return "找不到这条记录。"
        case .missingAudio: return "原声文件不可用。"
        case .invalidAudio: return "录音尚未完整保存，请保留原声后重试。"
        case .invalidTranscript: return "没有收到有效转写，原声会继续保留。"
        case .invalidDelivery: return "手机尚未确认保存这段录音。"
        case .invalidManifest: return "记录索引无法读取，原文件已保留。"
        case .draftNotDiscardable: return "只有尚未完成的本机录音草稿可以丢弃。"
        case .recordingNotActive: return "只能为正在录制的片段添加标记。"
        case .invalidMarker: return "标记时间无效。"
        case .duplicateMarker: return "这条标记已存在。"
        }
    }
}

final class RecordingStore: @unchecked Sendable {
    private struct Manifest: Codable {
        var version = 1
        var recordings: [Recording] = []
    }
    let root: URL
    private let audioDirectory: URL
    private let manifestURL: URL
    private let lock = NSRecursiveLock()
    private var manifest: Manifest

    init(root: URL) throws {
        self.root = root
        audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        manifestURL = root.appendingPathComponent("recordings.json")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.version == 1 else { throw StoreError.invalidManifest }
            for index in manifest.recordings.indices where manifest.recordings[index].transcriptionState == .transcribing {
                manifest.recordings[index].transcriptionState = .pending
            }
        } else {
            manifest = Manifest()
        }
        try write(manifest)
        try protect(root)
        try protect(audioDirectory)
    }

    func all() -> [Recording] {
        lock.lock(); defer { lock.unlock() }
        return manifest.recordings.sorted { $0.recordedAt > $1.recordedAt }
    }

    func recording(id: UUID) -> Recording? {
        lock.lock(); defer { lock.unlock() }
        return manifest.recordings.first { $0.id == id }
    }

    func audioURL(for recording: Recording) -> URL {
        audioDirectory.appendingPathComponent(recording.id.uuidString + ".m4a")
    }

    func begin(source: RecordingSource, intent: RecordingIntent = .note, mode: RecordingMode = .quick) throws -> Recording {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        let recording = Recording(id: id, recordedAt: Date(), duration: 0, source: source,
                                  fileName: id.uuidString + ".m4a", byteCount: 0,
                                  captureState: .recording, transcriptionState: .pending,
                                  transcript: nil, lastError: nil, phoneReceivedAt: nil,
                                  isKept: false, audioDeletedAt: nil, intent: intent, mode: mode)
        var next = manifest
        next.recordings.append(recording)
        try commit(next)
        return recording
    }

    @discardableResult
    func finish(id: UUID, duration: Double, interrupted: Bool = false) throws -> Recording {
        lock.lock(); defer { lock.unlock() }
        guard let recording = recording(id: id) else { throw StoreError.missingRecording }
        let url = audioURL(for: recording)
        let size = try sizeOfFile(url)
        guard size > 0, duration.isFinite, duration > 0 else { throw StoreError.invalidAudio }
        try protect(url)
        try update(id: id) {
            $0.duration = duration
            $0.byteCount = size
            $0.captureState = interrupted ? .interrupted : .ready
            $0.lastError = interrupted ? "录音曾中断，已保存可恢复的部分。" : nil
        }
        return self.recording(id: id)!
    }

    @discardableResult
    func importClip(from temporaryURL: URL, envelope: ClipEnvelope) throws -> Recording {
        lock.lock(); defer { lock.unlock() }
        guard envelope.source == .watch, envelope.duration.isFinite, envelope.duration > 0,
              envelope.byteCount > 0, try sizeOfFile(temporaryURL) == envelope.byteCount else { throw StoreError.invalidAudio }
        guard envelope.markers.allSatisfy({ $0.offset.isFinite && $0.offset >= 0 }) else { throw StoreError.invalidMarker }
        if let existing = recording(id: envelope.id) {
            guard existing.source == envelope.source, existing.byteCount == envelope.byteCount else { throw StoreError.invalidAudio }
            if existing.audioDeletedAt != nil || FileManager.default.fileExists(atPath: audioURL(for: existing).path) {
                return existing
            }
        }
        let recording = Recording(id: envelope.id, recordedAt: envelope.recordedAt, duration: envelope.duration,
                                  source: envelope.source, fileName: envelope.fileName, byteCount: envelope.byteCount,
                                  captureState: .ready, transcriptionState: .pending, transcript: nil,
                                  lastError: nil, phoneReceivedAt: Date(), isKept: false, audioDeletedAt: nil,
                                  intent: envelope.intent, mode: envelope.mode, markers: envelope.markers)
        let destination = audioURL(for: recording)
        // An interrupted import may have copied the file before committing the manifest.
        if !FileManager.default.fileExists(atPath: destination.path) {
            let staging = audioDirectory.appendingPathComponent(UUID().uuidString + ".incoming")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: temporaryURL, to: staging)
            try protect(staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        guard try sizeOfFile(destination) == envelope.byteCount else { throw StoreError.invalidAudio }
        var next = manifest
        if let index = next.recordings.firstIndex(where: { $0.id == recording.id }) {
            next.recordings[index].phoneReceivedAt = Date()
        } else {
            next.recordings.append(recording)
        }
        try commit(next)
        return self.recording(id: recording.id)!
    }

    func acknowledge(id: UUID, at: Date = Date()) throws {
        try update(id: id) { $0.phoneReceivedAt = at; $0.lastError = nil }
    }

    func deleteDeliveredWatchAudio(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let recording = recording(id: id), recording.source == .watch,
              recording.phoneReceivedAt != nil, recording.captureState != .recording else { throw StoreError.invalidDelivery }
        try deleteAudio(recording, at: Date())
    }

    func recordError(id: UUID, message: String) throws {
        try update(id: id) { $0.lastError = message }
    }

    func addMarker(id: UUID, marker: RecordingMarker) throws {
        lock.lock(); defer { lock.unlock() }
        guard marker.offset.isFinite, marker.offset >= 0 else { throw StoreError.invalidMarker }
        guard let index = manifest.recordings.firstIndex(where: { $0.id == id }) else { throw StoreError.missingRecording }
        guard manifest.recordings[index].captureState == .recording else { throw StoreError.recordingNotActive }
        guard !manifest.recordings[index].markers.contains(where: { $0.id == marker.id }) else { throw StoreError.duplicateMarker }
        var next = manifest
        next.recordings[index].markers.append(marker)
        try commit(next)
    }

    func discardEmptyCapture(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let recording = recording(id: id), recording.captureState == .recording else { return }
        let url = audioURL(for: recording)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists, try sizeOfFile(url) > 0 { throw StoreError.invalidAudio }
        var next = manifest
        next.recordings.removeAll { $0.id == id }
        try commit(next)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func discardDraft(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let recording = recording(id: id) else { throw StoreError.missingRecording }
        guard recording.captureState == .recording,
              recording.phoneReceivedAt == nil,
              recording.audioDeletedAt == nil else { throw StoreError.draftNotDiscardable }

        let url = audioURL(for: recording)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        var next = manifest
        next.recordings.removeAll { $0.id == id }
        try commit(next)
    }

    func setTranscribing(id: UUID) throws {
        try update(id: id) { $0.transcriptionState = .transcribing; $0.lastError = nil }
    }

    func completeTranscription(id: UUID, text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StoreError.invalidTranscript }
        try update(id: id) {
            $0.transcript = text
            $0.transcriptionState = .completed
            $0.lastError = nil
        }
    }

    func failTranscription(id: UUID, message: String) throws {
        try update(id: id) { $0.transcriptionState = .failed; $0.lastError = message }
    }

    func retryTranscription(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let recording = recording(id: id), recording.audioDeletedAt == nil,
              recording.captureState != .recording,
              FileManager.default.fileExists(atPath: audioURL(for: recording).path) else { throw StoreError.missingAudio }
        try update(id: id) { $0.transcriptionState = .pending; $0.lastError = nil }
    }

    func setKept(id: UUID, kept: Bool) throws { try update(id: id) { $0.isKept = kept } }

    func expiredAudio(policy: RetentionPolicy, now: Date = Date()) -> [Recording] {
        all().filter { policy.canDelete($0, now: now) }
    }

    @discardableResult
    func cleanup(policy: RetentionPolicy, now: Date = Date()) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let expired = expiredAudio(policy: policy, now: now)
        for recording in expired { try deleteAudio(recording, at: now) }
        return expired.count
    }

    private func deleteAudio(_ recording: Recording, at: Date) throws {
        let url = audioURL(for: recording)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try update(id: recording.id) { $0.audioDeletedAt = at }
    }

    private func update(id: UUID, change: (inout Recording) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var next = manifest
        guard let index = next.recordings.firstIndex(where: { $0.id == id }) else { throw StoreError.missingRecording }
        change(&next.recordings[index])
        try commit(next)
    }

    private func commit(_ next: Manifest) throws {
        try write(next)
        manifest = next
    }

    private func write(_ next: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: manifestURL, options: .atomic)
        try protect(manifestURL)
    }

    private func sizeOfFile(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func protect(_ url: URL) throws {
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
