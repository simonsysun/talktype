import Foundation
import Security

/// One keychain slot per provider. Switching providers to compare them is the normal way
/// to use this app right now, so a key entered once has to survive being switched away
/// from and back.
///
/// There is deliberately no online key validation. Every provider would need its own
/// probe endpoint, and a wrong key already surfaces on the first dictation as "拒绝了这个
/// API key" — a check that costs four integrations to duplicate one error message is not
/// worth carrying.
enum STTKeyStore {

    static func apiKey(for provider: STTProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
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

    /// Store or replace. `SecItemAdd` fails on a duplicate rather than replacing, so an
    /// existing item is removed first.
    @discardableResult
    static func store(_ key: String, for provider: STTProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else { return false }
        delete(for: provider)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess { print("[stt-key] keychain write failed: OSStatus \(status)") }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(for provider: STTProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Versions before the single-call rewrite kept keys for OpenRouter transcription and
    /// Groq polish, plus a handful of older providers. None of those paths exist any more;
    /// clear the slots once so a dictation app does not sit on credentials it can no longer
    /// use and offers no way to remove.
    static func removeLegacyKeys() {
        let legacy = [
            "talktype-asr-openrouter",
            "talktype-groq",
            "talktype-asr-openai",
            "talktype-asr-dashscope",
            "talktype-asr-groq",
            "talktype-asr-custom",
        ]
        for service in legacy {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
