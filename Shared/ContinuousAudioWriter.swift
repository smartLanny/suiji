import AVFAudio
import Foundation

struct ContinuousAudioSnapshot: Sendable {
    var recordingID: UUID?
    var segmentFrames: Int64 = 0
    var writtenFrames: Int64 = 0
    var completedSegments = 0
    var level: Float = 0
    var failure: String?
}

enum ContinuousAudioEvent: Sendable {
    case began(Recording, [String: String])
    case saved(Recording, [String: String])
    case failed(String)
}

private struct CapturedAudioBlock: Sendable {
    let buffer: AVReadOnlyAudioPCMBuffer
    let sampleTime: Int64?
}

final class ContinuousAudioWriter: @unchecked Sendable {
    let sampleRate: Double
    private let format: AVAudioFormat
    private let store: RecordingStore
    private let source: RecordingSource
    private let intent: RecordingIntent
    private let mode: RecordingMode
    private let maximumPendingFrames: Int64
    private let shortSegmentDeadline: Date?
    private let onEvent: @Sendable (ContinuousAudioEvent) -> Void
    private let snapshotLock = NSLock()
    private var state = ContinuousAudioSnapshot()
    private var segmenter: AudioFrameSegmenter
    private var file: AVAudioFile?
    private var currentRecording: Recording?
    private var currentIndex = 0
    private var currentFrames: Int64 = 0
    private var attemptedWrite = false
    private var writtenFrames: Int64 = 0
    private var completedSegments = 0
    private var expectedSampleTime: Int64?
    private var terminalFailure: String?
    private lazy var inputQueue = BoundedAudioFrameQueue<CapturedAudioBlock>(
        maximumPendingFrames: maximumPendingFrames,
        consume: { [weak self] in try self?.consume($0) },
        onFailure: { [weak self] in self?.noteFailure($0) })

