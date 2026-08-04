import Foundation

/// Speech-to-text through a cloud provider's OpenAI-compatible endpoint.
///
/// The audio is the same WAV the local sidecar gets; only the transport differs. Three
/// shapes exist because the providers disagree: OpenRouter takes base64 JSON, OpenAI and
/// Groq take multipart, and DashScope's Qwen-ASR is a chat-completions call with an
/// `input_audio` content block. Response parsing is split the same way.
final class CloudASRClient {
    let baseURL: URL
    let apiKey: String
    let model: String
    let shape: CloudRequestShape
    let timeout: TimeInterval
    private let session: URLSession

    init(
        baseURL: String,
        apiKey: String,
        model: String,
        shape: CloudRequestShape,
        timeout: TimeInterval = 60.0
    ) {
        // Tolerate a base URL with or without a trailing slash; the endpoints below are
        // appended on top. Invalid URLs are caught here rather than mid-dictation.
        self.baseURL = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? URL(string: "https://invalid.local")!
        self.apiKey = apiKey
        self.model = model
        self.shape = shape
        self.timeout = timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Transcription

    func transcribe(
        audio: [Float],
        sampleRate: Int = 16000,
        vocabularyHints: [String]? = nil
    ) async throws -> String {
        guard !audio.isEmpty else { return "" }
        let wav = WAVEncoder.encode(samples: audio, sampleRate: sampleRate)
        let request = Self.makeRequest(
            shape: shape, baseURL: baseURL, apiKey: apiKey, model: model,
            audioWAV: wav, vocabularyHints: vocabularyHints, timeout: timeout)

        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(data: data, response: response)
        switch shape {
        case .dashScopeChat:
            return try Self.parseChatCompletionsResponse(data: data)
        case .openRouterJSON, .openAIMultipart:
            return try Self.parseTranscriptionsResponse(data: data)
        }
    }

    /// Synchronous variant for the existing background-thread dictation flow.
    func transcribeSync(
        audio: [Float],
        sampleRate: Int = 16000,
        vocabularyHints: [String]? = nil
    ) throws -> String {
        guard !audio.isEmpty else { return "" }
        let wav = WAVEncoder.encode(samples: audio, sampleRate: sampleRate)
        let request = Self.makeRequest(
            shape: shape, baseURL: baseURL, apiKey: apiKey, model: model,
            audioWAV: wav, vocabularyHints: vocabularyHints, timeout: timeout)

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        var requestError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                requestError = CloudASRError.unreachable(underlying: error.localizedDescription)
                return
            }
            guard let data = data else {
                requestError = CloudASRError.emptyResponse
                return
            }
            do {
                try Self.checkStatus(data: data, response: response)
                switch self.shape {
                case .dashScopeChat:
                    result = try Self.parseChatCompletionsResponse(data: data)
                case .openRouterJSON, .openAIMultipart:
                    result = try Self.parseTranscriptionsResponse(data: data)
                }
            } catch {
                requestError = error
            }
        }
        task.resume()
        semaphore.wait()
        if let error = requestError { throw error }
        return result
    }

    /// Probe `{base}/models` with the key, so a typo surfaces at entry rather than as a
    /// silent dictation failure later.
    static func validate(apiKey: String, baseURL: String, timeout: TimeInterval = 8) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let base = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              base.scheme != nil
        else { return false }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 1) != .success { task.cancel() }
        return ok
    }

    // MARK: - Request building

    static func makeRequest(
        shape: CloudRequestShape,
        baseURL: URL,
        apiKey: String,
        model: String,
        audioWAV: Data,
        vocabularyHints: [String]?,
        timeout: TimeInterval
    ) -> URLRequest {
        switch shape {
        case .openRouterJSON:
            return openRouterJSONRequest(baseURL: baseURL, apiKey: apiKey, model: model,
                                         audioWAV: audioWAV, vocabularyHints: vocabularyHints,
                                         timeout: timeout)
        case .openAIMultipart:
            return openAIMultipartRequest(baseURL: baseURL, apiKey: apiKey, model: model,
                                          audioWAV: audioWAV, vocabularyHints: vocabularyHints,
                                          timeout: timeout)
        case .dashScopeChat:
            return dashScopeChatRequest(baseURL: baseURL, apiKey: apiKey, model: model,
                                        audioWAV: audioWAV, vocabularyHints: vocabularyHints,
                                        timeout: timeout)
        }
    }

    private static func openRouterJSONRequest(
        baseURL: URL, apiKey: String, model: String, audioWAV: Data,
        vocabularyHints: [String]?, timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var body: [String: Any] = [
            "model": model,
            "input_audio": [
                "data": audioWAV.base64EncodedString(),
                "format": "wav",
            ],
        ]
        if let prompt = buildPrompt(vocabularyHints: vocabularyHints) {
            // Accepted where the provider supports it; OpenRouter passes it through to
            // providers that honour it. Verify per provider in the bake-off.
            body["prompt"] = prompt
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func openAIMultipartRequest(
        baseURL: URL, apiKey: String, model: String, audioWAV: Data,
        vocabularyHints: [String]?, timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var data = Data()
        data.appendMultipart(name: "model", value: model, boundary: boundary)
        if let prompt = buildPrompt(vocabularyHints: vocabularyHints) {
            data.appendMultipart(name: "prompt", value: prompt, boundary: boundary)
        }
        data.appendMultipart(name: "response_format", value: "json", boundary: boundary)
        data.appendMultipartFile(name: "file", filename: "audio.wav", contentType: "audio/wav",
                                 body: audioWAV, boundary: boundary)
        data.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = data
        return request
    }

    private static func dashScopeChatRequest(
        baseURL: URL, apiKey: String, model: String, audioWAV: Data,
        vocabularyHints: [String]?, timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let dataURI = "data:audio/wav;base64,\(audioWAV.base64EncodedString())"
        var messages: [[String: Any]] = []
        // Bare comma list, same rule as the local sidecar's X-TalkType-Context: prose
        // context has been observed making Qwen complete the prompt instead of
        // transcribing. Whether cloud Flash does the same is a bake-off question.
        if let prompt = buildPrompt(vocabularyHints: vocabularyHints) {
            messages.append(["role": "system", "content": "Vocabulary: \(prompt)"])
        }
        messages.append([
            "role": "user",
            "content": [
                ["type": "input_audio", "input_audio": ["data": dataURI]],
            ],
        ])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "asr_options": ["enable_itn": true],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The one vocabulary rule that must hold on every path: a bare comma list, no prose.
    static func buildPrompt(vocabularyHints: [String]?) -> String? {
        let hints = (vocabularyHints ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.replacingOccurrences(of: "[\r\n]", with: " ", options: .regularExpression) }
            .filter { !$0.isEmpty }
        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: ", ")
    }

    // MARK: - Response parsing

    static func checkStatus(data: Data, response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw CloudASRError.badStatus(statusCode: http.statusCode, body: detail)
        }
    }

    /// `{"text": "..."}` — OpenRouter JSON and OpenAI multipart both come back like this.
    static func parseTranscriptionsResponse(data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else { throw CloudASRError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `{"choices": [{"message": {"content": "..."}}]}` — DashScope's chat-completions shape.
    static func parseChatCompletionsResponse(data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw CloudASRError.emptyResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CloudASRError: LocalizedError {
    case unreachable(underlying: String)
    case badStatus(statusCode: Int, body: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unreachable(let underlying):
            return "Cloud speech engine unreachable: \(underlying)"
        case .badStatus(let code, let body):
            return "Cloud speech engine error (\(code)): \(body)"
        case .emptyResponse:
            return "Cloud speech engine returned no text."
        }
    }
}

// MARK: - Multipart helpers

private extension Data {
    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendMultipartFile(
        name: String, filename: String, contentType: String, body: Data, boundary: String
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(body)
        append(Data("\r\n".utf8))
    }
}
