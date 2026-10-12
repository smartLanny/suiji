import SwiftUI
import UIKit

@MainActor
final class PhoneApplicationDelegate: NSObject, UIApplicationDelegate {
    let model: SessionModel?
    let bootError: String?

    override init() {
        do { model = try SessionModel(); bootError = nil }
        catch { model = nil; bootError = error.localizedDescription }
        super.init()
    }
}

@main
struct SuijiApp: App {
    @UIApplicationDelegateAdaptor(PhoneApplicationDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = delegate.model { PhoneHome(model: model, capture: model.capture, companion: model.companion) }
                else if let bootError = delegate.bootError { ContentUnavailableView("记录暂时无法打开", systemImage: "externaldrive.badge.exclamationmark", description: Text(bootError + "\n已有文件会保留。")) }
                else { ProgressView("打开随记") }
            }
            .task { delegate.model?.resume() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { delegate.model?.resume() } }
        }
    }
}

struct PhoneHome: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var capture: AudioCapture
    @ObservedObject var companion: CompanionSync
    @State private var settingsOpen = false
    @State private var appearanceOpen = false
    @State private var selectedTab = 0
    @State private var query = ""
    @State private var positionedToday = false

    private var visibleRecordings: [Recording] {
        model.recordings.filter { $0.captureState != .recording || $0.lastError != nil }
    }
    private var today: [Recording] {
        visibleRecordings.filter { Calendar.current.isDateInToday($0.recordedAt) }.sorted { $0.recordedAt < $1.recordedAt }
    }
    private var pending: [Recording] {
        visibleRecordings.filter { $0.transcriptionState != .completed }
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                timeline
                    .tabItem { Label("今天", systemImage: "house") }.tag(0)
                memories
                    .tabItem { Label("记忆", systemImage: "book") }.tag(1)
                inbox
                    .tabItem { Label("待处理", systemImage: "tray") }.tag(2)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("随记").font(.custom("Songti SC", size: 22)).foregroundStyle(Palette.ink) }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 5) {
                        Circle().fill(capture.isRecording ? model.theme.color : Palette.muted).frame(width: 5, height: 5)
                        Text(capture.isRecording ? "正在记录" : "随时记下").font(.caption2)
                    }.foregroundStyle(capture.isRecording ? model.theme.color : Palette.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") { settingsOpen = true }
                }
            }
            .toolbarBackground(model.theme.background.opacity(0.94), for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in RecordingDetail(model: model, capture: capture, recordingID: id) }
        }
        .tint(model.theme.color)
        .preferredColorScheme(.light)
        .sheet(isPresented: $settingsOpen) { SettingsView(model: model) }
        .sheet(isPresented: $appearanceOpen) { AppearanceView(model: model) }
        .alert("需要留意", isPresented: Binding(get: { model.error != nil || capture.error != nil }, set: { if !$0 { model.error = nil; capture.clearError() } })) {
            Button("知道了", role: .cancel) { model.error = nil; capture.clearError() }
        } message: { Text(model.error ?? capture.error ?? "") }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    HStack {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(chineseDate).font(.custom("Songti SC", size: 34))
                            Text(Date().formatted(.dateTime.weekday(.wide)) + " · 今天").font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button { appearanceOpen = true } label: {
                            CompanionVisual(theme: model.theme, listening: capture.isRecording, level: capture.level, size: 77)
                        }.buttonStyle(.plain).accessibilityLabel("切换陪伴形象")
                    }.padding(.top, 18)

                    if today.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("今天，值得留下的").font(.custom("Songti SC", size: 24))
                            Text("一个突然的想法，\n一句想记住的话，\n都可以从这里开始。")
                                .font(.body).lineSpacing(7).foregroundStyle(Palette.muted)
                        }.padding(.vertical, 15)
                    }
                    VStack(spacing: 0) {
                        ForEach(today) { recording in
                            NavigationLink(value: recording.id) { TimelineRow(recording: recording, theme: model.theme) }.buttonStyle(.plain)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            Text("现在").font(.caption).frame(width: 42, alignment: .leading)
                            Circle().fill(model.theme.color).frame(width: 7, height: 7).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(capture.isRecording ? "正在倾听" : "想到什么，就记下来")
                                    .font(.custom("Songti SC", size: 21))
                                Text(capture.isRecording ? "\(durationText(capture.elapsed)) · 原声正在保存" : "轻点下方，说一句。")
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(model.theme.color).padding(.top, 18).padding(.bottom, 24).id("now")
                    }
                    if !model.transcriptionEnabled {
                        Button { settingsOpen = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "text.bubble")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("让记录变成文字").font(.subheadline.weight(.medium))
                                    Text("连接一次转写服务，之后自动处理").font(.caption).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(16).background(model.theme.softColor.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                    if !today.isEmpty {
                        HStack {
                            Text("今天已留下 \(today.count) 段记录").font(.caption).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("全部记忆", systemImage: "arrow.up.right") { selectedTab = 1 }.font(.caption)
                        }
                    }
                }.padding(.horizontal, 25).padding(.bottom, 20)
            }
            .background(model.theme.background)
            .safeAreaInset(edge: .bottom) { captureDock }
            .onAppear {
                if !positionedToday { proxy.scrollTo("now", anchor: .center); positionedToday = true }
            }
        }
    }

    private var memories: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("记忆").font(.custom("Songti SC", size: 34)).padding(.top, 20)
                Text("那些不想忘记的，慢慢留在这里。").font(.subheadline).foregroundStyle(Palette.muted)
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("搜索记录", text: $query).submitLabel(.search)
                    if !query.isEmpty { Button("清空", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly) }
                }.padding(13).background(model.theme.softColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
                let matches = visibleRecordings.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.transcript?.localizedCaseInsensitiveContains(query) ?? false) }
                if matches.isEmpty {
                    Text(query.isEmpty ? "还没有记录，说一句就能留下。" : "没有找到相关记录，试试其他词。").foregroundStyle(Palette.muted).padding(.vertical, 24)
                }
                ForEach(matches) { recording in
                    NavigationLink(value: recording.id) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(recording.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Palette.muted)
                            Text(recording.title).font(.headline).foregroundStyle(Palette.ink).lineLimit(2)
                            Text(recording.transcript ?? transcriptionLabel(recording)).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(3)
                            Rectangle().fill(Palette.line).frame(height: 0.5).padding(.top, 12)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 25).padding(.bottom, 24)
        }
        .background(model.theme.background)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { captureDock }
    }

    private var inbox: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("待处理").font(.custom("Songti SC", size: 34)).padding(.top, 20)
                Text(pending.isEmpty ? "都已收好，留点时间给自己。" : "原声已经收好，文字会在这里接上。")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if pending.isEmpty {
                    HStack { Image(systemName: "checkmark.circle"); Text("暂时没有需要处理的记录") }
                        .font(.subheadline).foregroundStyle(Palette.muted).padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
                } else {
                    if !model.transcriptionEnabled {
                        Button("连接转写服务", systemImage: "slider.horizontal.3") { settingsOpen = true }.buttonStyle(.bordered)
                    }
                    ForEach(pending) { recording in
                        NavigationLink(value: recording.id) { TimelineRow(recording: recording, theme: model.theme) }.buttonStyle(.plain)
                    }
                }
            }.padding(.horizontal, 25).padding(.bottom, 24)
        }.background(model.theme.background).safeAreaInset(edge: .bottom) { captureDock }
    }

    private var captureDock: some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            if capture.isRecording { capture.stop(); model.refresh() }
            else { Task { await capture.start(); model.refresh() } }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: capture.isRecording ? "stop.fill" : "mic")
                Text(capture.isRecording ? "停止并保存 · \(durationText(capture.elapsed))" : "说一句").fontWeight(.medium)
            }
            .font(.system(size: 17)).frame(maxWidth: .infinity).frame(height: 49)
        }
        .buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.95))
        .background(capture.isRecording ? model.theme.color.opacity(0.84) : model.theme.color, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 0.7))
        .shadow(color: model.theme.color.opacity(0.14), radius: 10, y: 4)
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 10)
        .disabled(capture.isStarting).accessibilityIdentifier("captureButton")
    }

    private var chineseDate: String {
        let numbers = NumberFormatter()
        numbers.locale = Locale(identifier: "zh_CN")
        numbers.numberStyle = .spellOut
        let parts = Calendar.current.dateComponents([.month, .day], from: Date())
        return (numbers.string(from: NSNumber(value: parts.month ?? 1)) ?? "") + "月" + (numbers.string(from: NSNumber(value: parts.day ?? 1)) ?? "") + "日"
    }
}

