// File-only verification. Requires Xcode/macOS 27 SDK and macOS 27 runtime.
// Compile with production Recording/RecordingStore/AudioFrameSegmenter/BoundedAudioFrameQueue
// and Shared/ContinuousAudioWriter.swift. No AVAudioEngine, session, microphone or playback.
// The new output directory contains synthetic reference.wav, AAC files, native valid-frame
// decoded WAVs and a JSON report. Use segment_probe.py after converting WAVs to mono 16k PCM.
import AVFAudio
import Foundation
import AudioToolbox

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var saved = 0
    private var failed = 0
    func receive(_ event: ContinuousAudioEvent) {
        lock.lock(); defer { lock.unlock() }
        if case .saved = event { saved += 1 }
        if case .failed = event { failed += 1 }
    }
    var counts: (saved: Int, failed: Int) { lock.lock(); defer { lock.unlock() }; return (saved, failed) }
}

@main
enum VerifyAudioWriter {
    static let output = URL(fileURLWithPath: CommandLine.arguments[1])
    static let rate = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 0 : 44_100

    static func makeStore(_ name: String) throws -> RecordingStore {
        try RecordingStore(root: output.appendingPathComponent(name))
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "WriterCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func waitWritten(_ writer: ContinuousAudioWriter, frames: Int64) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while writer.snapshot.writtenFrames < frames, writer.snapshot.failure == nil {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "writer did not progress")
            usleep(1_000)
        }
    }
    static func sampleBuffer(_ format: AVAudioFormat, frames: Int) -> AVReadOnlyAudioPCMBuffer {
        let mutable = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        mutable.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { mutable.floatChannelData![0][i] = Float(sin(Double(i) * 0.13)) * 0.05 }
        return AVReadOnlyAudioPCMBuffer(copying: mutable)
    }

    static func main() {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
            fputs("Usage: verify-audio-writer /absolute/new/output-directory [44100|48000]\n", stderr)
            exit(1)
        }
        do { try verify() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func generateReference() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: output.appendingPathComponent("reference.wav"),
                                   settings: [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: rate,
                                              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                              AVLinearPCMIsFloatKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var seed: UInt32 = 0x5339
        var previous: Float = 0
        var beforePrevious: Float = 0
        var remaining = Int64(240 * rate)
        while remaining > 0 {
            let count = Int(min(8192, remaining))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Float(seed) / Float(UInt32.max) - 0.5) * 0.16
                buffer.floatChannelData![0][index] = (beforePrevious + 2 * previous + noise) / 4
                beforePrevious = previous
                previous = noise
            }
            try file.write(from: buffer)
            remaining -= Int64(count)
        }
        file.close()
    }

    static func decodeValidFrames(_ url: URL, index: Int) throws -> [String: Any] {
        let input = try AVAudioFile(forReading: url)
        let player = try AVAudioPlayer(contentsOf: url) // Metadata only; never play().
        let native = try AVAudioFile(forWriting: output.appendingPathComponent("native-\(index).wav"),
                                     settings: [AVFormatIDKey: Int(kAudioFormatLinearPCM),
                                                AVSampleRateKey: input.processingFormat.sampleRate,
                                                AVNumberOfChannelsKey: input.processingFormat.channelCount,
                                                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        while input.framePosition < input.length {
            let count = AVAudioFrameCount(min(8192, input.length - input.framePosition))
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count)!
            try input.read(into: buffer, frameCount: count)
            try native.write(from: buffer)
        }
        native.close()
        var table = AudioFilePacketTableInfo()
        var audio: AudioFileID?
        let opened = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audio)
        try require(opened == noErr && audio != nil, "cannot inspect AAC packet table")
        defer { AudioFileClose(audio!) }
        var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        try require(AudioFileGetProperty(audio!, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr,
                    "cannot read AAC valid-frame information")
        try require(input.length == Int64(60 * rate) && table.mNumberValidFrames == input.length,
                    "AAC valid frames differ from written PCM")
        return ["index": index, "validFrames": input.length, "nativePlayerDurationSeconds": player.duration,
                "primingFrames": table.mPrimingFrames, "remainderFrames": table.mRemainderFrames]
    }

    static func verify() throws {
        try require(CommandLine.arguments[1].hasPrefix("/"), "output directory must be absolute")
        try require(!FileManager.default.fileExists(atPath: output.path), "choose a new output directory")
        try require(rate == 44_100 || rate == 48_000, "sample rate must be 44100 or 48000")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try generateReference()
        // File-only check of the production writer; no engine, session, microphone or playback.
        let reader = try AVAudioFile(forReading: output.appendingPathComponent("reference.wav"))
        let format = reader.processingFormat
        let store = try makeStore("full")
        let events = Events()
        let writer = try ContinuousAudioWriter(store: store, source: .watch, intent: .note, mode: .continuous,
                                                format: format, segmentDuration: 60, onEvent: { events.receive($0) })
        try writer.start()
        var frame: Int64 = 0
        while frame < reader.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
            try reader.read(into: buffer)
            writer.submit(AVReadOnlyAudioPCMBuffer(copying: buffer),
                          at: AVAudioTime(sampleTime: frame, atRate: format.sampleRate))
            frame += Int64(buffer.frameLength)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while writer.receivedFrames - writer.snapshot.writtenFrames > Int64(format.sampleRate / 2),
                  writer.snapshot.failure == nil {
                try require(ProcessInfo.processInfo.systemUptime < deadline, "writer backlog did not drain")
                usleep(1_000)
            }
            try require(writer.snapshot.failure == nil, "unexpected writer failure")
        }
        let closingError = writer.finish(interrupted: false, message: nil)
        try require(closingError == nil, "normal finish failed")
        let recordings = store.all().sorted { $0.recordedAt < $1.recordedAt }
        try require(recordings.count == 4, "extra or missing segments at exact boundary")
        try require(recordings.allSatisfy { $0.captureState == .ready && abs($0.duration - 60) < 0.000_001 }, "wrong persisted duration")
        try require(writer.snapshot.writtenFrames == reader.length, "wrong total written frames")
        var metadata: [[String: Any]] = []
        for (index, recording) in recordings.enumerated() {
            try FileManager.default.copyItem(at: store.audioURL(for: recording),
                                            to: output.appendingPathComponent("segment-\(index + 1).m4a"))
            metadata.append(try decodeValidFrames(store.audioURL(for: recording), index: index + 1))
        }

        let tailStore = try makeStore("tail")
        let tail = try ContinuousAudioWriter(store: tailStore, source: .watch, intent: .note, mode: .continuous,
                                              format: format, segmentDuration: 1, onEvent: { _ in })
        try tail.start()
        tail.submit(sampleBuffer(format, frames: 17_337), at: AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        let marker = try tail.mark(intent: .journal)
        try require(abs(marker.offset - 17_337 / format.sampleRate) < 0.000_001, "marker ordered incorrectly")
        try require(tail.finish(interrupted: false, message: nil) == nil, "tail finish failed")
        try require(tailStore.all().count == 1 && tailStore.all()[0].markers.count == 1, "tail or marker missing")

        let failureStore = try makeStore("failure")
        let failures = Events()
        let failing = try ContinuousAudioWriter(store: failureStore, source: .watch, intent: .note, mode: .continuous,
                                                 format: format, segmentDuration: 1, onEvent: { failures.receive($0) })
        try failing.start()
        failing.submit(sampleBuffer(format, frames: 4_410), at: AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        try waitWritten(failing, frames: 4_410)
        let wrong = AVAudioFormat(standardFormatWithSampleRate: rate == 48_000 ? 44_100 : 48_000, channels: 1)!
        failing.submit(sampleBuffer(wrong, frames: 4_800), at: AVAudioTime(sampleTime: 4_410, atRate: wrong.sampleRate))
        let failureDeadline = ProcessInfo.processInfo.systemUptime + 3
        while failing.snapshot.failure == nil {
            try require(ProcessInfo.processInfo.systemUptime < failureDeadline, "fault not reported")
            usleep(1_000)
        }
        try require(failing.finish(interrupted: false, message: nil) != nil, "failure claimed success")
        try require(failureStore.all().count == 1 && failureStore.all()[0].captureState == .interrupted, "failed tail not retained")
        try require(failures.counts.failed == 1, "failure callback repeated")

        let discontinuityStore = try makeStore("discontinuity")
        let discontinuity = try ContinuousAudioWriter(store: discontinuityStore, source: .watch,
                                                       intent: .note, mode: .continuous,
                                                       format: format, segmentDuration: 1, onEvent: { _ in })
        try discontinuity.start()
        discontinuity.submit(sampleBuffer(format, frames: 4_410), at: AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        try waitWritten(discontinuity, frames: 4_410)
        discontinuity.submit(sampleBuffer(format, frames: 4_410),
                             at: AVAudioTime(sampleTime: 4_411, atRate: format.sampleRate))
        let discontinuityDeadline = ProcessInfo.processInfo.systemUptime + 3
        while discontinuity.snapshot.failure == nil {
            try require(ProcessInfo.processInfo.systemUptime < discontinuityDeadline, "input gap not reported")
            usleep(1_000)
        }
        try require(discontinuity.finish(interrupted: false, message: nil) != nil, "input gap claimed success")
        try require(discontinuityStore.all().count == 1
                    && discontinuityStore.all()[0].captureState == .interrupted
                    && discontinuity.snapshot.writtenFrames == 4_410, "input gap counted as saved coverage")

        let overflowStore = try makeStore("overflow")
        let overflow = try ContinuousAudioWriter(store: overflowStore, source: .watch, intent: .note, mode: .continuous,
                                                  format: format, segmentDuration: 1, maximumBufferedSeconds: 0.001,
                                                  onEvent: { _ in })
        try overflow.start()
        overflow.submit(sampleBuffer(format, frames: 4_410), at: AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        try require(overflow.finish(interrupted: false, message: nil) != nil, "overflow claimed success")
        try require(overflowStore.all().isEmpty && overflow.receivedFrames == 0, "rejected input persisted as coverage")

        let cancelStore = try makeStore("cancel")
        let cancellation = Events()
        let cancelling = try ContinuousAudioWriter(store: cancelStore, source: .watch, intent: .note, mode: .quick,
                                                    format: format, segmentDuration: 1, onEvent: { cancellation.receive($0) })
        try cancelling.start()
        cancelling.submit(sampleBuffer(format, frames: 4_410), at: AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        try cancelling.discard()
        try require(cancelStore.all().isEmpty && cancellation.counts.saved == 0, "successful cancellation saved or notified")
        let deadlineStore = try makeStore("deadline")
        let deadlineWriter = try ContinuousAudioWriter(store: deadlineStore, source: .watch, intent: .note, mode: .continuous,
                                                        format: format, segmentDuration: 1, shortSegmentDeadline: .distantPast,
                                                        onEvent: { _ in })
        try deadlineWriter.start()
        var sent: Int64 = 0
        let total = Int64((2.3 * format.sampleRate).rounded())
        while sent < total {
            let count = Int(min(8192, total - sent))
            deadlineWriter.submit(sampleBuffer(format, frames: count), at: AVAudioTime(sampleTime: sent, atRate: format.sampleRate))
            sent += Int64(count)
            try waitWritten(deadlineWriter, frames: sent)
        }
        try require(deadlineWriter.finish(interrupted: false, message: nil) == nil, "deadline finish failed")
        let deadlineRows = deadlineStore.all().sorted { $0.recordedAt < $1.recordedAt }
        try require(deadlineRows.count == 2 && abs(deadlineRows[0].duration - 1) < 0.000_001
                    && abs(deadlineRows[1].duration - 1.3) < 0.000_001, "short mode did not expire at boundary")
        let summary: [String: Any] = ["platform": "macOS 27; actual production writer, file-only",
                                      "audioHardwareUsed": false, "writtenFrames": writer.snapshot.writtenFrames,
                                      "sampleRate": format.sampleRate, "segments": recordings.count, "AACMetadata": metadata,
                                      "checks": ["exact-boundary", "tail-and-marker", "format-failure-retained", "input-discontinuity-stops", "overflow-not-success", "cancel-no-saved-event", "diagnostic-short-mode-expiry"]]
        try JSONSerialization.data(withJSONObject: summary, options: .prettyPrinted)
            .write(to: output.appendingPathComponent("writer-check-report.json"))
        print("PASS: actual AAC writer; 4 segments, valid frames, tail/marker, failure, input clock gap, overflow, cancellation, diagnostic expiry")
    }
}
