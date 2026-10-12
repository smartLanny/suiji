import SwiftUI
import AVFoundation
import Combine

@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(url: URL) throws {
        if isPlaying { stop(); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            guard player?.play() == true else { throw StoreError.missingAudio }
            isPlaying = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct RecordingDetail: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var capture: AudioCapture
    let recordingID: UUID
    @StateObject private var playback = AudioPlayback()
    @State private var editedText = ""
    @State private var editing = false

    private var recording: Recording? { model.recordings.first { $0.id == recordingID } }

    var body: some View {
        Group {
            if let recording {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(recording.recordedAt.formatted(date: .complete, time: .shortened))
                            .font(.caption).foregroundStyle(Palette.muted)
                        Text(recording.title).font(.custom("NotoSerifSC-Regular", size: 28)).foregroundStyle(Palette.ink)
                        HStack {
                            Label(recording.source == .watch ? "Apple Watch" : "iPhone", systemImage: recording.source == .watch ? "applewatch" : "iphone")
                            Spacer()
                            Text(durationText(recording.duration)).monospacedDigit()
                        }.font(.subheadline).foregroundStyle(.secondary)
                        if recording.intent == .journal {
                            Label("日记", systemImage: "book.closed")
                                .font(.caption).foregroundStyle(model.theme.color)
                        }
                        if recording.mode == .continuous {
                            Label("全天记录片段", systemImage: "record.circle")
                                .font(.caption).foregroundStyle(model.theme.color)
                        }
                        if !recording.markers.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(recording.markers) { marker in
                                    Label("\(durationText(marker.offset)) · \(marker.intent == .journal ? "日记起点" : "重点标记")",
                                          systemImage: marker.intent == .journal ? "book.closed" : "bookmark.fill")
                                }
                            }
                            .font(.subheadline).foregroundStyle(model.theme.color)
                        }
                        if recording.audioDeletedAt == nil {
                            Button {
                                do { try playback.toggle(url: model.store.audioURL(for: recording)) }
                                catch { model.error = error.localizedDescription }
                            } label: {
                                Label(playback.isPlaying ? "停止回听" : "回听原声", systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                                    .frame(maxWidth: .infinity).padding(12)
                            }.buttonStyle(.bordered).tint(model.theme.color).disabled(capture.isRecording)
                        }
                        if let transcript = recording.transcript {
                            Text(transcript).font(.body).lineSpacing(7).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Label(transcriptionLabel(recording), systemImage: recording.transcriptionState == .transcribing ? "waveform" : "text.alignleft")
                                .foregroundStyle(.secondary)
                        }
                        if let error = recording.lastError { Text(error).font(.subheadline).foregroundStyle(.orange) }
                        if recording.transcriptionState == .failed || recording.transcriptionState == .pending {
                            Button("转写这段录音", systemImage: "arrow.clockwise") { model.retry(recording) }
                                .disabled(!model.transcriptionEnabled || recording.audioDeletedAt != nil || recording.captureState == .recording)
                            if !model.transcriptionEnabled { Text("在首页设置中连接转写服务后即可开始。") .font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                        if recording.audioDeletedAt != nil { Text("原声已到期清理，转写文字继续保留。").font(.footnote).foregroundStyle(.secondary) }
                        else {
                            Toggle("一直保留这段原声", isOn: Binding(get: { recording.isKept }, set: { _ in model.toggleKept(recording) }))
                            Text(retentionDescription(recording)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(24)
                }
                .background(model.theme.background)
                .navigationTitle("记录").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(model.theme.background, for: .navigationBar)
                .toolbar {
                    if let transcript = recording.transcript {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: transcript) { Label("分享文字", systemImage: "square.and.arrow.up") }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("更正", systemImage: "pencil") { editedText = transcript; editing = true }
                        }
                    }
                }
            } else { ContentUnavailableView("记录不可用", systemImage: "doc") }
        }
        .onDisappear { if playback.isPlaying { playback.stop() } }
        .sheet(isPresented: $editing) {
            NavigationStack {
                TextEditor(text: $editedText).scrollContentBackground(.hidden).padding().background(model.theme.background)
                    .navigationTitle("更正文字").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                do { try model.store.completeTranscription(id: recordingID, text: editedText); model.refresh(); editing = false }
                                catch { model.error = error.localizedDescription }
                            }.disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        .preferredColorScheme(.light)
    }

    private func retentionDescription(_ recording: Recording) -> String {
        if recording.isKept { return "这段原声不会自动清理。" }
        guard let expiry = model.retention.expiryDate(for: recording) else { return "已关闭原声自动清理。" }
        return "\(expiry.formatted(date: .abbreviated, time: .omitted)) 后可自动清理；转写未完成时继续保留。"
    }
}
