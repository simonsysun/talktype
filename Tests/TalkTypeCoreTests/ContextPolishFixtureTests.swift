import XCTest
@testable import TalkTypeCore

final class ContextPolishFixtureTests: XCTestCase {
    private struct VisibleContext: Decodable {
        let captureStatus: String
        let terms: [String]
        let snippets: [String]
        let untrusted: Bool

        enum CodingKeys: String, CodingKey {
            case captureStatus = "capture_status"
            case terms, snippets, untrusted
        }
    }

    private struct Evidence: Decodable {
        let rawSpan: String
        let contextTerm: String

        enum CodingKeys: String, CodingKey {
            case rawSpan = "raw_span"
            case contextTerm = "context_term"
        }
    }

    private struct Fixture: Decodable {
        let schemaVersion: String
        let id: String
        let split: String
        let category: String
        let spokenText: String
        let rawTranscript: String
        let visibleContext: VisibleContext
        let expectedOutput: String
        let allowedOutputs: [String]
        let forbiddenSubstrings: [String]
        let contextUseEvidence: Evidence?
        let contextChangeExpected: Bool

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case id, split, category
            case spokenText = "spoken_text"
            case rawTranscript = "raw_transcript"
            case visibleContext = "visible_context"
            case expectedOutput = "expected_output"
            case allowedOutputs = "allowed_outputs"
            case forbiddenSubstrings = "forbidden_substrings"
            case contextUseEvidence = "context_use_evidence"
            case contextChangeExpected = "context_change_expected"
        }
    }

    private struct RecordingManifest: Decodable {
        let schemaVersion: String
        let caseID: String
        let recordingRequired: Bool

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case caseID = "case_id"
            case recordingRequired = "recording_required"
        }
    }

    private func fixtureURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ContextPolish")
            .appendingPathComponent(filename)
    }

    private func decodeJSONLines<T: Decodable>(_ type: T.Type, filename: String) throws -> [T] {
        let text = try String(contentsOf: fixtureURL(filename), encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map { line in
            try JSONDecoder().decode(type, from: Data(line.utf8))
        }
    }

    func testBenchmarkCorpusIsAuditableAndInternallyConsistent() throws {
        let cases = try decodeJSONLines(Fixture.self, filename: "context_polish_cases.jsonl")

        XCTAssertEqual(cases.count, 40)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        XCTAssertEqual(cases.filter { $0.split == "dev" }.count, 22)
        XCTAssertEqual(cases.filter { $0.split == "holdout" }.count, 18)
        XCTAssertGreaterThanOrEqual(Set(cases.map(\.category)).count, 12)

        for fixture in cases {
            XCTAssertEqual(fixture.schemaVersion, "1.0", fixture.id)
            XCTAssertFalse(fixture.spokenText.isEmpty, fixture.id)
            XCTAssertFalse(fixture.rawTranscript.isEmpty, fixture.id)
            XCTAssertTrue(fixture.visibleContext.untrusted, fixture.id)
            XCTAssertTrue(fixture.allowedOutputs.contains(fixture.expectedOutput), fixture.id)

            if fixture.contextChangeExpected {
                let evidence = try XCTUnwrap(fixture.contextUseEvidence, fixture.id)
                XCTAssertTrue(
                    fixture.rawTranscript.localizedCaseInsensitiveContains(evidence.rawSpan),
                    fixture.id
                )
                XCTAssertTrue(fixture.visibleContext.terms.contains(evidence.contextTerm), fixture.id)
            } else {
                XCTAssertNil(fixture.contextUseEvidence, fixture.id)
            }

            for forbidden in fixture.forbiddenSubstrings {
                XCTAssertFalse(fixture.expectedOutput.contains(forbidden), fixture.id)
            }
        }
    }

    func testRecordingManifestMatchesCorpusWithoutPretendingTextFixturesAreAudio() throws {
        let cases = try decodeJSONLines(Fixture.self, filename: "context_polish_cases.jsonl")
        let manifest = try decodeJSONLines(
            RecordingManifest.self,
            filename: "recording_manifest.jsonl"
        )

        XCTAssertEqual(manifest.count, cases.count)
        XCTAssertEqual(Set(manifest.map(\.caseID)), Set(cases.map(\.id)))
        XCTAssertEqual(manifest.filter(\.recordingRequired).count, 20)
        XCTAssertTrue(manifest.allSatisfy { $0.schemaVersion == "1.0" })
    }

    func testEveryExpectedOutputPassesTheShippingSafetyGate() throws {
        let cases = try decodeJSONLines(Fixture.self, filename: "context_polish_cases.jsonl")

        for fixture in cases {
            let context: PolishContext
            if fixture.visibleContext.captureStatus == "available" {
                context = PolishContext(
                    activeApp: "Benchmark",
                    terms: fixture.visibleContext.terms,
                    snippets: fixture.visibleContext.snippets
                )
            } else {
                context = .empty
            }

            XCTAssertTrue(
                TextRefiner.isPlausibleRefinement(
                    original: fixture.rawTranscript,
                    refined: fixture.expectedOutput,
                    context: context
                ),
                "expected output rejected by safety gate: \(fixture.id)"
            )

            if ["prompt_injection", "context_echo"].contains(fixture.category),
               let copiedText = fixture.visibleContext.snippets.first {
                let copiedCandidate = fixture.expectedOutput + " " + copiedText
                XCTAssertFalse(
                    TextRefiner.isPlausibleRefinement(
                        original: fixture.rawTranscript,
                        refined: copiedCandidate,
                        context: context
                    ),
                    "copied context could pass safety gate: \(fixture.id)"
                )
            }
        }
    }
}
