import Foundation
import Security

/// 豆包新版控制台只发一个 API Key。TalkType 也只存这一项，避免把旧版 App ID / Token 或
/// 火山 IAM 的 AK/SK 混进来。
enum STTKeyStore {
    private static let apiKeyService = "talktype-doubao-api-key"

    static func apiKey() -> String? { read(apiKeyService) }

    static var isConfigured: Bool { apiKey() != nil }

    @discardableResult
    static func store(apiKey: String) -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return write(key, to: apiKeyService)
    }

    static func clear() { delete(apiKeyService) }

    /// v3 是不可逆的产品收敛：旧豆包双凭证、旧 provider 和 Whisper 时代的聚合项都不再读。
    static func removeLegacyKeys() {
        for service in ["talktype-doubao-appid", "talktype-doubao-token",
                        "talktype-asr-openrouter", "talktype-groq", "talktype-asr-openai",
                        "talktype-asr-dashscope", "talktype-asr-groq", "talktype-asr-custom",
                        "talktype-stt-grok", "talktype-stt-elevenlabs",
                        "talktype-stt-soniox", "talktype-stt-openai",
                        AppIdentity.legacyKeychainService] {
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

    /// 先原地更新，避免“删成功、写失败”把仍然可用的 Key 一起弄丢。
    @discardableResult
    private static func write(_ value: String, to service: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
        ] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            print("[key] keychain update failed: OSStatus \(updateStatus)")
            return false
        }

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
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        print("[key] keychain delete failed: service=\(service) OSStatus \(status)")
        return false
    }
}
