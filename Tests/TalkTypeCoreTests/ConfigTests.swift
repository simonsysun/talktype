import XCTest
@testable import TalkTypeCore

final class ConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    /// Regression: synthesised decoding failed on any missing key, so shipping one new
    /// setting silently reset every setting the user had already chosen.
    func testConfigWrittenBeforeNewKeysExistedStillLoads() throws {
        let old = """
        {"launch_at_login": true, "silence_auto_stop_seconds": 42}
        """
        let config = try decode(old)
        XCTAssertTrue(config.launchAtLogin, "existing settings must survive")
        XCTAssertEqual(config.silenceAutoStopSeconds, 42)
        XCTAssertEqual(config.sttProvider, AppConfig().sttProvider, "new keys take defaults")
        XCTAssertEqual(config.grokLanguage, AppConfig().grokLanguage)
    }

    /// A config left behind by the version with a local engine and a polish pass carries
    /// keys that no longer exist. Unknown keys must be ignored, not throw.
    func testConfigFromThePipelineEraStillLoads() throws {
        let legacy = """
        {"asr_engine": "local", "asr_port": 9999, "refine_enabled": false,
         "refine_model": "qwen/qwen3.6-27b", "cloud_model_override": "x",
         "input_device_uid": "AppleHDA:1"}
        """
        let config = try decode(legacy)
        XCTAssertEqual(config.inputDeviceUID, "AppleHDA:1", "surviving settings are kept")
        XCTAssertEqual(config.sttProvider, AppConfig().sttProvider)
    }

    func testEmptyObjectYieldsDefaults() throws {
        XCTAssertEqual(try decode("{}").sttProvider, AppConfig().sttProvider)
        XCTAssertEqual(try decode("{}").sttTimeoutSeconds, AppConfig().sttTimeoutSeconds)
    }

    func testRoundTrip() throws {
        var config = AppConfig()
        config.sttProvider = .soniox
        config.sttTimeoutSeconds = 30
        config.grokLanguage = ""
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(back.sttProvider, .soniox)
        XCTAssertEqual(back.sttTimeoutSeconds, 30)
        XCTAssertEqual(back.grokLanguage, "")
    }

    func testEveryProviderRoundTripsThroughItsRawValue() {
        for provider in STTProvider.allCases {
            XCTAssertEqual(STTProvider(rawValue: provider.rawValue), provider)
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertTrue(provider.keychainService.hasPrefix("talktype-stt-"))
        }
    }
}
