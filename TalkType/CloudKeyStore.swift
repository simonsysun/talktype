import Foundation
import Security

/// The one API key TalkType needs: OpenRouter. A single slot, because there is a single
/// provider by design.
enum CloudKeyStore {

    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CloudDefaults.keychainService,
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

    /// Store or replace the key. `SecItemAdd` fails on a duplicate rather than replacing,
    /// so an existing item is removed first.
    @discardableResult
    static func storeAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else { return false }
        deleteAPIKey()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CloudDefaults.keychainService,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess { print("[asr-key] keychain write failed: OSStatus \(status)") }
        return status == errSecSuccess
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CloudDefaults.keychainService,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// 2.1.0 kept one keychain slot per provider. Those providers are gone; clear the
    /// orphaned entries once, so a privacy-focused app does not leave stale credentials
    /// lying around with no way to remove them. (`talktype-groq` stays — it is the
    /// polish key.)
    static func removeLegacyKeys() {
        let legacyServices = [
            "talktype-asr-openai",
            "talktype-asr-dashscope",
            "talktype-asr-groq",
            "talktype-asr-custom",
        ]
        for service in legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
