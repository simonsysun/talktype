import Foundation

enum PostProcessor {

    // MARK: - Speech tidying

    /// Hesitation sounds that carry no meaning in Mandarin. 啊, 那个 and 就是 are
    /// deliberately absent: they are filler often enough to be tempting and meaningful
    /// often enough that deleting them is a bet on the speaker's intent.
    private static let fillerParticles = "呃嗯额诶欸"

    /// ICU character-class body. ICU wants \uXXXX, not Swift's \u{XXXX}.
    private static let cjk = "\\u4E00-\\u9FFF\\u3400-\\u4DBF"

    /// Deterministic tidy-up of dictated text: hesitations, stutters, punctuation width,
    /// spacing between scripts, and stray punctuation at the edges. Runs in microseconds
    /// and can only delete or respace, never reword — it is the always-on tidy, and the
    /// floor below which output never drops.
    static func tidySpeech(_ text: String) -> String {
        var s = text

        s = replacing(s, "[\(fillerParticles)]+", with: "")

        // Deleting a particle can leave the punctuation that surrounded it doubled up:
        // "在于,嗯,就是说" becomes "在于,,就是说".
        s = replacing(s, "([,，。！？、；：])[\\s]*[,，、]+", with: "$1")

        // A phrase immediately repeated, optionally split by a comma: keep one copy.
        // "我们现在有用,我们现在有用这个" -> "我们现在有用这个"
        for _ in 0..<3 {
            s = replacing(s, "([\(cjk)]{2,12})[,，]?\\1", with: "$1")
        }

        // Stuttered pronouns only. Mandarin reduplicates verbs meaningfully — 看看,
        // 说说, 想想 are words, and a general AA rule turned 先看看 into 先看.
        s = replacing(s, "([我你他她它])\\1(?=[\(cjk)])", with: "$1")

        // Half-width punctuation that follows a Chinese character belongs full-width.
        for (half, full) in [(",", "，"), ("?", "？"), ("!", "！"), (";", "；"), (":", "：")] {
            s = replacing(s, "(?<=[\(cjk)])\\\(half)", with: full)
        }
        s = replacing(s, "(?<=[\(cjk)])\\.(?=\\s|$)", with: "。")

        // One space between Chinese and Latin/digits, none before Chinese punctuation.
        s = replacing(s, "([\(cjk)])([A-Za-z0-9])", with: "$1 $2")
        s = replacing(s, "([A-Za-z0-9])([\(cjk)])", with: "$1 $2")
        s = replacing(s, "[ \\t]{2,}", with: " ")
        s = replacing(s, "\\s+([，。？！、；：])", with: "$1")

        // The engine occasionally starts a transcript with a stray comma (observed in
        // bakeoff); a sentence never starts with punctuation, and never ends with a
        // comma/顿号 (even one followed by whitespace), so those edge runs are noise.
        s = replacing(s, "^[\\s,，、。；：!！?？.;:]+", with: "")
        s = replacing(s, "[、，,]+\\s*$", with: "")

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

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

    /// RMS threshold below which hallucination detection is active.
    /// Must stay above `AppConfig.minTranscribeRms` — below that cutoff the audio is
    /// discarded before transcription, so this check only earns its keep in the band
    /// between the two. Asserted in PostProcessorTests.
    static let hallucinationRmsThreshold: Float = 0.015

    /// Check if transcription is likely a hallucination of vocabulary words on near-silent audio.
    /// Only flags when audio RMS is low AND the entire result consists of vocab words.
    static func isLikelyHallucination(_ text: String, audioRMS: Float, vocabEntries: [VocabEntry]) -> Bool {
        // Never flag normal-volume speech
        guard audioRMS < hallucinationRmsThreshold else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let vocabWords = Set(vocabEntries.map { $0.canonical.trimmingCharacters(in: .whitespaces).lowercased() })
        guard !vocabWords.isEmpty else { return false }

        // Check space-separated tokens (handles "Claude Code" or "Todo")
        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let allTokensAreVocab = tokens.allSatisfy { token in
            vocabWords.contains(token.lowercased())
        }
        if allTokensAreVocab { return true }

        // Check if entire text matches a single vocab entry
        if vocabWords.contains(trimmed.lowercased()) { return true }

        // Check CJK concatenation (e.g. "做爱做爱" from vocab word "做爱")
        let cjkVocab = vocabEntries
            .map { $0.canonical.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(where: { c in c.unicodeScalars.allSatisfy { s in
                (0x4E00...0x9FFF).contains(s.value) ||   // CJK Unified
                (0x3400...0x4DBF).contains(s.value) ||   // CJK Extension A
                (0x3000...0x303F).contains(s.value) ||   // CJK Punctuation
                (0xFF00...0xFFEF).contains(s.value)      // Fullwidth
            }}) }
        if !cjkVocab.isEmpty {
            var remainder = trimmed
            var madeProgress = true
            while !remainder.isEmpty && madeProgress {
                madeProgress = false
                for word in cjkVocab {
                    while remainder.hasPrefix(word) {
                        remainder.removeFirst(word.count)
                        madeProgress = true
                    }
                }
                // Skip CJK punctuation and whitespace between words
                while let first = remainder.first,
                      first.isWhitespace || first.unicodeScalars.allSatisfy({ s in
                          (0x3000...0x303F).contains(s.value) || // CJK punctuation (。、！？etc)
                          (0xFF01...0xFF0F).contains(s.value) || // Fullwidth punctuation
                          (0xFF1A...0xFF1E).contains(s.value)    // Fullwidth colon-gt
                      }) {
                    remainder.removeFirst()
                    madeProgress = true
                }
            }
            if remainder.isEmpty { return true }
        }

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
