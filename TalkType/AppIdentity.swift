import Foundation

enum AppIdentity {
    static let appName = "TalkType"
    static let bundleID = "dev.talktype.local"
    static let legacyAppName = "Whisper"
    static let legacyStateDir = ".whisper"
    static let standardStateDir = ".talktype"
    static let legacyKeychainService = "com.whisper.api-keys"

    static let stateDir: URL = {
        // An explicit override keeps a test or candidate build out of the real ~/.talktype.
        // `homeDirectoryForCurrentUser` reads
        // the password database, so overriding HOME does not achieve this.
        if let override = ProcessInfo.processInfo.environment["TALKTYPE_STATE_DIR"],
           !override.isEmpty {
            let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let target = home.appendingPathComponent(standardStateDir)
        let legacy = home.appendingPathComponent(legacyStateDir)

        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }
        if FileManager.default.fileExists(atPath: legacy.path) {
            do {
                try FileManager.default.moveItem(at: legacy, to: target)
                return target
            } catch {
                return legacy
            }
        }
        return target
    }()
}
