import Foundation
import Security

/// One Keychain item per exclusive STT provider. Never reuse a retired service name that
/// `removeLegacyKeys` still deletes on launch.
enum STTKeyStore {
    private static let doubaoService = "talktype-doubao-api-key"
    private static let xaiService = "talktype-xai-api-key"

    static func apiKey(for provider: STTProvider) -> String? {
        read(service(for: provider))
    }

    static func isConfigured(_ provider: STTProvider) -> Bool {
        apiKey(for: provider) != nil
    }

    @discardableResult
    static func store(apiKey: String, for provider: STTProvider) -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return write(key, to: service(for: provider))
    }

    static func clear(_ provider: STTProvider) {
        delete(service(for: provider))
    }

    private static func service(for provider: STTProvider) -> String {
        switch provider {
        case .doubao: return doubaoService
        case .grok: return xaiService
        }
    }

    /// v3 cleaned old multi-provider keys. Keep wiping those names so a stale secret cannot
    /// be mistaken for the new exclusive-switch stores.
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
