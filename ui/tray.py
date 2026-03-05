import AppKit
import rumps

from config import load_config, save_config
from core.asr_api import DEFAULT_OPENAI_ASR_MODEL, OPENAI_ASR_ACCOUNT
from core.keychain import retrieve_key, store_key


class WhisperTray(rumps.App):
    """Menu bar app using rumps. Owns the NSApplication main runloop."""

    def __init__(self, on_quit=None, platform=None):
        super().__init__("Whisper", icon=None, quit_button=None)
        self._on_quit = on_quit
        self._platform = platform
        self._cfg = load_config()

        self.title = "W"

        self._asr_item = rumps.MenuItem(
            f"ASR: {DEFAULT_OPENAI_ASR_MODEL}", callback=None
        )
        self._key_status_item = rumps.MenuItem("", callback=None)
        self._refresh_key_status()
        self._launch_item = rumps.MenuItem(
            "Launch at Login", callback=self._toggle_launch_at_login
        )
        self._launch_item.state = self._initial_launch_state()

        self.menu = [
            rumps.MenuItem("Dictation: Option+Space", callback=None),
            self._asr_item,
            self._key_status_item,
            None,
            rumps.MenuItem("Set OpenAI API Key...", callback=self._set_api_key),
            self._launch_item,
            None,
            rumps.MenuItem("Quit Whisper", callback=self._quit),
        ]

    def _save_cfg(self):
        save_config(self._cfg)

    def _initial_launch_state(self) -> bool:
        config_state = bool(self._cfg.get("launch_at_login", False))
        if self._platform is None:
            return config_state
        try:
            platform_state = self._platform.is_launch_at_login_enabled()
            self._cfg["launch_at_login"] = platform_state
            self._save_cfg()
            return platform_state
        except Exception:
            return config_state

    def _refresh_key_status(self):
        key = retrieve_key(OPENAI_ASR_ACCOUNT) or retrieve_key("OpenAI")
        self._key_status_item.title = "API Key: Configured" if key else "API Key: Missing"

    def _set_api_key(self, sender):
        w = rumps.Window(
            message="Enter OpenAI API key for speech transcription:",
            title="Whisper — OpenAI API Key",
            default_text="",
            ok="Save",
            cancel="Cancel",
            secure=True,
        )
        resp = w.run()
        if resp.clicked and resp.text.strip():
            store_key(OPENAI_ASR_ACCOUNT, resp.text.strip())
            self._refresh_key_status()
            rumps.notification("Whisper", "", "OpenAI API key saved.")

    def _toggle_launch_at_login(self, sender):
        target = not bool(sender.state)
        if self._platform is None:
            sender.state = target
            self._cfg["launch_at_login"] = target
            self._save_cfg()
            return
        try:
            self._platform.set_launch_at_login(target)
            sender.state = target
            self._cfg["launch_at_login"] = target
            self._save_cfg()
        except Exception as e:
            self.notify_error(f"Failed to update launch-at-login: {e}")

    def _on_main(self, fn):
        if AppKit.NSThread.isMainThread():
            fn()
        else:
            AppKit.NSRunLoop.mainRunLoop().performInModes_block_(
                [AppKit.NSDefaultRunLoopMode, AppKit.NSEventTrackingRunLoopMode],
                fn,
            )

    def set_recording(self, active: bool):
        def _do():
            self.title = "W·" if active else "W"
        self._on_main(_do)

    def set_processing(self, active: bool):
        def _do():
            self.title = "W…" if active else "W"
        self._on_main(_do)

    def notify_error(self, message: str):
        self._on_main(lambda: rumps.notification("Whisper", "Error", message))

    def notify_info(self, message: str):
        self._on_main(lambda: rumps.notification("Whisper", "", message))

    def _quit(self, sender):
        if self._on_quit:
            self._on_quit()
        rumps.quit_application()
