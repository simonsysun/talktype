import XCTest
@testable import TalkTypeCore

final class CloudASRClientTests: XCTestCase {

    private let base = URL(string: "https://openrouter.ai/api/v1")!
    private let wav = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03])

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
}
