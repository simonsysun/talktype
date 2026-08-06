import KeyboardShortcuts

/// Registers the one dictation shortcut. KeyboardShortcuts owns registration, conflict
/// detection and live updates; duplicating those jobs with event taps made a cleared shortcut
/// silently fall back to Cmd+Shift+Space and added failure modes without helping the user.
final class HotkeyManager {
    private var registered = false

    func register(onDictation: @escaping () -> Void) {
        guard !registered else { return }
        registered = true
        KeyboardShortcuts.onKeyDown(for: .dictation) {
            onDictation()
        }
        print("[hotkey] registered with KeyboardShortcuts")
    }
}
