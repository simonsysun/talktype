import XCTest
@testable import TalkTypeCore

final class VocabularyStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("talktype-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> VocabularyStore {
        VocabularyStore(path: tempDir.appendingPathComponent("vocabulary.json"))
    }

    func testAddAndList() throws {
        let store = makeStore()
        try store.add("TalkType")
        try store.add("Groq")
        XCTAssertEqual(Set(store.listEntries().map(\.canonical)), ["TalkType", "Groq"])
    }

    func testAddIsCaseInsensitivelyIdempotent() throws {
        let store = makeStore()
        let first = try store.add("TalkType")
        let second = try store.add("talktype")
        XCTAssertEqual(store.listEntries().count, 1)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.listEntries().first?.canonical, "TalkType", "first spelling wins")
    }

    func testAddCollapsesInternalWhitespace() throws {
        let store = makeStore()
        let entry = try store.add("  Claude    Code  ")
        XCTAssertEqual(entry.canonical, "Claude Code")
    }

    func testAddRejectsBlankEntries() {
        let store = makeStore()
        XCTAssertThrowsError(try store.add("   "))
        XCTAssertTrue(store.listEntries().isEmpty)
    }

    func testRemove() throws {
        let store = makeStore()
        let entry = try store.add("TalkType")
        XCTAssertTrue(store.remove(entryID: entry.id))
        XCTAssertFalse(store.remove(entryID: entry.id), "removing twice is not a success")
        XCTAssertTrue(store.listEntries().isEmpty)
    }

    func testEntriesSurviveAReload() throws {
        let path = tempDir.appendingPathComponent("vocabulary.json")
        try VocabularyStore(path: path).add("TalkType")
        XCTAssertEqual(VocabularyStore(path: path).listEntries().map(\.canonical), ["TalkType"])
    }

    func testMissingFileLoadsEmpty() {
        let store = VocabularyStore(path: tempDir.appendingPathComponent("nope.json"))
        XCTAssertTrue(store.listEntries().isEmpty)
    }

    func testCorruptFileLoadsEmptyRatherThanCrashing() throws {
        let path = tempDir.appendingPathComponent("vocabulary.json")
        try Data("not json".utf8).write(to: path)
        XCTAssertTrue(VocabularyStore(path: path).listEntries().isEmpty)
    }

    func testActiveVocabularyIsCappedByCount() throws {
        let store = makeStore()
        for i in 0..<60 { try store.add("word\(i)") }
        XCTAssertEqual(store.getActiveVocabulary(limit: 50).count, 50)
    }

    /// Count is the only store-side cap. Provider clients already enforce their own
    /// term/character budgets (Doubao and Grok: 100 × 50).
    func testActiveVocabularyDoesNotApplyAPromptCharacterBudget() throws {
        let store = makeStore()
        for i in 0..<60 { try store.add(String(repeating: "x", count: 40) + "\(i)") }
        XCTAssertEqual(store.getActiveVocabulary(limit: 50).count, 50)
    }

    func testLongSingleEntryIsStillIncluded() throws {
        let store = makeStore()
        try store.add(String(repeating: "y", count: 500))
        XCTAssertEqual(store.getActiveVocabulary().count, 1)
    }

    /// Pre-v3 vocabulary files carried polish-era fields. Those keys must load as a
    /// plain word list, not fail the decode.
    func testLegacyPinnedAndLastUsedFieldsAreIgnored() throws {
        let path = tempDir.appendingPathComponent("vocabulary.json")
        let json = """
        {"version":1,"entries":[
          {"id":"abcd1234","canonical":"Claude Code",
           "added_at":"2026-08-01T00:00:00Z","pinned":true,
           "last_used_at":"2026-08-02T00:00:00Z"}
        ]}
        """
        try Data(json.utf8).write(to: path)
        XCTAssertEqual(VocabularyStore(path: path).listEntries().map(\.canonical),
                       ["Claude Code"])
    }
}
