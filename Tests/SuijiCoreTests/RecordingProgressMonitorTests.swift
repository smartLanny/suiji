import XCTest
@testable import SuijiCore

final class RecordingProgressMonitorTests: XCTestCase {
    func testFixedRecorderTimeEventuallyReportsStalled() {
        var monitor = RecordingProgressMonitor()
        monitor.reset(at: 100)

        XCTAssertFalse(monitor.observe(audioTime: 0.015442, at: 100))
        XCTAssertFalse(monitor.observe(audioTime: 0.015442, at: 110))
        XCTAssertTrue(monitor.observe(audioTime: 0.015442, at: 110.01))
    }

    func testGrowingAudioTimeKeepsRecordingProgressing() {
        var monitor = RecordingProgressMonitor()
        monitor.reset(at: 20)

        XCTAssertFalse(monitor.observe(audioTime: 0.015442, at: 20))
        XCTAssertFalse(monitor.observe(audioTime: 1.25, at: 21.25))
        XCTAssertFalse(monitor.observe(audioTime: 12.5, at: 55))
    }

    func testLongObservationGapDoesNotStallWhenAudioAdvanced() {
        var monitor = RecordingProgressMonitor()
        monitor.reset(at: 0)

        XCTAssertFalse(monitor.observe(audioTime: 0.015442, at: 1))
        XCTAssertFalse(monitor.observe(audioTime: 40, at: 45))
        XCTAssertFalse(monitor.observe(audioTime: 40, at: 55))
        XCTAssertTrue(monitor.observe(audioTime: 40, at: 55.01))
    }

    func testResetStartsFreshStallWindowForNextSegment() {
        var monitor = RecordingProgressMonitor()
        monitor.reset(at: 0)
        XCTAssertFalse(monitor.observe(audioTime: 15, at: 15))
        XCTAssertTrue(monitor.observe(audioTime: 15, at: 25.01))

        monitor.reset(at: 30)

        XCTAssertFalse(monitor.observe(audioTime: 0.015442, at: 30))
        XCTAssertFalse(monitor.observe(audioTime: 0.015442, at: 40))
        XCTAssertTrue(monitor.observe(audioTime: 0.015442, at: 40.01))
    }
}
