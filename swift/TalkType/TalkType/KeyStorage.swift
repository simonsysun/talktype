import Foundation
import CryptoKit

/// Local encrypted API key storage using ChaChaPoly, machine-bound.
/// Compatible pattern with Python version but uses CryptoKit instead of Fernet.
enum KeyStorage {
    private static var keysDir: URL {
        AppIdentity.stateDir.appendingPathComponent("keys")
    }

    private static var masterKeyPath: URL {
        keysDir.appendingPathComponent("master_swift.key")
    }

    private static func encryptedPath(provider: String) -> URL {
        let safe = provider.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        return keysDir.appendingPathComponent("\(safe).senc")
    }

    // MARK: - Public API

    static func storeKey(provider: String, apiKey: String) -> Bool {
        deleteKey(provider: provider)

        guard let plaintext = apiKey.data(using: .utf8) else { return false }
        guard let key = symmetricKey() else { return false }

        do {
            let sealed = try ChaChaPoly.seal(plaintext, using: key)
            let data = sealed.combined
            let path = encryptedPath(provider: provider)
            ensureKeysDir()
            try data.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return true
        } catch {
            print("[keystore] encrypt failed: \(error)")
            return false
        }
    }

    static func retrieveKey(provider: String) -> String? {
        // Try Swift encrypted storage first
        if let value = retrieveEncrypted(provider: provider) {
            return value
        }

        // Try Python Fernet-encrypted storage (migration path)
        // We can't decrypt Fernet, so try legacy keychain instead
        if let legacy = retrieveLegacyKeychain(provider: provider) {
            if storeKey(provider: provider, apiKey: legacy) {
                deleteLegacyKeychain(provider: provider)
            }
            return legacy
        }

        return nil
    }

    @discardableResult
    static func deleteKey(provider: String) -> Bool {
        let encDeleted = deleteEncrypted(provider: provider)
        let legacyDeleted = deleteLegacyKeychain(provider: provider)
        return encDeleted || legacyDeleted
    }

    // MARK: - Encryption internals

    private static func ensureKeysDir() {
        let dir = keysDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static func loadOrCreateMasterSecret() -> Data? {
        ensureKeysDir()
        let path = masterKeyPath

        if FileManager.default.fileExists(atPath: path.path) {
            return try? Data(contentsOf: path)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { return nil }
        let secret = Data(bytes)

        let fd = open(path.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return nil }
        secret.withUnsafeBytes { _ = write(fd, $0.baseAddress!, 32) }
        close(fd)

        return secret
    }

    private static func machineBinding() -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let range = output.range(of: #""IOPlatformUUID"\s*=\s*"([^"]+)""#, options: .regularExpression) {
                let match = output[range]
                if let uuidRange = match.range(of: #"[0-9A-F-]{36}"#, options: .regularExpression) {
                    return match[uuidRange].data(using: .utf8) ?? Data("local-machine".utf8)
                }
            }
        } catch {}

        return Data("local-machine".utf8)
    }

    private static func symmetricKey() -> SymmetricKey? {
        guard let master = loadOrCreateMasterSecret() else { return nil }
        let binding = machineBinding()
        var combined = master
        combined.append(0) // null separator
        combined.append(binding)
        let hash = SHA256.hash(data: combined)
        return SymmetricKey(data: hash)
    }

    private static func retrieveEncrypted(provider: String) -> String? {
        let path = encryptedPath(provider: provider)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let key = symmetricKey() else { return nil }

        do {
            let box = try ChaChaPoly.SealedBox(combined: data)
            let plaintext = try ChaChaPoly.open(box, using: key)
            let value = String(data: plaintext, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value : nil
        } catch {
            return nil
        }
    }

    private static func deleteEncrypted(provider: String) -> Bool {
        let path = encryptedPath(provider: provider)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        do {
            try FileManager.default.removeItem(at: path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Legacy Keychain

    private static let securityPath = "/usr/bin/security"

    private static var keychainServices: [String] {
        [AppIdentity.keychainService, AppIdentity.legacyKeychainService]
    }

    private static func retrieveLegacyKeychain(provider: String) -> String? {
        for service in keychainServices {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: securityPath)
            process.arguments = ["find-generic-password", "-s", service, "-a", provider, "-w"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { continue }
                let value = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = value, !value.isEmpty { return value }
            } catch {
                continue
            }
        }
        return nil
    }

    @discardableResult
    private static func deleteLegacyKeychain(provider: String) -> Bool {
        var deleted = false
        for service in keychainServices {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: securityPath)
            process.arguments = ["delete-generic-password", "-s", service, "-a", provider]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { deleted = true }
            } catch {
                continue
            }
        }
        return deleted
    }
}
