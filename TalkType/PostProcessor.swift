import Foundation

enum PostProcessor {
    /// Normalize unicode and clean up whitespace.
    static func safeNormalize(_ text: String) -> String {
        var result = text.precomposedStringWithCompatibilityMapping // NFKC
        // Remove zero-width characters
        result = result.replacingOccurrences(
            of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}]",
            with: "",
            options: .regularExpression
        )
        // Collapse multiple spaces
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Check if a vocabulary word should be auto-replaced.
    static func isSafeForAutoReplace(_ canonical: String) -> Bool {
        let trimmed = canonical.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        let alphaChars = trimmed.filter { $0.isLetter }
        // ALL CAPS with 2+ letters
        if alphaChars.count >= 2 && alphaChars.allSatisfy({ $0.isUppercase }) { return true }
        // Contains digits
        if trimmed.contains(where: { $0.isNumber }) { return true }
        // Contains uppercase not at start
        if trimmed.count > 1 && trimmed.dropFirst().contains(where: { $0.isUppercase }) { return true }
        // Contains space
        if trimmed.contains(" ") { return true }
        // Contains non-ASCII
        if trimmed.contains(where: { !$0.isASCII }) { return true }

        return false
    }

    /// Apply vocabulary-based post-processing to transcript.
    static func postProcess(text: String, vocabEntries: [VocabEntry]) -> String {
        var result = safeNormalize(text)

        for entry in vocabEntries {
            let canonical = entry.canonical.trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty, isSafeForAutoReplace(canonical) else { continue }

            let pattern: String
            if canonical.allSatisfy({ $0.isASCII }) {
                pattern = "\\b\(NSRegularExpression.escapedPattern(for: canonical))\\b"
            } else {
                pattern = NSRegularExpression.escapedPattern(for: canonical)
            }

            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: canonical)
        }

        return result
    }
}
