import XCTest
@testable import TalkTypeCore

final class CloudASRClientTests: XCTestCase {

    private let base = URL(string: "https://openrouter.ai/api/v1")!
    private let wav = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03])

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    // MARK: - Vocabulary

    func testBuildPromptIsBareCommaList() {
        XCTAssertEqual(CloudASRClient.buildPrompt(vocabularyHints: ["API", " GPT-4o "]), "API, GPT-4o")
        XCTAssertEqual(CloudASRClient.buildPrompt(vocabularyHints: ["line\nbreak"]), "line break")
        XCTAssertNil(CloudASRClient.buildPrompt(vocabularyHints: []))
        XCTAssertNil(CloudASRClient.buildPrompt(vocabularyHints: ["  ", "\n"]))
        XCTAssertNil(CloudASRClient.buildPrompt(vocabularyHints: nil))
    }

    // MARK: - Request shape

    func testOpenRouterJSONRequest() throws {
        let request = CloudASRClient.makeRequest(
            baseURL: base, apiKey: "sk-or-test", model: "qwen/qwen3-asr-flash-2026-02-10",
            audioWAV: wav, vocabularyHints: ["TalkType"], timeout: 30)

        XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen/qwen3-asr-flash-2026-02-10")
        XCTAssertEqual(json["prompt"] as? String, "TalkType")
        let audio = try XCTUnwrap(json["input_audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "wav")
        XCTAssertEqual(audio["data"] as? String, wav.base64EncodedString())
        XCTAssertNotEqual(audio["data"] as? String, "data:audio/wav;base64,\(wav.base64EncodedString())",
                          "OpenRouter wants raw base64, not a data URI")
    }

    // MARK: - Response parsing

    func testParseTranscriptionsResponse() throws {
        let data = #"{"text": "  你好 world  "}"#.data(using: .utf8)!
        XCTAssertEqual(try CloudASRClient.parseTranscriptionsResponse(data: data), "你好 world")
    }

    func testParseTranscriptionsResponseThrowsWhenEmpty() {
        XCTAssertThrowsError(try CloudASRClient.parseTranscriptionsResponse(data: Data("{}".utf8)))
        XCTAssertThrowsError(try CloudASRClient.parseTranscriptionsResponse(data: Data("garbage".utf8)))
    }

    func testCheckStatus() throws {
        let ok = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertNoThrow(try CloudASRClient.checkStatus(data: Data(), response: ok))

        let bad = HTTPURLResponse(url: base, statusCode: 401, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try CloudASRClient.checkStatus(data: Data("unauthorized".utf8), response: bad))
    }

    // MARK: - Error classification

    func testClassificationInvalidKey() {
        XCTAssertEqual(CloudASRError.badStatus(statusCode: 401, body: "").classification, .invalidKey)
        XCTAssertEqual(CloudASRError.badStatus(statusCode: 403, body: "").classification, .invalidKey)
    }

    func testClassificationQuotaOrRateLimit() {
        XCTAssertEqual(CloudASRError.badStatus(statusCode: 402, body: "").classification, .limitOrRate)
        XCTAssertEqual(CloudASRError.badStatus(statusCode: 429, body: "").classification, .limitOrRate)
    }

    func testClassificationTimeout() {
        XCTAssertEqual(CloudASRError.timedOut.classification, .timeout)
        XCTAssertEqual(CloudASRError.badStatus(statusCode: 408, body: "").classification, .timeout)
    }

    func testClassificationServiceError() {
        XCTAssertEqual(CloudASRError.badStatus(statusCode: 500, body: "").classification, .serviceError)
        XCTAssertEqual(CloudASRError.badStatus(statusCode: 502, body: "").classification, .serviceError)
        XCTAssertEqual(CloudASRError.emptyResponse.classification, .serviceError)
    }

    func testClassificationUnreachableIsUnknown() {
        XCTAssertEqual(CloudASRError.unreachable(underlying: "connection reset").classification, .unknown)
    }

    // MARK: - Live request behaviour (stubbed)

    private func makeClient(timeout: TimeInterval = 5) -> CloudASRClient {
        // Registered URLProtocol classes are only consulted by URLSession.shared; a
        // session the client owns needs the stub wired in explicitly.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return CloudASRClient(apiKey: "sk-or-test", timeout: timeout,
                              session: URLSession(configuration: config))
    }

    func testTranscribeSyncReturnsParsedText() throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"  hello world  "}"#.utf8))
        }
        XCTAssertEqual(try makeClient().transcribeSync(audio: [0.1, 0.2, 0.3]), "hello world")
    }

    func testTranscribeSyncSurfacesHTTPStatusClassification() {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 402,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"insufficient_quota"}"#.utf8))
        }
        do {
            _ = try makeClient().transcribeSync(audio: [0.1])
            XCTFail("expected an error")
        } catch let error as CloudASRError {
            XCTAssertEqual(error.classification, .limitOrRate)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTranscribeSyncSurfacesConnectionFailures() {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try makeClient().transcribeSync(audio: [0.1])
            XCTFail("expected an error")
        } catch let error as CloudASRError {
            XCTAssertEqual(error.classification, .unknown)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The semaphore backstop exists because URLSession can fail to call back; a server
    /// that never answers must produce .timedOut, not a permanently hung dictation.
    func testTranscribeSyncTimesOutWhenServerNeverAnswers() {
        MockURLProtocol.handler = { request in
            Thread.sleep(forTimeInterval: 2)
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"late"}"#.utf8))
        }
        do {
            _ = try makeClient(timeout: 0.3).transcribeSync(audio: [0.1])
            XCTFail("expected a timeout")
        } catch let error as CloudASRError {
            XCTAssertEqual(error.classification, .timeout)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Key validation (stubbed)

    func testValidateAccepts200() {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/key", "OpenRouter must be checked via /auth/key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-good")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        XCTAssertEqual(CloudASRClient.validate(apiKey: "sk-or-good"), .valid)
    }

    func testValidateRejectsNon200() {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        XCTAssertEqual(CloudASRClient.validate(apiKey: "sk-or-bad"), .rejected)
    }

    /// Offline must not read as "the key was rejected" — the fixes are different.
    func testValidateDistinguishesNetworkFailureFromRejection() {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let result = CloudASRClient.validate(apiKey: "sk-or-x")
        guard case .unreachable = result else {
            return XCTFail("expected .unreachable, got \(result)")
        }
    }

    func testValidateRejectsMalformedURL() {
        XCTAssertEqual(CloudASRClient.validate(apiKey: "sk-or-x", baseURL: "not a url"), .invalidURL)
        XCTAssertEqual(CloudASRClient.validate(apiKey: "sk-or-x", baseURL: ""), .invalidURL)
    }
}