struct TimelineRow: View {
    let recording: Recording
    let theme: CompanionTheme
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(recording.recordedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                .frame(width: 43, alignment: .leading).padding(.top, 2)
            VStack(spacing: 8) {
                Image(systemName: recording.source == .watch ? "applewatch" : "waveform")
                    .font(.system(size: 11)).foregroundStyle(theme.color).frame(width: 14, height: 18)
                Rectangle().fill(Palette.line).frame(width: 0.6)
            }.frame(width: 14)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(recording.source == .watch ? "手表随记" : "随手记下").font(.caption2).foregroundStyle(Palette.muted)
                    Spacer()
                    if recording.isKept { Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(theme.color) }
                }
                Text(recording.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(2)
                if let transcript = recording.transcript { Text(transcript).font(.system(size: 13)).lineSpacing(4).foregroundStyle(Palette.muted).lineLimit(3) }
                HStack(spacing: 6) {
                    Text(durationText(recording.duration))
                    Text("·")
                    Text(transcriptionLabel(recording))
                }.font(.caption2).foregroundStyle(recording.transcriptionState == .failed ? theme.color : Palette.muted)
                Rectangle().fill(Palette.line).frame(height: 0.5).padding(.top, 8)
            }.padding(.bottom, 20)
        }.contentShape(Rectangle())
    }
}

func transcriptionLabel(_ recording: Recording) -> String {
    if recording.captureState == .recording { return "原声待恢复" }
    switch recording.transcriptionState {
    case .pending: return "已保存 · 待转写"
    case .transcribing: return "正在转写"
    case .completed: return recording.audioDeletedAt == nil ? "已转写" : "文字已保存 · 原声已到期"
    case .failed: return "转写待重试 · 原声已保存"
    }
}

struct AppearanceView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ForEach([CompanionTheme.star, .ink, .sprout]) { theme in
                    Button {
                        model.theme = theme
                        dismiss()
                    } label: {
                        HStack(spacing: 13) {
                            CompanionVisual(theme: theme, size: 72)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(theme.title).font(.headline).foregroundStyle(Palette.ink)
                                Text(theme.description).font(.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Image(systemName: model.theme == theme ? "checkmark.circle.fill" : "circle").foregroundStyle(theme.color)
                        }.padding(12).frame(maxWidth: .infinity)
                        .background(model.theme == theme ? theme.softColor : Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 17))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(model.theme == theme ? theme.color.opacity(0.45) : Palette.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }.padding(22).background(model.theme.background)
                .navigationTitle("外观").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) } }
        }.presentationDetents([.height(435)]).presentationDragIndicator(.visible)
            .preferredColorScheme(.light)
    }
}
