import threading

import AppKit
import rumps

from config import load_config, save_config
from core.asr_api import (
    DEFAULT_OPENAI_ASR_MODEL,
    DEFAULT_OPENROUTER_ASR_MODEL,
    OPENAI_ASR_ACCOUNT,
    OPENAI_PROVIDER,
    OPENROUTER_ASR_ACCOUNT,
    OPENROUTER_PROVIDER,
)
from core.keychain import delete_key, retrieve_key, store_key


class WhisperTray(rumps.App):
    """Menu bar app using rumps. Owns the NSApplication main runloop."""

    def __init__(
        self,
        on_quit=None,
        platform=None,
        on_provider_change=None,
        is_dictating=None,
        vocabulary_store=None,
    ):
        super().__init__("Whisper", icon=None, quit_button=None)
        self._on_quit = on_quit
        self._platform = platform
        self._on_provider_change = on_provider_change
        self._is_dictating = is_dictating
        self._vocabulary_store = vocabulary_store
        self._cfg = load_config()
        self._validation_seq = 0
        self._provider = self._normalize_provider(self._cfg.get("asr_provider", OPENAI_PROVIDER))

        self.title = "W"

        self._asr_item = rumps.MenuItem("", callback=None)
        self._key_status_item = rumps.MenuItem("", callback=None)

        self._provider_openai_item = rumps.MenuItem("Use OpenAI", callback=self._use_openai)
        self._provider_openrouter_item = rumps.MenuItem("Use OpenRouter", callback=self._use_openrouter)
        self._key_menu_item = rumps.MenuItem("ASR API Key...", callback=self._set_api_key)
        self._vocab_menu = rumps.MenuItem("Vocabulary")

        self._launch_item = rumps.MenuItem(
            "Launch at Login", callback=self._toggle_launch_at_login
        )
        self._launch_item.state = self._initial_launch_state()

        self.menu = [
            rumps.MenuItem("Dictation: Option+Space", callback=None),
            self._asr_item,
            self._key_status_item,
            None,
            self._provider_openai_item,
            self._provider_openrouter_item,
            self._key_menu_item,
            self._vocab_menu,
            self._launch_item,
            None,
            rumps.MenuItem("Quit Whisper", callback=self._quit),
        ]

        self._refresh_provider_ui()
        self._refresh_key_status()
        self._refresh_vocabulary_menu()

        # Validate existing key on startup for current provider.
        key = self._current_api_key()
        if key:
            self._validate_key(key, notify=False)

    @staticmethod
    def _normalize_provider(provider: str) -> str:
        p = (provider or OPENAI_PROVIDER).strip().lower()
        return OPENROUTER_PROVIDER if p == OPENROUTER_PROVIDER else OPENAI_PROVIDER

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

    def _provider_label(self, provider: str | None = None) -> str:
        p = self._normalize_provider(provider or self._provider)
        return "OpenRouter" if p == OPENROUTER_PROVIDER else "OpenAI"

    def _provider_account(self, provider: str | None = None) -> str:
        p = self._normalize_provider(provider or self._provider)
        return OPENROUTER_ASR_ACCOUNT if p == OPENROUTER_PROVIDER else OPENAI_ASR_ACCOUNT

    def _provider_model(self, provider: str | None = None) -> str:
        p = self._normalize_provider(provider or self._provider)
        if p == OPENROUTER_PROVIDER:
            return self._cfg.get("openrouter_asr_model", DEFAULT_OPENROUTER_ASR_MODEL)
        return self._cfg.get("asr_model", DEFAULT_OPENAI_ASR_MODEL)

    def _current_api_key(self, provider: str | None = None) -> str | None:
        p = self._normalize_provider(provider or self._provider)
        if p == OPENROUTER_PROVIDER:
            return retrieve_key(OPENROUTER_ASR_ACCOUNT) or retrieve_key("OpenRouter")
        return retrieve_key(OPENAI_ASR_ACCOUNT) or retrieve_key("OpenAI")

    def _delete_provider_keys(self, provider: str | None = None) -> None:
        p = self._normalize_provider(provider or self._provider)
        if p == OPENROUTER_PROVIDER:
            delete_key(OPENROUTER_ASR_ACCOUNT)
            delete_key("OpenRouter")
            return
        delete_key(OPENAI_ASR_ACCOUNT)
        delete_key("OpenAI")

    def _refresh_provider_ui(self):
        label = self._provider_label()
        model = self._provider_model()
        self._asr_item.title = f"ASR: {label} / {model}"
        self._provider_openai_item.state = 1 if self._provider == OPENAI_PROVIDER else 0
        self._provider_openrouter_item.state = 1 if self._provider == OPENROUTER_PROVIDER else 0
        self._key_menu_item.title = f"{label} API Key..."

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

    def _set_key_status(self, title: str, checked: bool) -> None:
        def _do():
            self._key_status_item.title = title
            self._key_status_item.state = 1 if checked else 0

        self._on_main(_do)

    def _invalidate_validations(self):
        # Mark any in-flight validation result as stale.
        self._validation_seq += 1

    def _set_provider(self, provider: str):
        provider = self._normalize_provider(provider)
        if provider == self._provider:
            return

        if self._is_dictating and self._is_dictating():
            self.notify_info("Cannot switch provider during dictation.")
            return

        prev_provider = self._provider

        self._invalidate_validations()
        self._provider = provider
        self._cfg["asr_provider"] = provider
        if provider == OPENROUTER_PROVIDER:
            self._cfg.setdefault("openrouter_asr_model", DEFAULT_OPENROUTER_ASR_MODEL)
            self._cfg.setdefault("openrouter_base_url", "https://openrouter.ai/api/v1")
        else:
            self._cfg.setdefault("asr_model", DEFAULT_OPENAI_ASR_MODEL)
        self._save_cfg()

        self._refresh_provider_ui()
        self._refresh_key_status()

        key = self._current_api_key(provider)
        if key:
            self._validate_key(key, notify=False)
        else:
            # No key for this provider — prompt immediately; revert if cancelled
            if not self._prompt_new_key():
                self._provider = prev_provider
                self._cfg["asr_provider"] = prev_provider
                self._save_cfg()
                self._refresh_provider_ui()
                self._refresh_key_status()
                self.notify_info("Provider switch cancelled (no API key entered).")
                return

        if self._on_provider_change:
            try:
                self._on_provider_change(provider)
            except Exception as e:
                print(f"[tray] provider change callback failed: {e}")

        self.notify_info(f"ASR provider switched to {self._provider_label(provider)}.")

    def _use_openai(self, sender):
        self._set_provider(OPENAI_PROVIDER)

    def _use_openrouter(self, sender):
        self._set_provider(OPENROUTER_PROVIDER)

    def _validate_key(self, key: str, notify: bool = True):
        """Validate the current provider API key in a background thread."""
        provider = self._provider
        label = self._provider_label(provider)
        self._invalidate_validations()
        seq = self._validation_seq
        self._set_key_status("API Key: Checking...", checked=False)

        def _check():
            try:
                from openai import OpenAI

                kwargs = {"api_key": key, "timeout": 10.0}
                if provider == OPENROUTER_PROVIDER:
                    kwargs["base_url"] = self._cfg.get(
                        "openrouter_base_url", "https://openrouter.ai/api/v1"
                    )
                client = OpenAI(**kwargs)
                client.models.list()
                if seq != self._validation_seq or provider != self._provider:
                    return
                self._set_key_status("API Key: Connected", checked=True)
                if notify:
                    self.notify_info(f"{label} API key verified.")
            except Exception as e:
                if seq != self._validation_seq or provider != self._provider:
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
                    current = self._current_api_key(provider)
                    if current != key:
                        return
                    self._delete_provider_keys(provider)
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
        label = self._provider_label()
        existing = self._current_api_key()
        if existing:
            masked = self._mask_key(existing)
            result = rumps.alert(
                title=f"Whisper — {label} API Key",
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
                rumps.notification("Whisper", "", f"{label} API key cleared.")
            # Done/cancel or unknown code -> no-op
        else:
            self._prompt_new_key()

    def _prompt_new_key(self) -> bool:
        """Prompt user for API key. Returns True if key was saved."""
        label = self._provider_label()
        w = rumps.Window(
            message=f"Enter {label} API key for speech transcription:",
            title=f"Whisper — {label} API Key",
            default_text="",
            ok="Save",
            cancel="Cancel",
            secure=True,
        )
        resp = w.run()
        if resp.clicked and resp.text.strip():
            key = resp.text.strip()
            if store_key(self._provider_account(), key):
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
            title="Whisper — Vocabulary",
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
            title="Whisper — Vocabulary",
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
