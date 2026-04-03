import Cocoa
import KeyboardShortcuts

// MARK: - Shortcut name registration

extension KeyboardShortcuts.Name {
    static let dictation = Self("dictation", default: .init(.space, modifiers: [.command, .shift]))
}

// MARK: - Settings window

final class HotkeySettingsWindow {
    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "TalkType - Hotkey Settings"
        w.center()
        w.isReleasedWhenClosed = false

        let contentView = NSView(frame: w.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Label
        let label = NSTextField(labelWithString: "Dictation Hotkey:")
        label.frame = NSRect(x: 20, y: 80, width: 130, height: 20)
        label.font = .systemFont(ofSize: 13)
        contentView.addSubview(label)

        // KeyboardShortcuts recorder (Cocoa version)
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .dictation)
        recorder.frame = NSRect(x: 155, y: 76, width: 180, height: 28)
        contentView.addSubview(recorder)

        // Hint text
        let hint = NSTextField(wrappingLabelWithString: "Click the recorder and press your desired key combination. System shortcut conflicts are detected automatically.")
        hint.frame = NSRect(x: 20, y: 16, width: 320, height: 50)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        contentView.addSubview(hint)

        w.contentView = contentView
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = w
    }
}
