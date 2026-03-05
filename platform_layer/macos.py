import time
import AppKit
import Quartz
from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
from platform_layer.base import PlatformBase

_MAIN_LOOP_MODES = [AppKit.NSDefaultRunLoopMode, AppKit.NSEventTrackingRunLoopMode]


class MacOSPlatform(PlatformBase):
    """macOS-specific hotkeys (NSEvent), paste (CGEvent), and clipboard."""

    def __init__(self):
        self._monitors = []
        self._event_tap = None
        self._event_tap_source = None

    def _run_on_main(self, fn) -> None:
        if AppKit.NSThread.isMainThread():
            fn()
        else:
            AppKit.NSRunLoop.mainRunLoop().performInModes_block_(_MAIN_LOOP_MODES, fn)

    @staticmethod
    def _is_dictation_hotkey(keycode: int, flags: int) -> bool:
        if keycode != 49:  # Space
            return False
        if not (flags & Quartz.kCGEventFlagMaskAlternate):
            return False

        blocked = (
            Quartz.kCGEventFlagMaskShift
            | Quartz.kCGEventFlagMaskCommand
            | Quartz.kCGEventFlagMaskControl
            | Quartz.kCGEventFlagMaskSecondaryFn
        )
        return (flags & blocked) == 0

    def copy_text(self, text: str) -> None:
        """Copy text to system clipboard only."""
        pb = AppKit.NSPasteboard.generalPasteboard()
        pb.clearContents()
        pb.setString_forType_(text, AppKit.NSPasteboardTypeString)

    def paste_text(self, text: str) -> None:
        """Copy text to system clipboard and simulate Cmd+V."""
        self.copy_text(text)

        # Brief delay to ensure clipboard is ready
        time.sleep(0.05)

        # Simulate Cmd+V keypress
        # Keycode 9 = 'v'
        v_down = Quartz.CGEventCreateKeyboardEvent(None, 9, True)
        v_up = Quartz.CGEventCreateKeyboardEvent(None, 9, False)
        Quartz.CGEventSetFlags(v_down, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventSetFlags(v_up, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, v_down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, v_up)

    def register_hotkey(self, on_dictation) -> None:
        """Register a global hotkey and suppress the underlying key event if possible."""

        def fire_dictation():
            self._run_on_main(on_dictation)

        def tap_handler(proxy, event_type, event, refcon):
            if event_type in (
                Quartz.kCGEventTapDisabledByTimeout,
                Quartz.kCGEventTapDisabledByUserInput,
            ):
                if self._event_tap is not None:
                    Quartz.CGEventTapEnable(self._event_tap, True)
                return event

            if event_type != Quartz.kCGEventKeyDown:
                return event

            if Quartz.CGEventGetIntegerValueField(
                event, Quartz.kCGKeyboardEventAutorepeat
            ):
                return event

            keycode = int(
                Quartz.CGEventGetIntegerValueField(
                    event, Quartz.kCGKeyboardEventKeycode
                )
            )
            flags = int(Quartz.CGEventGetFlags(event))

            if self._is_dictation_hotkey(keycode, flags):
                fire_dictation()
                return None

            return event

        tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionDefault,
            Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown),
            tap_handler,
            None,
        )

        if tap is not None:
            source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
            Quartz.CFRunLoopAddSource(
                Quartz.CFRunLoopGetMain(), source, Quartz.kCFRunLoopCommonModes
            )
            Quartz.CGEventTapEnable(tap, True)
            self._event_tap = tap
            self._event_tap_source = source
            return

        mask = AppKit.NSEventMaskKeyDown

        def handler(event):
            if event.isARepeat():
                return

            keycode = event.keyCode()
            flags = event.modifierFlags()
            quartz_flags = 0
            if flags & AppKit.NSEventModifierFlagOption:
                quartz_flags |= Quartz.kCGEventFlagMaskAlternate
            if flags & AppKit.NSEventModifierFlagShift:
                quartz_flags |= Quartz.kCGEventFlagMaskShift
            if flags & AppKit.NSEventModifierFlagCommand:
                quartz_flags |= Quartz.kCGEventFlagMaskCommand
            if flags & AppKit.NSEventModifierFlagControl:
                quartz_flags |= Quartz.kCGEventFlagMaskControl
            if flags & AppKit.NSEventModifierFlagFunction:
                quartz_flags |= Quartz.kCGEventFlagMaskSecondaryFn

            if self._is_dictation_hotkey(keycode, quartz_flags):
                fire_dictation()

        monitor = AppKit.NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            mask, handler
        )
        self._monitors.append(monitor)

    def request_accessibility(self) -> bool:
        """Check if accessibility permission is granted."""
        trusted = AXIsProcessTrustedWithOptions(
            {kAXTrustedCheckOptionPrompt: True}
        )
        return bool(trusted)

    def cleanup(self):
        if self._event_tap_source is not None:
            Quartz.CFRunLoopRemoveSource(
                Quartz.CFRunLoopGetMain(),
                self._event_tap_source,
                Quartz.kCFRunLoopCommonModes,
            )
            self._event_tap_source = None
        if self._event_tap is not None:
            Quartz.CFMachPortInvalidate(self._event_tap)
            self._event_tap = None
        for monitor in self._monitors:
            AppKit.NSEvent.removeMonitor_(monitor)
        self._monitors.clear()
