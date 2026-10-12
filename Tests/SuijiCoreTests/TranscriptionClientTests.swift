import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SuijiCore

final class TranscriptionClientTests: XCTestCase {
    func testEndpointNormalizationAndLoopback() throws {
        let cases: [(String, String)] = [
            ("https://example.com", "https://example.com/audio/transcriptions"),
            ("https://example.com/v1/", "https://example.com/v1/audio/transcriptions"),
            ("https://example.com/custom/audio/transcriptions/", "https://example.com/custom/audio/transcriptions"),
            ("http://localhost:8080/v1", "http://localhost:8080/v1/audio/transcriptions"),
            ("http://127.0.0.2:8080", "http://127.0.0.2:8080/audio/transcriptions"),
            ("http://[::1]:8080", "http://[::1]:8080/audio/transcriptions")
        ]
        for (base, expected) in cases {
            XCTAssertEqual(try APIConfiguration(baseURL: base).transcriptionURL.absoluteString, expected)
        }
    }

    func testRejectsUnsafeURLs() {
        for base in ["http://example.com", "http://192.168.1.5", "ftp://localhost"] {
            XCTAssertThrowsError(try APIConfiguration(baseURL: base).transcriptionURL) {
                XCTAssertEqual($0 as? TranscriptionError, .requiresHTTPS)
            }
        }
        for base in ["https://user:secret@example.com", "https://example.com?key=secret", "https://example.com#fragment", "example.com"] {
            XCTAssertThrowsError(try APIConfiguration(baseURL: base).transcriptionURL) {
                XCTAssertEqual($0 as? TranscriptionError, .invalidURL)
            }
        }
    }

    func testMultipartUsesOnlyPortableFieldsAndM4AMime() throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bodyURL = try TranscriptionClient.makeMultipartBody(
            fileURL: audio, configuration: APIConfiguration(model: "asr-model", language: "zh"), boundary: "test-boundary")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let body = String(decoding: try Data(contentsOf: bodyURL), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nasr-model\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"\(audio.lastPathComponent)\""))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4\r\n\r\naudio-bytes"))
        XCTAssertEqual(body.components(separatedBy: "Content-Disposition:").count - 1, 3)
        XCTAssertTrue(body.hasSuffix("\r\n--test-boundary--\r\n"))
        XCTAssertEqual(try Data(contentsOf: audio), Data("audio-bytes".utf8))
    }

    func testEmptyLanguageIsOmittedAndModelIsRequired() throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let bodyURL = try TranscriptionClient.makeMultipartBody(
            fileURL: audio, configuration: APIConfiguration(model: "asr-model", language: "  "), boundary: "test")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let body = String(decoding: try Data(contentsOf: bodyURL), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertEqual(body.components(separatedBy: "Content-Disposition:").count - 1, 2)
        XCTAssertThrowsError(try TranscriptionClient.makeMultipartBody(
            fileURL: audio, configuration: APIConfiguration(model: " \n"), boundary: "test")) {
            XCTAssertEqual($0 as? TranscriptionError, .missingModel)
        }
    }

    func testSuccessfulUploadHeadersPathAndTimeout() async throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let (client, configuration) = makeClient(status: 200, body: "{\"text\":\"  测试转录  \"}", timeout: 37)
        let result = try await client.transcribe(fileURL: audio, configuration: configuration, apiKey: "test-token")
        XCTAssertEqual(result, "测试转录")
        let request = try XCTUnwrap(StubURLProtocol.state.request(for: configuration.baseURL))
        XCTAssertEqual(request.url?.path, "/custom/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=suiji-") == true)
        XCTAssertEqual(request.timeoutInterval, 37)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testPrivateGatewayCanOmitAuthorization() async throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let (client, configuration) = makeClient(status: 200, body: "{\"text\":\"无需密钥\"}")
        _ = try await client.transcribe(fileURL: audio, configuration: configuration, apiKey: " \n")
        let request = try XCTUnwrap(StubURLProtocol.state.request(for: configuration.baseURL))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testEmptyAndMalformedSuccessAreNotComplete() async throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        for (body, expected) in [("{\"text\":\" \"}", TranscriptionError.emptyTranscript), ("{}", .invalidResponse), ("not json", .invalidResponse)] {
            let (client, configuration) = makeClient(status: 200, body: body)
            do {
                _ = try await client.transcribe(fileURL: audio, configuration: configuration, apiKey: "")
                XCTFail("空结果不得标为完成")
            } catch { XCTAssertEqual(error as? TranscriptionError, expected) }
        }
    }

    func testHTTPFailuresDoNotExposeResponseBodyOrToken() async throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        for (status, expected) in [(401, TranscriptionError.unauthorized), (429, .rateLimited), (302, .httpFailure(302))] {
            let (client, configuration) = makeClient(status: status, body: "private-response-with-secret-token")
            do {
                _ = try await client.transcribe(fileURL: audio, configuration: configuration, apiKey: "secret-token")
                XCTFail("HTTP 错误不得标为完成")
            } catch {
                XCTAssertEqual(error as? TranscriptionError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret-token"))
                XCTAssertFalse(error.localizedDescription.contains("private-response"))
            }
        }
    }

    func testOversizedAudioIsRejectedAndPreserved() throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let handle = try FileHandle(forWritingTo: audio)
        try handle.seek(toOffset: UInt64(TranscriptionClient.maximumFileSize))
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertThrowsError(try TranscriptionClient.makeMultipartBody(
            fileURL: audio, configuration: APIConfiguration(model: "asr"), boundary: "test")) {
            XCTAssertEqual($0 as? TranscriptionError, .fileTooLarge)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testEmptyAudioIsRejectedBeforeUpload() throws {
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        try Data().write(to: audio)
        XCTAssertThrowsError(try TranscriptionClient.makeMultipartBody(
            fileURL: audio, configuration: APIConfiguration(model: "asr"), boundary: "test")) {
            XCTAssertEqual($0 as? TranscriptionError, .emptyFile)
        }
    }

    func testAllRedirectsAreRejected() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = try XCTUnwrap(URL(string: "https://source.invalid/audio/transcriptions"))
        let target = try XCTUnwrap(URL(string: "https://other.invalid/audio/transcriptions"))
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil, headerFields: nil))
        let task = session.dataTask(with: source)
        NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                       newRequest: URLRequest(url: target)) { redirectedRequest in
            XCTAssertNil(redirectedRequest)
        }
        task.cancel()
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("suiji-test-\(UUID().uuidString).m4a")
        try Data("audio-bytes".utf8).write(to: url)
        return url
    }

    private func makeClient(status: Int, body: String, timeout: TimeInterval = 120) -> (TranscriptionClient, APIConfiguration) {
        let host = "test-\(UUID().uuidString.lowercased()).invalid"
        StubURLProtocol.state.register(host: host, status: status, data: Data(body.utf8))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        return (TranscriptionClient(session: session, timeout: timeout), APIConfiguration(baseURL: "https://\(host)/custom", model: "asr-model"))
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let stub = Self.state.record(request),
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StubState: @unchecked Sendable {
    struct Response { let status: Int; let data: Data }
    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private var requests: [String: URLRequest] = [:]

    func register(host: String, status: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        responses[host] = Response(status: status, data: data)
    }

    func record(_ request: URLRequest) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        guard let host = request.url?.host else { return nil }
        requests[host] = request
        return responses[host]
    }

    func request(for baseURL: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard let host = URL(string: baseURL)?.host else { return nil }
        return requests[host]
    }
}
