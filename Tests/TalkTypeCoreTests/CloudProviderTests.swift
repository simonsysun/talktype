import XCTest
@testable import TalkTypeCore

final class CloudProviderTests: XCTestCase {

    func testDetectFromBaseURL() {
        XCTAssertEqual(CloudProvider.detect(baseURL: "https://openrouter.ai/api/v1"), .openRouter)
        XCTAssertEqual(CloudProvider.detect(baseURL: "https://api.openai.com/v1"), .openAI)
        XCTAssertEqual(CloudProvider.detect(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"), .dashScope)
        XCTAssertEqual(CloudProvider.detect(baseURL: "https://api.groq.com/openai/v1"), .groq)
        XCTAssertEqual(CloudProvider.detect(baseURL: "https://api.moonshot.ai/v1"), .custom)
    }

    func testDetectIgnoresCaseAndTrailingSlash() {
        XCTAssertEqual(CloudProvider.detect(baseURL: "OpenRouter.AI/API/V1/"), .openRouter)
        XCTAssertEqual(CloudProvider.detect(baseURL: " https://api.openai.com/v1/ "), .openAI)
    }

    func testDetectFromKeyShape() {
        XCTAssertEqual(CloudProvider.detect(key: "sk-or-v1-abcdef"), .openRouter)
        XCTAssertNil(CloudProvider.detect(key: "sk-abcdef"))
        XCTAssertNil(CloudProvider.detect(key: "gsk_abcdef"))
    }

    func testProfilesHaveSensibleDefaults() {
        XCTAssertEqual(CloudProvider.openRouter.profile.defaultModel, "qwen/qwen3-asr-flash-2026-02-10")
        XCTAssertEqual(CloudProvider.openRouter.profile.requestShape, .openRouterJSON)
        XCTAssertEqual(CloudProvider.openAI.profile.requestShape, .openAIMultipart)
        XCTAssertEqual(CloudProvider.dashScope.profile.requestShape, .dashScopeChat)
        XCTAssertEqual(CloudProvider.dashScope.profile.defaultModel, "qwen3-asr-flash")
        XCTAssertFalse(CloudProvider.custom.profile.isKnown)
    }

    func testKeychainServiceIsUniquePerProvider() {
        let services = CloudProvider.allCases.map { $0.profile.keychainService }
        XCTAssertEqual(Set(services).count, services.count, "each provider needs its own keychain slot")
    }
}
