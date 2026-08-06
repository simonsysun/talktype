import XCTest
@testable import TalkTypeCore

/// Explicitly opt-in: ordinary `swift test` never contacts Groq or reads its key.
///
/// TALKTYPE_RUN_LIVE_POLISH=1 swift test --filter ContextPolishLiveBenchmarkTests
/// TALKTYPE_BENCH_SPLIT=holdout ...  # only after implementation is frozen
/// TALKTYPE_BENCH_REPETITIONS=3 ...  # final stability pass
final class ContextPolishLiveBenchmarkTests: XCTestCase {
    private struct CapturedContext: Decodable {
        let captureStatus: String
        let terms: [String]
        let snippets: [String]

        enum CodingKeys: String, CodingKey {
            case captureStatus = "capture_status"
            case terms, snippets
        }
    }

    private struct Fixture: Decodable {
        let id: String
        let split: String
        let rawTranscript: String
        let visibleContext: CapturedContext
        let allowedOutputs: [String]
        let forbiddenSubstrings: [String]
        let contextChangeExpected: Bool

        enum CodingKeys: String, CodingKey {
            case id, split
            case rawTranscript = "raw_transcript"
            case visibleContext = "visible_context"
            case allowedOutputs = "allowed_outputs"
            case forbiddenSubstrings = "forbidden_substrings"
            case contextChangeExpected = "context_change_expected"
        }
    }

    private enum Variant: String, CaseIterable {
        case none
        case terms
        case termsAndSnippets
    }

    func testLiveContextPolishBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TALKTYPE_RUN_LIVE_POLISH"] == "1" else {
            throw XCTSkip("Live Polish benchmark is opt-in and never runs in the normal suite.")
        }
        guard TextRefiner.apiKey() != nil else {
            throw XCTSkip("No Groq key is configured in the TalkType keychain.")
        }

        let split = environment["TALKTYPE_BENCH_SPLIT"] ?? "dev"
        let repetitions = max(1, Int(environment["TALKTYPE_BENCH_REPETITIONS"] ?? "1") ?? 1)
        let delayMilliseconds = max(
            0,
            Int(environment["TALKTYPE_BENCH_DELAY_MS"] ?? "1100") ?? 1_100
        )
        let includeText = environment["TALKTYPE_BENCH_INCLUDE_TEXT"] == "1"
        var fixtures = try loadFixtures().filter { $0.split == split }
        if let limit = Int(environment["TALKTYPE_BENCH_LIMIT"] ?? ""), limit > 0 {
            fixtures = Array(fixtures.prefix(limit))
        }
        XCTAssertFalse(fixtures.isEmpty, "unknown or empty benchmark split: \(split)")

        let refiner = TextRefiner()
        refiner.prewarm()
        var exactByVariant: [Variant: Int] = [:]
        var unsafeByVariant: [Variant: Int] = [:]
        var terminalPunctuationByVariant: [Variant: Int] = [:]
        var elapsedByVariant: [Variant: [Double]] = [:]

        for fixture in fixtures {
            for variant in Variant.allCases {
                for repetition in 0..<repetitions {
                    let context = polishContext(for: variant, fixture: fixture)
                    let started = ProcessInfo.processInfo.systemUptime
                    let modelOutput = refiner.refine(fixture.rawTranscript, context: context)
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    let output = modelOutput ?? PostProcessor.tidySpeech(fixture.rawTranscript)
                    let normalized = PostProcessor.normalizeTypography(output)
                    let exact = fixture.allowedOutputs.contains {
                        acceptanceKey($0) == acceptanceKey(normalized)
                    }
                    let unsafe = fixture.forbiddenSubstrings.contains { normalized.contains($0) }

                    if exact { exactByVariant[variant, default: 0] += 1 }
                    if unsafe { unsafeByVariant[variant, default: 0] += 1 }
                    if normalized.range(of: #"[。！？.!?]$"#, options: .regularExpression) != nil {
                        terminalPunctuationByVariant[variant, default: 0] += 1
                    }
                    elapsedByVariant[variant, default: []].append(elapsed)

                    if includeText {
                        print("[context-bench] \(fixture.id) \(variant.rawValue) #\(repetition + 1) exact=\(exact) unsafe=\(unsafe) output=\(normalized)")
                    }
                    if delayMilliseconds > 0 {
                        Thread.sleep(forTimeInterval: Double(delayMilliseconds) / 1_000)
                    }
                }
            }
        }

        let denominator = fixtures.count * repetitions
        for variant in Variant.allCases {
            let times = elapsedByVariant[variant, default: []].sorted()
            let p95Index = max(0, Int(ceil(Double(times.count) * 0.95)) - 1)
            let p95 = times.isEmpty ? 0 : times[p95Index]
            print("[context-bench] split=\(split) variant=\(variant.rawValue) accepted=\(exactByVariant[variant, default: 0])/\(denominator) unsafe=\(unsafeByVariant[variant, default: 0]) terminal_punctuation=\(terminalPunctuationByVariant[variant, default: 0])/\(denominator) p95_ms=\(Int(p95 * 1_000))")
        }

        // Wrong or injected context is never an acceptable trade for higher accuracy.
        for variant in Variant.allCases {
            XCTAssertEqual(unsafeByVariant[variant, default: 0], 0, variant.rawValue)
        }
        XCTAssertEqual(
            exactByVariant[.termsAndSnippets, default: 0],
            denominator,
            "context-enabled Polish must satisfy every accepted output in the selected split"
        )
    }

    /// Context quality is about words and meaning. The shipping Polish model does not
    /// consistently add a final sentence mark, so compare that orthogonal difference
    /// separately instead of misclassifying a correct proper-noun fix as a context miss.
    private func acceptanceKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[。！？.!?]+$"#,
                with: "",
                options: .regularExpression
            )
    }

    private func polishContext(for variant: Variant, fixture: Fixture) -> PolishContext {
        guard fixture.visibleContext.captureStatus == "available" else { return .empty }
        switch variant {
        case .none:
            return .empty
        case .terms:
            return PolishContext(activeApp: "Benchmark", terms: fixture.visibleContext.terms)
        case .termsAndSnippets:
            return PolishContext(
                activeApp: "Benchmark",
                terms: fixture.visibleContext.terms,
                snippets: fixture.visibleContext.snippets
            )
        }
    }

    private func loadFixtures() throws -> [Fixture] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ContextPolish/context_polish_cases.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map { line in
            try JSONDecoder().decode(Fixture.self, from: Data(line.utf8))
        }
    }
}
