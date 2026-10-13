import XCTest
@testable import SuijiCore

final class TransferRetryLedgerTests: XCTestCase {
    private let recordingID = "synthetic-recording"
    private let firstAttempt = "attempt-a"

    func testSuccessfulFinishSuppressesSixtySecondResendThenAllowsTimeoutRecovery() {
        var ledger = TransferRetryLedger()
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.beginAttempt(recordingID: recordingID, attemptID: firstAttempt)

        XCTAssertEqual(ledger.finishAttempt(recordingID: recordingID, attemptID: firstAttempt,
                                            succeeded: true, at: finishedAt), .awaitingReceipt)
        XCTAssertTrue(ledger.isWaitingForReceipt(recordingID: recordingID,
                                                  at: finishedAt.addingTimeInterval(60)))
        XCTAssertFalse(ledger.isWaitingForReceipt(recordingID: recordingID,
                                                   at: finishedAt.addingTimeInterval(300)))
    }

    func testSuccessfulWaitSurvivesPersistenceAndReload() throws {
        var ledger = TransferRetryLedger()
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.beginAttempt(recordingID: recordingID, attemptID: firstAttempt)
        _ = ledger.finishAttempt(recordingID: recordingID, attemptID: firstAttempt,
                                 succeeded: true, at: finishedAt)

        var reloaded = try JSONDecoder().decode(TransferRetryLedger.self,
                                                from: JSONEncoder().encode(ledger))

        XCTAssertTrue(reloaded.isWaitingForReceipt(recordingID: recordingID,
                                                    at: finishedAt.addingTimeInterval(240)))
        XCTAssertFalse(reloaded.isWaitingForReceipt(recordingID: recordingID,
                                                     at: finishedAt.addingTimeInterval(301)))
    }

    func testReceiptClearsWaitAndMakesLateDuplicateCompletionStale() {
        var ledger = TransferRetryLedger()
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.beginAttempt(recordingID: recordingID, attemptID: firstAttempt)
        _ = ledger.finishAttempt(recordingID: recordingID, attemptID: firstAttempt,
                                 succeeded: true, at: finishedAt)

        ledger.confirmReceipt(recordingID: recordingID)

        XCTAssertFalse(ledger.isWaitingForReceipt(recordingID: recordingID,
                                                   at: finishedAt.addingTimeInterval(1)))
        XCTAssertEqual(ledger.finishAttempt(recordingID: recordingID, attemptID: firstAttempt,
                                            succeeded: true, at: finishedAt.addingTimeInterval(2)), .stale)
        XCTAssertFalse(ledger.isWaitingForReceipt(recordingID: recordingID,
                                                   at: finishedAt.addingTimeInterval(2)))
    }

    func testFailureAllowsRetryAndLateCompletionFromOldAttemptCannotAffectNewAttempt() {
        var ledger = TransferRetryLedger()
        let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.beginAttempt(recordingID: recordingID, attemptID: firstAttempt)

        XCTAssertEqual(ledger.finishAttempt(recordingID: recordingID, attemptID: firstAttempt,
                                            succeeded: false, at: failedAt), .failed)
        XCTAssertFalse(ledger.isWaitingForReceipt(recordingID: recordingID,
                                                   at: failedAt.addingTimeInterval(1)))
        ledger.beginAttempt(recordingID: recordingID, attemptID: "attempt-b")

        XCTAssertEqual(ledger.finishAttempt(recordingID: recordingID, attemptID: firstAttempt,
                                            succeeded: true, at: failedAt.addingTimeInterval(2)), .stale)
        XCTAssertEqual(ledger.finishAttempt(recordingID: recordingID, attemptID: "attempt-b",
                                            succeeded: true, at: failedAt.addingTimeInterval(3)), .awaitingReceipt)
    }

    func testLegacyCompletionWithoutAttemptTokenIsAcceptedOnlyOnce() {
        var ledger = TransferRetryLedger()
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(ledger.finishAttempt(recordingID: recordingID, attemptID: nil,
                                            succeeded: true, at: finishedAt), .awaitingReceipt)
        XCTAssertEqual(ledger.finishAttempt(recordingID: recordingID, attemptID: nil,
                                            succeeded: true, at: finishedAt.addingTimeInterval(1)), .stale)
        XCTAssertTrue(ledger.isWaitingForReceipt(recordingID: recordingID,
                                                  at: finishedAt.addingTimeInterval(60)))
    }
}
