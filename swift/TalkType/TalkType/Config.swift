import Foundation

struct AppConfig: Codable {
    var dictationHotkey: String = "option+space"
    var sampleRate: Int = 16000
    var overlayPosition: String = "center-bottom"
    var overlayTheme: String = "auto"
    var launchAtLogin: Bool = false
    var asrModel: String = "gpt-4o-mini-transcribe"
    var asrTimeoutSeconds: Double = 30.0
    var silenceAutoStopEnabled: Bool = true
    var silenceAutoStopSeconds: Double = 20
    var silenceRmsThreshold: Double = 0.008
    var minTranscribeRms: Double = 0.003

    enum CodingKeys: String, CodingKey {
        case dictationHotkey = "dictation_hotkey"
        case sampleRate = "sample_rate"
        case overlayPosition = "overlay_position"
        case overlayTheme = "overlay_theme"
        case launchAtLogin = "launch_at_login"
        case asrModel = "asr_model"
        case asrTimeoutSeconds = "asr_timeout_seconds"
        case silenceAutoStopEnabled = "silence_auto_stop_enabled"
        case silenceAutoStopSeconds = "silence_auto_stop_seconds"
        case silenceRmsThreshold = "silence_rms_threshold"
        case minTranscribeRms = "min_transcribe_rms"
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
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
            case "asr_model":
                let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if cleaned == "gpt-4o-transcribe" || cleaned == "gpt-4o-mini-transcribe" {
                    config.asrModel = cleaned
                }
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
