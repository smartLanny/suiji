import SwiftUI
import WatchKit

@MainActor
final class WatchApplicationDelegate: NSObject, WKApplicationDelegate {
    let model: SessionModel?
    let bootError: String?

    override init() {
        do { model = try SessionModel(); bootError = nil }
        catch { model = nil; bootError = error.localizedDescription }
        super.init()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                CompanionSync.registerBackgroundTask(connectivityTask)
            } else { task.setTaskCompletedWithSnapshot(false) }
        }
        model?.resume()
    }
}

@main
struct SuijiWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchApplicationDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = delegate.model { WatchHome(model: model, capture: model.capture, companion: model.companion) }
                else if let bootError = delegate.bootError { Text(bootError).font(.footnote).padding() }
                else { ProgressView() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { delegate.model?.resume() } }
        }
    }
}

struct WatchHome: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var capture: AudioCapture
    @ObservedObject var companion: CompanionSync

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(capture.isRecording ? Color(hex: 0xC86D4F) : Color(hex: 0x777770))
                            .frame(width: 6, height: 6)
                        Text(capture.isRecording ? "记录中" : "已暂停")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Palette.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    CompanionVisual(
                        theme: model.theme,
                        listening: capture.isRecording,
                        level: capture.level,
                        size: 134,
                        watchInkMask: true
                    )
                    .padding(.top, -4)

                    Text(capture.isStarting ? "准备中" : capture.isRecording ? "正在倾听" : "想到就说")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.top, -13)

                    if capture.isRecording {
                        Text(durationText(capture.elapsed))
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color(hex: 0xA59B90))
                            .padding(.top, 3)
                    }

                    Button {
                        if capture.isRecording { capture.stop(); model.refresh() }
                        else { Task { await capture.start(); model.refresh() } }
                    } label: {
                        Label(
                            capture.isStarting ? "准备中…" : capture.isRecording ? "结束并保存" : "开始记录",
                            systemImage: capture.isRecording ? "stop.fill" : "mic.fill"
                        )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color(hex: 0x292827), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.top, 13)
                    .disabled(capture.isStarting)
                    .accessibilityIdentifier("captureButton")

                    Text(capture.isRecording ? "原声正在手表保存" : companion.status)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color(hex: 0xA59B90))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 18)
                        .padding(.top, 9)

                    NavigationLink { WatchRecordings(model: model) } label: {
                        HStack(spacing: 5) {
                            Text("最近记录")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color(hex: 0xC1B8AD))
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
            .background(Color.black)
            .navigationTitle("随记")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { WatchThemePicker(theme: $model.theme) }
                        label: { Image(systemName: "paintpalette").foregroundStyle(Color(hex: 0xC1B8AD)) }
                }
            }
            .containerBackground(Color.black, for: .navigation)
        }
        .preferredColorScheme(.dark)
        .alert("需要留意", isPresented: Binding(get: { capture.error != nil || model.error != nil }, set: { if !$0 { capture.clearError(); model.error = nil } })) {
            Button("知道了", role: .cancel) { capture.clearError(); model.error = nil }
        } message: { Text(capture.error ?? model.error ?? "") }
    }
}

struct WatchThemePicker: View {
    @Binding var theme: CompanionTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(CompanionTheme.allCases) { option in
                Button {
                    theme = option
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        CompanionVisual(theme: option, size: 62, watchInkMask: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                            Text(option.description)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hex: 0xA59B90))
                        }
                        Spacer(minLength: 0)
                        if theme == option {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(option.color)
                        }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.black)
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .background(Color.black)
        .navigationTitle("主题")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .containerBackground(Color.black, for: .navigation)
    }
}

struct WatchRecordings: View {
    @ObservedObject var model: SessionModel
    var body: some View {
        List {
            if model.recordings.isEmpty {
                Text("还没有录音")
                    .foregroundStyle(Palette.muted)
                    .listRowBackground(Color.black)
            }
            ForEach(model.recordings.filter { $0.captureState != .recording }.prefix(30)) { recording in
                VStack(alignment: .leading, spacing: 5) {
                    Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white)
                    Text("\(durationText(recording.duration)) · \(recording.phoneReceivedAt == nil ? "等待同步到手机" : "手机已保存")")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Color(hex: 0xA59B90))
                    if let error = recording.lastError {
                        Text(error).font(.system(size: 10, weight: .regular)).foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Color.black)
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .background(Color.black)
        .navigationTitle("最近记录")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .containerBackground(Color.black, for: .navigation)
    }
}
