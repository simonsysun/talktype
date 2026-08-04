import XCTest
@testable import TalkTypeCore

final class TranscriberTests: XCTestCase {

    private let base = URL(string: "http://127.0.0.1:8756")!

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

    // MARK: - Response parsing

    func testParseResponseReturnsTrimmedText() throws {
        let data = #"{"text":" 你好 world  "}"#.data(using: .utf8)!
        let response = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertEqual(try Transcriber.parseResponse(data: data, response: response), "你好 world")
    }

    func testParseResponse503IsLoading() {
        let data = #"{"status":"loading"}"#.data(using: .utf8)!
        let response = HTTPURLResponse(url: base, statusCode: 503, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try Transcriber.parseResponse(data: data, response: response)) { error in
            XCTAssertEqual(error as? TranscriberError, .sidecarLoading)
        }
    }

    func testParseResponseCarriesServerError() {
        let data = #"{"error":"boom"}"#.data(using: .utf8)!
        let response = HTTPURLResponse(url: base, statusCode: 500, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try Transcriber.parseResponse(data: data, response: response)) { error in
            guard case .sidecarError(let code, let body) = error as? TranscriberError else {
                return XCTFail("expected sidecarError, got \(error)")
            }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(body, "boom")
        }
    }

    func testParseResponseEmptyWhenNoText() {
        let response = HTTPURLResponse(url: base, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try Transcriber.parseResponse(data: Data("{}".utf8), response: response)) { error in
            XCTAssertEqual(error as? TranscriberError, .emptyResponse)
        }
    }

    // MARK: - Request behaviour (stubbed)

    func testTranscribeReturnsParsedText() throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/transcribe")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"ok"}"#.utf8))
        }
        XCTAssertEqual(try Transcriber().transcribe(audio: [0.1, 0.2, 0.3]), "ok")
    }

    func testTranscribeSendsBareCommaListContext() throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TalkType-Context"), "TalkType, GPT-4o")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"ok"}"#.utf8))
        }
        _ = try Transcriber().transcribe(audio: [0.1], vocabularyHints: ["TalkType", "GPT-4o"])
    }

    func testTranscribe503SurfacesAsLoading() {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"loading"}"#.utf8))
        }
        XCTAssertThrowsError(try Transcriber().transcribe(audio: [0.1])) { error in
            XCTAssertEqual(error as? TranscriberError, .sidecarLoading)
        }
    }
}
