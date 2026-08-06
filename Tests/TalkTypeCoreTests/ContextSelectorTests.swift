import XCTest
@testable import TalkTypeCore

final class ContextSelectorTests: XCTestCase {
    func testSelectsTheNearestVisibleReplyAndItsMatchingProperNoun() {
        let snapshot = WindowContextSnapshot(
            activeApp: "ChatGPT",
            blocks: [
                WindowTextBlock(text: "New chat Settings Upgrade", proximity: 800, visualOrder: 1),
                WindowTextBlock(
                    text: "Claude Code is already authenticated on this Mac.",
                    proximity: 18,
                    visualOrder: 20
                ),
                WindowTextBlock(text: "Reply to ChatGPT", proximity: 2, visualOrder: 21),
            ]
        )

        let context = ContextSelector.resolve(
            snapshot: snapshot,
            rawTranscript: "请用 cloud code 打开项目"
        )

        XCTAssertEqual(context.activeApp, "ChatGPT")
        XCTAssertEqual(context.terms.first, "Claude Code")
        XCTAssertEqual(context.snippets, ["Claude Code is already authenticated on this Mac."])
        XCTAssertFalse(context.snippets.joined().contains("Settings"))
        XCTAssertFalse(context.snippets.joined().contains("Reply to ChatGPT"))
    }

    func testDoesNotPromoteAnUnrelatedVisibleProductName() {
        let snapshot = WindowContextSnapshot(
            activeApp: "ChatGPT",
            blocks: [
                WindowTextBlock(
                    text: "Claude Code is already authenticated on this Mac.",
                    proximity: 10,
                    visualOrder: 5
                ),
            ]
        )

        let context = ContextSelector.resolve(
            snapshot: snapshot,
            rawTranscript: "今天天气不错"
        )

        XCTAssertTrue(context.terms.isEmpty)
        // The nearest short excerpt is still useful for topic experiments, but the
        // deterministic guard must prevent it from adding an unspoken product name.
        XCTAssertEqual(context.snippets.count, 1)
    }

    func testDeduplicatesRepeatedAccessibilityTextAndHonorsBudgets() {
        let repeated = String(repeating: "A", count: 900)
        let snapshot = WindowContextSnapshot(
            activeApp: "Safari",
            blocks: (0..<80).map { index in
                WindowTextBlock(text: repeated, proximity: Double(index), visualOrder: index)
            }
        )

        let context = ContextSelector.resolve(snapshot: snapshot, rawTranscript: "hello")

        XCTAssertLessThanOrEqual(context.terms.joined().count, 400)
        XCTAssertLessThanOrEqual(context.snippets.joined().count, 400)
        XCTAssertEqual(context.snippets.count, 1)
    }

    func testEmptyCapturePreservesTheCurrentNoContextPath() {
        XCTAssertEqual(
            ContextSelector.resolve(
                snapshot: WindowContextSnapshot(activeApp: "Notes", blocks: []),
                rawTranscript: "我们明天继续 review"
            ),
            .empty
        )
    }

    func testMatchesSpokenDigitWordToAProductIdentifier() {
        let snapshot = WindowContextSnapshot(
            activeApp: "Terminal",
            blocks: [
                WindowTextBlock(
                    text: "Qwen3-ASR is serving on localhost.",
                    proximity: 5,
                    visualOrder: 1
                ),
            ]
        )

        let context = ContextSelector.resolve(
            snapshot: snapshot,
            rawTranscript: "qwen three asr 的延迟是多少"
        )

        XCTAssertEqual(context.terms.first, "Qwen3-ASR")
    }

    func testCanUseALowercaseTopicTermWhenTheRawWordIsClose() {
        let snapshot = WindowContextSnapshot(
            activeApp: "Xcode",
            blocks: [
                WindowTextBlock(
                    text: "The build cache occupies 8 GB.",
                    proximity: 4,
                    visualOrder: 1
                ),
            ]
        )

        let context = ContextSelector.resolve(
            snapshot: snapshot,
            rawTranscript: "这个 cash 需要清掉"
        )

        XCTAssertTrue(context.terms.contains("cache"))
    }

    func testRedactsLinksEmailAddressesAndSecretsBeforeSelection() {
        let snapshot = WindowContextSnapshot(
            activeApp: "Mail",
            blocks: [
                WindowTextBlock(
                    text: "Open https://internal.example/path for simon@example.com api_key=sk-secret-123456",
                    proximity: 4,
                    visualOrder: 1
                ),
            ]
        )

        let context = ContextSelector.resolve(snapshot: snapshot, rawTranscript: "open the link")
        let selected = context.snippets.joined(separator: " ")

        XCTAssertTrue(selected.contains("[link]"))
        XCTAssertTrue(selected.contains("[email]"))
        XCTAssertTrue(selected.contains("[redacted]"))
        XCTAssertFalse(selected.contains("internal.example"))
        XCTAssertFalse(selected.contains("simon@example.com"))
        XCTAssertFalse(selected.contains("sk-secret"))
    }
}
