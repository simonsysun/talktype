import Foundation

struct AppConfig: Codable {
    // The hotkey itself is owned by the KeyboardShortcuts library (UserDefaults), not this file.
    var sampleRate: Int = 16000
    var launchAtLogin: Bool = false
    /// Loopback port of the local ASR sidecar.
    var asrPort: Int = SidecarDefaults.port
    /// Generous by design: inference is local, so a slow response means a long recording,
    /// not a flaky network.
    var asrTimeoutSeconds: Double = 60.0
    var silenceAutoStopEnabled: Bool = true
    var silenceAutoStopSeconds: Double = 20
    var silenceRmsThreshold: Double = 0.008
    var minTranscribeRms: Double = 0.012
    /// Cloud refinement of the transcript. The only step that leaves the machine, so it
    /// is opt-in-shaped: off means dictation still works, just less polished.
    var refineEnabled: Bool = true
    var refineModel: String = "qwen/qwen3.6-27b"
    var refineTimeoutSeconds: Double = 2.5

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case launchAtLogin = "launch_at_login"
        case asrPort = "asr_port"
        case asrTimeoutSeconds = "asr_timeout_seconds"
        case silenceAutoStopEnabled = "silence_auto_stop_enabled"
        case silenceAutoStopSeconds = "silence_auto_stop_seconds"
        case silenceRmsThreshold = "silence_rms_threshold"
        case minTranscribeRms = "min_transcribe_rms"
        case refineEnabled = "refine_enabled"
        case refineModel = "refine_model"
        case refineTimeoutSeconds = "refine_timeout_seconds"
    }

    init() {}

    /// Every field is optional on the way in. Synthesised decoding treats a missing key
    /// as a hard error, so adding one setting silently reset every other setting the
    /// user had chosen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? d.sampleRate
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        asrPort = try c.decodeIfPresent(Int.self, forKey: .asrPort) ?? d.asrPort
        asrTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .asrTimeoutSeconds) ?? d.asrTimeoutSeconds
        silenceAutoStopEnabled = try c.decodeIfPresent(Bool.self, forKey: .silenceAutoStopEnabled) ?? d.silenceAutoStopEnabled
        silenceAutoStopSeconds = try c.decodeIfPresent(Double.self, forKey: .silenceAutoStopSeconds) ?? d.silenceAutoStopSeconds
        silenceRmsThreshold = try c.decodeIfPresent(Double.self, forKey: .silenceRmsThreshold) ?? d.silenceRmsThreshold
        minTranscribeRms = try c.decodeIfPresent(Double.self, forKey: .minTranscribeRms) ?? d.minTranscribeRms
        refineEnabled = try c.decodeIfPresent(Bool.self, forKey: .refineEnabled) ?? d.refineEnabled
        refineModel = try c.decodeIfPresent(String.self, forKey: .refineModel) ?? d.refineModel
        refineTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .refineTimeoutSeconds) ?? d.refineTimeoutSeconds
    }
}

enum ConfigManager {
    private static var configURL: URL {
        AppIdentity.stateDir.appendingPathComponent("config.json")
    }

    /// Legacy YAML config path
    private static var legacyConfigURL: URL {
        AppIdentity.stateDir.appendingPathComponent("config.yaml")
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
        } else {
            // Try migrating a few values from legacy YAML
            migrateLegacyYAML(into: &config)
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

    /// Simple line-based parsing of a few YAML values — no YAML library needed.
    private static func migrateLegacyYAML(into config: inout AppConfig) {
        let url = legacyConfigURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "silence_auto_stop_seconds":
                if let val = Double(value) { config.silenceAutoStopSeconds = val }
            case "launch_at_login":
                config.launchAtLogin = (value.lowercased() == "true")
            default:
                break
            }
        }

        print("[config] migrated values from legacy config.yaml")
    }
}
