import Foundation

enum AudioFrameQueueError: LocalizedError, Equatable {
    case overflow
    var errorDescription: String? { "录音写盘缓冲已满。" }
}

final class BoundedAudioFrameQueue<Payload: Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lann.suiji.audio-writer", qos: .userInitiated)
    private let lock = NSLock()
    private let maximumPendingFrames: Int64
    private let consume: @Sendable (Payload) throws -> Void
    private let onFailure: @Sendable (Error) -> Void
    private var accepting = true
    private var processingFailed = false
    private var failure: Error?
    private var pendingFrames: Int64 = 0
    private var acceptedFrames: Int64 = 0

    init(maximumPendingFrames: Int64, consume: @escaping @Sendable (Payload) throws -> Void,
         onFailure: @escaping @Sendable (Error) -> Void) {
        precondition(maximumPendingFrames > 0)
        self.maximumPendingFrames = maximumPendingFrames
        self.consume = consume
        self.onFailure = onFailure
    }

    var counts: (accepted: Int64, pending: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (acceptedFrames, pendingFrames)
    }

    @discardableResult
    func enqueue(_ payload: Payload, frameCount: Int) -> Bool {
        precondition(frameCount > 0)
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        guard Int64(frameCount) <= maximumPendingFrames - pendingFrames else {
            accepting = false
            failure = AudioFrameQueueError.overflow
            // Already accepted audio drains before the overflow is reported.
            queue.async { self.onFailure(AudioFrameQueueError.overflow) }
            return false
        }
        pendingFrames += Int64(frameCount)
        acceptedFrames += Int64(frameCount)
        // Schedule under the lock so closeAndDrain cannot overtake an accepted buffer.
        queue.async { self.process(payload, frameCount: frameCount) }
        return true
    }

    func perform<T>(_ operation: () throws -> T) throws -> T {
        try queue.sync {
            lock.lock()
            let failure = self.failure
            lock.unlock()
            if let failure { throw failure }
            return try operation()
        }
    }

    func closeAndDrain<T>(_ operation: () -> T) -> (result: T, failure: Error?) {
        lock.lock()
        accepting = false
        lock.unlock()
        return queue.sync {
            let result = operation()
            lock.lock(); defer { lock.unlock() }
            return (result, failure)
        }
    }

    private func process(_ payload: Payload, frameCount: Int) {
        lock.lock()
        let skip = processingFailed
        lock.unlock()
        if !skip {
            do { try consume(payload) }
            catch {
                lock.lock()
                processingFailed = true
                accepting = false
                let reportFailure = failure == nil
                if reportFailure { failure = error }
                lock.unlock()
                if reportFailure { onFailure(error) }
            }
        }
        lock.lock()
        pendingFrames -= Int64(frameCount)
        lock.unlock()
    }
}
