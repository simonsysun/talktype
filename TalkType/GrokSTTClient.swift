import Foundation

/// xAI Grok Speech-to-Text (REST file). One exclusive provider path — not a Doubao fallback.
///
/// Chinese is best-effort on xAI (not on the official formatting language list). Do not send
/// `format`/`language=en` for TalkType's mixed CN/EN use; vocabulary maps to `keyterm` only.
struct GrokSTTClient {
    static let endpoint = URL(string: "https://api.x.ai/v1/stt")!

    let apiKey: String
    private let session: URLSession?

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session
    }

    func transcribe(wav: Data, terms: [String], timeout: TimeInterval) throws -> String {
        let session = self.session ?? STTTransport.makeSession(timeout: timeout)
        let request = Self.makeRequest(apiKey: apiKey, wav: wav, terms: terms, timeout: timeout)
        let data = try STTTransport.run(request, session: session, timeout: timeout)
        return try Self.parse(data)
    }

    // MARK: - Request

    static func makeRequest(apiKey: String, wav: Data, terms: [String],
                            timeout: TimeInterval) -> URLRequest {
        let boundary = "----TalkTypeGrok\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = multipartBody(boundary: boundary, wav: wav, terms: terms)
        return request
    }

    /// Option fields before `file` — xAI may ignore trailing fields after the file part.
    static func multipartBody(boundary: String, wav: Data, terms: [String]) -> Data {
        var body = Data()
        for term in keyterms(terms) {
            appendFormField(&body, boundary: boundary, name: "keyterm", value: term)
        }
        appendFileField(&body, boundary: boundary, name: "file", filename: "dictation.wav",
                        mimeType: "audio/wav", data: wav)
        body.append("--\(boundary)--\r\n")
        return body
    }

    /// Match Doubao hotword budget: at most 100 terms, 50 chars each.
    static func keyterms(_ terms: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(min(terms.count, 100))
        for raw in terms {
            let cleaned = raw
                .replacingOccurrences(of: "[\r\n]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            out.append(String(cleaned.prefix(50)))
            if out.count >= 100 { break }
        }
        return out
    }

    // MARK: - Response

    static func parse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw STTError.emptyResponse
        }
        if let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let message = json["error"] as? String, !message.isEmpty {
            throw STTError.rejected(message)
        }
        if let err = json["error"] as? [String: Any],
           let message = err["message"] as? String, !message.isEmpty {
            throw STTError.rejected(message)
        }
        throw STTError.emptyResponse
    }

    // MARK: - Multipart helpers

    private static func appendFormField(_ body: inout Data, boundary: String,
                                        name: String, value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append(value)
        body.append("\r\n")
    }

    private static func appendFileField(_ body: inout Data, boundary: String, name: String,
                                        filename: String, mimeType: String, data: Data) {
        body.append("--\(boundary)\r\n")
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
