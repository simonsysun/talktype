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
        // Fullwidth Latin normalizes to ASCII under NFKC.
        XCTAssertEqual(PostProcessor.safeNormalize("\u{FF21}\u{FF22}"), "AB")
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
}
