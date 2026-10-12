import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var modelName = ""
    @State private var language = "zh"
    @State private var key = ""
    @State private var days = "30"
    @State private var forever = false
    @State private var message: String?
    @State private var cleanupConfirmation = false
    @State private var expiredCount = 0
    @State private var loadedKey = false
    @State private var appearanceOpen = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("接口地址") { TextField("https://…/v1", text: $baseURL).multilineTextAlignment(.trailing).keyboardType(.URL) }
                    LabeledContent("语音模型") { TextField("服务商提供的模型名称", text: $modelName).multilineTextAlignment(.trailing) }
                    SecureField("API Key（无鉴权服务可留空）", text: $key)
                    LabeledContent("语言") { TextField("zh 或留空自动识别", text: $language).multilineTextAlignment(.trailing) }
                    Button("保存并开始转写") { saveConfiguration() }.disabled(!loadedKey)
                    if model.transcriptionEnabled { Button("暂停自动转写") { model.pauseTranscription(); notice = "已暂停自动转写，录音继续正常保存。" } }
                } header: { Text("转写服务") } footer: {
                    Text("填写 OpenAI 兼容接口的基础地址和语音模型。录音会发送至该地址，密钥仅存于此手机的系统钥匙串。打开 App 后会继续处理待转写记录。")
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                Section {
                    Toggle("永久保留原声", isOn: $forever)
                    if !forever {
                        LabeledContent("保存天数") { TextField("30", text: $days).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
                        HStack { ForEach([7, 30, 90, 365], id: \.self) { count in
                            Button("\(count) 天") { days = String(count); applyRetention() }.buttonStyle(.bordered).font(.caption)
                        } }
                    }
                    Button("应用保存期限") { applyRetention() }
                } header: { Text("原声保存") } footer: {
                    Text("默认 30 天，可设为 1 至 3650 天或永久保存。转写文字长期保留；未完成转写和手动保留的原声不会自动清理。手表在手机确认保存后释放本地副本。")
                }
                Section("陪伴形象") {
                    Button { appearanceOpen = true } label: {
                        HStack {
                            CompanionVisual(theme: model.theme, size: 44)
                            Text(model.theme.title).foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }.buttonStyle(.plain)
                }
                Section {
                    LabeledContent("已保存记录", value: String(model.recordings.filter { $0.captureState != .recording }.count))
                    LabeledContent("待转写", value: String(model.recordings.filter { $0.isReadyForTranscription }.count))
                    LabeledContent("需要重试", value: String(model.recordings.filter { $0.transcriptionState == .failed }.count))
                    Button("重试失败的转写") { model.retryFailed() }.disabled(!model.transcriptionEnabled)
                } header: { Text("记录状态") }
                if let notice { Section { Text(notice).font(.footnote).foregroundStyle(model.theme.color) } }
            }
            .scrollContentBackground(.hidden).background(model.theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .task {
                baseURL = model.configuration.baseURL
                modelName = model.configuration.model
                language = model.configuration.language
                days = String(model.retention.days ?? 30)
                forever = model.retention.days == nil
                do { key = try APIKeyStore.load(); loadedKey = true }
                catch { message = error.localizedDescription }
            }
            .alert("随记", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .confirmationDialog("这会清理 \(expiredCount) 段已转写的到期原声，文字继续保留。", isPresented: $cleanupConfirmation, titleVisibility: .visible) {
                Button("应用并清理原声", role: .destructive) { commitRetention() }
            }
            .sheet(isPresented: $appearanceOpen) { AppearanceView(model: model) }
        }.tint(model.theme.color)
    }

    private func saveConfiguration() {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let configuration = APIConfiguration(baseURL: address, model: name, language: language.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try configuration.transcriptionURL
            guard !name.isEmpty else { throw TranscriptionError.missingModel }
            try model.saveAPI(configuration: configuration, key: key)
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private func applyRetention() {
        guard forever || Int(days).map({ (1...3650).contains($0) }) == true else { message = "请输入 1 至 3650 天。"; return }
        expiredCount = model.store.expiredAudio(policy: RetentionPolicy(days: forever ? nil : Int(days))).count
        if expiredCount > 0 { cleanupConfirmation = true }
        else { commitRetention() }
    }

    private func commitRetention() {
        model.saveRetention(days: forever ? nil : Int(days))
        notice = "原声保存期限已更新。"
    }
}
