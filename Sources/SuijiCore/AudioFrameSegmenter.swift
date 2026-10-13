struct AudioFrameSlice: Equatable, Sendable {
    let segmentIndex: Int
    let bufferOffset: Int
    let frameCount: Int
    let segmentFrameLimit: Int64
}

struct AudioFrameSegmenter {
    private(set) var framesPerSegment: Int64
    private(set) var segmentIndex = 0
    private(set) var framesInSegment: Int64 = 0
    private(set) var totalFrames: Int64 = 0

    init(framesPerSegment: Int64) {
        precondition(framesPerSegment > 0)
        self.framesPerSegment = framesPerSegment
    }

    mutating func append(frameCount: Int, nextSegmentFrames: (() -> Int64)? = nil,
                         write: (AudioFrameSlice) throws -> Void) rethrows {
        precondition(frameCount >= 0)
        var offset = 0
        while offset < frameCount {
            let count = Int(min(Int64(frameCount - offset), framesPerSegment - framesInSegment))
            try write(AudioFrameSlice(segmentIndex: segmentIndex, bufferOffset: offset, frameCount: count,
                                      segmentFrameLimit: framesPerSegment))
            offset += count
            framesInSegment += Int64(count)
            totalFrames += Int64(count)
            if framesInSegment == framesPerSegment {
                segmentIndex += 1
                framesInSegment = 0
                if let nextSegmentFrames {
                    let next = nextSegmentFrames()
                    precondition(next > 0)
                    framesPerSegment = next
                }
            }
        }
    }
}
