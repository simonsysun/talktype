import Foundation
import Security

/// Turns a raw transcript into text that reads like it was written rather than spoken.
///
/// This is the one part of TalkType that leaves the machine: the audio is transcribed
/// locally, and only the resulting text is sent. It is optional, times out fast, and
/// falls back to `PostProcessor.tidySpeech` — a dictation never waits on the network to
/// produce something usable.
///
/// Qwen was chosen after benchmarking the Groq catalogue on real recordings. Llama 3.1 8B
/// invented content that was never spoken ("英伟达的财报看起来不错，股价上涨了") and answered
/// questions instead of tidying them; Llama 3.3 70B translated English input to Chinese;
/// gpt-oss-20b returned empty output on two of five cases. Qwen was also the fastest.
final class TextRefiner {

    static let defaultModel = "qwen/qwen3.6-27b"
    static let keychainService = "talktype-groq"

    private let model: String
    private let timeout: TimeInterval
    private let session: URLSession

    init(model: String = TextRefiner.defaultModel, timeout: TimeInterval = 2.5) {
        self.model = model
        self.timeout = timeout

        // A dedicated session so the TLS connection to Groq stays warm between
        // dictations; a cold handshake costs more than the inference does.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Availability

    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    var isConfigured: Bool { Self.apiKey() != nil }

    /// Open the connection ahead of first use so the initial dictation does not pay for
    /// DNS and the TLS handshake on top of everything else.
    func prewarm() {
        guard let key = Self.apiKey() else { return }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        session.dataTask(with: request).resume()
    }

    // MARK: - Refinement

    /// Returns refined text, or nil to mean "use the local fallback". Never throws:
    /// every failure — no key, no network, timeout, rejected output — is the same
    /// outcome from the caller's point of view.
    func refine(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, let key = Self.apiKey() else { return nil }

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Groq's edge rejects the default URLSession/urllib agents with a 403.
        request.setValue("TalkType/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 800,
            "reasoning_effort": "none",      // Qwen3.6 otherwise spends the budget thinking
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": trimmed],
            ],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload

        let semaphore = DispatchSemaphore(value: 0)
        var refined: String?

        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                print("[refine] \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("[refine] unusable response (HTTP \(code))")
                return
            }
            refined = Self.stripReasoning(content).trimmingCharacters(in: .whitespacesAndNewlines)
        }.resume()

        guard semaphore.wait(timeout: .now() + timeout + 0.5) == .success else {
            print("[refine] timed out")
            return nil
        }

        guard let candidate = refined, !candidate.isEmpty else { return nil }
        guard Self.isPlausibleRefinement(original: trimmed, refined: candidate) else {
            print("[refine] rejected — falling back to local tidy")
            return nil
        }
        return candidate
    }

    // MARK: - Guard rails

    private static func stripReasoning(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<think>.*?</think>",
                                                   options: .dotMatchesLineSeparators) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Cheap checks against the failure modes actually observed while benchmarking.
    /// Rewording is allowed — that is the point of refinement — so this cannot be a
    /// subsequence test. It catches translation and truncation, not same-language
    /// invention; the defence against that is model choice.
    static func isPlausibleRefinement(original: String, refined: String) -> Bool {
        let originalCJK = cjkRatio(original)
        let refinedCJK = cjkRatio(refined)
        if abs(originalCJK - refinedCJK) > 0.25 { return false }   // language flipped

        let a = Double(original.count), b = Double(refined.count)
        guard a > 0 else { return false }
        return b >= a * 0.45 && b <= a * 1.35                      // truncated or padded
    }

    private static func cjkRatio(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let cjk = letters.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        return Double(cjk.count) / Double(letters.count)
    }

    // MARK: - Prompt

    /// Written in Chinese and rule-first on purpose. An English prompt with the
    /// language rule buried mid-paragraph made small models translate the input.
    static let systemPrompt = """
    你把口述的语音转写整理成通顺的文字。

    必须遵守：
    - 输出和输入用同一种语言。中文进中文出，英文进英文出，中英混说保持中英混。绝不翻译。
    - 只整理，不回答、不总结、不添加任何信息。保留说话人表达的每一个意思。
    - 删除语气词、重复、结巴、说了一半又放弃的内容。
    - 自我更正时只保留改正后的版本。
    - 可以调整语序和断句，让它读起来像写出来的，而不是说出来的。
    - 中文用全角标点，英文用半角标点，中文和英文/数字之间加一个空格。

    只输出整理后的文字，不要解释，不要引号。
    """
}
