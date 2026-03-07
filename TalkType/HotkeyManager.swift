import Carbon
import Cocoa

/// Registers Option+Space as a global hotkey with a 3-tier fallback:
/// 1. Carbon RegisterEventHotKey (suppresses the key event)
/// 2. CGEventTap (suppresses the key event)
/// 3. NSEvent global monitor (cannot suppress)
final class HotkeyManager {
    enum CaptureMode: String {
        case carbon = "carbon"
        case eventTap = "event_tap"
        case monitor = "monitor"
        case unregistered = "unregistered"
    }

    private(set) var captureMode: CaptureMode = .unregistered

    private var onDictation: (() -> Void)?
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonHandlerRef: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var globalMonitor: Any?

    // Must hold a reference to prevent deallocation
    private var carbonHandlerUPP: EventHandlerUPP?

    private static let spaceKeyCode: UInt32 = 49
    private static let optionModifier: UInt32 = UInt32(optionKey)

    func register(onDictation: @escaping () -> Void) {
        self.onDictation = onDictation

        if registerCarbonHotkey() {
            captureMode = .carbon
            print("[hotkey] using Carbon global hotkey registration")
            return
        }

        if registerEventTap() {
            captureMode = .eventTap
            print("[hotkey] using CGEventTap fallback")
            return
        }

        registerGlobalMonitor()
        captureMode = .monitor
        print("[hotkey] using NSEvent global monitor fallback")
    }

    // MARK: - Carbon Hotkey (Tier 1)

    private func registerCarbonHotkey() -> Bool {
        let eventTarget = GetApplicationEventTarget()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.onDictation?()
            }
            return noErr
        }
        self.carbonHandlerUPP = handler

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            eventTarget,
            handler,
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        guard installStatus == noErr else { return false }
        self.carbonHandlerRef = handlerRef

        let hotkeyID = EventHotKeyID(
            signature: OSType(0x57535052), // "WSPR"
            id: 1
        )
        var hotkeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            Self.spaceKeyCode,
            Self.optionModifier,
            hotkeyID,
            eventTarget,
            0,
            &hotkeyRef
        )
        guard registerStatus == noErr else {
            if let ref = self.carbonHandlerRef {
                RemoveEventHandler(ref)
                self.carbonHandlerRef = nil
            }
            return false
        }
        self.carbonHotKeyRef = hotkeyRef
        return true
    }

    // MARK: - CGEventTap (Tier 2)

    private func registerEventTap() -> Bool {
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

                // Ignore auto-repeat
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                    return Unmanaged.passUnretained(event)
                }

                let keycode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags

                if HotkeyManager.isDictationHotkey(keycode: keycode, flags: flags) {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async {
                        manager.onDictation?()
                    }
                    return nil // Suppress the event
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

    // MARK: - NSEvent Global Monitor (Tier 3)

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

            if Self.isDictationHotkey(keycode: keycode, flags: quartzFlags) {
                self?.onDictation?()
            }
        }
    }

    // MARK: - Hotkey Detection

    static func isDictationHotkey(keycode: UInt32, flags: CGEventFlags) -> Bool {
        guard keycode == spaceKeyCode else { return false }
        guard flags.contains(.maskAlternate) else { return false }

        let blocked: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskSecondaryFn]
        return flags.intersection(blocked).isEmpty
    }

    // MARK: - Cleanup

    func cleanup() {
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
        if let ref = carbonHandlerRef {
            RemoveEventHandler(ref)
            carbonHandlerRef = nil
        }
        carbonHandlerUPP = nil

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

        captureMode = .unregistered
    }

    deinit {
        cleanup()
    }
}
