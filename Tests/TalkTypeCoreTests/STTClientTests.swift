import XCTest
@testable import TalkTypeCore

/// These tests are the part of the four integrations that can be verified without an API
/// key: what exactly goes on the wire, and what comes back off it. The parameters asserted
/// here are the ones that decide output quality — filler removal, code-switching, term
/// biasing — so a silent regression in any of them would change what the user sees without
/// changing anything visible in the app.
final class STTClientTests: XCTestCase {

    private let wav = WAVEncoder.encode(samples: [0.1, -0.1, 0.2], sampleRate: 16000)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func ok(_ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200,
                         httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private func status(_ code: Int, _ body: String = "{}") -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: code,
                         httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    /// Field names in the order they appear in the body, plus each one's value. A file part
    /// reports its value as "<file>" — the bytes are not what these tests are about, but
    /// the position is: xAI requires the file last.
    private func parts(of request: URLRequest) -> [(name: String, value: String)] {
        guard let body = request.httpBody,
              let text = String(data: body, encoding: .isoLatin1),
              let contentType = request.value(forHTTPHeaderField: "Content-Type"),
              let boundary = contentType.components(separatedBy: "boundary=").last
        else { return [] }

        var found: [(String, String)] = []
        for chunk in text.components(separatedBy: "--\(boundary)") {
            guard let range = chunk.range(of: "name=\"") else { continue }
            let afterName = chunk[range.upperBound...]
            guard let quote = afterName.firstIndex(of: "\"") else { continue }
            let name = String(afterName[..<quote])
            if chunk.contains("filename=") {
                found.append((name, "<file>"))
                continue
            }
            guard let bodyStart = chunk.range(of: "\r\n\r\n") else { continue }
            let value = chunk[bodyStart.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            found.append((name, value))
        }
        return found
    }

    private func value(_ name: String, in request: URLRequest) -> String? {
        parts(of: request).first { $0.name == name }?.value
    }

    private func values(_ name: String, in request: URLRequest) -> [String] {
        parts(of: request).filter { $0.name == name }.map { $0.value }
    }

    // MARK: - Grok

    func testGrokSendsLanguageFormatAndFillerRemoval() {
        let request = GrokSTTClient.makeRequest(apiKey: "k", language: "zh", wav: wav,
                                                terms: [], timeout: 10)
        XCTAssertEqual(value("language", in: request), "zh")
        XCTAssertEqual(value("format", in: request), "true",
                       "text normalization is the reason to send a language at all")
        XCTAssertEqual(value("filler_words", in: request), "false",
                       "filler removal is the polish we are relying on")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    /// xAI rejects `format` without a language, so blanking the language must drop both.
    func testGrokOmitsFormatWhenLanguageIsBlank() {
        let request = GrokSTTClient.makeRequest(apiKey: "k", language: "", wav: wav,
                                                terms: [], timeout: 10)
        XCTAssertNil(value("language", in: request))
        XCTAssertNil(value("format", in: request))
        XCTAssertEqual(value("filler_words", in: request), "false")
    }

    /// Documented xAI requirement: the file part must come last.
    func testGrokPutsTheFilePartLast() {
        let request = GrokSTTClient.makeRequest(apiKey: "k", language: "zh", wav: wav,
                                                terms: ["Kubernetes", "P95"], timeout: 10)
        XCTAssertEqual(parts(of: request).last?.name, "file")
        XCTAssertEqual(parts(of: request).last?.value, "<file>")
    }

    func testGrokRepeatsKeytermFieldAndCapsAtHundred() {
        let many = (1...150).map { "term\($0)" }
        let request = GrokSTTClient.makeRequest(apiKey: "k", language: "zh", wav: wav,
                                                terms: many, timeout: 10)
        let sent = values("keyterm", in: request)
        XCTAssertEqual(sent.count, GrokSTTClient.maxTerms)
        XCTAssertEqual(sent.first, "term1")
    }

    // MARK: - ElevenLabs

    func testElevenLabsForcesNoVerbatimAndSuppressesAudioEvents() {
        let request = ElevenLabsSTTClient.makeRequest(apiKey: "k", wav: wav, terms: [], timeout: 10)
        XCTAssertEqual(value("model_id", in: request), "scribe_v2")
        XCTAssertEqual(value("no_verbatim", in: request), "true",
                       "this is the whole reason to pick ElevenLabs")
        XCTAssertEqual(value("tag_audio_events", in: request), "false",
                       "defaults to true and would paste '(laughter)' into the document")
    }

    /// Pinning `language_code` would defeat the mixed Chinese/English case this app exists
    /// for — ElevenLabs predicts the language when the field is absent.
    func testElevenLabsNeverPinsALanguage() {
        let request = ElevenLabsSTTClient.makeRequest(apiKey: "k", wav: wav,
                                                      terms: ["TalkType"], timeout: 10)
        XCTAssertNil(value("language_code", in: request))
    }

    func testElevenLabsAuthenticatesWithItsOwnHeader() {
        let request = ElevenLabsSTTClient.makeRequest(apiKey: "k", wav: wav, terms: [], timeout: 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "k")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "a Bearer header here would be silently ignored")
    }

    // MARK: - OpenAI

    func testOpenAISendsBothLanguageHints() {
        let request = OpenAISTTClient.makeRequest(apiKey: "k", wav: wav, terms: ["Grok"], timeout: 10)
        XCTAssertEqual(value("model", in: request), "gpt-transcribe")
        XCTAssertEqual(values("languages[]", in: request), ["zh", "en"],
                       "one hint alone would push a mixed sentence into a single language")
        XCTAssertEqual(values("keywords[]", in: request), ["Grok"])
    }

    // MARK: - Soniox

    func testSonioxJobBodyCarriesHintsAndTerms() throws {
        let body = SonioxSTTClient.jobBody(fileID: "file-1", terms: ["P95", "Kubernetes"])
        XCTAssertEqual(body["model"] as? String, "stt-async-v5")
        XCTAssertEqual(body["file_id"] as? String, "file-1")
        XCTAssertEqual(body["language_hints"] as? [String], ["zh", "en"])
        let context = try XCTUnwrap(body["context"] as? [String: Any])
        XCTAssertEqual(context["terms"] as? [String], ["P95", "Kubernetes"])
    }

    func testSonioxOmitsContextWhenThereAreNoTerms() {
        let body = SonioxSTTClient.jobBody(fileID: "file-1", terms: [])
        XCTAssertNil(body["context"], "an empty context object is noise, not information")
    }

    /// Soniox returns tokens, not a sentence. Its tokens carry their own leading space
    /// where one belongs, so joining with a separator would put spaces between Chinese
    /// characters — the exact failure this test exists to prevent.
    func testSonioxJoinsTokensWithoutInsertingSeparators() throws {
        let json = """
        {"tokens": [{"text": "我们"}, {"text": "跑一下"}, {"text": " benchmark"}, {"text": "。"}]}
        """
        let text = try SonioxSTTClient.joinTokens(Data(json.utf8))
        XCTAssertEqual(text, "我们跑一下 benchmark。")
    }

    func testSonioxRejectsAResponseWithNoTokens() {
        XCTAssertThrowsError(try SonioxSTTClient.joinTokens(Data("{}".utf8)))
    }

    /// The four-step dance in order: upload, create, poll, fetch. A wrong order or a
    /// skipped poll would show up as an empty transcript on the first real dictation.
    func testSonioxWalksUploadCreatePollFetch() throws {
        var visited: [String] = []
        var polls = 0
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? ""
            guard method != "DELETE" else { return self.ok("{}") }
            visited.append("\(method) \(path)")
            switch (method, path) {
            case ("POST", "/v1/files"):
                return self.ok(#"{"id": "file-1"}"#)
            case ("POST", "/v1/transcriptions"):
                return self.ok(#"{"id": "job-1"}"#)
            case ("GET", "/v1/transcriptions/job-1"):
                polls += 1
                return self.ok(polls < 2 ? #"{"status": "processing"}"# : #"{"status": "completed"}"#)
            case ("GET", "/v1/transcriptions/job-1/transcript"):
                return self.ok(#"{"tokens": [{"text": "好"}]}"#)
            default:
                return self.status(404)
            }
        }

        let client = SonioxSTTClient(apiKey: "k", session: mockSession())
        let text = try client.transcribe(wav: wav, terms: [], timeout: 10)

        XCTAssertEqual(text, "好")
        XCTAssertEqual(visited, [
            "POST /v1/files",
            "POST /v1/transcriptions",
            "GET /v1/transcriptions/job-1",
            "GET /v1/transcriptions/job-1",
            "GET /v1/transcriptions/job-1/transcript",
        ])
    }

    func testSonioxSurfacesAFailedJob() {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "DELETE" { return self.ok("{}") }
            if path == "/v1/files" { return self.ok(#"{"id": "file-1"}"#) }
            if path == "/v1/transcriptions" && request.httpMethod == "POST" {
                return self.ok(#"{"id": "job-1"}"#)
            }
            return self.ok(#"{"status": "error", "error_message": "audio too short"}"#)
        }

        let client = SonioxSTTClient(apiKey: "k", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            XCTAssertTrue((error as? STTError)?.userMessage.contains("audio too short") ?? false)
        }
    }

    // MARK: - Response parsing, shared by the three one-shot providers

    func testEachOneShotProviderReadsTheTextField() throws {
        MockURLProtocol.handler = { _ in self.ok(#"{"text": "  我们跑一下 benchmark。  "}"#) }
        let session = mockSession()
        let clients: [STTClient] = [
            GrokSTTClient(apiKey: "k", language: "zh", session: session),
            ElevenLabsSTTClient(apiKey: "k", session: session),
            OpenAISTTClient(apiKey: "k", session: session),
        ]
        for client in clients {
            XCTAssertEqual(try client.transcribe(wav: wav, terms: [], timeout: 5),
                           "我们跑一下 benchmark。")
        }
    }

    // MARK: - Errors

    func testRejectedKeySaysSoInsteadOfShowingAStatusCode() {
        MockURLProtocol.handler = { _ in self.status(401, #"{"error": "invalid"}"#) }
        let client = ElevenLabsSTTClient(apiKey: "bad", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("API key"), "got: \(message)")
            XCTAssertTrue(message.contains("ElevenLabs"), "the message must name the provider")
        }
    }

    func testQuotaExhaustionIsNotReportedAsABadKey() {
        MockURLProtocol.handler = { _ in self.status(429) }
        let client = GrokSTTClient(apiKey: "k", language: "zh", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("额度"), "got: \(message)")
        }
    }

    func testMissingTextFieldIsAnError() {
        MockURLProtocol.handler = { _ in self.ok(#"{"language": "zh"}"#) }
        let client = OpenAISTTClient(apiKey: "k", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5))
    }

    // MARK: - Term hygiene

    /// A newline inside a multipart field would corrupt the body, and an overlong term is
    /// rejected by the provider — both are silent failures if they reach the wire.
    func testTermSanitizingStripsNewlinesAndDropsOverlongEntries() {
        let sanitized = STTTerms.sanitize(
            ["  Kubernetes  ", "two\nlines", "", String(repeating: "x", count: 80)],
            maxCount: 10, maxLength: 50)
        XCTAssertEqual(sanitized, ["Kubernetes", "two lines"])
    }

    func testTermSanitizingRespectsTheCount() {
        let sanitized = STTTerms.sanitize(["a", "b", "c"], maxCount: 2, maxLength: 50)
        XCTAssertEqual(sanitized, ["a", "b"])
    }
}
