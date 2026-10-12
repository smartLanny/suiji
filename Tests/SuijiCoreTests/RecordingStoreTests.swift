import XCTest
@testable import SuijiCore

final class RecordingStoreTests: XCTestCase {
    private var directory: URL!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try RecordingStore(root: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCompletedCaptureSurvivesRestartAndInterruptedTranscriptionRequeues() throws {
        let clip = try makeCapture()
        try store.setTranscribing(id: clip.id)
        let reopened = try RecordingStore(root: directory)
        let saved = try XCTUnwrap(reopened.recording(id: clip.id))
        XCTAssertEqual(saved.captureState, .ready)
        XCTAssertEqual(saved.transcriptionState, .pending)
        XCTAssertEqual(saved.byteCount, 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(for: saved).path))
    }

    func testReceivedClipIsCopiedBeforeTemporaryFileDisappearsAndDeduplicated() throws {
        let clip = fixture()
        let transfer = directory.appendingPathComponent("transfer.m4a")
        try Data(repeating: 9, count: 12).write(to: transfer)
        let first = try store.importClip(from: transfer, envelope: ClipEnvelope(recording: clip))
        let second = try store.importClip(from: transfer, envelope: ClipEnvelope(recording: clip))
        try FileManager.default.removeItem(at: transfer)
        let reopened = try RecordingStore(root: directory)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertNotNil(reopened.recording(id: clip.id)?.phoneReceivedAt)
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL(for: first)).count, 12)
    }

    func testIncompleteTransferDoesNotCreateReceipt() throws {
        let clip = fixture()
        let transfer = directory.appendingPathComponent("transfer.m4a")
        try Data([1, 2]).write(to: transfer)
        XCTAssertThrowsError(try store.importClip(from: transfer, envelope: ClipEnvelope(recording: clip)))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testJournalIntentSurvivesEnvelopeAndPhoneImport() throws {
        let draft = try store.begin(source: .watch, intent: .journal)
        let audioURL = store.audioURL(for: draft)
        try Data(repeating: 7, count: 12).write(to: audioURL)
        let saved = try store.finish(id: draft.id, duration: 8)
        let envelopeData = try JSONEncoder().encode(ClipEnvelope(recording: saved))
        let envelope = try JSONDecoder().decode(ClipEnvelope.self, from: envelopeData)
        let phoneStore = try RecordingStore(root: directory.appendingPathComponent("phone", isDirectory: true))

        let imported = try phoneStore.importClip(from: audioURL, envelope: envelope)

        XCTAssertEqual(envelope.intent, .journal)
        XCTAssertEqual(imported.intent, .journal)
        XCTAssertEqual(imported.title, "一段日记")
    }

    func testContinuousModeAndMarkersSurviveRestartAndEnvelopeImport() throws {
        let draft = try store.begin(source: .watch, mode: .continuous)
        let audioURL = store.audioURL(for: draft)
        try Data(repeating: 7, count: 12).write(to: audioURL)
        let note = RecordingMarker(id: UUID(), offset: 2.5, intent: .note)
        let journal = RecordingMarker(id: UUID(), offset: 7.25, intent: .journal)
        try store.addMarker(id: draft.id, marker: note)
        try store.addMarker(id: draft.id, marker: journal)

        let reopened = try RecordingStore(root: directory)
        XCTAssertEqual(reopened.recording(id: draft.id)?.mode, .continuous)
        XCTAssertEqual(reopened.recording(id: draft.id)?.markers, [note, journal])
        let saved = try reopened.finish(id: draft.id, duration: 8)
        let encoded = try JSONEncoder().encode(ClipEnvelope(recording: saved))
        let envelope = try JSONDecoder().decode(ClipEnvelope.self, from: encoded)
        let phoneStore = try RecordingStore(root: directory.appendingPathComponent("phone", isDirectory: true))

        let imported = try phoneStore.importClip(from: audioURL, envelope: envelope)

        XCTAssertEqual(envelope.mode, .continuous)
        XCTAssertEqual(envelope.markers, [note, journal])
        XCTAssertEqual(imported.mode, .continuous)
        XCTAssertEqual(imported.markers, [note, journal])
    }

    func testMarkersRejectInvalidOffsetsAndCompletedRecordings() throws {
        let draft = try store.begin(source: .phone, mode: .continuous)
        try Data(repeating: 8, count: 12).write(to: store.audioURL(for: draft))
        XCTAssertThrowsError(try store.addMarker(id: draft.id,
                                                  marker: RecordingMarker(id: UUID(), offset: .nan, intent: .note))) { error in
            XCTAssertEqual(error as? StoreError, .invalidMarker)
        }
        XCTAssertThrowsError(try store.addMarker(id: draft.id,
                                                  marker: RecordingMarker(id: UUID(), offset: -.infinity, intent: .note))) { error in
            XCTAssertEqual(error as? StoreError, .invalidMarker)
        }

        let marker = RecordingMarker(id: UUID(), offset: 3, intent: .journal)
        try store.addMarker(id: draft.id, marker: marker)
        let saved = try store.finish(id: draft.id, duration: 8)
        XCTAssertThrowsError(try store.addMarker(id: saved.id,
                                                  marker: RecordingMarker(id: UUID(), offset: 4, intent: .note))) { error in
            XCTAssertEqual(error as? StoreError, .recordingNotActive)
        }
        XCTAssertEqual(store.recording(id: saved.id)?.markers, [marker])
    }

    func testLegacyManifestAndEnvelopeDefaultMissingIntentToNote() throws {
        let oldRecording = fixture()
        var oldRecordingJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldRecording)) as? [String: Any])
        oldRecordingJSON.removeValue(forKey: "intent")
        oldRecordingJSON.removeValue(forKey: "mode")
        oldRecordingJSON.removeValue(forKey: "markers")
        let oldManifest = try JSONSerialization.data(withJSONObject: ["version": 1, "recordings": [oldRecordingJSON]], options: [.sortedKeys])
        try oldManifest.write(to: directory.appendingPathComponent("recordings.json"))

        let reopened = try RecordingStore(root: directory)
        XCTAssertEqual(reopened.recording(id: oldRecording.id)?.intent, .note)
        XCTAssertEqual(reopened.recording(id: oldRecording.id)?.mode, .quick)
        XCTAssertEqual(reopened.recording(id: oldRecording.id)?.markers, [])

        let oldClip = fixture()
        var oldEnvelopeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ClipEnvelope(recording: oldClip))) as? [String: Any])
        oldEnvelopeJSON.removeValue(forKey: "intent")
        oldEnvelopeJSON.removeValue(forKey: "mode")
        oldEnvelopeJSON.removeValue(forKey: "markers")
        let oldEnvelopeData = try JSONSerialization.data(withJSONObject: oldEnvelopeJSON, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(ClipEnvelope.self, from: oldEnvelopeData)
        let transfer = directory.appendingPathComponent("legacy-transfer.m4a")
        try Data(repeating: 4, count: Int(oldClip.byteCount)).write(to: transfer)

        let imported = try reopened.importClip(from: transfer, envelope: decoded)

        XCTAssertEqual(decoded.intent, .note)
        XCTAssertEqual(decoded.mode, .quick)
        XCTAssertEqual(decoded.markers, [])
        XCTAssertEqual(imported.intent, .note)
        XCTAssertEqual(imported.mode, .quick)
        XCTAssertEqual(imported.markers, [])
    }

    func testDiscardDraftRemovesOnlyUnfinishedCapture() throws {
        let draft = try store.begin(source: .phone, intent: .journal)
        let draftURL = store.audioURL(for: draft)
        try Data(repeating: 3, count: 12).write(to: draftURL)
        let ready = try makeCapture()
        let acknowledged = try makeCapture(source: .watch)
        try store.acknowledge(id: acknowledged.id)

        XCTAssertThrowsError(try store.discardDraft(id: ready.id))
        XCTAssertThrowsError(try store.discardDraft(id: acknowledged.id))
        try store.discardDraft(id: draft.id)

        XCTAssertNil(store.recording(id: draft.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertEqual(store.recording(id: ready.id), ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: ready).path))
        XCTAssertNotNil(store.recording(id: acknowledged.id)?.phoneReceivedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: acknowledged).path))
    }

    func testDraftAudioRemovalFailureKeepsDraftAndSavedAudio() throws {
        let draft = try store.begin(source: .watch, intent: .journal)
        let draftURL = store.audioURL(for: draft)
        try Data(repeating: 5, count: 12).write(to: draftURL)
        let ready = try makeCapture()
        let audioDirectory = directory.appendingPathComponent("Audio", isDirectory: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: audioDirectory.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: audioDirectory.path)

        XCTAssertThrowsError(try store.discardDraft(id: draft.id))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: audioDirectory.path)
        XCTAssertEqual(store.recording(id: draft.id)?.captureState, .recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertEqual(store.recording(id: ready.id), ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: ready).path))
    }

    func testDraftIndexWriteFailureLeavesRecoverableEmptyDraft() throws {
        let draft = try store.begin(source: .phone)
        let draftURL = store.audioURL(for: draft)
        try Data(repeating: 6, count: 12).write(to: draftURL)
        let ready = try makeCapture()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        XCTAssertThrowsError(try store.discardDraft(id: draft.id))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let emptyDraft = try XCTUnwrap(store.recording(id: draft.id))
        XCTAssertEqual(emptyDraft.captureState, .recording)
        XCTAssertEqual(emptyDraft.byteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertEqual(store.recording(id: ready.id), ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: ready).path))

        try store.discardEmptyCapture(id: draft.id)
        XCTAssertNil(store.recording(id: draft.id))
    }

    func testWatchDoesNotDeleteUntilPhoneAcknowledgesDurableSave() throws {
        let clip = try makeCapture(source: .watch)
        XCTAssertThrowsError(try store.deleteDeliveredWatchAudio(id: clip.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: clip).path))
        try store.acknowledge(id: clip.id)
        try store.deleteDeliveredWatchAudio(id: clip.id)
        let reopened = try RecordingStore(root: directory)
        XCTAssertNotNil(reopened.recording(id: clip.id)?.audioDeletedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: clip).path))
    }

    func testEmptyOrFailedTranscriptCannotMakeAudioEligibleForDeletion() throws {
        let clip = try makeCapture()
        XCTAssertThrowsError(try store.completeTranscription(id: clip.id, text: " \n"))
        try store.failTranscription(id: clip.id, message: "断网")
        let future = Date().addingTimeInterval(100 * 86_400)
        XCTAssertEqual(try store.cleanup(policy: RetentionPolicy(days: 1), now: future), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: clip).path))
        try store.retryTranscription(id: clip.id)
        XCTAssertEqual(store.recording(id: clip.id)?.transcriptionState, .pending)
    }

    func testThirtyDayExpiryRemovesOnlyAudioAndKeepsTranscriptAfterRestart() throws {
        let clip = try makeCapture()
        try store.completeTranscription(id: clip.id, text: "  咖啡馆的通话测试  ")
        XCTAssertEqual(try store.cleanup(policy: RetentionPolicy(), now: clip.recordedAt.addingTimeInterval(29 * 86_400)), 0)
        XCTAssertEqual(try store.cleanup(policy: RetentionPolicy(), now: clip.recordedAt.addingTimeInterval(30 * 86_400)), 1)
        let reopened = try RecordingStore(root: directory)
        XCTAssertEqual(reopened.recording(id: clip.id)?.transcript, "咖啡馆的通话测试")
        XCTAssertNotNil(reopened.recording(id: clip.id)?.audioDeletedAt)
        XCTAssertThrowsError(try reopened.retryTranscription(id: clip.id))
    }

    func testPinnedAndPermanentPolicyProtectCompletedAudio() throws {
        let clip = try makeCapture()
        try store.completeTranscription(id: clip.id, text: "保留原声")
        let future = Date().addingTimeInterval(400 * 86_400)
        XCTAssertEqual(try store.cleanup(policy: RetentionPolicy(days: nil), now: future), 0)
        try store.setKept(id: clip.id, kept: true)
        XCTAssertEqual(try store.cleanup(policy: RetentionPolicy(days: 1), now: future), 0)
        try store.setKept(id: clip.id, kept: false)
        XCTAssertEqual(try store.cleanup(policy: RetentionPolicy(days: 365), now: future), 1)
    }

    func testChangingRetentionCanShortenOrLengthenWindow() {
        var clip = fixture()
        clip.transcriptionState = .completed
        clip.transcript = "有效文字"
        clip.phoneReceivedAt = Date()
        let now = clip.recordedAt.addingTimeInterval(15 * 86_400)
        XCTAssertTrue(RetentionPolicy(days: 7).canDelete(clip, now: now))
        XCTAssertFalse(RetentionPolicy(days: 30).canDelete(clip, now: now))
        clip.phoneReceivedAt = nil
        XCTAssertFalse(RetentionPolicy(days: 7).canDelete(clip, now: now))
    }

    func testDuplicateAfterRetentionDoesNotRecreateExpiredAudio() throws {
        let clip = fixture()
        let transfer = directory.appendingPathComponent("transfer.m4a")
        try Data(repeating: 9, count: 12).write(to: transfer)
        let saved = try store.importClip(from: transfer, envelope: ClipEnvelope(recording: clip))
        try store.completeTranscription(id: saved.id, text: "文字已保存")
        try store.cleanup(policy: RetentionPolicy(days: 1), now: saved.recordedAt.addingTimeInterval(2 * 86_400))
        let duplicate = try store.importClip(from: transfer, envelope: ClipEnvelope(recording: clip))
        XCTAssertEqual(duplicate.transcript, "文字已保存")
        XCTAssertNotNil(duplicate.audioDeletedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: duplicate).path))
    }

    func testCorruptManifestIsNotSilentlyOverwritten() throws {
        let manifest = directory.appendingPathComponent("recordings.json")
        let data = Data("{ incomplete".utf8)
        try data.write(to: manifest)
        XCTAssertThrowsError(try RecordingStore(root: directory))
        XCTAssertEqual(try Data(contentsOf: manifest), data)
    }

    func testUnfinishedNonemptyCaptureCannotBeDiscardedAsEmpty() throws {
        let clip = try store.begin(source: .phone)
        try Data([1]).write(to: store.audioURL(for: clip))
        XCTAssertThrowsError(try store.discardEmptyCapture(id: clip.id))
        XCTAssertNotNil(store.recording(id: clip.id))
    }

    private func makeCapture(source: RecordingSource = .phone) throws -> Recording {
        let recording = try store.begin(source: source)
        try Data(repeating: 9, count: 12).write(to: store.audioURL(for: recording))
        return try store.finish(id: recording.id, duration: 8)
    }

    private func fixture() -> Recording {
        let id = UUID()
        return Recording(id: id, recordedAt: Date(), duration: 8, source: .watch,
                         fileName: id.uuidString + ".m4a", byteCount: 12, captureState: .ready,
                         transcriptionState: .pending, transcript: nil, lastError: nil,
                         phoneReceivedAt: nil, isKept: false, audioDeletedAt: nil)
    }
}
