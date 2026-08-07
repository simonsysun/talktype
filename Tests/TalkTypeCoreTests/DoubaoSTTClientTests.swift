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

    private func respond(_ code: Int, _ json: String,
                         headers: [String: String]? = nil) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: DoubaoSTTClient.endpoint, statusCode: code,
                         httpVersion: nil, headerFields: headers)!, Data(json.utf8))
    }

    private func decodedBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Request

    func testHeadersCarryTheSingleAPIKeyAndTurboResourceID() {
        let request = DoubaoSTTClient.makeRequest(apiKey: "key-1", wav: wav,
                                                  terms: [], timeout: 10, requestID: "req-1")
        XCTAssertEqual(request.url, DoubaoSTTClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "key-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-App-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Access-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.bigasr.auc_turbo",
                       "标准版的 resource id 会把请求路由到提交+轮询那条路")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Request-Id"), "req-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Sequence"), "-1")
    }

    func testAudioIsBase64WAVWithMatchingFormatFields() throws {
        let request = DoubaoSTTClient.makeRequest(apiKey: "k", wav: wav,
                                                  terms: [], timeout: 10, requestID: "r")
        let audio = try XCTUnwrap(try decodedBody(request)["audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, wav.base64EncodedString())
        XCTAssertEqual(audio["format"] as? String, "wav")
        XCTAssertEqual(audio["rate"] as? Int, 16000, "必须和 WAVEncoder 写进头里的采样率一致")
        XCTAssertEqual(audio["bits"] as? Int, 16)
        XCTAssertEqual(audio["channel"] as? Int, 1)
    }

    /// 本地后处理已经全部删掉，所以可直接粘贴的文字只能靠这三个原生开关。
    func testNativeFormattingAndSemanticSmoothingAreOn() throws {
        let request = DoubaoSTTClient.makeRequest(apiKey: "k", wav: wav,
                                                  terms: [], timeout: 10, requestID: "r")
        let fields = try XCTUnwrap(try decodedBody(request)["request"] as? [String: Any])
        XCTAssertEqual(fields["model_name"] as? String, "bigmodel")
        XCTAssertEqual(fields["enable_punc"] as? Bool, true)
        XCTAssertEqual(fields["enable_itn"] as? Bool, true)
        XCTAssertEqual(fields["enable_ddc"] as? Bool, true)
    }

    /// 火山把热词放在一个 JSON *字符串* 里，不是嵌套对象——写成对象会被静默忽略。
    func testHotwordsAreAJSONStringNotANestedObject() throws {
        let request = DoubaoSTTClient.makeRequest(apiKey: "k", wav: wav,
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

    /// 词库为空时不带 corpus：没有词就不传无意义的结构。
    func testNoCorpusFieldWhenThereAreNoTerms() throws {
        let request = DoubaoSTTClient.makeRequest(apiKey: "k", wav: wav,
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

    // MARK: - Streaming 2.0

    func testStreamingUsesTheEnabled2Point0ResourceAndProjectAPIKey() {
        let request = DoubaoStreamProtocol.makeRequest(
            apiKey: "key-2", connectID: "connection-1", timeout: 12)

        XCTAssertEqual(request.url, DoubaoStreamProtocol.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "key-2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"),
                       "volc.seedasr.sauc.duration")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Connect-Id"), "connection-1")
    }

    func testStreamingConfigKeepsNativeFormattingAndHotwords() throws {
        let frame = try DoubaoStreamProtocol.configFrame(terms: ["Claude Code", "P95"])
        XCTAssertEqual(Array(frame.prefix(4)), [0x11, 0x10, 0x10, 0x00])

        let payloadSize = Int(frame.readUInt32BE(at: 4))
        XCTAssertEqual(payloadSize, frame.count - 8)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: frame.subdata(in: 8..<frame.count))
                as? [String: Any])
        let audio = try XCTUnwrap(body["audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "pcm")
        XCTAssertEqual(audio["rate"] as? Int, 16000)
        XCTAssertEqual(audio["bits"] as? Int, 16)
        XCTAssertEqual(audio["channel"] as? Int, 1)

        let fields = try XCTUnwrap(body["request"] as? [String: Any])
        XCTAssertEqual(fields["model_name"] as? String, "bigmodel")
        XCTAssertEqual(fields["enable_punc"] as? Bool, true)
        XCTAssertEqual(fields["enable_itn"] as? Bool, true)
        XCTAssertEqual(fields["enable_ddc"] as? Bool, true)
        let corpus = try XCTUnwrap(fields["corpus"] as? [String: Any])
        XCTAssertEqual(corpus["context"] as? String,
                       DoubaoSTTClient.hotwordContext(["Claude Code", "P95"]))
    }

    func testStreamingAudioFrameMarksOnlyTheLastPacketFinal() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let ordinary = DoubaoStreamProtocol.audioFrame(pcm, isFinal: false)
        let final = DoubaoStreamProtocol.audioFrame(pcm, isFinal: true)

        XCTAssertEqual(Array(ordinary.prefix(4)), [0x11, 0x20, 0x00, 0x00])
        XCTAssertEqual(Array(final.prefix(4)), [0x11, 0x22, 0x00, 0x00])
        XCTAssertEqual(ordinary.readUInt32BE(at: 4), 4)
        XCTAssertEqual(ordinary.suffix(4), pcm)
    }

    func testStreamingFinalResponseReturnsTrimmedText() throws {
        let payload = Data(#"{"result":{"text":"  流式更快。  "}}"#.utf8)
        let frame = DoubaoStreamProtocol.testServerFrame(
            messageType: 0x9, flags: 0x2, payload: payload)

        let parsed = try DoubaoStreamProtocol.parseServerFrame(frame)
        XCTAssertTrue(parsed.isFinal)
        XCTAssertEqual(parsed.text, "流式更快。")
    }

    func testStreamingProviderErrorKeepsCodeAndMessage() {
        let payload = Data("invalid audio format".utf8)
        let frame = DoubaoStreamProtocol.testServerFrame(
            messageType: 0xF, flags: 0, payload: payload, errorCode: 45_000_151)

        XCTAssertThrowsError(try DoubaoStreamProtocol.parseServerFrame(frame)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("45000151"), "got: \(message)")
            XCTAssertTrue(message.contains("invalid audio format"), "got: \(message)")
        }
    }

    func testPCM16PacketizerEmitsTwoHundredMillisecondPackets() {
        var packetizer = StreamingPCM16Packetizer()
        let first = packetizer.append(samples: Array(repeating: 0.5, count: 1_600),
                                      sampleRate: 16_000)
        let second = packetizer.append(samples: Array(repeating: -0.5, count: 1_600),
                                       sampleRate: 16_000)

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].count, 6_400)
        XCTAssertTrue(packetizer.finish().isEmpty)
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
        let client = DoubaoSTTClient(apiKey: "k", session: mockSession())
        XCTAssertEqual(try client.transcribe(wav: wav, terms: [], timeout: 5), "好的")
    }

    func testRejectedCredentialsSaySoInsteadOfShowingAStatusCode() {
        MockURLProtocol.handler = { _ in self.respond(401, "{}") }
        let client = DoubaoSTTClient(apiKey: "bad", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("API Key"), "got: \(message)")
        }
    }

    /// 新接口有时把旧式、遮罩或格式错误的 key 当成“没有 app key”，并返回 HTTP 400。
    /// 这和 401 一样是用户需要重填项目 API Key，不该把 provider 原文直接扔给用户。
    func testMissingAppKeyResponsePointsBackToTheAPIKeyField() {
        MockURLProtocol.handler = { _ in
            self.respond(400, #"{"header":{"code":45000000,"message":"app key not found in header or query"}}"#)
        }
        let client = DoubaoSTTClient(apiKey: "wrong-kind-of-key", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("API Key"), "got: \(message)")
            XCTAssertFalse(message.contains("豆包出错（400）"), "got: \(message)")
        }
    }

    func testMissingServiceGrantExplainsWhatToEnable() {
        MockURLProtocol.handler = { _ in
            self.respond(401, "", headers: ["X-Api-Message": "requested grant not found"])
        }
        let client = DoubaoSTTClient(apiKey: "valid-project-key", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("录音文件识别 2.0"), "got: \(message)")
        }
    }

    func testProviderErrorInSuccessfulHTTPHeadersIsNotTreatedAsEmptyText() {
        MockURLProtocol.handler = { _ in
            self.respond(200, "", headers: [
                "X-Api-Status-Code": "45000030",
                "X-Api-Message": "requested grant not found",
            ])
        }
        let client = DoubaoSTTClient(apiKey: "valid-project-key", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("录音文件识别 2.0"), "got: \(message)")
        }
    }

    func testHeaderOnlyProviderErrorExplainsTheMissingGrant() {
        MockURLProtocol.handler = { _ in
            (HTTPURLResponse(url: DoubaoSTTClient.endpoint, statusCode: 200,
                             httpVersion: nil, headerFields: [
                                "X-Api-Status-Code": "45000030",
                                "X-Api-Message": "requested grant not found",
                             ])!, nil)
        }
        let client = DoubaoSTTClient(apiKey: "valid-project-key", session: mockSession())
        XCTAssertThrowsError(try client.transcribe(wav: wav, terms: [], timeout: 5)) { error in
            let message = (error as? STTError)?.userMessage ?? ""
            XCTAssertTrue(message.contains("录音文件识别 2.0"), "got: \(message)")
        }
    }

    func testMissingKeyTellsTheUserWhereToFixIt() {
        XCTAssertTrue(STTError.missingKey.userMessage.contains("API Key"))
    }
}
