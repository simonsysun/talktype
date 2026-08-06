import Foundation

/// A small, platform-neutral description of visible text. The macOS adapter computes
/// proximity from Accessibility geometry; tests can provide it directly without AX.
struct WindowTextBlock: Equatable, Sendable {
    let text: String
    let proximity: Double
    let visualOrder: Int
}

struct WindowContextSnapshot: Equatable, Sendable {
    let activeApp: String
    let blocks: [WindowTextBlock]
}

/// Reduces a bounded local window snapshot to the much smaller packet Polish may see.
/// This uses deterministic spelling similarity and geometry, not another model or call.
enum ContextSelector {
    private struct Candidate {
        let term: String
        let distance: Int
        let proximity: Double
        let order: Int
    }

    private static let ignoredSingleWords: Set<String> = [
        "a", "an", "and", "assistant", "chat", "i", "mac", "new", "reply",
        "email", "link", "redacted", "settings", "system", "the", "this",
        "upgrade", "user", "we", "you",
    ]

    static func resolve(snapshot: WindowContextSnapshot, rawTranscript: String) -> PolishContext {
        let orderedBlocks = sanitizedBlocks(snapshot.blocks)
        guard !orderedBlocks.isEmpty else { return .empty }

        let terms = matchingTerms(in: orderedBlocks, rawTranscript: rawTranscript)
        let snippets = selectedSnippets(from: orderedBlocks)
        guard !terms.isEmpty || !snippets.isEmpty else { return .empty }
        return PolishContext(activeApp: snapshot.activeApp, terms: terms, snippets: snippets)
    }

    private static func sanitizedBlocks(_ blocks: [WindowTextBlock]) -> [WindowTextBlock] {
        var seen: Set<String> = []
        return blocks
            .sorted {
                if $0.proximity != $1.proximity { return $0.proximity < $1.proximity }
                return $0.visualOrder > $1.visualOrder
            }
            .compactMap { block in
                let text = singleLine(block.text)
                guard text.count >= 2, !looksLikePlaceholder(text) else { return nil }
                let identity = text.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                guard seen.insert(identity).inserted else { return nil }
                return WindowTextBlock(
                    text: String(text.prefix(2_000)),
                    proximity: block.proximity,
                    visualOrder: block.visualOrder
                )
            }
    }

    private static func matchingTerms(
        in blocks: [WindowTextBlock],
        rawTranscript: String
    ) -> [String] {
        let raw = normalizedSpokenASCII(rawTranscript)
        guard !raw.isEmpty else { return [] }

        var bestByIdentity: [String: Candidate] = [:]
        for block in blocks.prefix(30) {
            for term in termCandidates(block.text) {
                let normalized = normalizedASCII(term)
                guard normalized.count >= 2,
                      !ignoredSingleWords.contains(normalized),
                      let distance = approximateDistance(target: normalized, in: raw)
                else { continue }

                let identity = normalized
                let candidate = Candidate(
                    term: term,
                    distance: distance,
                    proximity: block.proximity,
                    order: block.visualOrder
                )
                if let previous = bestByIdentity[identity] {
                    if candidate.distance < previous.distance
                        || (candidate.distance == previous.distance
                            && candidate.proximity < previous.proximity) {
                        bestByIdentity[identity] = candidate
                    }
                } else {
                    bestByIdentity[identity] = candidate
                }
            }
        }

        let ranked = bestByIdentity.values.sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.proximity != $1.proximity { return $0.proximity < $1.proximity }
            return $0.order > $1.order
        }

        var result: [String] = []
        var usedCharacters = 0
        for candidate in ranked {
            let separator = result.isEmpty ? 0 : 1
            guard usedCharacters + separator + candidate.term.count <= 400 else { continue }
            result.append(candidate.term)
            usedCharacters += separator + candidate.term.count
            if result.count == 12 { break }
        }
        return result
    }

    private static func selectedSnippets(from blocks: [WindowTextBlock]) -> [String] {
        var result: [String] = []
        var usedCharacters = 0
        let nearest = blocks.first?.proximity ?? 0
        for block in blocks.prefix(20) where block.proximity <= nearest + 300 {
            let remaining = 400 - usedCharacters - (result.isEmpty ? 0 : 1)
            guard remaining > 0 else { break }
            // The tail nearest the input usually contains the conclusion of the latest
            // response, while the head of a long web node is often navigation chrome.
            let bounded = String(block.text.suffix(min(block.text.count, remaining)))
            guard !bounded.isEmpty else { continue }
            result.append(bounded)
            usedCharacters += bounded.count + (result.count == 1 ? 0 : 1)
            if result.count == 2 { break }
        }
        return result
    }

    private static func properNounCandidates(_ text: String) -> [String] {
        let token = #"[A-Z][A-Za-z0-9]*(?:[-_.][A-Za-z0-9]+)*"#
        let pattern = #"(?<![A-Za-z0-9])"# + token + #"(?:\s+"# + token + #"){0,3}(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func termCandidates(_ text: String) -> [String] {
        let properNouns = properNounCandidates(text)
        let covered = properNouns.map(normalizedASCII)
        let pattern = #"[A-Za-z][A-Za-z0-9]*(?:[-_.][A-Za-z0-9]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return properNouns
        }
        let range = NSRange(text.startIndex..., in: text)
        let lowerOrIdentifier = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let candidate = String(text[range])
            let normalized = normalizedASCII(candidate)
            guard normalized.count >= 4,
                  !ignoredSingleWords.contains(normalized),
                  !covered.contains(where: { $0.contains(normalized) })
            else { return nil }
            return candidate
        }
        return properNouns + lowerOrIdentifier
    }

    private static func approximateDistance(target: String, in source: String) -> Int? {
        let targetCharacters = Array(target)
        let sourceCharacters = Array(source)
        guard !targetCharacters.isEmpty, !sourceCharacters.isEmpty else { return nil }
        let allowed = targetCharacters.count >= 5
            ? max(2, targetCharacters.count / 4)
            : 1

        var previous = Array(repeating: 0, count: sourceCharacters.count + 1)
        for (row, left) in targetCharacters.enumerated() {
            var current = Array(repeating: 0, count: sourceCharacters.count + 1)
            current[0] = row + 1
            for (column, right) in sourceCharacters.enumerated() {
                current[column + 1] = min(
                    min(current[column] + 1, previous[column + 1] + 1),
                    previous[column] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        guard let distance = previous.min(), distance <= allowed else { return nil }
        return distance
    }

    private static func normalizedASCII(_ text: String) -> String {
        text.lowercased().filter { character in
            character.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            }
        }
    }

    private static func normalizedSpokenASCII(_ text: String) -> String {
        var value = text.lowercased()
        let digitWords = [
            "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
            "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        ]
        for (word, digit) in digitWords {
            value = value.replacingOccurrences(
                of: #"\b"# + word + #"\b"#,
                with: digit,
                options: .regularExpression
            )
        }
        return normalizedASCII(value)
    }

    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)https?://[^\s]+|www\.[^\s]+"#,
                with: "[link]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
                with: "[email]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\b(api[_ -]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#,
                with: "$1=[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\bbearer\s+[A-Z0-9._-]{8,}"#,
                with: "Bearer [redacted]",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikePlaceholder(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.hasPrefix("reply to ")
            || value.hasPrefix("message ")
            || value.contains("keyboard shortcut")
            || value == "ask anything"
    }
}
