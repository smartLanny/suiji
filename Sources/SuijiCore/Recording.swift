import Foundation

enum RecordingSource: String, Codable, Sendable { case phone, watch }
enum CaptureState: String, Codable, Sendable { case recording, ready, interrupted }
enum TranscriptionState: String, Codable, Sendable { case pending, transcribing, completed, failed }

struct Recording: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var recordedAt: Date
    var duration: Double
    var source: RecordingSource
    var fileName: String
    var byteCount: Int64
    var captureState: CaptureState
    var transcriptionState: TranscriptionState
    var transcript: String?
    var lastError: String?
    var phoneReceivedAt: Date?
    var isKept: Bool
    var audioDeletedAt: Date?

    var title: String {
        guard let text = transcript, !text.isEmpty else { return "一段新记录" }
        return String(text.prefix(38)).replacingOccurrences(of: "\n", with: " ")
    }

    var isReadyForTranscription: Bool {
        captureState != .recording && audioDeletedAt == nil && byteCount > 0
            && transcriptionState == .pending
    }
}

struct ClipEnvelope: Codable, Equatable, Sendable {
    let id: UUID
    let recordedAt: Date
    let duration: Double
    let source: RecordingSource
    let byteCount: Int64

    init(recording: Recording) {
        id = recording.id
        recordedAt = recording.recordedAt
        duration = recording.duration
        source = recording.source
        byteCount = recording.byteCount
    }

    var fileName: String { id.uuidString + ".m4a" }
}

struct RetentionPolicy: Codable, Equatable, Sendable {
    // nil means that automatic deletion is disabled.
    var days: Int? = 30

    func expiryDate(for recording: Recording) -> Date? {
        guard let days, days > 0 else { return nil }
        return recording.recordedAt.addingTimeInterval(Double(days) * 86_400)
    }

    func canDelete(_ recording: Recording, now: Date) -> Bool {
        guard !recording.isKept, recording.audioDeletedAt == nil,
              recording.captureState != .recording,
              recording.transcriptionState == .completed,
              let transcript = recording.transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expiry = expiryDate(for: recording), expiry <= now else { return false }
        return recording.source == .phone || recording.phoneReceivedAt != nil
    }
}
