import Foundation

struct TransferRetryLedger: Codable, Equatable {
    enum Completion: Equatable {
        case awaitingReceipt
        case failed
        case stale
    }

    static let receiptWaitLimit: TimeInterval = 5 * 60

    private(set) var attempts: [String: String] = [:]
    private(set) var successfulFinishes: [String: Date] = [:]

    mutating func beginAttempt(recordingID: String, attemptID: String) {
        attempts[recordingID] = attemptID
    }

    mutating func finishAttempt(recordingID: String, attemptID: String?, succeeded: Bool,
                                at date: Date) -> Completion {
        if let attemptID {
            guard attempts[recordingID] == attemptID else { return .stale }
            attempts.removeValue(forKey: recordingID)
        } else {
            guard attempts[recordingID] == nil, successfulFinishes[recordingID] == nil else { return .stale }
        }

        guard succeeded else { return .failed }
        successfulFinishes[recordingID] = date
        return .awaitingReceipt
    }

    mutating func isWaitingForReceipt(recordingID: String, at date: Date) -> Bool {
        guard let finishedAt = successfulFinishes[recordingID] else { return false }
        guard date.timeIntervalSince(finishedAt) < Self.receiptWaitLimit else {
            successfulFinishes.removeValue(forKey: recordingID)
            return false
        }
        return true
    }

    mutating func confirmReceipt(recordingID: String) {
        clear(recordingID: recordingID)
    }

    mutating func clear(recordingID: String) {
        attempts.removeValue(forKey: recordingID)
        successfulFinishes.removeValue(forKey: recordingID)
    }
}
