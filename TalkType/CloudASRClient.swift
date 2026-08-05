import Foundation

/// The single cloud dialect TalkType speaks. Everything about the cloud engine is fixed
/// by design — one provider (OpenRouter), one model family (Qwen3-ASR) — so there is
/// nothing to configure and nothing to get wrong.
enum CloudDefaults {
    static let baseURL = "https://openrouter.ai/api/v1"
    static let model = "qwen/qwen3-asr-flash-2026-02-10"
    static let keychainService = "talktype-asr-openrouter"
}

/// Speech-to-text through OpenRouter's audio endpoint.
///
/// The audio is the same WAV the local sidecar gets; only the transport differs.
/// OpenRouter takes base64 JSON under `input_audio`.
final class CloudASRClient {
    let baseURL: URL
    let apiKey: String
    let model: String
    let timeout: TimeInterval
    private let session: URLSession

    init(
        apiKey: String,
        model: String = CloudDefaults.model,
        baseURL: String = CloudDefaults.baseURL,
        timeout: TimeInterval = 60.0,
        session: URLSession? = nil
    ) {
        // Tolerate a base URL with or without a trailing slash; the endpoints below are
        // appended on top. Invalid URLs are caught here rather than mid-dictation.
        self.baseURL = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? URL(string: "https://invalid.local")!
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Transcription

    /// The dictation flow is background-thread and synchronous, so there is only the
    /// sync variant; request building and response parsing are shared with the
    /// static helpers below.
    func transcribeSync(
        audio: [Float],
        sampleRate: Int = 16000,
        vocabularyHints: [String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> String {
        guard !audio.isEmpty else { return "" }
        let effectiveTimeout = timeout ?? self.timeout
        let wav = WAVEncoder.encode(samples: audio, sampleRate: sampleRate)
        let request = Self.makeRequest(
            baseURL: baseURL, apiKey: apiKey, model: model,
            audioWAV: wav, vocabularyHints: vocabularyHints, timeout: effectiveTimeout)

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        var requestError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                if (error as? URLError)?.code == .timedOut {
                    requestError = CloudASRError.timedOut
                } else {
                    requestError = CloudASRError.unreachable(underlying: error.localizedDescription)
                }
                return
            }
            guard let data = data else {
                requestError = CloudASRError.emptyResponse
                return
            }
            do {
                try Self.checkStatus(data: data, response: response)
                result = try Self.parseTranscriptionsResponse(data: data)
            } catch {
                requestError = error
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + effectiveTimeout + 1) != .success {
            task.cancel()
            throw CloudASRError.timedOut
        }
        if let error = requestError { throw error }
        return result
    }

    /// Probe the key with OpenRouter. `/models` is public — it returns 200 even with
    /// no key — so `/auth/key` is the real check.
    static func validate(
        apiKey: String,
        baseURL: String = CloudDefaults.baseURL,
        timeout: TimeInterval = 8
    ) -> KeyValidationResult {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let base = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              base.scheme != nil,
              base.host != nil
        else { return .invalidURL }
        var request = URLRequest(url: base.appendingPathComponent("auth/key"))
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var result = KeyValidationResult.unreachable("no response")
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    result = .valid
                case 401, 403:
                    result = .rejected
                default:
                    // A 5xx/429 is OpenRouter having a bad moment, not a wrong key —
                    // reporting it as rejection would lock a good key out of Setup.
                    result = .unreachable("HTTP \(http.statusCode)")
                }
                return
            }
            if let transportError = error {
                result = .unreachable(transportError.localizedDescription)
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 1) != .success {
            task.cancel()
            result = .unreachable("request timed out")
        }
        return result
    }

    // MARK: - Request building

    static func makeRequest(
        baseURL: URL,
        apiKey: String,
        model: String,
        audioWAV: Data,
        vocabularyHints: [String]?,
        timeout: TimeInterval
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
            // OpenRouter accepts the field but ignores it (verified 2026-08-04); kept
            // because the vocabulary post-processing is the reliable path anyway.
            body["prompt"] = prompt
        }
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

    /// `{"text": "..."}` — OpenRouter's transcription response.
    static func parseTranscriptionsResponse(data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else { throw CloudASRError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CloudASRError: LocalizedError {
    case unreachable(underlying: String)
    case badStatus(statusCode: Int, body: String)
    case emptyResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unreachable(let underlying):
            return "Cloud speech engine unreachable: \(underlying)"
        case .badStatus(let code, let body):
            return "Cloud speech engine error (\(code)): \(body)"
        case .emptyResponse:
            return "Cloud speech engine returned no text."
        case .timedOut:
            return "Cloud speech engine timed out."
        }
    }

    /// Maps the error onto the user-facing taxonomy that drives the fallback policy.
    var classification: CloudFailure {
        switch self {
        case .timedOut:
            return .timeout
        case .badStatus(let code, _):
            switch code {
            case 401, 403: return .invalidKey
            case 402: return .limitOrRate
            case 404: return .modelUnavailable
            case 408: return .timeout
            case 429: return .limitOrRate
            default: return .serviceError
            }
        case .unreachable:
            return .unknown
        case .emptyResponse:
            return .serviceError
        }
    }
}

/// Why a key check did not succeed, so Setup can tell "the provider rejected the key"
/// apart from "this Mac could not reach the provider" — the two need different fixes.
enum KeyValidationResult: Equatable {
    case valid
    /// The provider answered and said the key is wrong.
    case rejected
    /// The request never got a usable answer — offline, DNS failure, timeout.
    case unreachable(String)
    /// The base URL is not a valid address.
    case invalidURL
}
