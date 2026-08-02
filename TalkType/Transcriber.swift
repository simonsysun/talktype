import Foundation

/// Speech-to-text via the local Qwen3-ASR sidecar on 127.0.0.1.
///
/// There is no cloud path and no API key. The sidecar (`~/.talktype/asr/server.py`)
/// holds the model in memory, so a dictation is one loopback POST of raw WAV bytes —
/// ~0.3 s for a short phrase, ~0.9 s for 18 s of speech, and nothing leaves the machine.
final class Transcriber {
    var timeout: TimeInterval
    let baseURL: URL

    init(port: Int = SidecarDefaults.port, timeout: TimeInterval = 60.0) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.timeout = timeout
    }

    // MARK: - Transcription

    func transcribe(
        audio: [Float],
        sampleRate: Int = 16000,
        vocabularyHints: [String]? = nil
    ) throws -> String {
        guard !audio.isEmpty else { return "" }
        let request = buildRequest(audio: audio, sampleRate: sampleRate, vocabularyHints: vocabularyHints)

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        var requestError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                requestError = TranscriberError.sidecarUnreachable(underlying: error.localizedDescription)
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

        if let error = requestError { throw error }
        return result
    }

    /// Async variant, for callers that must not block a thread.
    func transcribeAsync(
        audio: [Float],
        sampleRate: Int = 16000,
        vocabularyHints: [String]? = nil
    ) async throws -> String {
        guard !audio.isEmpty else { return "" }
        let request = buildRequest(audio: audio, sampleRate: sampleRate, vocabularyHints: vocabularyHints)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return try Transcriber.parseResponse(data: data, response: response)
        } catch let error as TranscriberError {
            throw error
        } catch {
            throw TranscriberError.sidecarUnreachable(underlying: error.localizedDescription)
        }
    }

    // MARK: - Health

    /// Sidecar state, for the menu bar. Never throws — an unreachable sidecar is a state, not an error.
    func health() -> SidecarHealth {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0

        let semaphore = DispatchSemaphore(value: 0)
        var health = SidecarHealth.unreachable

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                let model = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?
                    .flatMap { $0["model"] as? String }
                health = .ready(model: model ?? "unknown")
            case 503:
                health = .loading
            default:
                health = .unreachable
            }
        }
        task.resume()
        semaphore.wait()
        return health
    }

    // MARK: - Private

    private func buildRequest(
        audio: [Float],
        sampleRate: Int,
        vocabularyHints: [String]?
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = WAVEncoder.encode(samples: audio, sampleRate: sampleRate)
        request.timeoutInterval = timeout

        // Bare comma list only. A prose context makes the model complete the prompt
        // instead of transcribing — it has been observed translating a Chinese clip to
        // English and inventing a sentence that was never spoken.
        if let prompt = Self.buildPrompt(vocabularyHints: vocabularyHints) {
            request.setValue(prompt, forHTTPHeaderField: "X-TalkType-Context")
        }
        return request
    }

    static func buildPrompt(vocabularyHints: [String]?) -> String? {
        let hints = (vocabularyHints ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // Header values must stay single-line ASCII-safe control-free text.
            .map { $0.replacingOccurrences(of: "[\r\n]", with: " ", options: .regularExpression) }
            .filter { !$0.isEmpty }
        guard !hints.isEmpty else { return nil }
        return hints.joined(separator: ", ")
    }

    static func parseResponse(data: Data, response: URLResponse?) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = json?["error"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 503 { throw TranscriberError.sidecarLoading }
            throw TranscriberError.sidecarError(statusCode: http.statusCode, body: detail)
        }

        guard let text = json?["text"] as? String else {
            throw TranscriberError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Sidecar

enum SidecarDefaults {
    static let port = 8756
}

enum SidecarHealth: Equatable {
    case ready(model: String)
    case loading
    case unreachable
}

enum TranscriberError: LocalizedError, Equatable {
    case sidecarUnreachable(underlying: String)
    case sidecarLoading
    case emptyResponse
    case sidecarError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .sidecarUnreachable:
            return "Local speech engine is not running. Check the TalkType menu."
        case .sidecarLoading:
            return "Local speech engine is still loading. Try again in a moment."
        case .emptyResponse:
            return "Local speech engine returned no text."
        case .sidecarError(let code, let body):
            return "Local speech engine error (\(code)): \(body)"
        }
    }

    static func == (lhs: TranscriberError, rhs: TranscriberError) -> Bool {
        switch (lhs, rhs) {
        case (.sidecarUnreachable, .sidecarUnreachable): return true
        case (.sidecarLoading, .sidecarLoading): return true
        case (.emptyResponse, .emptyResponse): return true
        case (.sidecarError(let a, _), .sidecarError(let b, _)): return a == b
        default: return false
        }
    }
}

// MARK: - WAV encoding

/// Mono 16-bit PCM WAV encoder.
///
/// The PCM block is converted once and appended in a single bulk copy rather than one
/// `Data.append` per sample. Measured on Apple silicon this is ~20x faster but saves only
/// ~10 ms on a 30 s recording — negligible next to inference. It lives here as a separate
/// type so it can be tested directly.
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

// MARK: - Data helpers

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
