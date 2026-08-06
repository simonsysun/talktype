import Foundation

/// The four speech-to-text APIs TalkType can speak to. Each one is a single call that is
/// expected to return text good enough to paste — no polish layer runs afterwards, so
/// whatever the provider does natively is what the user sees. That is the whole point:
/// the app is a shell, and the comparison between providers stays honest.
enum STTProvider: String, Codable, CaseIterable {
    case grok
    case elevenlabs
    case soniox
    case openai

    var displayName: String {
        switch self {
        case .grok: return "xAI Grok"
        case .elevenlabs: return "ElevenLabs Scribe v2"
        case .soniox: return "Soniox v5"
        case .openai: return "OpenAI gpt-transcribe"
        }
    }

    /// One line for the picker: what it costs and what it natively does to the text.
    var summary: String {
        switch self {
        case .grok:
            return "$0.10/h · 默认去口头语 · 中文不在官方语言表内"
        case .elevenlabs:
            return "$0.22/h · no_verbatim 去口头语、重复、结巴"
        case .soniox:
            return "~$0.10/h · 中英同句混说 · 不去口头语 · 异步轮询，较慢"
        case .openai:
            return "$0.27/h · 中英混说好 · 不去口头语"
        }
    }

    /// One keychain slot per provider, so switching back and forth never asks for a key
    /// that was already entered.
    var keychainService: String { "talktype-stt-\(rawValue)" }

    var keyPlaceholder: String {
        switch self {
        case .grok: return "xai-…"
        case .elevenlabs: return "sk_…"
        case .soniox: return "soniox key"
        case .openai: return "sk-…"
        }
    }

    /// Where to get a key, shown next to the field.
    var consoleURL: String {
        switch self {
        case .grok: return "https://console.x.ai"
        case .elevenlabs: return "https://elevenlabs.io/app/settings/api-keys"
        case .soniox: return "https://console.soniox.com"
        case .openai: return "https://platform.openai.com/api-keys"
        }
    }

    func makeClient(apiKey: String, config: AppConfig, session: URLSession? = nil) -> STTClient {
        switch self {
        case .grok:
            return GrokSTTClient(apiKey: apiKey, language: config.grokLanguage, session: session)
        case .elevenlabs:
            return ElevenLabsSTTClient(apiKey: apiKey, session: session)
        case .soniox:
            return SonioxSTTClient(apiKey: apiKey, session: session)
        case .openai:
            return OpenAISTTClient(apiKey: apiKey, session: session)
        }
    }
}
