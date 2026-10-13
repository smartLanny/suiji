import Foundation
import Combine
#if os(iOS)
import UIKit
import Security
#endif

@MainActor
final class SessionModel: ObservableObject {
    let store: RecordingStore
    let capture: AudioCapture
    let companion: CompanionSync
    @Published private(set) var recordings: [Recording] = []
    @Published var error: String?
    @Published var retention: RetentionPolicy
    @Published var theme: CompanionTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "companionTheme") }
    }
    #if os(iOS)
    @Published var configuration: APIConfiguration
    @Published private(set) var transcriptionEnabled: Bool
    private var transcriptionTask: Task<Void, Never>?
    private var resumeAfterCancellation = false
    #endif

    init() throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true).appendingPathComponent("Suiji", isDirectory: true)
        store = try RecordingStore(root: root)
        let diagnostics = CaptureDiagnostics(root: root)
        #if os(watchOS)
        capture = AudioCapture(store: store, source: .watch, diagnostics: diagnostics)
        #else
        capture = AudioCapture(store: store, source: .phone, diagnostics: diagnostics)
        #endif
        companion = CompanionSync(store: store, diagnostics: diagnostics)
        if let data = UserDefaults.standard.data(forKey: "retention"),
           let policy = try? JSONDecoder().decode(RetentionPolicy.self, from: data) {
            retention = policy
        } else { retention = RetentionPolicy() }
        theme = CompanionTheme(rawValue: UserDefaults.standard.string(forKey: "companionTheme") ?? "ink") ?? .ink
        #if os(iOS)
        if let data = UserDefaults.standard.data(forKey: "apiConfiguration"),
           let saved = try? JSONDecoder().decode(APIConfiguration.self, from: data) {
            configuration = saved
        } else { configuration = APIConfiguration() }
        transcriptionEnabled = UserDefaults.standard.bool(forKey: "transcriptionEnabled")
        #endif
        capture.onSaved = { [weak self] _ in
            self?.refresh()
            self?.companion.enqueuePending()
            #if os(iOS)
            self?.processQueue()
            #endif
        }
        companion.onChange = { [weak self] in
            self?.refresh()
            #if os(iOS)
            self?.processQueue()
            #endif
        }
        refresh()
        companion.activate()
    }

    func resume() {
        refresh()
        companion.enqueuePending()
        #if os(iOS)
        cleanup()
        processQueue()
        #endif
    }

    func refresh() { recordings = store.all() }

    func toggleKept(_ recording: Recording) {
        do { try store.setKept(id: recording.id, kept: !recording.isKept); refresh() }
        catch { self.error = error.localizedDescription }
    }

    func saveRetention(days: Int?) {
        guard days == nil || (1...3650).contains(days!) else { error = "保存天数需为 1 至 3650 天。"; return }
        do {
            let policy = RetentionPolicy(days: days)
            UserDefaults.standard.set(try JSONEncoder().encode(policy), forKey: "retention")
            retention = policy
            #if os(iOS)
            cleanup()
            #endif
        } catch { self.error = error.localizedDescription }
    }

    #if os(iOS)
    func saveAPI(configuration: APIConfiguration, key: String) throws {
        try APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: "apiConfiguration")
        self.configuration = configuration
        transcriptionEnabled = true
        UserDefaults.standard.set(true, forKey: "transcriptionEnabled")
        retryFailed()
    }

    func pauseTranscription() {
        transcriptionEnabled = false
        UserDefaults.standard.set(false, forKey: "transcriptionEnabled")
        transcriptionTask?.cancel()
    }

    func retry(_ recording: Recording) {
        do { try store.retryTranscription(id: recording.id); refresh(); processQueue() }
        catch { self.error = error.localizedDescription }
    }

    func retryFailed() {
        do {
            for recording in store.all() where recording.transcriptionState == .failed && recording.audioDeletedAt == nil {
                try store.retryTranscription(id: recording.id)
            }
            refresh()
            processQueue()
        } catch { self.error = error.localizedDescription }
    }

    func processQueue() {
        guard transcriptionEnabled else { return }
        if let task = transcriptionTask {
            if task.isCancelled { resumeAfterCancellation = true }
            return
        }
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                transcriptionTask = nil
                refresh()
                if resumeAfterCancellation {
                    resumeAfterCancellation = false
                    processQueue()
                }
            }
            while !Task.isCancelled, transcriptionEnabled,
                  let recording = store.all().reversed().first(where: \.isReadyForTranscription) {
                var backgroundID = UIBackgroundTaskIdentifier.invalid
                backgroundID = UIApplication.shared.beginBackgroundTask(withName: "保存转写") { [weak self] in
                    self?.transcriptionTask?.cancel()
                }
                do {
                    try store.setTranscribing(id: recording.id)
                    refresh()
                    let key = try APIKeyStore.load()
                    let text = try await TranscriptionClient().transcribe(fileURL: store.audioURL(for: recording), configuration: configuration, apiKey: key)
                    try Task.checkCancellation()
                    try store.completeTranscription(id: recording.id, text: text)
                    cleanup()
                } catch {
                    do {
                        if Task.isCancelled { try store.retryTranscription(id: recording.id) }
                        else { try store.failTranscription(id: recording.id, message: error.localizedDescription) }
                    } catch { self.error = error.localizedDescription }
                }
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
                refresh()
            }
        }
    }

    private func cleanup() {
        do { try store.cleanup(policy: retention); refresh() }
        catch { self.error = error.localizedDescription }
    }
    #endif
}

#if os(iOS)
enum APIKeyStore {
    private static let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.lann.suiji.transcription",
        kSecAttrAccount as String: "apiKey"
    ]

    static func load() throws -> String {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeyError.unavailable(status)
        }
        return key
    }

    static func save(_ key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyError.unavailable(status) }
    }

    enum KeyError: LocalizedError {
        case unavailable(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unavailable(errSecInteractionNotAllowed):
                return "钥匙串暂不可用，请解锁手机后再试。"
            case .unavailable(errSecMissingEntitlement):
                return "当前安装的签名配置不完整，请更新安装随记后重试。"
            case .unavailable:
                return "暂时无法访问系统钥匙串，请稍后重试。"
            }
        }
    }
}
#endif
