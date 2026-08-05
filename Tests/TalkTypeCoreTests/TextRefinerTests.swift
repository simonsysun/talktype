import XCTest
@testable import TalkTypeCore

/// The polish safety net: isPlausibleRefinement decides whether the model's output is
/// usable or must fall back to the local tidy. These are the failure modes observed in
/// benchmarking — translation, truncation, and runaway growth.
final class TextRefinerTests: XCTestCase {

    func testRejectsTranslationFlip() {
        XCTAssertFalse(TextRefiner.isPlausibleRefinement(
            original: "今天天气不错。",
            refined: "The weather is nice today."))
    }

    func testRejectsTruncation() {
        let original = String(repeating: "今天天气不错，", count: 40)
        XCTAssertFalse(TextRefiner.isPlausibleRefinement(original: original, refined: "今天"))
    }

    func testAllowsLegitSelfCorrection() {
        XCTAssertTrue(TextRefiner.isPlausibleRefinement(
            original: "周二…不对，周三下午开会",
            refined: "周三下午开会"))
    }

    /// Dense CN/EN alternation gains spaces from the typography rule. The old 1.2x cap
    /// rejected it; the character-budget bound accepts it.
    func testAllowsDenseMixedLanguageSpacing() {
        XCTAssertTrue(TextRefiner.isPlausibleRefinement(
            original: "a中b中c中d中",
            refined: "a 中 b 中 c 中 d 中"))
    }

    func testRejectsRunawayGrowth() {
        XCTAssertFalse(TextRefiner.isPlausibleRefinement(
            original: "你好",
            refined: "你好，这是模型自己加的一整句内容，而且又加了一句更长的话。"))
    }
}
