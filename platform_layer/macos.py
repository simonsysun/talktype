import time
import os
import plistlib
import subprocess
from pathlib import Path
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
        bundle = AppKit.NSBundle.mainBundle()
        bundle_id = bundle.bundleIdentifier() if bundle else None
        bundle_name = bundle.objectForInfoDictionaryKey_("CFBundleName") if bundle else None
        self._bundle_id = str(bundle_id or "dev.whisper.local")
        self._app_name = str(bundle_name or "Whisper")
        self._launch_agent_label = f"{self._bundle_id}.launcher"
        self._log_dir = Path.home() / "Library" / "Logs" / self._app_name

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
            self.run_on_main(on_dictation)

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

    def _launch_agent_path(self) -> Path:
        return Path.home() / "Library" / "LaunchAgents" / f"{self._launch_agent_label}.plist"

    def _resolve_app_executable(self) -> str:
        bundle = AppKit.NSBundle.mainBundle()
        exe = bundle.executablePath() if bundle else None
        # Trust the bundle path if it's a genuine .app bundle (not Python.app).
        # Validate by bundle identifier rather than hardcoded folder name,
        # so renamed apps (e.g. "Whisper 2.app") still work.
        if exe and bundle.bundleIdentifier() and "/Contents/MacOS/" in exe:
            bundle_id = bundle.bundleIdentifier()
            if bundle_id != "org.python.python" and not bundle_id.startswith("com.apple."):
                return str(exe)

        preferred_names = [self._app_name, "Whisper"]
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
