import XCTest
@testable import TalkTypeCore

final class PostProcessorTests: XCTestCase {

    private func vocab(_ words: String...) -> [VocabEntry] {
        words.enumerated().map { index, word in
            VocabEntry(id: "id\(index)", canonical: word, addedAt: "2026-01-0\(index + 1)", pinned: false, lastUsedAt: nil)
        }
    }

    // MARK: - safeNormalize

    func testNormalizeStripsZeroWidthCharacters() {
        XCTAssertEqual(PostProcessor.safeNormalize("he\u{200B}llo\u{FEFF}"), "hello")
    }

    func testNormalizeCollapsesRunsOfSpaces() {
        XCTAssertEqual(PostProcessor.safeNormalize("a    b  c"), "a b c")
    }

    func testNormalizeTrimsEdges() {
        XCTAssertEqual(PostProcessor.safeNormalize("  hello  "), "hello")
    }

    func testNormalizeAppliesCompatibilityMapping() {
        // Fullwidth Latin normalizes to ASCII (the useful part of NFKC, kept).
        XCTAssertEqual(PostProcessor.safeNormalize("\u{FF21}\u{FF22}"), "AB")
    }

    /// Regression: NFKC used to flatten full-width punctuation back to half-width,
    /// undoing the typography pass — every Chinese sentence lost its ，？！.
    func testNormalizeKeepsFullWidthPunctuation() {
        XCTAssertEqual(PostProcessor.safeNormalize("这样好吗？"), "这样好吗？")
        XCTAssertEqual(PostProcessor.safeNormalize("你好，世界！"), "你好，世界！")
    }

    func testPostProcessPipelineKeepsFullWidthPunctuation() {
        let tidied = PostProcessor.tidySpeech("这样好吗?")
        let processed = PostProcessor.postProcess(text: tidied, vocabEntries: [])
        XCTAssertEqual(processed, "这样好吗？")
    }

    // MARK: - isSafeForAutoReplace

    func testDistinctiveTermsAreAutoReplaceable() {
        XCTAssertTrue(PostProcessor.isSafeForAutoReplace("API"))          // all caps
        XCTAssertTrue(PostProcessor.isSafeForAutoReplace("GPT-4o"))       // digits
        XCTAssertTrue(PostProcessor.isSafeForAutoReplace("TalkType"))     // internal caps
        XCTAssertTrue(PostProcessor.isSafeForAutoReplace("Claude Code"))  // contains a space
        XCTAssertTrue(PostProcessor.isSafeForAutoReplace("语音"))          // non-ASCII
    }

    func testOrdinaryWordsAreNotAutoReplaceable() {
        XCTAssertFalse(PostProcessor.isSafeForAutoReplace("hello"))
        XCTAssertFalse(PostProcessor.isSafeForAutoReplace("Simon"))       // leading cap only
        XCTAssertFalse(PostProcessor.isSafeForAutoReplace(""))
        XCTAssertFalse(PostProcessor.isSafeForAutoReplace("   "))
        XCTAssertFalse(PostProcessor.isSafeForAutoReplace("A"))           // single letter
    }

    // MARK: - postProcess

    func testPostProcessCanonicalizesDistinctiveTerms() {
        let result = PostProcessor.postProcess(text: "we use talktype daily", vocabEntries: vocab("TalkType"))
        XCTAssertEqual(result, "we use TalkType daily")
    }

    func testPostProcessLeavesOrdinaryWordsAlone() {
        let result = PostProcessor.postProcess(text: "say hello to simon", vocabEntries: vocab("Simon"))
        XCTAssertEqual(result, "say hello to simon")
    }

    func testPostProcessRespectsWordBoundariesForASCII() {
        let result = PostProcessor.postProcess(text: "the rapid apidog", vocabEntries: vocab("API"))
        XCTAssertEqual(result, "the rapid apidog", "substring matches must not be rewritten")
    }

    // MARK: - isLikelyHallucination

    func testNormalVolumeSpeechIsNeverFlagged() {
        XCTAssertFalse(PostProcessor.isLikelyHallucination(
            "TalkType", audioRMS: 0.2, vocabEntries: vocab("TalkType")
        ))
    }

    func testQuietAudioReturningOnlyVocabIsFlagged() {
        XCTAssertTrue(PostProcessor.isLikelyHallucination(
            "TalkType", audioRMS: 0.001, vocabEntries: vocab("TalkType")
        ))
        XCTAssertTrue(PostProcessor.isLikelyHallucination(
            "Claude TalkType", audioRMS: 0.001, vocabEntries: vocab("TalkType", "Claude")
        ))
    }

    func testQuietAudioWithRealSentenceIsNotFlagged() {
        XCTAssertFalse(PostProcessor.isLikelyHallucination(
            "please open TalkType now", audioRMS: 0.001, vocabEntries: vocab("TalkType")
        ))
    }

    func testEmptyVocabularyNeverFlags() {
        XCTAssertFalse(PostProcessor.isLikelyHallucination("anything", audioRMS: 0.0, vocabEntries: []))
    }

    func testEmptyTranscriptIsNotFlagged() {
        XCTAssertFalse(PostProcessor.isLikelyHallucination("  ", audioRMS: 0.0, vocabEntries: vocab("TalkType")))
    }

