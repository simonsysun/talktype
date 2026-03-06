import time
import os
import plistlib
import subprocess
import ctypes
from pathlib import Path
import AppKit
import Quartz
from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
from core.app_identity import (
    LEGACY_APP_NAME,
    app_name as current_app_name,
    bundle_id as current_bundle_id,
)
from platform_layer.base import PlatformBase

_MAIN_LOOP_MODES = [AppKit.NSDefaultRunLoopMode, AppKit.NSEventTrackingRunLoopMode]
_CARBON = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Carbon.framework/Carbon")
_CARBON_OPTION_KEY = 0x0800
_CARBON_NO_ERR = 0
_CARBON_EVENT_CLASS_KEYBOARD = int.from_bytes(b"keyb", "big")
_CARBON_EVENT_HOTKEY_PRESSED = 6
_CARBON_HOTKEY_SIGNATURE = int.from_bytes(b"WSPR", "big")


class _EventTypeSpec(ctypes.Structure):
    _fields_ = [("eventClass", ctypes.c_uint32), ("eventKind", ctypes.c_uint32)]


class _EventHotKeyID(ctypes.Structure):
    _fields_ = [("signature", ctypes.c_uint32), ("id", ctypes.c_uint32)]


_CarbonHotKeyHandler = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
_CARBON.GetApplicationEventTarget.restype = ctypes.c_void_p
_CARBON.InstallEventHandler.argtypes = [
    ctypes.c_void_p,
    _CarbonHotKeyHandler,
    ctypes.c_uint32,
    ctypes.POINTER(_EventTypeSpec),
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_void_p),
]
_CARBON.InstallEventHandler.restype = ctypes.c_int32
_CARBON.RegisterEventHotKey.argtypes = [
    ctypes.c_uint32,
    ctypes.c_uint32,
    _EventHotKeyID,
    ctypes.c_void_p,
    ctypes.c_uint32,
    ctypes.POINTER(ctypes.c_void_p),
]
_CARBON.RegisterEventHotKey.restype = ctypes.c_int32
_CARBON.UnregisterEventHotKey.argtypes = [ctypes.c_void_p]
_CARBON.UnregisterEventHotKey.restype = ctypes.c_int32
_CARBON.RemoveEventHandler.argtypes = [ctypes.c_void_p]
_CARBON.RemoveEventHandler.restype = ctypes.c_int32


