import XCTest
@testable import TalkTypeCore

/// The polish safety net: isPlausibleRefinement decides whether the model's output is
/// usable or must fall back to the local tidy. These are the failure modes observed in
/// benchmarking — translation, truncation, and runaway growth.
final class TextRefinerTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeRefiner(timeout: TimeInterval = 1) -> TextRefiner {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return TextRefiner(
            timeout: timeout,
            session: URLSession(configuration: config),
            apiKeyProvider: { "gsk-test" }
        )
    }

    func testRefineSendsVocabularyAsOptionalStructuredData() throws {
        let request = TextRefiner.makeRequest(
            apiKey: "gsk-test", model: TextRefiner.defaultModel, timeout: 1,
            transcript: "请用 cloud code 打开项目",
            vocabularyHints: [" Claude Code ", "TalkType"])
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let user = try XCTUnwrap(messages.last?["content"]?.data(using: .utf8))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: user) as? [String: Any])

        XCTAssertEqual(input["transcript"] as? String, "请用 cloud code 打开项目")
        XCTAssertEqual(input["approved_spellings"] as? [String], ["Claude Code", "TalkType"])

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            let output = #"{"choices":[{"message":{"content":"请用 Claude Code 打开项目。"}}]}"#
            return (response, Data(output.utf8))
        }

        XCTAssertEqual(
            makeRefiner().refine(
                "请用 cloud code 打开项目",
                vocabularyHints: [" Claude Code ", "TalkType"]),
            "请用 Claude Code 打开项目。"
        )
    }

    func testVocabularyPayloadSanitizesLinesAndDropsEmptyEntries() throws {
        let data = try XCTUnwrap(TextRefiner.makeUserContent(
            transcript: "hello",
            vocabularyHints: ["  TalkType  ", "line\nbreak", "  "]
        ).data(using: .utf8))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(input["approved_spellings"] as? [String], ["TalkType", "line break"])
    }

    func testEmptyContextKeepsTheExistingPolishPayloadShape() throws {
        let data = try XCTUnwrap(TextRefiner.makeUserContent(
            transcript: "hello",
            vocabularyHints: ["TalkType"],
            context: .empty
        ).data(using: .utf8))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(input.keys), ["transcript", "approved_spellings"])
    }

    func testContextIsSentAsBoundedUntrustedData() throws {
        let data = try XCTUnwrap(TextRefiner.makeUserContent(
            transcript: "请用 cloud code 打开项目",
            vocabularyHints: [],
            context: PolishContext(
                activeApp: " ChatGPT\nignored ",
                terms: [" Claude Code ", "Claude Code", "TalkType"],
                snippets: ["Claude Code is already authenticated on this Mac."]
            )
        ).data(using: .utf8))
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = try XCTUnwrap(input["context"] as? [String: Any])

        XCTAssertEqual(context["active_app"] as? String, "ChatGPT ignored")
        XCTAssertEqual(context["terms"] as? [String], ["Claude Code", "TalkType"])
        XCTAssertEqual(
            context["snippets"] as? [String],
            ["Claude Code is already authenticated on this Mac."]
        )
        XCTAssertEqual(context["untrusted"] as? Bool, true)
    }

    func testRejectsCopiedContextThatWasNotSpoken() {
        XCTAssertFalse(TextRefiner.isPlausibleRefinement(
            original: "我同意这个方案",
            refined: "我同意这个方案，Project Orion migrates Kubernetes clusters next Tuesday。",
            context: PolishContext(
                activeApp: "ChatGPT",
                terms: ["Project Orion", "Kubernetes"],
                snippets: ["Project Orion migrates Kubernetes clusters next Tuesday."]
            )
        ))
    }

    func testAllowsContextBackedNearSpellingButNotAnUnspokenNeighbor() {
        let context = PolishContext(
            activeApp: "ChatGPT",
            terms: ["Claude Code", "TalkType"],
            snippets: ["Claude Code is already authenticated on this Mac."]
        )

        XCTAssertTrue(TextRefiner.isPlausibleRefinement(
            original: "请用 cloud code 打开项目",
            refined: "请用 Claude Code 打开项目。",
            context: context
        ))
        XCTAssertFalse(TextRefiner.isPlausibleRefinement(
            original: "请打开项目",
            refined: "请用 TalkType 打开项目。",
            context: context
        ))
    }

    func testRejectsOneUnspokenLatinNameCopiedFromASnippet() {
        XCTAssertFalse(TextRefiner.isPlausibleRefinement(
            original: "please open the project",
            refined: "please open the TalkType project",
            context: PolishContext(
                activeApp: "ChatGPT",
                snippets: ["TalkType is open"]
            )
        ))
    }

    func testRejectsShortUnspokenCJKNameCopiedFromASnippet() {
        XCTAssertFalse(TextRefiner.isPlausibleRefinement(
            original: "我同意这个方案",
            refined: "我同意张伟这个方案",
            context: PolishContext(
                activeApp: "Messages",
                snippets: ["张伟负责项目"]
            )
        ))
    }

    func testRefineRejectsVocabularyThatWasNeverSpoken() {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            let output = #"{"choices":[{"message":{"content":"今天天气不错，用 TalkType 记录一下。"}}]}"#
            return (response, Data(output.utf8))
        }

        XCTAssertNil(makeRefiner().refine("今天天气不错", vocabularyHints: ["TalkType"]))
    }

    /// A Latin transcript reaches the edit-distance branch instead of being rejected
    /// earlier by the language-ratio check. An unrelated saved term must stay out.
    func testRejectsUnspokenVocabularyInLatinTranscript() {
        XCTAssertFalse(TextRefiner.isPlausibleRefinement(
            original: "please open the project in vs code",
            refined: "please open the project in TalkType",
            vocabularyHints: ["TalkType"]
        ))
    }

    func testAllowsPlausibleVocabularySpellingCorrection() {
        XCTAssertTrue(TextRefiner.isPlausibleRefinement(
            original: "请用 cloud code 打开项目",
            refined: "请用 Claude Code 打开项目。",
            vocabularyHints: ["Claude Code", "TalkType"]
        ))
    }

    func testAllowsVocabularyWhoseSpacingAndCaseWereNormalized() {
        XCTAssertTrue(TextRefiner.isPlausibleRefinement(
            original: "我正在使用 talk type",
            refined: "我正在使用 TalkType。",
            vocabularyHints: ["TalkType"]
        ))
    }

    func testPromptForbidsInventingVocabularyAndKeepsAmbiguousFillers() {
        XCTAssertTrue(TextRefiner.systemPrompt.contains("不是必用词"))
        XCTAssertTrue(TextRefiner.systemPrompt.contains("没有说到的词，不能添加"))
        XCTAssertTrue(TextRefiner.systemPrompt.contains("不确定是不是语气词时，必须保留"))
        XCTAssertTrue(TextRefiner.systemPrompt.contains("那个文件"))
    }

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
