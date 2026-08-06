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
            if let focused = Self.focusedProviderMessage(detail) { return focused }
            return "豆包拒绝了这次请求：\(detail.prefix(200))"
        case .badStatus(let code, let body):
            switch code {
            case 401, 403:
                if let focused = Self.focusedProviderMessage(body) { return focused }
                return "豆包 API Key 不对。菜单栏 ▸ API Key… 重填。"
            case 429:
                return "请求太频繁，或额度用完了。"
            case 413:
                return "录音太长，豆包拒收。"
            default:
                return "豆包出错（\(code)）：\(body.prefix(200))"
            }
        }
    }

    private static func focusedProviderMessage(_ detail: String) -> String? {
        let lower = detail.lowercased()
        if lower.contains("requested grant not found") {
            return "这个豆包项目还没开通「录音文件识别大模型 极速版」。"
        }
        if lower.contains("invalid x-api-key") || lower.contains("invalid api key") {
            return "豆包 API Key 不对。菜单栏 ▸ API Key… 重填。"
        }
        return nil
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
            if let http = response as? HTTPURLResponse {
                let responseBody = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let apiMessage = http.value(forHTTPHeaderField: "X-Api-Message")?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let apiStatus = http.value(forHTTPHeaderField: "X-Api-Status-Code")?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = [apiStatus, apiMessage, responseBody].filter { !$0.isEmpty }
                    .joined(separator: ": ")
                if !(200...299).contains(http.statusCode) {
                    failure = STTError.badStatus(code: http.statusCode, body: detail)
                    return
                }
                // The v3 speech API also reports provider failures in headers while HTTP is 200.
                if !apiStatus.isEmpty, apiStatus != "20000000" {
                    failure = STTError.rejected(detail)
                    return
                }
            }
            guard let data = data else {
                failure = STTError.emptyResponse
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