    func testRepeatedCJKVocabIsFlagged() {
        XCTAssertTrue(PostProcessor.isLikelyHallucination(
            "语音语音语音", audioRMS: 0.001, vocabEntries: vocab("语音")
        ))
        XCTAssertTrue(PostProcessor.isLikelyHallucination(
            "语音。语音！", audioRMS: 0.001, vocabEntries: vocab("语音")
        ))
    }

    func testCJKSentenceWithRealContentIsNotFlagged() {
        XCTAssertFalse(PostProcessor.isLikelyHallucination(
            "语音输入很好用", audioRMS: 0.001, vocabEntries: vocab("语音")
        ))
    }

    /// The threshold gap matters: below minTranscribeRms the audio is dropped before
    /// transcription, so hallucination detection only earns its keep in the band
    /// between minTranscribeRms and hallucinationRmsThreshold.
    func testHallucinationThresholdCoversTheTranscribeThreshold() {
        XCTAssertGreaterThan(
            PostProcessor.hallucinationRmsThreshold,
            Float(AppConfig().minTranscribeRms),
            "hallucination detection must stay active above the transcribe cutoff"
        )
    }

    // MARK: - tidySpeech

    func testTidyRemovesHesitationParticles() {
        XCTAssertEqual(PostProcessor.tidySpeech("我今天呃想去公园"), "我今天想去公园")
        XCTAssertEqual(PostProcessor.tidySpeech("然后就是嗯我要用"), "然后就是我要用")
    }

    func testTidyCollapsesImmediateRepetition() {
        XCTAssertEqual(
            PostProcessor.tidySpeech("我们现在有用,我们现在有用这个"),
            "我们现在有用这个")
    }

    func testTidyFixesStutteredPronouns() {
        XCTAssertEqual(PostProcessor.tidySpeech("我我们现在开始"), "我们现在开始")
    }

    /// Mandarin reduplicates verbs meaningfully. An earlier general "AA -> A" rule
    /// turned 先看看 into 先看, which changes what the speaker said.
    func testTidyKeepsMeaningfulReduplication() {
        XCTAssertEqual(PostProcessor.tidySpeech("我们先看看财报"), "我们先看看财报")
        XCTAssertEqual(PostProcessor.tidySpeech("你想想这个问题"), "你想想这个问题")
        XCTAssertEqual(PostProcessor.tidySpeech("出去走走吧"), "出去走走吧")
    }

    func testTidyConvertsPunctuationWidthAfterChinese() {
        XCTAssertEqual(PostProcessor.tidySpeech("这样好吗?是的,没错!"), "这样好吗？是的，没错！")
    }

    func testTidyLeavesEnglishPunctuationAlone() {
        let english = "Can you check whether the deployment finished?"
        XCTAssertEqual(PostProcessor.tidySpeech(english), english)
    }

    func testTidySpacesBetweenScripts() {
        XCTAssertEqual(PostProcessor.tidySpeech("把这个bug修一下"), "把这个 bug 修一下")
        XCTAssertEqual(PostProcessor.tidySpeech("用Groq的模型"), "用 Groq 的模型")
    }

    func testTidyDoesNotSpaceBeforeChinesePunctuation() {
        XCTAssertEqual(PostProcessor.tidySpeech("我用 browser ，然后"), "我用 browser，然后")
    }

    func testTidyIsIdempotent() {
        let once = PostProcessor.tidySpeech("我们现在有用,我们现在有用这个呃是什么?")
        XCTAssertEqual(PostProcessor.tidySpeech(once), once)
    }

    func testTidyHandlesEmptyAndBlank() {
        XCTAssertEqual(PostProcessor.tidySpeech(""), "")
        XCTAssertEqual(PostProcessor.tidySpeech("   "), "")
    }

    /// Deleting a particle used to leave the punctuation around it doubled:
    /// "在于,嗯,就是说" became "在于,,就是说".
    func testTidyCollapsesPunctuationLeftByRemovedFiller() {
        XCTAssertEqual(
            PostProcessor.tidySpeech("它的问题在于,嗯,就是说它太慢了"),
            "它的问题在于，就是说它太慢了")
    }

    /// Regression: the engine sometimes emits a leading comma (seen in bakeoff); a
    /// sentence never starts with punctuation or ends with a comma/顿号.
    func testTidyStripsLeadingPunctuation() {
        XCTAssertEqual(PostProcessor.tidySpeech("，明天下午三点。"), "明天下午三点。")
        XCTAssertEqual(PostProcessor.tidySpeech("、hello"), "hello")
        XCTAssertEqual(PostProcessor.tidySpeech(".hello"), "hello")
    }

    func testTidyStripsTrailingCommaButKeepsSentenceEnd() {
        XCTAssertEqual(PostProcessor.tidySpeech("好的，"), "好的")
        XCTAssertEqual(PostProcessor.tidySpeech("好的， "), "好的", "comma followed by whitespace must still go")
        XCTAssertEqual(PostProcessor.tidySpeech("好的。"), "好的。")
        XCTAssertEqual(PostProcessor.tidySpeech("是吗？"), "是吗？")
    }
}
