import Foundation

struct AppConfig: Codable {
    // The hotkey itself is owned by the KeyboardShortcuts library (UserDefaults), not this file.
    var sampleRate: Int = 16000
    var launchAtLogin: Bool = false
    /// Generous on purpose: a long recording is a big upload, and a dictation that fails
    /// early is worse than one that waits.
    var sttTimeoutSeconds: Double = 60.0
    var silenceAutoStopEnabled: Bool = true
    var silenceAutoStopSeconds: Double = 20
    var silenceRmsThreshold: Double = 0.008
    /// UID of the microphone to record from. Empty means follow the system default.
    var inputDeviceUID: String = ""

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case launchAtLogin = "launch_at_login"
        case sttTimeoutSeconds = "stt_timeout_seconds"
        case silenceAutoStopEnabled = "silence_auto_stop_enabled"
        case silenceAutoStopSeconds = "silence_auto_stop_seconds"
        case silenceRmsThreshold = "silence_rms_threshold"
        case inputDeviceUID = "input_device_uid"
    }

    init() {}

    /// Every field is optional on the way in. Synthesised decoding treats a missing key
    /// as a hard error, so adding one setting silently reset every other setting the
    /// user had chosen — and a config written by an older version is missing several.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? d.sampleRate
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        sttTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .sttTimeoutSeconds) ?? d.sttTimeoutSeconds
        silenceAutoStopEnabled = try c.decodeIfPresent(Bool.self, forKey: .silenceAutoStopEnabled) ?? d.silenceAutoStopEnabled
        silenceAutoStopSeconds = try c.decodeIfPresent(Double.self, forKey: .silenceAutoStopSeconds) ?? d.silenceAutoStopSeconds
        silenceRmsThreshold = try c.decodeIfPresent(Double.self, forKey: .silenceRmsThreshold) ?? d.silenceRmsThreshold
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? d.inputDeviceUID
    }
}

enum ConfigManager {
    private static var configURL: URL {
        AppIdentity.stateDir.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        var config = AppConfig()
        let url = configURL

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                config = try JSONDecoder().decode(AppConfig.self, from: data)
            } catch {
                print("[config] failed to load config.json: \(error), using defaults")
            }
        }

        // Force sample rate
        config.sampleRate = 16000
        return config
    }

    static func save(_ config: AppConfig) {
        let url = configURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            if FileManager.default.fileExists(atPath: url.path) {
                let tmp = url.appendingPathExtension("tmp")
                try data.write(to: tmp, options: .atomic)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            print("[config] failed to save: \(error)")
        }
    }
}
