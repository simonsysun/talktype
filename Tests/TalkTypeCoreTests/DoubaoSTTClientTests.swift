import XCTest
@testable import TalkTypeCore

/// 没有 API key 也能验的那一半：请求到底长什么样、响应怎么解。这里断言的每个字段都直接
/// 决定粘贴出来的文字——`enable_punc` 掉了就没有标点，`enable_itn` 掉了「百分之九十五」就
/// 不会变成「95%」——而这类回归在 app 里是看不出原因的。
final class DoubaoSTTClientTests: XCTestCase {

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

    private func respond(_ code: Int, _ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: DoubaoSTTClient.endpoint, statusCode: code,
                         httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private func decodedBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Request

    func testHeadersCarryBothCredentialsAndTheTurboResourceID() {
        let request = DoubaoSTTClient.makeRequest(appID: "app-1", accessToken: "tok-1", wav: wav,
                                                  terms: [], timeout: 10, requestID: "req-1")
        XCTAssertEqual(request.url, DoubaoSTTClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-App-Key"), "app-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Access-Key"), "tok-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.bigasr.auc_turbo",
                       "标准版的 resource id 会把请求路由到提交+轮询那条路")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Request-Id"), "req-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Sequence"), "-1")
    }

    func testAudioIsBase64WAVWithMatchingFormatFields() throws {
        let request = DoubaoSTTClient.makeRequest(appID: "a", accessToken: "t", wav: wav,
                                                  terms: [], timeout: 10, requestID: "r")
        let audio = try XCTUnwrap(try decodedBody(request)["audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, wav.base64EncodedString())
        XCTAssertEqual(audio["format"] as? String, "wav")
        XCTAssertEqual(audio["rate"] as? Int, 16000, "必须和 WAVEncoder 写进头里的采样率一致")
        XCTAssertEqual(audio["bits"] as? Int, 16)
        XCTAssertEqual(audio["channel"] as? Int, 1)
    }

    /// 本地后处理已经全部删掉，所以标点和口语数字转写只能靠这两个开关。
    func testPunctuationAndNumberNormalisationAreBothOn() throws {
        let request = DoubaoSTTClient.makeRequest(appID: "a", accessToken: "t", wav: wav,
                                                  terms: [], timeout: 10, requestID: "r")
        let fields = try XCTUnwrap(try decodedBody(request)["request"] as? [String: Any])
        XCTAssertEqual(fields["model_name"] as? String, "bigmodel")
        XCTAssertEqual(fields["enable_punc"] as? Bool, true)
        XCTAssertEqual(fields["enable_itn"] as? Bool, true)
    }

    /// 火山把热词放在一个 JSON *字符串* 里，不是嵌套对象——写成对象会被静默忽略。
    func testHotwordsAreAJSONStringNotANestedObject() throws {
        let request = DoubaoSTTClient.makeRequest(appID: "a", accessToken: "t", wav: wav,
                                                  terms: ["Kubernetes", "P95"], timeout: 10,
                                                  requestID: "r")
        let fields = try XCTUnwrap(try decodedBody(request)["request"] as? [String: Any])
        let corpus = try XCTUnwrap(fields["corpus"] as? [String: Any])
        let context = try XCTUnwrap(corpus["context"] as? String)

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        let hotwords = try XCTUnwrap(parsed["hotwords"] as? [[String: String]])
        XCTAssertEqual(hotwords.map { $0["word"] }, ["Kubernetes", "P95"])
    }

    /// 词库为空时不带 corpus：万一极速版不认这个字段，没有词库的听写不该跟着一起失败。
    func testNoCorpusFieldWhenThereAreNoTerms() throws {
        let request = DoubaoSTTClient.makeRequest(appID: "a", accessToken: "t", wav: wav,
                                                  terms: [], timeout: 10, requestID: "r")
        let fields = try XCTUnwrap(try decodedBody(request)["request"] as? [String: Any])
        XCTAssertNil(fields["corpus"])
    }

    func testHotwordsAreTrimmedAndNewlinesRemoved() throws {
        // 换行会破坏那个内嵌的 JSON 字符串。
        let context = try XCTUnwrap(DoubaoSTTClient.hotwordContext(["  Kubernetes  ", "two\nlines", ""]))
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        let hotwords = try XCTUnwrap(parsed["hotwords"] as? [[String: String]])
        XCTAssertEqual(hotwords.map { $0["word"] }, ["Kubernetes", "two lines"])
    }

    func testHotwordsAreCappedAtOneHundred() throws {
        let context = try XCTUnwrap(DoubaoSTTClient.hotwordContext((1...150).map { "term\($0)" }))
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        XCTAssertEqual((parsed["hotwords"] as? [[String: String]])?.count, 100)
    }

    // MARK: - Response

    func testTranscriptComesFromResultText() throws {
        let json = #"{"result": {"text": "  我们跑一下 benchmark。 ", "utterances": []}}"#
        XCTAssertEqual(try DoubaoSTTClient.parse(Data(json.utf8)), "我们跑一下 benchmark。")
    }

    /// 火山会用 HTTP 200 配一个错误 body 回应，直接报「没返回文字」会把真正的原因藏起来。
    func testAnErrorBodyOnHTTP200IsReportedWithItsMessage() {
        let json = #"{"code": 45000001, "message": "invalid audio format"}"#
        XCTAssertThrowsError(try DoubaoSTTClient.parse(Data(json.utf8))) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("invalid audio format"), "got: \(message)")
            XCTAssertTrue(message.contains("45000001"), "错误码要带上，方便对着火山文档查")
        }
    }

    func testAnEmptyTranscriptIsAnErrorNotAnEmptyString() {
        XCTAssertThrowsError(try DoubaoSTTClient.parse(Data(#"{"result": {"text": ""}}"#.utf8)))
        XCTAssertThrowsError(try DoubaoSTTClient.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try DoubaoSTTClient.parse(Data("not json".utf8)))
    }

    // MARK: - End to end

    func testASuccessfulDictationRoundTrip() throws {
        MockURLProtocol.handler = { _ in self.respond(200, #"{"result": {"text": "好的"}}"#) }
        let client = DoubaoSTTClient(appID: "a", accessToken: "t", session: mockSession())
        XCTAssertEqual(try client.transcribe(wav: wav, terms: [], timeout: 5), "好的")
    }

    func testRejectedCredentialsSaySoInsteadOfShowingAStatusCode() {
        MockURLProtocol.handler = { _ in self.respond(401, "{}") }
        let client = DoubaoSTTClient(appID: "a", accessToken: "bad", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("App ID"), "got: \(message)")
        }
    }

    func testMissingKeyTellsTheUserWhereToFixIt() {
        XCTAssertTrue(STTError.missingKey.userMessage.contains("API Key"))
    }
}
