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
        let currentModel = model
        let connectivityTaskCount = backgroundTasks.filter { $0 is WKWatchConnectivityRefreshBackgroundTask }.count
        currentModel?.companion.recordWatchRefreshStage("handler_entered", taskCount: backgroundTasks.count,
                                                        connectivityTaskCount: connectivityTaskCount)
        currentModel?.resume()
        currentModel?.companion.recordWatchRefreshStage("resume_returned", taskCount: backgroundTasks.count,
                                                        connectivityTaskCount: connectivityTaskCount)
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask,
               let companion = currentModel?.companion {
                companion.registerBackgroundTask(connectivityTask)
            } else { task.setTaskCompletedWithSnapshot(false) }
        }
        currentModel?.companion.recordWatchRefreshStage("task_registration_finished", taskCount: backgroundTasks.count,
                                                        connectivityTaskCount: connectivityTaskCount)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @AppStorage("watchBotControlsV2HintSeen") private var hintSeen = false
    @GestureState private var touching = false
    @State private var touchStartedAt: Date?
    @State private var touchTranslation = CGSize.zero
    @State private var maximumTravel: CGFloat = 0
    @State private var touchBeganRecording = false
    @State private var choosingMode = false
    @State private var holdTask: Task<Void, Never>?
    @State private var showMore = false
    @State private var recordingIntent: RecordingIntent = .note
    @State private var feedback: String?
    @State private var recordingStoppedUnexpectedly = false

    private let selectionDistance: CGFloat = 42
    private let cancelDistance: CGFloat = 50

    private var continuous: Bool { capture.isRecording && capture.mode == .continuous }
    private var selecting: Bool { touching && choosingMode }
    private var pulling: Bool {
        touching && touchBeganRecording && !continuous && maximumTravel >= 12
    }
    private var cancelIsReady: Bool {
        capture.canDiscardRecording && touchTranslation.height >= cancelDistance
            && abs(touchTranslation.width) < 75
    }
    private var selection: Int {
        guard selecting, abs(touchTranslation.height) < 65 else { return 0 }
        if touchTranslation.width < -selectionDistance { return -1 }
        if touchTranslation.width > selectionDistance { return 1 }
        return 0
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 3) {
                    ZStack {
                        botButton(size: CGSize(width: geometry.size.width, height: max(44, geometry.size.height - 33)))
                            .highPriorityGesture(touchGesture)

                        if selecting {
                            HStack {
                                modeTarget(-1, title: continuous ? "标记" : "录音", icon: continuous ? "bookmark" : "waveform")
                                Spacer(minLength: 8)
                                modeTarget(1, title: continuous ? "日记标记" : "日记", icon: "book.closed")
                            }
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                        }

                        VStack {
                            Spacer()
                            if selecting {
                                Text(selection == 0 ? "拖向两侧 · 松手取消" : "松手确认")
                            } else if pulling {
                                Text(cancelIsReady ? "松手取消" : capture.canDiscardRecording ? "下拉取消 · 拖回继续" : "拖回继续录音")
                            } else if let feedback {
                                Text(feedback)
                            } else if !hintSeen {
                                Text("轻点开停 · 按住更多")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    recordingStatus
                        .frame(height: 27)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .navigationTitle("")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if capture.isRecording && !continuous {
                            if capture.canDiscardRecording { discardRecording() }
                            else { finishRecording() }
                        } else { showMore = true }
                    } label: {
                        Image(systemName: capture.isRecording && !continuous ? (capture.canDiscardRecording ? "xmark" : "stop.fill") : "ellipsis")
                    }
                    .disabled(capture.isStarting || selecting)
                    .accessibilityLabel(capture.isRecording && !continuous ? (capture.canDiscardRecording ? "取消这次录音" : "停止并保存") : "记录与主题")
                }
            }
            .containerBackground(Color.black, for: .navigation)
            .sheet(isPresented: $showMore) {
                NavigationStack {
                    List {
                        if continuous {
                            Button { showMore = false; markRecording(.journal) } label: {
                                Label("标记日记起点", systemImage: "book.closed")
                            }
                            Button { showMore = false; finishRecording() } label: {
                                Label("暂停录音", systemImage: "pause.fill")
                            }
                        } else {
                            Button { showMore = false; beginRecording(.journal) } label: {
                                Label("记日记", systemImage: "book.closed")
                            }
                        }
                        NavigationLink { WatchRecordings(model: model) } label: {
                            Label("最近记录", systemImage: "clock")
                        }
                        NavigationLink { WatchThemePicker(theme: $model.theme) } label: {
                            Label("主题", systemImage: "paintpalette")
                        }
                    }
                    .navigationTitle("更多")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { showMore = false } label: { Image(systemName: "xmark") }
                                .accessibilityLabel("返回录音")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selection) { _, value in
            if value != 0 { WKInterfaceDevice.current().play(.click) }
        }
        .onChange(of: cancelIsReady) { _, ready in
            if ready { WKInterfaceDevice.current().play(.click) }
        }
        .onChange(of: touching) { _, active in
            if !active {
                DispatchQueue.main.async {
                    if !touching { resetTouch() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { resetTouch() }
            capture.noteLifecycle(scenePhase: String(describing: phase), isLuminanceReduced: isLuminanceReduced)
        }
        .onChange(of: isLuminanceReduced) { _, reduced in
            capture.noteLifecycle(scenePhase: String(describing: scenePhase), isLuminanceReduced: reduced)
        }
        .onAppear {
            capture.noteLifecycle(scenePhase: String(describing: scenePhase), isLuminanceReduced: isLuminanceReduced)
        }
        .onChange(of: capture.error) { _, error in
            if error != nil && !capture.isRecording { recordingStoppedUnexpectedly = true }
        }
        .onDisappear { resetTouch() }
        .task {
            guard !hintSeen else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { hintSeen = true }
        }
        .task(id: feedback) {
            guard feedback != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { feedback = nil }
        }
        .alert("需要留意", isPresented: Binding(get: { capture.error != nil || model.error != nil }, set: { if !$0 { capture.clearError(); model.error = nil } })) {
            Button("知道了", role: .cancel) { capture.clearError(); model.error = nil }
        } message: { Text(capture.error ?? model.error ?? "") }
    }

    private var recordingStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(capture.isRecording ? Color.red : Color.white.opacity(0.4))
                .frame(width: 5, height: 5)
            if capture.isStarting { Text("正在开启…") }
            else if capture.isRecording {
                Text(recordingIntent == .journal ? "日记中" : "录音中")
                Text(durationText(capture.elapsed)).monospacedDigit()
            } else { Text(recordingStoppedUnexpectedly ? "录音已中断" : "未录音") }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.65))
        .accessibilityElement(children: .combine)
    }

    private func botButton(size: CGSize) -> some View {
        Button {
            if !touching { primaryAction() }
        } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: scenePhase != .active || reduceMotion)) { context in
                let moving = scenePhase == .active && !reduceMotion && context.cadence == .live && !touching
                let time = context.date.timeIntervalSinceReferenceDate
                let breath = moving ? sin(time * 2 * .pi / 4.2) * 0.035 : 0
                let drift = moving ? sin(time * 2 * .pi / 5.4) * 2.2 : 0
                let blinkPhase = time.truncatingRemainder(dividingBy: 5.8)
                let blink = moving && !capture.isRecording && model.theme == .ink
                    ? 1 - 0.85 * max(0, 1 - abs(blinkPhase - 5.2) / 0.14) : 1
                CompanionVisual(theme: model.theme, listening: capture.isRecording, level: capture.level,
                                size: botTileSize(in: size), watchInkMask: true, centered: true)
                    .scaleEffect(x: 1 + breath, y: (1 + breath) * blink)
                    .scaleEffect(selecting ? 0.48 : 1)
                    .offset(x: selecting ? min(25, max(-25, touchTranslation.width)) : 0,
                            y: drift + (pulling ? min(25, max(0, touchTranslation.height)) : 0))
                    .opacity(selecting ? 0.3 : 1)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(capture.isStarting)
        .handGestureShortcut(.primaryAction, isEnabled: !capture.isStarting && !showMore)
        .accessibilityIdentifier("captureButton")
        .accessibilityLabel(capture.isRecording ? "暂停并保存录音" : "开始持续录音")
        .accessibilityValue(capture.isRecording ? durationText(capture.elapsed) : "未录音")
        .accessibilityHint(continuous ? "轻点暂停，按住后拖左标记、拖右标记日记起点" : capture.isRecording ? "轻点保存，向下拖动可取消未保存的首段" : "轻点持续录音，按住后拖向日记，拖回中央松手取消")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selecting)
    }

    private func botTileSize(in size: CGSize) -> CGFloat {
        let bounds: CGSize
        switch model.theme {
        case .star: bounds = CGSize(width: 0.735, height: 0.696)
        case .ink: bounds = CGSize(width: 0.359, height: 0.196)
        case .sprout: bounds = CGSize(width: 0.851, height: 0.55)
        }
        // Fit visible sprite content, including breathing and meter expansion, inside the Bot area.
        return max(44, min((size.width - 18) / bounds.width, (size.height - 14) / bounds.height) / 1.075)
    }

    private func modeTarget(_ side: Int, title: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.title3)
                .frame(width: 56, height: 56)
                .background(selection == side ? model.theme.color : Color(white: 0.18), in: Circle())
            Text(title).font(.caption2)
        }
        .foregroundStyle(.white)
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if touchStartedAt == nil {
                    touchStartedAt = value.time
                    touchBeganRecording = capture.isRecording
                    maximumTravel = 0
                    if !capture.isRecording || continuous {
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled, touching, maximumTravel < 30 else { return }
                            choosingMode = true
                            WKInterfaceDevice.current().play(.click)
                        }
                    }
                }
                touchTranslation = value.translation
                maximumTravel = max(maximumTravel, hypot(value.translation.width, value.translation.height))
                if maximumTravel >= 30 && !choosingMode { holdTask?.cancel() }
            }
            .onEnded { value in
                guard let startedAt = touchStartedAt else { return }
                let held = value.time.timeIntervalSince(startedAt)
                let wasChoosing = choosingMode
                let beganRecording = touchBeganRecording
                let travel = max(maximumTravel, hypot(value.translation.width, value.translation.height))
                resetTouch()
                guard !capture.isStarting, beganRecording == capture.isRecording else { return }
                if wasChoosing {
                    guard abs(value.translation.height) < 65 else { return }
                    if value.translation.width < -selectionDistance {
                        if continuous { markRecording(.note) } else { beginRecording(.note, mode: .continuous) }
                    } else if value.translation.width > selectionDistance {
                        if continuous { markRecording(.journal) } else { beginRecording(.journal) }
                    }
                } else if travel < 12 && held < 0.4 {
                    primaryAction()
                } else if beganRecording && !continuous && capture.canDiscardRecording
                            && value.translation.height >= cancelDistance && abs(value.translation.width) < 75 {
                    discardRecording()
                }
            }
    }

    private func resetTouch() {
        holdTask?.cancel()
        holdTask = nil
        touchStartedAt = nil
        touchTranslation = .zero
        maximumTravel = 0
        choosingMode = false
    }

    private func primaryAction() {
        guard !capture.isStarting else { return }
        if capture.isRecording { finishRecording() }
        else { beginRecording(.note, mode: .continuous) }
    }

    private func beginRecording(_ intent: RecordingIntent, mode: RecordingMode = .quick) {
        guard !capture.isStarting, !capture.isRecording else { return }
        hintSeen = true
        feedback = nil
        recordingStoppedUnexpectedly = false
        recordingIntent = intent
        Task {
            await capture.start(intent: intent, mode: mode)
            model.refresh()
            if capture.isRecording { WKInterfaceDevice.current().play(.start) }
        }
    }

    private func finishRecording() {
        capture.stop()
        model.refresh()
        if capture.error == nil {
            feedback = "已保存"
            WKInterfaceDevice.current().play(.success)
        }
    }

    private func markRecording(_ intent: RecordingIntent) {
        do {
            _ = try capture.mark(intent: intent)
            model.refresh()
            feedback = intent == .journal ? "已标记日记起点" : "已标记"
            WKInterfaceDevice.current().play(.click)
        } catch { model.error = error.localizedDescription }
    }

    private func discardRecording() {
        do {
            try capture.discardCurrentRecording()
            model.refresh()
            feedback = "已取消"
            WKInterfaceDevice.current().play(.stop)
        } catch { model.error = error.localizedDescription }
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
                    if recording.intent == .journal {
                        Label("日记", systemImage: "book.closed")
                            .font(.caption2).foregroundStyle(model.theme.color)
                    }
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
