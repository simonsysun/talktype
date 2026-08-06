import Foundation

/// Errors from the one speech-to-text call a dictation makes. Each case exists because it
/// needs a different sentence in the tray notification — the user should never have to
/// look up a status code to know what to do.
enum STTError: LocalizedError {
    case missingKey
    case unreachable(String)
    case badStatus(code: Int, body: String)
    /// HTTP said 200, but the body carried a failure instead of a transcript.
    case rejected(String)
    case emptyResponse
    case timedOut

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .missingKey:
            return "还没填 API Key。菜单栏 ▸ API Key… 填一下。"
        case .unreachable(let detail):
            return "连不上豆包：\(detail)"
        case .timedOut:
            return "豆包超时了。检查网络。"
        case .emptyResponse:
            return "豆包没返回文字。"
        case .rejected(let detail):
            return "豆包拒绝了这次请求：\(detail.prefix(200))"
        case .badStatus(let code, let body):
            switch code {
            case 401, 403:
                return "App ID 或 Access Token 不对。菜单栏 ▸ API Key… 重填。"
            case 429:
                return "请求太频繁，或额度用完了。"
            case 413:
                return "录音太长，豆包拒收。"
            default:
                return "豆包出错（\(code)）：\(body.prefix(200))"
            }
        }
    }
}

/// The synchronous HTTP the client runs on. The dictation pipeline is already on a
/// background queue with the audio in memory, so there is nothing to overlap with.
enum STTTransport {

    static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config)
    }

    /// Runs the request and returns the body, throwing on transport failure or non-2xx.
    static func run(_ request: URLRequest, session: URLSession, timeout: TimeInterval) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var body: Data?
        var failure: Error?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                failure = (error as? URLError)?.code == .timedOut
                    ? STTError.timedOut
                    : STTError.unreachable(error.localizedDescription)
                return
            }
            guard let data = data else {
                failure = STTError.emptyResponse
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failure = STTError.badStatus(code: http.statusCode,
                                             body: String(data: data, encoding: .utf8) ?? "")
                return
            }
            body = data
        }
        task.resume()
        // The extra second lets URLSession's own timeout fire first, so the error says
        // "timed out" rather than the vaguer wait-expired path below.
        if semaphore.wait(timeout: .now() + timeout + 1) != .success {
            task.cancel()
            throw STTError.timedOut
        }
        if let failure = failure { throw failure }
        guard let body = body else { throw STTError.emptyResponse }
        return body
    }
}
