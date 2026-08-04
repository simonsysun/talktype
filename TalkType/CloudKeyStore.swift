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
}
