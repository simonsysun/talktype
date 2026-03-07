import Foundation

enum AppIdentity {
    static let appName = "TalkType"
    static let bundleID = "dev.talktype.local"

    static let legacyAppName = "Whisper"
    static let legacyStateDir = ".whisper"
    static let standardStateDir = ".talktype"

    static let keychainService = "com.talktype.api-keys"
    static let legacyKeychainService = "com.whisper.api-keys"

    static var stateDir: URL {
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
    }
}
