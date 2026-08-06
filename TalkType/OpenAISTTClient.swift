import Foundation

/// OpenAI `gpt-transcribe` — `POST /v1/audio/transcriptions`, multipart, one round trip.
///
/// No filler-removal switch exists here; what this provider brings is explicit
/// code-switching support and structured hints. Both language hints are sent so a
/// Chinese/English sentence is not forced into one of them.
struct OpenAISTTClient: STTClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let name = "OpenAI"
    static let model = "gpt-transcribe"
    static let languages = ["zh", "en"]
    /// Not a documented API cap — a self-imposed one, so a long vocabulary list cannot
    /// quietly dominate the request.
    static let maxTerms = 100
    static let maxTermLength = 60

    let apiKey: String
    private let session: URLSession?

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session
    }

    func transcribe(wav: Data, terms: [String], timeout: TimeInterval) throws -> String {
        let session = self.session ?? STTTransport.makeSession(timeout: timeout)
        let request = Self.makeRequest(apiKey: apiKey, wav: wav, terms: terms, timeout: timeout)
        let data = try STTTransport.run(request, session: session, provider: Self.name,
                                        timeout: timeout)
        return try STTTransport.text(from: data, provider: Self.name)
    }

    static func makeRequest(apiKey: String, wav: Data, terms: [String], timeout: TimeInterval,
                            boundary: String? = nil) -> URLRequest {
        var form = boundary.map { MultipartBody(boundary: $0) } ?? MultipartBody()
        form.addField("model", model)
        form.addRepeatedField("languages[]", languages)
        form.addRepeatedField("keywords[]", STTTerms.sanitize(terms, maxCount: maxTerms,
                                                              maxLength: maxTermLength))
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
