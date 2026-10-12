import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct APIConfiguration: Codable, Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var language: String

    public init(baseURL: String = "https://api.openai.com/v1", model: String = "", language: String = "zh") {
        self.baseURL = baseURL
        self.model = model
        self.language = language
    }

    public var transcriptionURL: URL {
        get throws {
            guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host?.lowercased(), !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil else {
                throw TranscriptionError.invalidURL
            }
            let hostname = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let octets = hostname.split(separator: ".", omittingEmptySubsequences: false)
            let ipv4Loopback = octets.count == 4 && octets.first == "127"
                && octets.allSatisfy {
                    !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
                        && (Int($0).map { (0...255).contains($0) } ?? false)
                }
            let loopback = hostname == "localhost" || ipv4Loopback
                || hostname == "::1" || hostname == "0:0:0:0:0:0:0:1"
            guard scheme == "https" || (scheme == "http" && loopback) else {
                throw TranscriptionError.requiresHTTPS
            }
            components.scheme = scheme
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            if !path.hasSuffix("/audio/transcriptions") { path += "/audio/transcriptions" }
            components.path = path
            guard let url = components.url else { throw TranscriptionError.invalidURL }
            return url
        }
    }
}

public enum TranscriptionError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL, requiresHTTPS, missingModel, unreadableFile, emptyFile, fileTooLarge
    case unauthorized, forbidden, rateLimited, invalidResponse, emptyTranscript, timedOut, network
    case httpFailure(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "转录地址无效，不能包含账号、查询参数或片段。"
        case .requiresHTTPS: "转录地址必须使用 HTTPS；仅本机网关允许 HTTP。"
        case .missingModel: "请填写转录模型。"
        case .unreadableFile: "无法读取录音文件。"
        case .emptyFile: "录音文件为空，请重新录制。"
        case .fileTooLarge: "录音超过 25 MB，请缩短分段后重试。"
        case .unauthorized: "转录服务认证失败，请检查 API Key。"
        case .forbidden: "转录服务拒绝访问，请检查权限。"
        case .rateLimited: "转录服务请求过多，请稍后重试。"
        case .invalidResponse: "转录服务返回了无法识别的结果。"
        case .emptyTranscript: "转录服务没有返回有效文字。"
        case .timedOut: "转录请求超时，请稍后重试。"
        case .network: "无法连接转录服务，请检查网络。"
        case .httpFailure(let status): "转录请求失败（HTTP \(status)）。"
        }
    }
}

public struct TranscriptionClient: Sendable {
    private let session: URLSession
    private let timeout: TimeInterval
    static let maximumFileSize = 25_000_000

    public init(session: URLSession = .shared, timeout: TimeInterval = 120) {
        self.session = session
        self.timeout = timeout
    }

    public func transcribe(fileURL: URL, configuration: APIConfiguration, apiKey: String) async throws -> String {
        let url = try configuration.transcriptionURL
        let boundary = "suiji-\(UUID().uuidString)"
        let bodyURL = try Self.makeMultipartBody(fileURL: fileURL, configuration: configuration, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: bodyURL, delegate: NoRedirectDelegate())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { throw TranscriptionError.timedOut }
            throw TranscriptionError.network
        }
        guard let response = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw TranscriptionError.unauthorized
        case 403: throw TranscriptionError.forbidden
        case 413: throw TranscriptionError.fileTooLarge
        case 429: throw TranscriptionError.rateLimited
        default: throw TranscriptionError.httpFailure(response.statusCode)
        }
        struct Result: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw TranscriptionError.invalidResponse
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        return text
    }

    static func makeMultipartBody(fileURL: URL, configuration: APIConfiguration, boundary: String) throws -> URL {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw TranscriptionError.missingModel }
        guard fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw TranscriptionError.unreadableFile }
        guard size.int64Value > 0 else { throw TranscriptionError.emptyFile }
        guard size.int64Value <= Int64(maximumFileSize) else { throw TranscriptionError.fileTooLarge }

        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("suiji-upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw TranscriptionError.unreadableFile
        }
        do {
            let source = try FileHandle(forReadingFrom: fileURL)
            defer { try? source.close() }
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".utf8))
            let language = configuration.language.trimmingCharacters(in: .whitespacesAndNewlines)
            if !language.isEmpty {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".utf8))
            }
            let filename = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            let mime: String
            switch fileURL.pathExtension.lowercased() {
            case "m4a", "mp4": mime = "audio/mp4"
            case "wav": mime = "audio/wav"
            case "mp3", "mpeg", "mpga": mime = "audio/mpeg"
            case "aac": mime = "audio/aac"
            case "flac": mime = "audio/flac"
            case "ogg": mime = "audio/ogg"
            case "webm": mime = "audio/webm"
            case "caf": mime = "audio/x-caf"
            default: mime = "application/octet-stream"
            }
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            var copiedBytes = 0
            while let chunk = try source.read(upToCount: 65_536), !chunk.isEmpty {
                copiedBytes += chunk.count
                guard copiedBytes <= maximumFileSize else { throw TranscriptionError.fileTooLarge }
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return bodyURL
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            if let error = error as? TranscriptionError { throw error }
            throw TranscriptionError.unreadableFile
        }
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
