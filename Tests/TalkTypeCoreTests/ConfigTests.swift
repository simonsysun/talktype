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
        XCTAssertEqual(config.sttTimeoutSeconds, AppConfig().sttTimeoutSeconds, "new keys take defaults")
    }

    /// 上一代（本地引擎 + 润色层，以及后来的四选一 provider）留下的 config 里带着已经不存在
    /// 的键。未知键必须被忽略，而不是让整个配置解析失败。
    func testConfigFromThePipelineEraStillLoads() throws {
        let legacy = """
        {"asr_engine": "local", "asr_port": 9999, "refine_enabled": false,
         "stt_provider": "elevenlabs", "grok_language": "zh",
         "input_device_uid": "AppleHDA:1"}
        """
        let config = try decode(legacy)
        XCTAssertEqual(config.inputDeviceUID, "AppleHDA:1", "surviving settings are kept")
    }

    func testEmptyObjectYieldsDefaults() throws {
        XCTAssertEqual(try decode("{}").sttTimeoutSeconds, AppConfig().sttTimeoutSeconds)
        XCTAssertEqual(try decode("{}").silenceAutoStopSeconds, AppConfig().silenceAutoStopSeconds)
    }

    func testRetiredLoudnessGateIsIgnoredInExistingConfig() throws {
        let config = try decode("{\"min_transcribe_rms\": 0.012, \"launch_at_login\": true}")
        XCTAssertTrue(config.launchAtLogin)
    }

    func testRoundTrip() throws {
        var config = AppConfig()
        config.sttTimeoutSeconds = 30
        config.inputDeviceUID = "AppleHDA:1"
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(back.sttTimeoutSeconds, 30)
        XCTAssertEqual(back.inputDeviceUID, "AppleHDA:1")
    }
}
