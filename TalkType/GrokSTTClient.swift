import Foundation

/// xAI Grok speech-to-text — `POST /v1/stt`, multipart, one round trip.
///
/// Two things are worth knowing. `filler_words` defaults to false, so Grok strips "um"
/// and "uh" without being asked. And `format` (spoken numbers → written form) only takes
/// effect when `language` is also set — but Chinese is absent from xAI's published
/// language table, so `language` is configurable rather than hardcoded: sending `zh` is a
/// bet on undocumented behaviour, and leaving it empty is the honest fallback.
struct GrokSTTClient: STTClient {
    static let endpoint = URL(string: "https://api.x.ai/v1/stt")!
    static let name = "Grok"
    /// xAI's documented ceiling: 100 terms, 50 characters each.
    static let maxTerms = 100
    static let maxTermLength = 50

    let apiKey: String
    /// Empty means "send no language", which also disables `format`.
    let language: String
    private let session: URLSession?

    init(apiKey: String, language: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func transcribe(wav: Data, terms: [String], timeout: TimeInterval) throws -> String {
        let session = self.session ?? STTTransport.makeSession(timeout: timeout)
        let request = Self.makeRequest(apiKey: apiKey, language: language, wav: wav,
                                       terms: terms, timeout: timeout)
        let data = try STTTransport.run(request, session: session, provider: Self.name,
                                        timeout: timeout)
        return try STTTransport.text(from: data, provider: Self.name)
    }

    static func makeRequest(apiKey: String, language: String, wav: Data, terms: [String],
                            timeout: TimeInterval,
                            boundary: String? = nil) -> URLRequest {
        var form = boundary.map { MultipartBody(boundary: $0) } ?? MultipartBody()

        // `format` is rejected without a language, so the pair moves together.
        if !language.isEmpty {
            form.addField("language", language)
            form.addField("format", "true")
        }
        // Explicit rather than relying on the default: this is the polish we are counting on.
        form.addField("filler_words", "false")
        form.addRepeatedField("keyterm", STTTerms.sanitize(terms, maxCount: maxTerms,
                                                           maxLength: maxTermLength))
        // xAI requires the file part last.
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: wav)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = form.finalized()
        return request
    }
}
