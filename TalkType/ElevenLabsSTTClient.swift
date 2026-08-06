import Foundation

/// ElevenLabs Scribe v2 — `POST /v1/speech-to-text`, multipart, one round trip.
///
/// This is the provider with an actual polish contract: `no_verbatim` removes fillers,
/// false starts, repetitions and stuttering. Two deliberate choices beyond that:
///
/// - `language_code` is never sent. ElevenLabs predicts the language when it is omitted,
///   and its stated behaviour is to transcribe English words in English regardless of the
///   surrounding language — pinning it to `zho` would throw that away, and mixed
///   Chinese/English is the main use here.
/// - `tag_audio_events` is forced off. It defaults to true and would sprinkle
///   "(laughter)" and "(footsteps)" into text that is about to be pasted into a text field.
struct ElevenLabsSTTClient: STTClient {
    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    static let name = "ElevenLabs"
    static let model = "scribe_v2"
    /// Batch ceiling: 1000 terms, under 50 characters each.
    static let maxTerms = 1000
    static let maxTermLength = 49

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
        form.addField("model_id", model)
        form.addField("no_verbatim", "true")
        form.addField("tag_audio_events", "false")
        form.addRepeatedField("keyterms", STTTerms.sanitize(terms, maxCount: maxTerms,
                                                            maxLength: maxTermLength))
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: wav)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = form.finalized()
        return request
    }
}
