import Foundation

enum RecordingSource: String, Codable, Sendable { case phone, watch }
enum CaptureState: String, Codable, Sendable { case recording, ready, interrupted }
enum TranscriptionState: String, Codable, Sendable { case pending, transcribing, completed, failed }
enum RecordingIntent: String, Codable, Sendable { case note, journal }
enum RecordingMode: String, Codable, Sendable { case quick, continuous }

struct RecordingMarker: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var offset: Double
    var intent: RecordingIntent
}

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
    var intent: RecordingIntent = .note
    var mode: RecordingMode = .quick
    var markers: [RecordingMarker] = []

    var title: String {
        guard let text = transcript, !text.isEmpty else { return intent == .journal ? "一段日记" : "一段新记录" }
        return String(text.prefix(38)).replacingOccurrences(of: "\n", with: " ")
    }

    var isReadyForTranscription: Bool {
        captureState != .recording && audioDeletedAt == nil && byteCount > 0
            && transcriptionState == .pending
    }
}

extension Recording {
    private enum CodingKeys: String, CodingKey {
        case id, recordedAt, duration, source, fileName, byteCount, captureState
        case transcriptionState, transcript, lastError, phoneReceivedAt, isKept, audioDeletedAt
        case intent, mode, markers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        recordedAt = try values.decode(Date.self, forKey: .recordedAt)
        duration = try values.decode(Double.self, forKey: .duration)
        source = try values.decode(RecordingSource.self, forKey: .source)
        fileName = try values.decode(String.self, forKey: .fileName)
        byteCount = try values.decode(Int64.self, forKey: .byteCount)
        captureState = try values.decode(CaptureState.self, forKey: .captureState)
        transcriptionState = try values.decode(TranscriptionState.self, forKey: .transcriptionState)
        transcript = try values.decodeIfPresent(String.self, forKey: .transcript)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        phoneReceivedAt = try values.decodeIfPresent(Date.self, forKey: .phoneReceivedAt)
        isKept = try values.decode(Bool.self, forKey: .isKept)
        audioDeletedAt = try values.decodeIfPresent(Date.self, forKey: .audioDeletedAt)
        intent = try values.decodeIfPresent(RecordingIntent.self, forKey: .intent) ?? .note
        mode = try values.decodeIfPresent(RecordingMode.self, forKey: .mode) ?? .quick
        markers = try values.decodeIfPresent([RecordingMarker].self, forKey: .markers) ?? []
    }
}

struct ClipEnvelope: Codable, Equatable, Sendable {
    let id: UUID
    let recordedAt: Date
    let duration: Double
    let source: RecordingSource
    let byteCount: Int64
    var intent: RecordingIntent = .note
    var mode: RecordingMode = .quick
    var markers: [RecordingMarker] = []

    init(recording: Recording) {
        id = recording.id
        recordedAt = recording.recordedAt
        duration = recording.duration
        source = recording.source
        byteCount = recording.byteCount
        intent = recording.intent
        mode = recording.mode
        markers = recording.markers
    }

    var fileName: String { id.uuidString + ".m4a" }
}

extension ClipEnvelope {
    private enum CodingKeys: String, CodingKey { case id, recordedAt, duration, source, byteCount, intent, mode, markers }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        recordedAt = try values.decode(Date.self, forKey: .recordedAt)
        duration = try values.decode(Double.self, forKey: .duration)
        source = try values.decode(RecordingSource.self, forKey: .source)
        byteCount = try values.decode(Int64.self, forKey: .byteCount)
        intent = try values.decodeIfPresent(RecordingIntent.self, forKey: .intent) ?? .note
        mode = try values.decodeIfPresent(RecordingMode.self, forKey: .mode) ?? .quick
        markers = try values.decodeIfPresent([RecordingMarker].self, forKey: .markers) ?? []
    }
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
