import Foundation

enum AppIdentity {
    static let appName = "TalkType"

    #if os(iOS)
    static let bundleID = "dev.talktype.ios"
    static let appGroupID = "group.dev.talktype"

    static let stateDir: URL = {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let dir = container.appendingPathComponent("talktype")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        // Fallback to documents (won't be shared with extension)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("talktype")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    #else
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
    #endif
}
