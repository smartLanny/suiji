import XCTest
@testable import SuijiCore

final class AudioFrameSegmenterTests: XCTestCase {
    func testCrossingBuffersPreservesEveryFrameOnce() throws {
        var splitter = AudioFrameSegmenter(framesPerSegment: 10)
        let input = Array(0..<37)
        var segments: [Int: [Int]] = [:]
        var base = 0
        for count in [3, 15, 1, 18] {
            let buffer = Array(input[base..<base + count])
            splitter.append(frameCount: count) { slice in
                segments[slice.segmentIndex, default: []].append(contentsOf:
                    buffer[slice.bufferOffset..<slice.bufferOffset + slice.frameCount])
            }
            base += count
        }
        XCTAssertEqual((0..<4).flatMap { segments[$0] ?? [] }, input)
        XCTAssertEqual((0..<4).map { segments[$0]?.count }, [10, 10, 10, 7])
        XCTAssertEqual(splitter.totalFrames, 37)
        XCTAssertEqual(splitter.framesInSegment, 7)
    }

    func testExactBoundaryDoesNotCreateAnEmptyTail() {
        var splitter = AudioFrameSegmenter(framesPerSegment: 10)
        var slices: [AudioFrameSlice] = []
        splitter.append(frameCount: 20) { slices.append($0) }
        splitter.append(frameCount: 0) { slices.append($0) }
        XCTAssertEqual(slices.map(\.frameCount), [10, 10])
        XCTAssertEqual(splitter.segmentIndex, 2)
        XCTAssertEqual(splitter.framesInSegment, 0)
    }

    func testFailedWriteDoesNotAdvanceFailedSlice() {
        enum Failure: Error { case write }
        var splitter = AudioFrameSegmenter(framesPerSegment: 10)
        XCTAssertThrowsError(try splitter.append(frameCount: 25) { slice in
            if slice.segmentIndex == 1 { throw Failure.write }
        })
        XCTAssertEqual(splitter.totalFrames, 10)
        XCTAssertEqual(splitter.segmentIndex, 1)
        XCTAssertEqual(splitter.framesInSegment, 0)
    }

    func testLongCaptureUses64BitFrameCounters() {
        var splitter = AudioFrameSegmenter(framesPerSegment: 300 * 48_000)
        for _ in 0..<300 { splitter.append(frameCount: 300 * 48_000) { _ in } }
        XCTAssertEqual(splitter.totalFrames, 4_320_000_000)
    }

    func testDurationChangeTakesEffectAtNextBoundaryOnly() {
        var splitter = AudioFrameSegmenter(framesPerSegment: 5)
        var slices: [AudioFrameSlice] = []
        splitter.append(frameCount: 8, nextSegmentFrames: { 10 }) { slices.append($0) }
        splitter.append(frameCount: 7) { slices.append($0) }
        XCTAssertEqual(slices.map(\.frameCount), [5, 3, 7])
        XCTAssertEqual(slices.map(\.segmentFrameLimit), [5, 10, 10])
        XCTAssertEqual(splitter.totalFrames, 15)
        XCTAssertEqual(splitter.segmentIndex, 2)
        XCTAssertEqual(splitter.framesInSegment, 0)
    }
}
