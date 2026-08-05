import Cocoa
import ApplicationServices

/// Puts the transcript where the cursor is.
///
/// Insertion is a synthesized ⌘V rather than character-by-character key events. Unicode
/// injection had to be chunked, and several apps — terminals and Electron ones especially —
/// dropped or reordered the tail of a long paragraph. A paste is one event, arrives whole,
/// and is instant regardless of length.
///
/// The transcript is deliberately left on the clipboard afterwards. Restoring the previous
/// contents races the app that is receiving the paste, and if anything goes wrong the user
/// is left with nothing; leaving it there means ⌘V always works as a manual fallback.
enum TextInserter {

    /// Paste `text` into the focused app. Returns false when Accessibility is not granted,
    /// in which case the text is on the clipboard and the caller should say so.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        copyToClipboard(text)

        guard accessibilityGranted(prompt: false) else { return false }

        // A private source so the user's real modifier state cannot bleed into the event —
        // the dictation hotkey itself carries ⌘⇧, and a stray Shift turns ⌘V into ⌘⇧V.
        let source = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 9   // ANSI "v"; ⌘V is bound to the physical key on every layout

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
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

    /// Whether the frontmost app currently has a focused element that accepts typed text.
    /// Fail-open: any AX hiccup means "yes", so terminals and unusual apps keep working —
    /// the worst case of failing open is today's behaviour (a beep), not a missed paste.
    static func focusedElementAcceptsText() -> Bool {
        guard accessibilityGranted(prompt: false),
              let app = NSWorkspace.shared.frontmostApplication else { return true }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused else { return true }

        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement,
                                            kAXRoleAttribute as CFString,
                                            &role) == .success,
              let roleString = role as? String else { return true }

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
            "AXWebArea",
        ]
        return textRoles.contains(roleString)
    }

    /// Forget any existing Accessibility decision for TalkType, then ask again.
    ///
    /// This exists because TalkType is not signed with a paid Developer ID. macOS ties the
    /// grant to the exact signature of the build it was given to, so installing a new
    /// version silently invalidates it — while still showing TalkType switched on in
    /// System Settings. Telling someone to enable a switch that is already enabled is no
    /// help, so clear the stale record and let macOS ask cleanly.
    static func repairAccessibilityGrant() {
        let bundleID = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", bundleID]
        try? reset.run()
        reset.waitUntilExit()
        Log.write("[perm] accessibility record reset (exit \(reset.terminationStatus))")

        // Re-ask. macOS shows its own dialog, and the app reappears in the list unchecked.
        _ = accessibilityGranted(prompt: true)
        openAccessibilitySettings()
    }

    /// Open the Accessibility section of System Settings.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
