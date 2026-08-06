import Foundation
import Security

/// 豆包要两个值：App ID 和 Access Token。两个一起存、一起取、一起清——只有一个的状态没有
/// 意义，暴露出来只会让「填好了没有」变成一个需要解释的问题。
enum STTKeyStore {
    private static let appIDService = "talktype-doubao-appid"
    private static let tokenService = "talktype-doubao-token"

    static func credentials() -> (appID: String, accessToken: String)? {
        guard let appID = read(appIDService), let token = read(tokenService) else { return nil }
        return (appID, token)
    }

    static var isConfigured: Bool { credentials() != nil }

    @discardableResult
    static func store(appID: String, accessToken: String) -> Bool {
        let id = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !token.isEmpty else { return false }
        return write(id, to: appIDService) && write(token, to: tokenService)
    }

    static func clear() {
        delete(appIDService)
        delete(tokenService)
    }

    /// 上一代管线的 key（OpenRouter 转写、Groq 润色）故意留着：上个 release 还是能回退的
    /// 版本，删掉它的凭证等于把回退变成重新配置。真的不再需要时再调这个。
    static func removeLegacyKeys() {
        for service in ["talktype-asr-openrouter", "talktype-groq", "talktype-asr-openai",
                        "talktype-asr-dashscope", "talktype-asr-groq", "talktype-asr-custom",
                        "talktype-stt-grok", "talktype-stt-elevenlabs",
                        "talktype-stt-soniox", "talktype-stt-openai"] {
            delete(service)
        }
    }

    // MARK: - Keychain

    private static func read(_ service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// `SecItemAdd` 在重复项上会失败而不是覆盖，所以先删再写。
    @discardableResult
    private static func write(_ value: String, to service: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(service)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess { print("[key] keychain write failed: OSStatus \(status)") }
        return status == errSecSuccess
    }

    @discardableResult
    private static func delete(_ service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
