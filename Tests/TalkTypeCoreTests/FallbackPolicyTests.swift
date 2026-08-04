import XCTest
@testable import TalkTypeCore

final class FallbackPolicyTests: XCTestCase {

    // MARK: - plan(offline:)

    func testOnlineWithLocalUsesShortCloudTimeout() {
        let policy = FallbackPolicy(localInstalled: true)
        XCTAssertEqual(policy.plan(offline: false), .cloud(timeout: 10))
    }

    func testOnlineWithoutLocalUsesGenerousCloudTimeout() {
        let policy = FallbackPolicy(localInstalled: false)
        XCTAssertEqual(policy.plan(offline: false), .cloud(timeout: 60))
    }

    func testOfflineWithLocalGoesLocalAndExplains() {
        let policy = FallbackPolicy(localInstalled: true)
        guard case .local(let reason) = policy.plan(offline: true) else {
            return XCTFail("expected local fallback")
        }
        XCTAssertTrue(reason.contains("本地"))
    }

    func testOfflineWithoutLocalBlocksWithActionableMessage() {
        let policy = FallbackPolicy(localInstalled: false)
        guard case .blocked(let message) = policy.plan(offline: true) else {
            return XCTFail("expected blocked")
        }
        XCTAssertTrue(message.contains("联网") && message.contains("安装本地引擎"))
    }

    // MARK: - fallbackPlan(failure:) with local installed

    func testInvalidKeyFallsBackToLocalWithFixHint() {
        let policy = FallbackPolicy(localInstalled: true)
        guard case .local(let reason) = policy.fallbackPlan(failure: .invalidKey) else {
            return XCTFail("expected local fallback")
        }
        XCTAssertTrue(reason.contains("换 key"))
    }

    func testQuotaFallsBackToLocal() {
        let policy = FallbackPolicy(localInstalled: true)
        XCTAssertEqual(policy.fallbackPlan(failure: .limitOrRate), .local(reason: "云端额度用完或请求太频繁，已用本地。"))
    }

    func testServiceErrorFallsBackToLocal() {
        let policy = FallbackPolicy(localInstalled: true)
        for failure in [CloudFailure.timeout, .offline, .serviceError, .unknown] {
            guard case .local = policy.fallbackPlan(failure: failure) else {
                return XCTFail("expected local fallback for \(failure)")
            }
        }
    }

    // MARK: - fallbackPlan(failure:) without local

    func testInvalidKeyWithoutLocalBlocksWithFixHint() {
        let policy = FallbackPolicy(localInstalled: false)
        guard case .blocked(let message) = policy.fallbackPlan(failure: .invalidKey) else {
            return XCTFail("expected blocked")
        }
        XCTAssertTrue(message.contains("OpenRouter key"))
    }

    func testQuotaWithoutLocalBlocks() {
        let policy = FallbackPolicy(localInstalled: false)
        guard case .blocked(let message) = policy.fallbackPlan(failure: .limitOrRate) else {
            return XCTFail("expected blocked")
        }
        XCTAssertTrue(message.contains("额度"))
    }

    func testServiceErrorWithoutLocalBlocks() {
        let policy = FallbackPolicy(localInstalled: false)
        for failure in [CloudFailure.timeout, .offline, .serviceError, .unknown] {
            guard case .blocked = policy.fallbackPlan(failure: failure) else {
                return XCTFail("expected blocked for \(failure)")
            }
        }
    }

    // MARK: - UserFacingError

    func testUserFacingErrorSurfacesMessageVerbatim() {
        let error = UserFacingError(message: "云端暂时不可用。")
        XCTAssertEqual(error.errorDescription, "云端暂时不可用。")
    }
}
