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

    // MARK: - Request shapes

    func testOpenRouterJSONRequest() throws {
        let request = CloudASRClient.makeRequest(
            shape: .openRouterJSON, baseURL: base, apiKey: "sk-or-test", model: "qwen/qwen3-asr-flash-2026-02-10",
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

    func testOpenAIMultipartRequest() throws {
        let request = CloudASRClient.makeRequest(
            shape: .openAIMultipart, baseURL: base, apiKey: "sk-test", model: "gpt-4o-transcribe",
            audioWAV: wav, vocabularyHints: nil, timeout: 30)

        XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try XCTUnwrap(request.httpBody)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertTrue(text.contains("gpt-4o-transcribe"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(text.contains("response_format"))
    }

    func testDashScopeChatRequest() throws {
        let request = CloudASRClient.makeRequest(
            shape: .dashScopeChat, baseURL: base, apiKey: "sk-dash", model: "qwen3-asr-flash",
            audioWAV: wav, vocabularyHints: ["API"], timeout: 30)

        XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen3-asr-flash")
        XCTAssertNotNil(json["asr_options"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2, "vocab system message + user audio")
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Vocabulary: API")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let audio = try XCTUnwrap(content[0]["input_audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, "data:audio/wav;base64,\(wav.base64EncodedString())",
                       "DashScope wants a data URI")
    }

    func testDashScopeChatOmitsVocabWhenEmpty() throws {
        let request = CloudASRClient.makeRequest(
            shape: .dashScopeChat, baseURL: base, apiKey: "sk-dash", model: "qwen3-asr-flash",
            audioWAV: wav, vocabularyHints: nil, timeout: 30)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "no vocab means no system message")
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

    func testParseChatCompletionsResponse() throws {
        let data = #"{"choices": [{"message": {"content": " 转写结果 "}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try CloudASRClient.parseChatCompletionsResponse(data: data), "转写结果")
    }

    func testParseChatCompletionsResponseThrowsWhenEmpty() {
        XCTAssertThrowsError(try CloudASRClient.parseChatCompletionsResponse(data: Data(#"{"choices": []}"#.utf8)))
        XCTAssertThrowsError(try CloudASRClient.parseChatCompletionsResponse(data: Data("{}".utf8)))
    }

    func testCheckStatus() throws {
        let ok = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertNoThrow(try CloudASRClient.checkStatus(data: Data(), response: ok))

        let bad = HTTPURLResponse(url: base, statusCode: 401, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try CloudASRClient.checkStatus(data: Data("unauthorized".utf8), response: bad))
    }

    func testValidationPathOpenRouterUsesAuthEndpoint() {
        XCTAssertEqual(CloudASRClient.validationPath(for: "https://openrouter.ai/api/v1"), "auth/key")
        XCTAssertEqual(CloudASRClient.validationPath(for: "https://api.openai.com/v1"), "models")
        XCTAssertEqual(CloudASRClient.validationPath(for: "https://dashscope.aliyuncs.com/compatible-mode/v1"), "models")
        XCTAssertEqual(CloudASRClient.validationPath(for: "https://api.groq.com/openai/v1"), "models")
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
        return CloudASRClient(baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-or-test",
                              model: "qwen/qwen3-asr-flash", shape: .openRouterJSON,
                              timeout: timeout, session: URLSession(configuration: config))
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
        XCTAssertEqual(CloudASRClient.validate(apiKey: "sk-or-good",
                                               baseURL: "https://openrouter.ai/api/v1"), .valid)
    }

    func testValidateRejectsNon200() {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        XCTAssertEqual(CloudASRClient.validate(apiKey: "sk-or-bad",
                                               baseURL: "https://openrouter.ai/api/v1"), .rejected)
    }

    /// Offline must not read as "the key was rejected" — the fixes are different.
    func testValidateDistinguishesNetworkFailureFromRejection() {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let result = CloudASRClient.validate(apiKey: "sk-or-x",
                                             baseURL: "https://openrouter.ai/api/v1")
        guard case .unreachable = result else {
            return XCTFail("expected .unreachable, got \(result)")
        }
    }

    func testValidateRejectsMalformedURL() {
        XCTAssertEqual(CloudASRClient.validate(apiKey: "sk-or-x", baseURL: "not a url"), .invalidURL)
        XCTAssertEqual(CloudASRClient.validate(apiKey: "sk-or-x", baseURL: ""), .invalidURL)
    }
}
