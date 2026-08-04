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
        {"asr_port": 9999, "launch_at_login": true, "silence_auto_stop_seconds": 42}
        """
        let config = try decode(old)
        XCTAssertEqual(config.asrPort, 9999, "existing settings must survive")
        XCTAssertTrue(config.launchAtLogin)
        XCTAssertEqual(config.silenceAutoStopSeconds, 42)
        XCTAssertEqual(config.refineEnabled, AppConfig().refineEnabled, "new keys take defaults")
        XCTAssertEqual(config.refineModel, AppConfig().refineModel)
        XCTAssertEqual(config.asrEngine, AppConfig().asrEngine)
        XCTAssertEqual(config.cloudProvider, AppConfig().cloudProvider)
        XCTAssertEqual(config.cloudModel, AppConfig().cloudModel)
        XCTAssertEqual(config.cloudBaseURL, AppConfig().cloudBaseURL)
    }

    func testEmptyObjectYieldsDefaults() throws {
        XCTAssertEqual(try decode("{}").asrPort, AppConfig().asrPort)
    }

    func testRoundTrip() throws {
        var config = AppConfig()
        config.refineEnabled = false
        config.asrPort = 1234
        config.asrEngine = .cloud
        config.cloudProvider = .dashScope
        config.cloudModel = "qwen3-asr-flash"
        config.cloudBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(back.refineEnabled, false)
        XCTAssertEqual(back.asrPort, 1234)
        XCTAssertEqual(back.asrEngine, .cloud)
        XCTAssertEqual(back.cloudProvider, .dashScope)
        XCTAssertEqual(back.cloudModel, "qwen3-asr-flash")
        XCTAssertEqual(back.cloudBaseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
    }
}
