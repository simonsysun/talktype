import Foundation

/// One call in, text out. Every provider hides its own transport behind this — multipart
/// for three of them, an upload-then-poll dance for Soniox — so the dictation flow never
/// learns which one it is talking to.
///
/// Synchronous by design: the dictation pipeline already runs on a background queue and
/// has the audio in memory, so there is nothing to overlap with.
protocol STTClient {
    /// - Parameters:
    ///   - wav: 16-bit mono WAV, exactly what `WAVEncoder` produced.
    ///   - terms: vocabulary to bias toward, in whatever shape the provider accepts.
    func transcribe(wav: Data, terms: [String], timeout: TimeInterval) throws -> String
}

// MARK: - Errors

enum STTError: LocalizedError {
    case unreachable(String)
    case badStatus(provider: String, code: Int, body: String)
    case emptyResponse(provider: String)
    case timedOut(provider: String)
    /// The provider accepted the job and then failed it (Soniox reports this in the body).
    case jobFailed(provider: String, message: String)
    /// No key stored for the chosen provider — the one failure retrying cannot fix.
    case missingKey(provider: String)

    var errorDescription: String? { userMessage }

    /// What the tray notification says. The rule: name the provider, then the one thing
    /// the user can actually do about it.
    var userMessage: String {
        switch self {
        case .missingKey(let provider):
            return "\(provider) 还没有 API key。到设置里添加。"
        case .unreachable(let detail):
            return "连不上语音服务：\(detail)"
        case .timedOut(let provider):
            return "\(provider) 超时了。检查网络，或换一个 provider。"
        case .emptyResponse(let provider):
            return "\(provider) 没有返回文字。"
        case .jobFailed(let provider, let message):
            return "\(provider) 转写失败：\(message)"
        case .badStatus(let provider, let code, let body):
            switch code {
            case 401, 403:
                return "\(provider) 拒绝了这个 API key。到设置里重新填。"
            case 402, 429:
                return "\(provider) 额度用完或请求太频繁。"
            case 404:
                return "\(provider) 的接口或模型不存在（\(code)）。"
            case 413:
                return "录音太长，\(provider) 拒收。"
            default:
                let detail = body.prefix(200)
                return "\(provider) 出错（\(code)）：\(detail)"
            }
        }
    }
}

// MARK: - Shared transport

/// The synchronous HTTP the clients share. Nothing here knows about speech; it exists so
/// four clients do not each hand-roll a semaphore and a timeout.
enum STTTransport {

    static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config)
    }

    /// Runs the request and returns the body, throwing on transport failure or non-2xx.
    static func run(_ request: URLRequest, session: URLSession, provider: String,
                    timeout: TimeInterval) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var body: Data?
        var failure: Error?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                failure = (error as? URLError)?.code == .timedOut
                    ? STTError.timedOut(provider: provider)
                    : STTError.unreachable(error.localizedDescription)
                return
            }
            guard let data = data else {
                failure = STTError.emptyResponse(provider: provider)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failure = STTError.badStatus(provider: provider, code: http.statusCode,
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
            throw STTError.timedOut(provider: provider)
        }
        if let failure = failure { throw failure }
        guard let body = body else { throw STTError.emptyResponse(provider: provider) }
        return body
    }

    /// Pulls a top-level string field out of a JSON object — the shape three of the four
    /// providers return.
    static func text(from data: Data, key: String = "text", provider: String) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json[key] as? String
        else { throw STTError.emptyResponse(provider: provider) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Multipart

/// Minimal multipart/form-data builder.
///
/// Field order is preserved and matters: xAI requires `file` to be the last part, so the
/// clients add their scalar fields first and the audio last.
struct MultipartBody {
    let boundary: String
    private var body = Data()

    init(boundary: String = "talktype-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append("\(value)\r\n")
    }

    /// Repeats the same field name once per value — how xAI's `keyterm` and ElevenLabs'
    /// `keyterms` both take lists.
    mutating func addRepeatedField(_ name: String, _ values: [String]) {
        for value in values { addField(name, value) }
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    func finalized() -> Data {
        var out = body
        out.append("--\(boundary)--\r\n")
        return out
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

// MARK: - Term hygiene

enum STTTerms {
    /// Providers cap term length and count, and a newline inside a multipart field would
    /// corrupt the body. Trim once, here, so four clients do not each get it slightly wrong.
    static func sanitize(_ terms: [String], maxCount: Int, maxLength: Int) -> [String] {
        terms
            .map { $0.replacingOccurrences(of: "[\r\n]+", with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxLength }
            .prefix(maxCount)
            .map { $0 }
    }
}
