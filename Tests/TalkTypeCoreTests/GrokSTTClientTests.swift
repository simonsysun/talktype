import XCTest
@testable import TalkTypeCore

final class GrokSTTClientTests: XCTestCase {

    private let wav = WAVEncoder.encode(samples: [0.1, -0.1, 0.2], sampleRate: 16000)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Request shape

    func testBearerAuthAndMultipartEndpoint() {
        let request = GrokSTTClient.makeRequest(apiKey: "xai-test", wav: wav, terms: [], timeout: 10)
        XCTAssertEqual(request.url, GrokSTTClient.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai-test")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
    }

    func testKeytermsPrecedeFilePart() {
        let boundary = "----TestBoundary"
        let body = GrokSTTClient.multipartBody(boundary: boundary, wav: wav,
                                               terms: ["TalkType", "Claude Code"])
        // Body is binary (WAV), so search ASCII markers without UTF-8 round-trip.
        let keytermIdx = body.range(of: Data("name=\"keyterm\"".utf8))?.lowerBound
        let fileIdx = body.range(of: Data("name=\"file\"".utf8))?.lowerBound
        XCTAssertNotNil(keytermIdx)
        XCTAssertNotNil(fileIdx)
        if let k = keytermIdx, let f = fileIdx {
            XCTAssertLessThan(k, f, "xAI may ignore fields after file")
        }
        XCTAssertNotNil(body.range(of: Data("TalkType".utf8)))
        XCTAssertNotNil(body.range(of: Data("Claude Code".utf8)))
        XCTAssertNil(body.range(of: Data("name=\"format\"".utf8)),
                     "no format/language for mixed CN/EN")
        XCTAssertNil(body.range(of: Data("name=\"language\"".utf8)))
    }

    func testNoKeytermPartsWhenVocabularyEmpty() {
        let body = GrokSTTClient.multipartBody(boundary: "b", wav: wav, terms: [])
        XCTAssertNil(body.range(of: Data("keyterm".utf8)))
        XCTAssertNotNil(body.range(of: Data("name=\"file\"".utf8)))
    }

    func testKeytermsTrimmedAndCapped() {
        let long = String(repeating: "a", count: 80)
        var terms = ["  spaced  ", long, ""]
        terms.append(contentsOf: (0..<120).map { "term\($0)" })
        let cleaned = GrokSTTClient.keyterms(terms)
        XCTAssertEqual(cleaned.count, 100)
        XCTAssertEqual(cleaned.first, "spaced")
        XCTAssertEqual(cleaned[1].count, 50)
        XCTAssertFalse(cleaned.contains(""))
        XCTAssertEqual(cleaned.last, "term97") // 2 prefix terms + term0…term97
    }

    // MARK: - Parse / live mock

    func testParseTextField() throws {
        let data = Data(#"{"text":"  hello  ","duration":1.2}"#.utf8)
        XCTAssertEqual(try GrokSTTClient.parse(data), "hello")
    }

    func testParseEmptyThrows() {
        XCTAssertThrowsError(try GrokSTTClient.parse(Data(#"{"text":"  "}"#.utf8))) { error in
            XCTAssertEqual(error as? STTError, .emptyResponse)
        }
    }

    func testTranscribeUsesMockedHTTP() throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
            let response = HTTPURLResponse(url: GrokSTTClient.endpoint, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"ok from grok"}"#.utf8))
        }
        let client = GrokSTTClient(apiKey: "k", session: mockSession())
        let text = try client.transcribe(wav: wav, terms: ["TalkType"], timeout: 5)
        XCTAssertEqual(text, "ok from grok")
    }
}

extension STTError: Equatable {
    public static func == (lhs: STTError, rhs: STTError) -> Bool {
        switch (lhs, rhs) {
        case (.missingKey, .missingKey),
             (.emptyResponse, .emptyResponse),
             (.timedOut, .timedOut):
            return true
        case (.unreachable(let a), .unreachable(let b)),
             (.rejected(let a), .rejected(let b)):
            return a == b
        case (.badStatus(let c1, let b1), .badStatus(let c2, let b2)):
            return c1 == c2 && b1 == b2
        default:
            return false
        }
    }
}
