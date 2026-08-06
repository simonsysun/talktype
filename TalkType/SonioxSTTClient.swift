import Foundation

/// Soniox v5 — the only provider here without a synchronous endpoint.
///
/// A dictation costs four round trips: upload the audio, create the job, poll until it
/// finishes, fetch the transcript. That is structurally slower than the other three, and
/// whether the latency is acceptable for push-to-talk dictation is the open question this
/// client exists to answer.
///
/// What it buys: `language_hints` plus `context.terms`, and an explicit promise to handle
/// languages mixed inside a single sentence. What it does not do is remove fillers — there
/// is no such switch, so its transcripts arrive verbatim.
struct SonioxSTTClient: STTClient {
    static let base = URL(string: "https://api.soniox.com/v1")!
    static let name = "Soniox"
    static let model = "stt-async-v5"
    static let languageHints = ["zh", "en"]
    /// Soniox caps the whole context object at ~8k tokens; the vocabulary list is nowhere
    /// near that, so these limits only guard against a pathological entry.
    static let maxTerms = 500
    static let maxTermLength = 100
    static let pollInterval: TimeInterval = 0.25

    let apiKey: String
    private let session: URLSession?

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session
    }

    func transcribe(wav: Data, terms: [String], timeout: TimeInterval) throws -> String {
        let session = self.session ?? STTTransport.makeSession(timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)

        let fileID = try upload(wav: wav, session: session, deadline: deadline)
        let jobID: String
        do {
            jobID = try createJob(fileID: fileID, terms: terms, session: session, deadline: deadline)
        } catch {
            // The upload succeeded but the job did not — do not leave the audio sitting in
            // the account.
            discard(path: "files/\(fileID)", session: session)
            throw error
        }

        defer {
            // Audio and transcript both live server-side until deleted. Fire and forget:
            // the user is waiting for text, not for our housekeeping.
            discard(path: "transcriptions/\(jobID)", session: session)
            discard(path: "files/\(fileID)", session: session)
        }

        try awaitCompletion(jobID: jobID, session: session, deadline: deadline)
        return try fetchTranscript(jobID: jobID, session: session, deadline: deadline)
    }

    // MARK: - Steps

    private func upload(wav: Data, session: URLSession, deadline: Date) throws -> String {
        var form = MultipartBody()
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: wav)

        var request = URLRequest(url: Self.base.appendingPathComponent("files"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let data = try send(request, session: session, deadline: deadline)
        return try Self.id(from: data)
    }

    private func createJob(fileID: String, terms: [String], session: URLSession,
                           deadline: Date) throws -> String {
        var request = URLRequest(url: Self.base.appendingPathComponent("transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: Self.jobBody(fileID: fileID, terms: terms))

        let data = try send(request, session: session, deadline: deadline)
        return try Self.id(from: data)
    }

    /// Polls until the job reports `completed`, or the deadline runs out.
    private func awaitCompletion(jobID: String, session: URLSession, deadline: Date) throws {
        let url = Self.base.appendingPathComponent("transcriptions/\(jobID)")
        while Date() < deadline {
            let data = try send(get(url), session: session, deadline: deadline)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch json?["status"] as? String {
            case "completed":
                return
            case "error":
                let message = json?["error_message"] as? String ?? "unknown error"
                throw STTError.jobFailed(provider: Self.name, message: message)
            default:
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        }
        throw STTError.timedOut(provider: Self.name)
    }

    private func fetchTranscript(jobID: String, session: URLSession, deadline: Date) throws -> String {
        let url = Self.base.appendingPathComponent("transcriptions/\(jobID)/transcript")
        let data = try send(get(url), session: session, deadline: deadline)
        return try Self.joinTokens(data)
    }

    /// Delete something we created, ignoring the outcome.
    private func discard(path: String, session: URLSession) {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: request).resume()
    }

    // MARK: - Helpers

    private func get(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Every step shares one deadline, so a slow upload eats into the polling budget
    /// rather than each step getting a fresh full timeout.
    private func send(_ request: URLRequest, session: URLSession, deadline: Date) throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw STTError.timedOut(provider: Self.name) }
        var request = request
        request.timeoutInterval = remaining
        return try STTTransport.run(request, session: session, provider: Self.name,
                                    timeout: remaining)
    }

    static func jobBody(fileID: String, terms: [String]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "file_id": fileID,
            "language_hints": languageHints,
        ]
        let clean = STTTerms.sanitize(terms, maxCount: maxTerms, maxLength: maxTermLength)
        if !clean.isEmpty {
            body["context"] = ["terms": clean]
        }
        return body
    }

    static func id(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty
        else { throw STTError.emptyResponse(provider: name) }
        return id
    }

    /// Soniox returns an array of tokens rather than a finished string. The token text
    /// carries its own leading space where one belongs (English words) and none where it
    /// does not (Chinese), so a plain concatenation is the faithful reconstruction —
    /// inserting separators here would put spaces between Chinese characters.
    static func joinTokens(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [[String: Any]]
        else { throw STTError.emptyResponse(provider: name) }
        let text = tokens.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