    init(store: RecordingStore, source: RecordingSource, intent: RecordingIntent, mode: RecordingMode,
         format: AVAudioFormat, segmentDuration: Double, shortSegmentDeadline: Date? = nil,
         maximumBufferedSeconds: Double = 2,
         onEvent: @escaping @Sendable (ContinuousAudioEvent) -> Void) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              segmentDuration.isFinite, segmentDuration > 0,
              maximumBufferedSeconds.isFinite, maximumBufferedSeconds > 0 else {
            throw ContinuousAudioWriterError.unsupportedFormat
        }
        sampleRate = format.sampleRate
        self.format = format
        self.store = store
        self.source = source
        self.intent = intent
        self.mode = mode
        self.onEvent = onEvent
        self.shortSegmentDeadline = shortSegmentDeadline
        segmenter = AudioFrameSegmenter(framesPerSegment: max(1, Int64((segmentDuration * format.sampleRate).rounded())))
        maximumPendingFrames = max(1, Int64((maximumBufferedSeconds * format.sampleRate).rounded()))
    }

    func start() throws {
        try inputQueue.perform { try openSegment(index: 0, frameLimit: segmenter.framesPerSegment) }
    }

    func submit(_ buffer: AVReadOnlyAudioPCMBuffer, at when: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }
        inputQueue.enqueue(CapturedAudioBlock(buffer: buffer,
                                             sampleTime: when.isSampleTimeValid ? when.sampleTime : nil),
                           frameCount: buffer.frameLength)
    }

    var snapshot: ContinuousAudioSnapshot {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return state
    }

    var receivedFrames: Int64 { inputQueue.counts.accepted }

    func finish(interrupted: Bool, message: String?) -> String? {
        let result = inputQueue.closeAndDrain {
            do {
                try closeCurrent(interrupted: interrupted || terminalFailure != nil,
                                 message: message ?? terminalFailure)
                return terminalFailure
            } catch {
                let message = "录音收尾未完成，原声已保留：\(error.localizedDescription)"
                recordCurrentError(message)
                return message
            }
        }
        return result.result ?? result.failure.map { failureMessage($0) }
    }

    func mark(intent: RecordingIntent) throws -> RecordingMarker {
        try inputQueue.perform {
            guard let recording = currentRecording else { throw ContinuousAudioWriterError.noActiveRecording }
            let marker = RecordingMarker(id: UUID(), offset: Double(currentFrames) / sampleRate, intent: intent)
            try store.addMarker(id: recording.id, marker: marker)
            return marker
        }
    }

    func discard() throws {
        let result: (result: Error?, failure: Error?) = inputQueue.closeAndDrain {
            guard completedSegments == 0, let recording = currentRecording else {
                do { try closeCurrent(interrupted: false, message: nil) }
                catch {
                    let message = "较早分段已保存，取消未执行；当前文件收尾失败：\(error.localizedDescription)"
                    recordCurrentError(message)
                    return ContinuousAudioWriterError.cancellationFailed(message)
                }
                return ContinuousAudioWriterError.committedSegmentsExist
            }
            file?.close()
            file = nil
            do {
                try store.discardDraft(id: recording.id)
                currentRecording = nil
                updateSnapshot()
                return nil
            } catch {
                let removalError = error.localizedDescription
                let exists = FileManager.default.fileExists(atPath: store.audioURL(for: recording).path)
                if exists {
                    let message = "取消未成功，原声仍保留：\(removalError)"
                    do { try closeCurrent(interrupted: true, message: message) }
                    catch { recordCurrentError("\(message)；恢复索引失败：\(error.localizedDescription)") }
                    return ContinuousAudioWriterError.cancellationFailed(message)
                }
                let message = "取消未完成，原声已删除，空草稿索引待恢复清理：\(removalError)"
                recordCurrentError(message)
                return ContinuousAudioWriterError.cancellationFailed(message)
            }
        }
        if let error = result.result { throw error }
    }

    private func consume(_ block: CapturedAudioBlock) throws {
        guard block.buffer.format == format else { throw ContinuousAudioWriterError.unsupportedFormat }
        if let sampleTime = block.sampleTime {
            if let expectedSampleTime, sampleTime != expectedSampleTime {
                throw ContinuousAudioWriterError.inputDiscontinuity
            }
            expectedSampleTime = sampleTime + Int64(block.buffer.frameLength)
        } else { expectedSampleTime = nil }

        var nextSegmenter = segmenter
        defer { segmenter = nextSegmenter; updateSnapshot() }
        try nextSegmenter.append(frameCount: block.buffer.frameLength, nextSegmentFrames: {
            if let deadline = self.shortSegmentDeadline, Date() >= deadline { return Int64((300 * self.sampleRate).rounded()) }
            return self.segmenter.framesPerSegment
        }) { slice in
            if slice.segmentIndex != currentIndex {
                try closeCurrent(interrupted: false, message: nil)
                try openSegment(index: slice.segmentIndex, frameLimit: slice.segmentFrameLimit)
            }
            guard let file else { throw ContinuousAudioWriterError.writerUnavailable }
            attemptedWrite = true
            if slice.bufferOffset == 0, slice.frameCount == block.buffer.frameLength {
                try file.write(from: block.buffer)
            } else {
                let part = try copySlice(block.buffer, slice: slice)
                try file.write(from: part)
            }
            currentFrames += Int64(slice.frameCount)
            writtenFrames += Int64(slice.frameCount)
        }
        stateLevel(from: block.buffer)
    }

    private func openSegment(index: Int, frameLimit: Int64) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let recording = try store.begin(source: source, intent: intent, mode: mode)
        let storeFinished = ProcessInfo.processInfo.systemUptime
        currentRecording = recording
        currentIndex = index
        currentFrames = 0
        attemptedWrite = false
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                                      AVSampleRateKey: sampleRate,
                                      AVNumberOfChannelsKey: format.channelCount,
                                      AVEncoderBitRateKey: 64_000,
                                      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        file = try AVAudioFile(forWriting: store.audioURL(for: recording), settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard file?.processingFormat == format else { throw ContinuousAudioWriterError.unsupportedFormat }
        updateSnapshot()
        onEvent(.began(recording, ["phase": "file_begin", "outcome": "success", "units": "milliseconds",
                                  "segmentDurationSeconds": String(Double(frameLimit) / sampleRate),
                                  "store_begin_ms": String((storeFinished - started) * 1_000),
                                  "file_init_ms": String((ProcessInfo.processInfo.systemUptime - storeFinished) * 1_000),
                                  "meaning": "writer_processing_not_audio_frame_boundaries"]))
    }

    private func closeCurrent(interrupted: Bool, message: String?) throws {
        guard let recording = currentRecording else { return }
        let started = ProcessInfo.processInfo.systemUptime
        file?.close()
        file = nil
        let closed = ProcessInfo.processInfo.systemUptime
        if interrupted, attemptedWrite {
            // A throwing write can have partially changed the file; preserve or recover it.
            let recovered = try AVAudioFile(forReading: store.audioURL(for: recording))
            guard recovered.length > 0 else { throw ContinuousAudioWriterError.unreadablePartialFile }
            if recovered.length > currentFrames {
                writtenFrames += recovered.length - currentFrames
                currentFrames = recovered.length
            }
        }
        guard currentFrames > 0 else {
            try store.discardDraft(id: recording.id)
            currentRecording = nil
            updateSnapshot()
            return
        }
        var saved = try store.finish(id: recording.id, duration: Double(currentFrames) / sampleRate,
                                     interrupted: interrupted)
        if let message {
            do { try store.recordError(id: saved.id, message: message) }
            catch { terminalFailure = "\(message)（索引错误说明未能保存：\(error.localizedDescription)）" }
            saved = store.recording(id: saved.id) ?? saved
        }
        currentRecording = nil
        completedSegments += 1
        updateSnapshot()
        onEvent(.saved(saved, ["phase": "file_finish", "outcome": interrupted ? "interrupted" : "saved",
                              "units": "milliseconds", "close_ms": String((closed - started) * 1_000),
                              "store_finish_ms": String((ProcessInfo.processInfo.systemUptime - closed) * 1_000),
                              "frames": String(currentFrames), "sample_rate": String(sampleRate),
                              "meaning": "writer_processing_not_audio_frame_boundaries"]))
    }

    private func copySlice(_ source: AVReadOnlyAudioPCMBuffer, slice: AudioFrameSlice) throws -> AVAudioPCMBuffer {
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slice.frameCount)) else {
            throw ContinuousAudioWriterError.bufferAllocation
        }
        result.frameLength = AVAudioFrameCount(slice.frameCount)
        let destination = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        source.withUnsafeAudioBufferList { list in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            for index in 0..<input.count {
                let bytesPerFrame = Int(input[index].mNumberChannels) * MemoryLayout<Float>.size
                memcpy(destination[index].mData!, input[index].mData!.advanced(by: slice.bufferOffset * bytesPerFrame),
                       slice.frameCount * bytesPerFrame)
            }
        }
        return result
    }

    private func stateLevel(from buffer: AVReadOnlyAudioPCMBuffer) {
        let level: Float = buffer.withUnsafeAudioBufferList { list in
            guard let data = list.pointee.mBuffers.mData else { return 0 }
            let samples = data.assumingMemoryBound(to: Float.self)
            let stride = Int(list.pointee.mBuffers.mNumberChannels)
            var energy: Float = 0
            for index in 0..<buffer.frameLength { let value = samples[index * stride]; energy += value * value }
            let rms = sqrt(energy / Float(buffer.frameLength))
            return max(0, min(1, (20 * log10(max(rms, 0.000_001)) + 60) / 60))
        }
        snapshotLock.lock(); state.level = level; snapshotLock.unlock()
    }

    private func updateSnapshot() {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        state.recordingID = currentRecording?.id
        state.segmentFrames = currentRecording == nil ? 0 : currentFrames
        state.writtenFrames = writtenFrames
        state.completedSegments = completedSegments
        state.failure = terminalFailure
    }

    private func noteFailure(_ error: Error) {
        guard terminalFailure == nil else { return }
        terminalFailure = failureMessage(error)
        updateSnapshot()
        onEvent(.failed(terminalFailure!))
    }

    private func recordCurrentError(_ message: String) {
        guard let recording = currentRecording else { return }
        do { try store.recordError(id: recording.id, message: message) }
        catch { terminalFailure = "\(message)（索引错误说明未能保存：\(error.localizedDescription)）" }
        updateSnapshot()
    }

    private func failureMessage(_ error: Error) -> String {
        if error as? AudioFrameQueueError == .overflow { return "录音写盘跟不上收音，缓冲已满；已停止并保留已接收的部分。" }
        return "录音写入中断，已保留可恢复部分：\(error.localizedDescription)"
    }
}

enum ContinuousAudioWriterError: LocalizedError {
    case unsupportedFormat, inputDiscontinuity, writerUnavailable, bufferAllocation, unreadablePartialFile
    case noActiveRecording, committedSegmentsExist, cancellationFailed(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "麦克风与写盘格式不匹配。"
        case .inputDiscontinuity: return "输入音频帧不连续。"
        case .writerUnavailable: return "录音输出文件不可用。"
        case .bufferAllocation: return "无法分配分段音频缓冲。"
        case .unreadablePartialFile: return "写入失败的文件暂时无法读取，原文件已保留。"
        case .noActiveRecording: return "当前没有正在录制的片段，无法添加标记。"
        case .committedSegmentsExist: return "较早分段已保存，取消未执行；当前录音已停止并保存。"
        case let .cancellationFailed(message): return message
        }
    }
}
