import Foundation

// MARK: - Provider definitions

enum ASRProvider: String, Codable {
    case openai
    case groq

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        }
    }

    var transcriptionEndpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1/audio/transcriptions"
        case .groq: return "https://api.groq.com/openai/v1/audio/transcriptions"
        }
    }

    var modelsEndpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1/models"
        case .groq: return "https://api.groq.com/openai/v1/models"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return defaultOpenAIASRModel
        case .groq: return defaultGroqASRModel
        }
    }

    var models: [(id: String, label: String)] {
        switch self {
        case .openai: return [
            (defaultOpenAIASRModel, "GPT-4o mini Transcribe"),
            (premiumOpenAIASRModel, "GPT-4o Transcribe"),
        ]
        case .groq: return [
            (defaultGroqASRModel, "Whisper Large v3"),
            (turboGroqASRModel, "Whisper Large v3 Turbo"),
        ]
        }
    }

    var keyAccount: String {
        switch self {
        case .openai: return openAIASRAccount
        case .groq: return groqASRAccount
        }
    }

    var envVar: String {
        switch self {
        case .openai: return "TALKTYPE_API_KEY"
        case .groq: return "TALKTYPE_GROQ_API_KEY"
        }
    }
}

let defaultOpenAIASRModel = "gpt-4o-mini-transcribe"
let premiumOpenAIASRModel = "gpt-4o-transcribe"
let openAIASRAccount = "OpenAI-ASR"

let defaultGroqASRModel = "whisper-large-v3"
let turboGroqASRModel = "whisper-large-v3-turbo"
let groqASRAccount = "Groq-ASR"

/// Speech-to-text via OpenAI-compatible transcription API. Supports OpenAI and Groq providers.
final class Transcriber {
    var model: String
    var timeout: TimeInterval
    var provider: ASRProvider

    init(provider: ASRProvider = .openai, model: String = defaultOpenAIASRModel, timeout: TimeInterval = 30.0) {
        self.provider = provider
        self.model = model
        self.timeout = timeout
    }

    func transcribe(
        audio: [Float],
        sampleRate: Int = 16000,
        vocabularyHints: [String]? = nil
    ) throws -> String {
        guard !audio.isEmpty else { return "" }
        let request = try buildRequest(audio: audio, sampleRate: sampleRate, vocabularyHints: vocabularyHints)

        let semaphore = DispatchSemaphore(value: 0)
        var result: String = ""
        var requestError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                requestError = error
                return
            }

            guard let data = data else {
                requestError = TranscriberError.emptyResponse
                return
            }

            do {
                result = try Transcriber.parseResponse(data: data, response: response)
            } catch {
                requestError = error
            }
        }
        task.resume()
        semaphore.wait()

        if let error = requestError {
            throw error
        }
        return result
    }

    /// Async transcription for iOS keyboard extension (non-blocking).
    func transcribeAsync(
        audio: [Float],
        sampleRate: Int = 16000,
        vocabularyHints: [String]? = nil
    ) async throws -> String {
        guard !audio.isEmpty else { return "" }
        let request = try buildRequest(audio: audio, sampleRate: sampleRate, vocabularyHints: vocabularyHints)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try Transcriber.parseResponse(data: data, response: response)
    }

    /// Validate an API key by calling the models endpoint (instance method).
    func validateKey(_ key: String) throws {
        try Transcriber.validateKey(key, modelsEndpoint: provider.modelsEndpoint, provider: provider)
    }

    /// Validate an API key against a specific models endpoint (thread-safe, no instance state).
    static func validateKey(_ key: String, modelsEndpoint: String, provider: ASRProvider = .openai) throws {
        var request = URLRequest(url: URL(string: modelsEndpoint)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10.0

        let semaphore = DispatchSemaphore(value: 0)
        var requestError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                requestError = error
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                requestError = TranscriberError.invalidAPIKey(provider: provider)
                return
            }
        }
        task.resume()
        semaphore.wait()

        if let error = requestError { throw error }
    }

    // MARK: - Request / response

    /// Build the multipart transcription request. Shared by the sync and async paths
    /// so the body format can never drift between platforms.
    private func buildRequest(
        audio: [Float],
        sampleRate: Int,
        vocabularyHints: [String]?
    ) throws -> URLRequest {
        guard let apiKey = loadAPIKey() else {
            throw TranscriberError.missingAPIKey(provider: provider)
        }

        let wavData = WAVEncoder.encode(samples: audio, sampleRate: sampleRate)
        let prompt = buildPrompt(vocabularyHints: vocabularyHints)
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        body.reserveCapacity(wavData.count + 512)

        body.appendMultipart(name: "model", value: model, boundary: boundary)
        // Explicit response format — don't rely on provider defaults.
        body.appendMultipart(name: "response_format", value: "json", boundary: boundary)
        if let prompt = prompt {
            body.appendMultipart(name: "prompt", value: prompt, boundary: boundary)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: provider.transcriptionEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout
        return request
    }

    /// Extract the transcript, or throw on an API error.
    /// A body that isn't JSON is treated as a plain-text transcript; JSON without a
    /// `text` field yields "" rather than dumping raw JSON into the user's document.
    static func parseResponse(data: Data, response: URLResponse?) throws -> String {
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriberError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = json["text"] as? String ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Private

    private func loadAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment[provider.envVar], !key.isEmpty {
            return key
        }
        let key = KeyStorage.retrieveKey(provider: provider.keyAccount)
        // Legacy fallback for OpenAI only
        if key == nil && provider == .openai {
            return KeyStorage.retrieveKey(provider: "OpenAI")
        }
        return key
    }

    private func buildPrompt(vocabularyHints: [String]?) -> String? {
        let hints = (vocabularyHints ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: ", ")
    }

}

// MARK: - WAV encoding

/// Mono 16-bit PCM WAV encoder.
///
/// The PCM block is converted once and appended in a single bulk copy rather than one
/// `Data.append` per sample. Measured on Apple silicon this is ~20x faster but saves only
/// ~10 ms on a 30 s recording — negligible next to the API round trip. It lives here as a
/// separate type mainly so both request paths share one encoder and it can be tested.
enum WAVEncoder {
    static let headerSize = 44

    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var wav = Data(capacity: headerSize + dataSize)

        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLittleEndian(UInt32(36 + dataSize))   // file size - 8
        wav.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLittleEndian(UInt32(16))              // chunk size
        wav.appendLittleEndian(UInt16(1))               // PCM format
        wav.appendLittleEndian(UInt16(1))               // mono
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(UInt32(sampleRate * 2))  // byte rate
        wav.appendLittleEndian(UInt16(2))               // block align
        wav.appendLittleEndian(UInt16(16))              // bits per sample

        // data chunk
        wav.append(contentsOf: "data".utf8)
        wav.appendLittleEndian(UInt32(dataSize))

        guard !samples.isEmpty else { return wav }

        // Store little-endian explicitly so the bulk copy below is byte-exact
        // regardless of host endianness.
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0).littleEndian
        }
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }

        return wav
    }
}

enum TranscriberError: LocalizedError {
    case missingAPIKey(provider: ASRProvider)
    case invalidAPIKey(provider: ASRProvider)
    case emptyResponse
    case apiError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            #if os(iOS)
            return "\(provider.displayName) API key is missing. Open the TalkType app to set it up."
            #else
            return "\(provider.displayName) API key is missing. Set it from TalkType tray menu."
            #endif
        case .invalidAPIKey(let provider):
            return "\(provider.displayName) API key is invalid."
        case .emptyResponse:
            return "Empty response from transcription API."
        case .apiError(let code, let body):
            return "API error (\(code)): \(body)"
        }
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
