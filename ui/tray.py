import threading
from pathlib import Path

import AppKit
import rumps

from config import load_config, save_config
from core.asr_api import (
    DEFAULT_OPENAI_ASR_MODEL,
    OPENAI_ASR_ACCOUNT,
    PREMIUM_OPENAI_ASR_MODEL,
)
from core.keychain import delete_key, retrieve_key, store_key


class WhisperTray(rumps.App):
    """Menu bar app using rumps. Owns the NSApplication main runloop."""

    def __init__(
        self,
        on_quit=None,
        platform=None,
        on_model_change=None,
        is_dictating=None,
        vocabulary_store=None,
        app_name="Whisper",
        demo_license_manager=None,
    ):
        super().__init__(app_name, icon=None, quit_button=None)
        self._on_quit = on_quit
        self._platform = platform
        self._on_model_change = on_model_change
        self._is_dictating = is_dictating
        self._vocabulary_store = vocabulary_store
        self._app_name = app_name
        self._demo_license_manager = demo_license_manager
        self._cfg = load_config()
        self._validation_seq = 0
        self._model = self._normalize_model(self._cfg.get("asr_model", DEFAULT_OPENAI_ASR_MODEL))
        self._cfg["asr_model"] = self._model

        self.title = "W"

        self._asr_item = rumps.MenuItem("", callback=None)
        self._key_status_item = rumps.MenuItem("", callback=None)
        self._key_menu_item = rumps.MenuItem("OpenAI API Key...", callback=self._set_api_key)
        self._model_menu = rumps.MenuItem("Model")
        self._model_mini_item = rumps.MenuItem(
            "GPT-4o mini Transcribe", callback=self._use_openai_mini_model
        )
        self._model_premium_item = rumps.MenuItem(
            "GPT-4o Transcribe", callback=self._use_openai_premium_model
        )
        self._vocab_menu = rumps.MenuItem("Vocabulary")
        self._accessibility_item = rumps.MenuItem(
            "Accessibility Settings...", callback=self._open_accessibility_settings
        )
        self._demo_license_menu = (
            rumps.MenuItem("Demo License") if self._demo_license_manager is not None else None
        )
        self._demo_status_item = rumps.MenuItem("", callback=None)

        self._launch_item = rumps.MenuItem(
            "Launch at Login", callback=self._toggle_launch_at_login
        )
        self._launch_item.state = self._initial_launch_state()

        menu_items = [
            rumps.MenuItem("Dictation: Option+Space", callback=None),
            self._asr_item,
            self._key_status_item,
            self._accessibility_item,
            None,
            self._key_menu_item,
            self._model_menu,
            self._vocab_menu,
            self._launch_item,
            None,
            rumps.MenuItem(f"Quit {self._app_name}", callback=self._quit),
        ]
        if self._demo_license_menu is not None:
            menu_items.insert(8, self._demo_license_menu)
        self.menu = menu_items

        self._refresh_model_ui()
        self._refresh_key_status()
        self._refresh_vocabulary_menu()
        self._refresh_demo_license_menu()

        # Validate existing key on startup.
        key = self._current_api_key()
        if key:
            self._validate_key(key, notify=False)

    @staticmethod
    def _normalize_model(model: str) -> str:
        if model == PREMIUM_OPENAI_ASR_MODEL:
            return PREMIUM_OPENAI_ASR_MODEL
        return DEFAULT_OPENAI_ASR_MODEL

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

    def _current_api_key(self) -> str | None:
        return retrieve_key(OPENAI_ASR_ACCOUNT) or retrieve_key("OpenAI")

    def _delete_provider_keys(self) -> None:
        delete_key(OPENAI_ASR_ACCOUNT)
        delete_key("OpenAI")

    def _refresh_model_ui(self):
        self._asr_item.title = f"ASR: OpenAI / {self._model}"
        if getattr(self._model_menu, "_menu", None) is not None:
            self._model_menu.clear()
        self._model_mini_item.state = 1 if self._model == DEFAULT_OPENAI_ASR_MODEL else 0
        self._model_premium_item.state = 1 if self._model == PREMIUM_OPENAI_ASR_MODEL else 0
        self._model_menu.add(self._model_mini_item)
        self._model_menu.add(self._model_premium_item)

    def _refresh_key_status(self):
        key = self._current_api_key()
        self._set_key_status("API Key: Saved" if key else "API Key: Missing", checked=False)

    def _refresh_vocabulary_menu(self):
        if getattr(self._vocab_menu, "_menu", None) is not None:
            self._vocab_menu.clear()
        self._vocab_menu.add(rumps.MenuItem("Add Word...", callback=self._add_vocabulary_word))
        self._vocab_menu.add(None)

        entries = []
        if self._vocabulary_store is not None:
            entries = sorted(
                self._vocabulary_store.list_entries(),
                key=lambda entry: str(entry.get("added_at", "")),
                reverse=True,
            )

        if not entries:
            self._vocab_menu.add(rumps.MenuItem("No saved words", callback=None))
            return

        for entry in entries:
            item = rumps.MenuItem(entry["canonical"], callback=self._remove_vocabulary_word)
            item._vocab_entry_id = entry["id"]
            item._vocab_canonical = entry["canonical"]
            self._vocab_menu.add(item)

    def _refresh_demo_license_menu(self):
        if self._demo_license_menu is None:
            return

        if getattr(self._demo_license_menu, "_menu", None) is not None:
            self._demo_license_menu.clear()

        activated, summary = self._demo_license_manager.status_summary()
        self._demo_status_item.title = f"Status: {summary}"
        self._demo_license_menu.add(self._demo_status_item)
        self._demo_license_menu.add(
            rumps.MenuItem("Copy Machine ID", callback=self._copy_machine_id)
        )
        self._demo_license_menu.add(
            rumps.MenuItem("Import License File...", callback=self._import_license_file)
        )

    def _set_key_status(self, title: str, checked: bool) -> None:
        def _do():
            self._key_status_item.title = title
            self._key_status_item.state = 1 if checked else 0

        self._on_main(_do)

    def _invalidate_validations(self):
        # Mark any in-flight validation result as stale.
        self._validation_seq += 1

    def _set_model(self, model: str):
        model = self._normalize_model(model)
        if model == self._model:
            return

        if self._is_dictating and self._is_dictating():
            self.notify_info("Cannot switch model during dictation.")
            return

        self._invalidate_validations()
        self._model = model
        self._cfg["asr_model"] = model
        self._save_cfg()
        self._refresh_model_ui()

        if self._on_model_change:
            try:
                self._on_model_change(model)
            except Exception as e:
                print(f"[tray] model change callback failed: {e}")

        self.notify_info(f"ASR model switched to {model}.")

    def _use_openai_mini_model(self, sender):
        self._set_model(DEFAULT_OPENAI_ASR_MODEL)

    def _use_openai_premium_model(self, sender):
        self._set_model(PREMIUM_OPENAI_ASR_MODEL)

    def _validate_key(self, key: str, notify: bool = True):
        """Validate the OpenAI API key in a background thread."""
        label = "OpenAI"
        self._invalidate_validations()
        seq = self._validation_seq
        self._set_key_status("API Key: Checking...", checked=False)

        def _check():
            try:
                from openai import OpenAI

                client = OpenAI(api_key=key, timeout=10.0)
                client.models.list()
                if seq != self._validation_seq:
                    return
                self._set_key_status("API Key: Connected", checked=True)
                if notify:
                    self.notify_info(f"{label} API key verified.")
            except Exception as e:
                if seq != self._validation_seq:
                    return
                err = str(e).lower()
                status_code = getattr(e, "status_code", None)
                is_auth_error = (
                    status_code == 401
                    or "invalid_api_key" in err
                    or "incorrect api key" in err
                    or "unauthorized" in err
                )
                if is_auth_error:
                    current = self._current_api_key()
                    if current != key:
                        return
                    self._delete_provider_keys()
                    self._set_key_status("API Key: Invalid", checked=False)
                    self.notify_error(f"{label} API key is invalid. Please enter a new one.")
                else:
                    self._set_key_status("API Key: Saved (offline)", checked=False)
                    if notify:
                        self.notify_info(
                            f"{label} API key saved but couldn't verify (network error)."
                        )

        threading.Thread(target=_check, daemon=True).start()

    @staticmethod
    def _mask_key(key: str) -> str:
        if len(key) <= 7:
            return "***"
        return f"{key[:3]}...{key[-4:]}"

    def _set_api_key(self, sender):
        label = "OpenAI"
        existing = self._current_api_key()
        if existing:
            masked = self._mask_key(existing)
            result = rumps.alert(
                title=f"{self._app_name} — {label} API Key",
                message=f"Current key: {masked}",
                ok="Change Key",
                cancel="Done",
                other="Clear Key",
            )
            if result in (1, 1000):  # Change Key
                self._prompt_new_key()
            elif result in (2, 1002, -1):  # Clear Key (rumps/AppKit return variants)
                self._invalidate_validations()
                self._delete_provider_keys()
                self._refresh_key_status()
                rumps.notification(self._app_name, "", f"{label} API key cleared.")
            # Done/cancel or unknown code -> no-op
        else:
            self._prompt_new_key()

    def _prompt_new_key(self) -> bool:
        """Prompt user for API key. Returns True if key was saved."""
        label = "OpenAI"
        w = rumps.Window(
            message=f"Enter {label} API key for speech transcription:",
            title=f"{self._app_name} — {label} API Key",
            default_text="",
            ok="Save",
            cancel="Cancel",
            secure=True,
        )
        resp = w.run()
        if resp.clicked and resp.text.strip():
            key = resp.text.strip()
            if store_key(OPENAI_ASR_ACCOUNT, key):
                self._validate_key(key, notify=True)
                return True
            else:
                self.notify_error("Failed to save API key.")
        return False

    def _add_vocabulary_word(self, sender):
        if self._vocabulary_store is None:
            self.notify_error("Vocabulary store is unavailable.")
            return

        window = rumps.Window(
            message="Add a word or phrase to bias transcription spelling:",
            title=f"{self._app_name} — Vocabulary",
            default_text="",
            ok="Save",
            cancel="Cancel",
        )
        resp = window.run()
        if not resp.clicked:
            return

        value = resp.text.strip()
        if not value:
            self.notify_info("Vocabulary entry was empty.")
            return

        existing = None
        for entry in self._vocabulary_store.list_entries():
            if entry["canonical"].casefold() == value.casefold():
                existing = entry
                break

        try:
            entry = self._vocabulary_store.add(value)
        except ValueError as e:
            self.notify_error(str(e))
            return
        except Exception as e:
            self.notify_error(f"Failed to save vocabulary word: {e}")
            return

        self._refresh_vocabulary_menu()
        if existing is not None:
            self.notify_info(f"Vocabulary word already exists: {entry['canonical']}")
        else:
            self.notify_info(f"Saved vocabulary word: {entry['canonical']}")

    def _remove_vocabulary_word(self, sender):
        if self._vocabulary_store is None:
            self.notify_error("Vocabulary store is unavailable.")
            return

        entry_id = getattr(sender, "_vocab_entry_id", None)
        canonical = getattr(sender, "_vocab_canonical", sender.title)
        result = rumps.alert(
            title=f"{self._app_name} — Vocabulary",
            message=f"Remove '{canonical}' from saved vocabulary?",
            ok="Remove",
            cancel="Cancel",
        )
        if result not in (1, 1000):
            return

        try:
            removed = self._vocabulary_store.remove(entry_id)
        except Exception as e:
            self.notify_error(f"Failed to remove vocabulary word: {e}")
            return

        if removed:
            self._refresh_vocabulary_menu()
            self.notify_info(f"Removed vocabulary word: {canonical}")

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

    def _open_accessibility_settings(self, sender):
        if self._platform is None:
            self.notify_error("Accessibility settings are unavailable.")
            return
        try:
            self._platform.open_accessibility_settings()
        except Exception as e:
            self.notify_error(f"Failed to open Accessibility settings: {e}")

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
        self._on_main(lambda: rumps.notification(self._app_name, "Error", message))

    def notify_info(self, message: str):
        self._on_main(lambda: rumps.notification(self._app_name, "", message))

    def _copy_machine_id(self, sender):
        if self._demo_license_manager is None:
            return
        machine_id = self._demo_license_manager.machine_id()
        if self._platform is not None:
            self._platform.copy_text(machine_id)
        self.notify_info(f"Machine ID copied: {machine_id}")

    def _import_license_file(self, sender):
        if self._demo_license_manager is None:
            return

        def _pick_file():
            panel = AppKit.NSOpenPanel.openPanel()
            panel.setCanChooseFiles_(True)
            panel.setCanChooseDirectories_(False)
            panel.setAllowsMultipleSelection_(False)
            panel.setAllowedFileTypes_(["whisper-demo-license", "json"])
            panel.setAllowsOtherFileTypes_(True)
            if panel.runModal() != AppKit.NSModalResponseOK:
                return None
            url = panel.URL()
            return Path(str(url.path())) if url else None

        try:
            path = _pick_file()
            if path is None:
                return
            license_data = self._demo_license_manager.import_license(path)
        except Exception as e:
            self.notify_error(str(e))
            return

        self._refresh_demo_license_menu()
        self.notify_info(
            f"Activated demo license: {license_data['seat_code']} ({license_data['licensee']})"
        )

    def _quit(self, sender):
        if self._on_quit:
            self._on_quit()
        rumps.quit_application()
