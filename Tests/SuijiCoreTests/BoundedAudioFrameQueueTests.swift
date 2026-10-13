import XCTest
@testable import SuijiCore

final class BoundedAudioFrameQueueTests: XCTestCase {
    private final class Results: @unchecked Sendable {
        let lock = NSLock()
        var values: [Int] = []
        var errors = 0
        func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        func fail() { lock.lock(); defer { lock.unlock() }; errors += 1 }
    }

    func testOverflowDrainsAcceptedAudioInOrderAndRejectsLaterInput() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let results = Results()
        let queue = BoundedAudioFrameQueue<Int>(maximumPendingFrames: 4, consume: { value in
            if value == 1 { entered.signal(); release.wait() }
            results.append(value)
        }, onFailure: { _ in results.fail() })
        XCTAssertTrue(queue.enqueue(1, frameCount: 2))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(queue.enqueue(2, frameCount: 2))
        XCTAssertFalse(queue.enqueue(3, frameCount: 1))
        XCTAssertFalse(queue.enqueue(4, frameCount: 1))
        release.signal()
        let drained = queue.closeAndDrain { results.values }
        XCTAssertEqual(drained.result, [1, 2])
        XCTAssertEqual(drained.failure as? AudioFrameQueueError, .overflow)
        XCTAssertEqual(results.errors, 1)
        XCTAssertEqual(queue.counts.accepted, 4)
        XCTAssertEqual(queue.counts.pending, 0)
    }

    func testWriteFailureIsReportedOnceAndFailedAudioIsNotReplayed() {
        enum Failure: Error { case disk }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let results = Results()
        let queue = BoundedAudioFrameQueue<Int>(maximumPendingFrames: 10, consume: { value in
            results.append(value)
            if value == 2 { entered.signal(); release.wait(); throw Failure.disk }
        }, onFailure: { _ in results.fail() })
        XCTAssertTrue(queue.enqueue(1, frameCount: 1))
        XCTAssertTrue(queue.enqueue(2, frameCount: 1))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(queue.enqueue(3, frameCount: 1))
        release.signal()
        let drained = queue.closeAndDrain { results.values }
        XCTAssertEqual(drained.result, [1, 2])
        XCTAssertNotNil(drained.failure)
        XCTAssertEqual(results.errors, 1)
        XCTAssertEqual(queue.counts.pending, 0)
        XCTAssertFalse(queue.enqueue(4, frameCount: 1))
    }

    func testDrainCompletesBeforeReturningAndNoLaterBufferIsAccepted() {
        let results = Results()
        let queue = BoundedAudioFrameQueue<Int>(maximumPendingFrames: 10,
                                               consume: { results.append($0) }, onFailure: { _ in results.fail() })
        for value in 0..<5 { XCTAssertTrue(queue.enqueue(value, frameCount: 1)) }
        let drained = queue.closeAndDrain { results.values }
        XCTAssertEqual(drained.result, Array(0..<5))
        XCTAssertNil(drained.failure)
        XCTAssertFalse(queue.enqueue(6, frameCount: 1))
    }
}
