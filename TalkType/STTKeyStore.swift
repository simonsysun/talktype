import Foundation
import Security

/// One Keychain item per exclusive STT provider. Never reuse a retired service name that
/// `removeLegacyKeys` still deletes on launch.
///
/// Access policy: each item's ACL trusts **this app only**, so after one save (or one
/// migration Allow), TalkType can read the key without re-prompting the login keychain
/// password on every dictation / menu refresh. Items created by `security` CLI or other
/// tools lack that ACL and re-prompt until rewritten via `store` / `rewireAccessIfNeeded`.
enum STTKeyStore {
    private static let doubaoService = "talktype-doubao-api-key"
    private static let xaiService = "talktype-xai-api-key"
    /// Stable account attribute (not the macOS username) so items are easy to find/replace.
    private static let account = "talktype"

    private static let cacheLock = NSLock()
    private static var memoryCache: [String: String] = [:]

    static func apiKey(for provider: STTProvider) -> String? {
        let service = service(for: provider)
        cacheLock.lock()
        if let cached = memoryCache[service] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let value = readSecret(service) else { return nil }
        cacheLock.lock()
        memoryCache[service] = value
        cacheLock.unlock()
        return value
    }

    /// Existence only — does not pull the secret when possible, and uses the memory cache
    /// so the menu bar does not hammer Keychain on every open.
    static func isConfigured(_ provider: STTProvider) -> Bool {
        let service = service(for: provider)
        cacheLock.lock()
        if memoryCache[service] != nil {
            cacheLock.unlock()
            return true
        }
        cacheLock.unlock()
        if itemExists(service) { return true }
        // Fall back to a full read (may prompt once for legacy ACL items).
        return apiKey(for: provider) != nil
    }

    @discardableResult
    static func store(apiKey: String, for provider: STTProvider) -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let service = service(for: provider)
        let ok = writeSecret(key, to: service)
        if ok {
            cacheLock.lock()
            memoryCache[service] = key
            cacheLock.unlock()
        }
        return ok
    }

    static func clear(_ provider: STTProvider) {
        let service = service(for: provider)
        delete(service)
        cacheLock.lock()
        memoryCache.removeValue(forKey: service)
        cacheLock.unlock()
    }

    /// Call once at launch: if a key is readable, rewrite it with an ACL that trusts this
    /// app so subsequent reads do not re-prompt. User may still approve **once** for keys
    /// that were created outside TalkType (e.g. `security add-generic-password`).
    static func rewireAccessIfNeeded() {
        for provider in STTProvider.allCases {
            let service = service(for: provider)
            guard let value = apiKey(for: provider) else { continue }
            // Rewrite even if data is unchanged — the point is the ACL.
            if writeSecret(value, to: service) {
                print("[key] rewired ACL for \(service)")
            }
        }
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

    /// ACL that allows only the running TalkType binary to use the item without a prompt.
    private static func appOnlyAccess(label: String) -> SecAccess? {
        var trusted: SecTrustedApplication?
        // nil path = the calling application (this TalkType.app binary / signature).
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess,
              let trusted
        else {
            print("[key] SecTrustedApplicationCreateFromPath failed")
            return nil
        }
        var access: SecAccess?
        let status = SecAccessCreate(label as CFString, [trusted] as CFArray, &access)
        guard status == errSecSuccess else {
            print("[key] SecAccessCreate failed: OSStatus \(status)")
            return nil
        }
        return access
    }

    private static func itemExists(_ service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    private static func readSecret(_ service: String) -> String? {
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

    /// Delete-then-add with app-trusted ACL. In-place SecItemUpdate does not reliably
    /// repair ACLs on items created by other tools (CLI, old builds).
    @discardableResult
    private static func writeSecret(_ value: String, to service: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Best-effort delete of any prior item (any account) for this service.
        delete(service)

        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        if let access = appOnlyAccess(label: "TalkType \(service)") {
            attrs[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            print("[key] keychain write failed: service=\(service) OSStatus \(status)")
            return false
        }
        return true
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
