import Cocoa
import ApplicationServices

/// Types text into the focused app via CGEvent or copies to clipboard as fallback.
enum TextInserter {
    private static let chunkSize = 64

    /// Type text into the focused application using CGEvent unicode injection.
    /// Requires Accessibility permission.
    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }

        // Split into chunks of up to chunkSize Characters (not UTF-16 units)
        // to avoid breaking surrogate pairs at chunk boundaries.
        for chunk in text.characterChunks(maxSize: chunkSize) {
            let utf16 = Array(chunk.utf16)

            utf16.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: baseAddress)
                up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: baseAddress)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }

            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    /// Copy text to the system clipboard.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Check if the current process is trusted for Accessibility.
    static func accessibilityGranted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open the Accessibility section of System Settings.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension String {
    /// Split into substrings of at most `maxSize` Characters.
    /// Never breaks surrogate pairs since it advances by Character.
    func characterChunks(maxSize: Int) -> [Substring] {
        var chunks: [Substring] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: maxSize, limitedBy: endIndex) ?? endIndex
            chunks.append(self[start..<end])
            start = end
        }
        return chunks
    }
}