class MacOSPlatform(PlatformBase):
    """macOS-specific hotkeys, direct text injection, and clipboard."""

    def __init__(self):
        self._monitors = []
        self._event_tap = None
        self._event_tap_source = None
        bundle = AppKit.NSBundle.mainBundle()
        bundle_id = bundle.bundleIdentifier() if bundle else None
        bundle_name = bundle.objectForInfoDictionaryKey_("CFBundleName") if bundle else None
        self._bundle_id = str(bundle_id or current_bundle_id())
        self._app_name = str(bundle_name or current_app_name())
        self._launch_agent_label = f"{self._bundle_id}.launcher"
        self._log_dir = Path.home() / "Library" / "Logs" / self._app_name
        self._hotkey_ref = None
        self._hotkey_handler_ref = None
        self._hotkey_handler = None
        self._hotkey_mode = "unregistered"

    def run_on_main(self, fn) -> None:
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
        """Type text into the focused app without touching the clipboard."""
        if not text:
            return

        # CGEvent unicode payloads have practical size limits; type in chunks.
        chunk_size = 64
        for start in range(0, len(text), chunk_size):
            chunk = text[start : start + chunk_size]
            down = Quartz.CGEventCreateKeyboardEvent(None, 0, True)
            up = Quartz.CGEventCreateKeyboardEvent(None, 0, False)
            Quartz.CGEventKeyboardSetUnicodeString(down, len(chunk), chunk)
            Quartz.CGEventKeyboardSetUnicodeString(up, len(chunk), chunk)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)
            time.sleep(0.002)

    def register_hotkey(self, on_dictation) -> None:
        """Register a global hotkey and suppress the underlying key event if possible."""

        def fire_dictation():
            self.run_on_main(on_dictation)

        if self._register_carbon_hotkey(fire_dictation):
            self._hotkey_mode = "carbon"
            print("[hotkey] using Carbon global hotkey registration")
            return

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
            self._hotkey_mode = "event_tap"
            print("[hotkey] using CGEventTap fallback")
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
        self._hotkey_mode = "monitor"
        print("[hotkey] using NSEvent global monitor fallback")

    def _register_carbon_hotkey(self, fire_dictation) -> bool:
        event_target = _CARBON.GetApplicationEventTarget()
        if not event_target:
            return False

        event_spec = _EventTypeSpec(
            eventClass=_CARBON_EVENT_CLASS_KEYBOARD,
            eventKind=_CARBON_EVENT_HOTKEY_PRESSED,
        )
        hotkey_id = _EventHotKeyID(signature=_CARBON_HOTKEY_SIGNATURE, id=1)

        def handler(next_handler, event_ref, user_data):
            fire_dictation()
            return _CARBON_NO_ERR

        callback = _CarbonHotKeyHandler(handler)
        handler_ref = ctypes.c_void_p()
        status = _CARBON.InstallEventHandler(
            event_target,
            callback,
            1,
            ctypes.byref(event_spec),
            None,
            ctypes.byref(handler_ref),
        )
        if status != _CARBON_NO_ERR:
            return False

        hotkey_ref = ctypes.c_void_p()
        status = _CARBON.RegisterEventHotKey(
            49,  # Space
            _CARBON_OPTION_KEY,
            hotkey_id,
            event_target,
            0,
            ctypes.byref(hotkey_ref),
        )
        if status != _CARBON_NO_ERR:
            _CARBON.RemoveEventHandler(handler_ref)
            return False

        self._hotkey_handler = callback
        self._hotkey_handler_ref = handler_ref
        self._hotkey_ref = hotkey_ref
        return True

    def request_accessibility(self) -> bool:
        """Check if accessibility permission is granted."""
        trusted = AXIsProcessTrustedWithOptions(
            {kAXTrustedCheckOptionPrompt: True}
        )
        return bool(trusted)

    def open_accessibility_settings(self) -> None:
        subprocess.run(
            ["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"],
            check=False,
        )

    def hotkey_capture_mode(self) -> str:
        return self._hotkey_mode

    def _launch_agent_path(self) -> Path:
        return Path.home() / "Library" / "LaunchAgents" / f"{self._launch_agent_label}.plist"

    def _resolve_app_executable(self) -> str:
        bundle = AppKit.NSBundle.mainBundle()
        exe = bundle.executablePath() if bundle else None
        # Trust the bundle path if it's a genuine .app bundle (not Python.app).
        # Validate by bundle identifier rather than hardcoded folder name,
        # so renamed apps still work.
        if exe and bundle.bundleIdentifier() and "/Contents/MacOS/" in exe:
            bundle_id = bundle.bundleIdentifier()
            if bundle_id != "org.python.python" and not bundle_id.startswith("com.apple."):
                return str(exe)

        preferred_names = [self._app_name, "TalkType", LEGACY_APP_NAME]
        seen: set[str] = set()
        candidates = []
        for name in preferred_names:
            if name in seen:
                continue
            seen.add(name)
            candidates.extend(
                [
                    Path.home() / "Applications" / f"{name}.app" / "Contents" / "MacOS" / name,
                    Path(__file__).resolve().parent.parent / "dist" / f"{name}.app" / "Contents" / "MacOS" / name,
                ]
            )

        for candidate in candidates:
            if candidate.exists():
                return str(candidate)

        raise RuntimeError(
            f"Cannot find {self._app_name}.app. Install it first."
        )

    def _write_launch_agent(self) -> Path:
        path = self._launch_agent_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        program = self._resolve_app_executable()
        plist = {
            "Label": self._launch_agent_label,
            "ProgramArguments": [program],
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ProcessType": "Interactive",
            "StandardOutPath": str(self._log_dir / "launchagent.out.log"),
            "StandardErrorPath": str(self._log_dir / "launchagent.err.log"),
        }
        self._log_dir.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as f:
            plistlib.dump(plist, f)
        return path

    @staticmethod
    def _launchctl(*args: str, check: bool = False) -> int:
        r = subprocess.run(
            ["launchctl", *args],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        if check and r.returncode != 0:
            detail = r.stderr.decode(errors="replace").strip()
            raise RuntimeError(f"launchctl {args[0]} failed: {detail or r.returncode}")
        return r.returncode

    def set_launch_at_login(self, enabled: bool) -> None:
        path = self._launch_agent_path()
        uid = str(os.getuid())
        domain = f"gui/{uid}"
        if enabled:
            self._write_launch_agent()
            # Just write the plist — launchd auto-loads from ~/Library/LaunchAgents on next login.
            # Do NOT bootstrap here: it would immediately start a second instance.
            return

        self._launchctl("bootout", domain, str(path))
        if path.exists():
            path.unlink()

    def is_launch_at_login_enabled(self) -> bool:
        # Plist existence is the source of truth — launchd loads it on next login.
        return self._launch_agent_path().exists()

    def cleanup(self):
        if self._hotkey_ref is not None:
            _CARBON.UnregisterEventHotKey(self._hotkey_ref)
            self._hotkey_ref = None
        if self._hotkey_handler_ref is not None:
            _CARBON.RemoveEventHandler(self._hotkey_handler_ref)
            self._hotkey_handler_ref = None
        self._hotkey_handler = None
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
        self._hotkey_mode = "unregistered"
