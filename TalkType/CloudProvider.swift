import Foundation

/// Cloud speech-to-text providers. Each maps to an OpenAI-compatible base URL plus the
/// request shape that provider actually serves — not all of them speak the same dialect.
enum CloudProvider: String, Codable, CaseIterable {
    case openRouter
    case openAI
    case dashScope
    case groq
    case custom

    var profile: ProviderProfile {
        switch self {
        case .openRouter:
            return ProviderProfile(
                name: "OpenRouter",
                defaultBaseURL: "https://openrouter.ai/api/v1",
                defaultModel: "qwen/qwen3-asr-flash-2026-02-10",
                keyPlaceholder: "sk-or-…",
                requestShape: .openRouterJSON,
                keychainService: "talktype-asr-openrouter",
                isKnown: true)
        case .openAI:
            return ProviderProfile(
                name: "OpenAI",
                defaultBaseURL: "https://api.openai.com/v1",
                defaultModel: "gpt-4o-transcribe",
                keyPlaceholder: "sk-…",
                requestShape: .openAIMultipart,
                keychainService: "talktype-asr-openai",
                isKnown: true)
        case .dashScope:
            return ProviderProfile(
                name: "Alibaba DashScope 百炼",
                defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                defaultModel: "qwen3-asr-flash",
                keyPlaceholder: "sk-…",
                requestShape: .dashScopeChat,
                keychainService: "talktype-asr-dashscope",
                isKnown: true)
        case .groq:
            return ProviderProfile(
                name: "Groq",
                defaultBaseURL: "https://api.groq.com/openai/v1",
                defaultModel: "whisper-large-v3-turbo",
                keyPlaceholder: "gsk_…",
                requestShape: .openAIMultipart,
                keychainService: "talktype-asr-groq",
                isKnown: true)
        case .custom:
            return ProviderProfile(
                name: "Custom (OpenAI-compatible)",
                defaultBaseURL: "",
                defaultModel: "",
                keyPlaceholder: "API key",
                requestShape: .openAIMultipart,
                keychainService: "talktype-asr-custom",
                isKnown: false)
        }
    }

    /// Identify the provider from the base URL the user pastes. The URL is the reliable
    /// signal — two providers can both use `sk-` keys, but their hosts differ.
    static func detect(baseURL: String) -> CloudProvider {
        let normalized = baseURL.lowercased()
        if normalized.contains("openrouter") { return .openRouter }
        if normalized.contains("openai.com") { return .openAI }
        if normalized.contains("dashscope") || normalized.contains("aliyuncs.com") { return .dashScope }
        if normalized.contains("groq.com") { return .groq }
        return .custom
    }

    /// Best-effort key-shape hint. OpenRouter keys are the only ones with a recognizable
    /// prefix today (`sk-or-`); the URL stays the source of truth.
    static func detect(key: String) -> CloudProvider? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sk-or-") { return .openRouter }
        return nil
    }
}

struct ProviderProfile {
    let name: String
    let defaultBaseURL: String
    let defaultModel: String
    let keyPlaceholder: String
    let requestShape: CloudRequestShape
    let keychainService: String
    let isKnown: Bool
}

/// How a provider's `/audio/transcriptions`-equivalent endpoint wants the audio.
enum CloudRequestShape: String, Codable {
    /// OpenRouter: POST {base}/audio/transcriptions with a JSON body whose
    /// `input_audio.data` is raw base64 (not a data URI).
    case openRouterJSON
    /// OpenAI/Groq: POST {base}/audio/transcriptions with multipart/form-data.
    case openAIMultipart
    /// DashScope Qwen-ASR: POST {base}/chat/completions with an `input_audio`
    /// content block carrying a `data:audio/wav;base64,…` URI.
    case dashScopeChat
}
