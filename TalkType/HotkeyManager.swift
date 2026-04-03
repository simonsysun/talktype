import Carbon
import Cocoa
import KeyboardShortcuts

/// Registers the dictation hotkey using KeyboardShortcuts library (Carbon-based).
/// Falls back to CGEventTap if Carbon registration fails, then NSEvent monitor as last resort.
final class HotkeyManager {
    enum CaptureMode: String {
        case keyboardShortcuts = "keyboard_shortcuts"
        case eventTap = "event_tap"
        case monitor = "monitor"
        case unregistered = "unregistered"
    }

    private(set) var captureMode: CaptureMode = .unregistered

    private var onDictation: (() -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var globalMonitor: Any?

    func register(onDictation: @escaping () -> Void) {
        self.onDictation = onDictation

        // Register the KeyboardShortcuts callback ONCE. The library auto-updates
        // its Carbon registration when the shortcut changes — we must never call
        // onKeyDown again or callbacks will stack and double-fire.
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
            self?.onDictation?()
        }

        if KeyboardShortcuts.getShortcut(for: .dictation) != nil {
            captureMode = .keyboardShortcuts
            print("[hotkey] using KeyboardShortcuts (user-configurable)")
        } else if registerEventTap() {
            captureMode = .eventTap
            print("[hotkey] using CGEventTap fallback")
        } else {
            registerGlobalMonitor()
            captureMode = .monitor
            print("[hotkey] using NSEvent global monitor fallback")
        }

        // Observe shortcut changes — only to manage fallbacks, NOT to re-register onKeyDown
        NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                  name == .dictation else { return }
            self?.shortcutDidChange()
        }
    }

    private func shortcutDidChange() {
        if KeyboardShortcuts.getShortcut(for: .dictation) != nil {
            // KeyboardShortcuts auto-registered the new Carbon hotkey.
            // Just clean up any active fallbacks.
            cleanupFallbacks()
            captureMode = .keyboardShortcuts
            print("[hotkey] hotkey updated via KeyboardShortcuts")
        } else {
            // User cleared the shortcut — clean up any existing fallback first
            cleanupFallbacks()
            if registerEventTap() {
                captureMode = .eventTap
                print("[hotkey] shortcut cleared, using CGEventTap fallback")
            } else {
                registerGlobalMonitor()
                captureMode = .monitor
                print("[hotkey] shortcut cleared, using NSEvent monitor fallback")
            }
        }
    }

    // MARK: - CGEventTap (Fallback 1)

    private func registerEventTap() -> Bool {
        let shortcut = KeyboardShortcuts.getShortcut(for: .dictation)
        guard shortcut == nil else { return false }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                    return Unmanaged.passUnretained(event)
                }

                let keycode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags

                if HotkeyManager.isDefaultHotkey(keycode: keycode, flags: flags) {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async {
                        manager.onDictation?()
                    }
                    return nil
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else { return false }
        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTapSource = source
        return true
    }

    // MARK: - NSEvent Global Monitor (Fallback 2)

    private func registerGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard !event.isARepeat else { return }

            let keycode = UInt32(event.keyCode)
            var quartzFlags: CGEventFlags = []
            if event.modifierFlags.contains(.option)  { quartzFlags.insert(.maskAlternate) }
            if event.modifierFlags.contains(.shift)    { quartzFlags.insert(.maskShift) }
            if event.modifierFlags.contains(.command)  { quartzFlags.insert(.maskCommand) }
            if event.modifierFlags.contains(.control)  { quartzFlags.insert(.maskControl) }
            if event.modifierFlags.contains(.function) { quartzFlags.insert(.maskSecondaryFn) }

            if Self.isDefaultHotkey(keycode: keycode, flags: quartzFlags) {
                self?.onDictation?()
            }
        }
    }

    // MARK: - Default hotkey check (Cmd+Shift+Space)

    private static let spaceKeyCode: UInt32 = 49

    static func isDefaultHotkey(keycode: UInt32, flags: CGEventFlags) -> Bool {
        guard keycode == spaceKeyCode else { return false }
        guard flags.contains(.maskCommand) else { return false }
        guard flags.contains(.maskShift) else { return false }

        let blocked: CGEventFlags = [.maskAlternate, .maskControl, .maskSecondaryFn]
        return flags.intersection(blocked).isEmpty
    }

    // MARK: - Cleanup

    private func cleanupFallbacks() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    func cleanup() {
        KeyboardShortcuts.disable(.dictation)
        cleanupFallbacks()
        captureMode = .unregistered
    }

    deinit {
        cleanup()
    }
}
