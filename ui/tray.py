import webbrowser

import AppKit
import rumps

from config import load_config, save_config
from core.keychain import store_key, retrieve_key
from core.cleanup import PROVIDERS
from core.models import MODELS, MODEL_DISPLAY_NAMES, is_model_downloaded, delete_model_data

_ALL_PROVIDERS = list(PROVIDERS.keys()) + ["Custom"]
_NEEDS_MODEL_SETTING = {"OpenRouter", "Custom"}


class WhisperTray(rumps.App):
    """Menu bar app using rumps. Owns the NSApplication main runloop."""

    def __init__(self, on_quit=None, cfg=None, on_model_change=None):
        super().__init__("Whisper", icon=None, quit_button=None)
        self._on_quit = on_quit
        self._on_model_change = on_model_change
        self._cfg = cfg if cfg is not None else load_config()
        self._model_loading = False

        # Clean "W" in menu bar — minimal, recognizable
        self.title = "W"

        # --- Build Text Cleanup submenu ---
        cleanup_menu = rumps.MenuItem("Text Cleanup")

        self._enable_item = rumps.MenuItem(
            "Enable Cleanup", callback=self._toggle_cleanup
        )
        self._enable_item.state = self._cfg.get("cleanup_enabled", False)
        cleanup_menu.add(self._enable_item)
        cleanup_menu.add(None)  # separator

        # Provider radio group
        self._provider_items = {}
        current_provider = self._cfg.get("cleanup_provider", "DeepSeek")
        for name in _ALL_PROVIDERS:
            item = rumps.MenuItem(name, callback=self._select_provider)
            item.state = name == current_provider
            self._provider_items[name] = item
            cleanup_menu.add(item)

        cleanup_menu.add(None)  # separator

        # Current model info (non-clickable)
        self._model_info_item = rumps.MenuItem(
            self._model_info_title(), callback=None
        )
        cleanup_menu.add(self._model_info_item)

        self._set_key_item = rumps.MenuItem(
            "Set API Key...", callback=self._set_api_key
        )
        cleanup_menu.add(self._set_key_item)

        self._set_model_item = rumps.MenuItem(
            "Set Model...", callback=self._set_custom_model
        )
        if current_provider not in _NEEDS_MODEL_SETTING:
            self._set_model_item.set_callback(None)
            self._set_model_item.title = ""
        cleanup_menu.add(self._set_model_item)

        self._browse_models_item = rumps.MenuItem(
            "Browse Models...", callback=self._browse_models
        )
        if current_provider != "OpenRouter":
            self._browse_models_item.set_callback(None)
            self._browse_models_item.title = ""
        cleanup_menu.add(self._browse_models_item)

        self._set_url_item = rumps.MenuItem(
            "Set Custom URL...", callback=self._set_custom_url
        )
        if current_provider != "Custom":
            self._set_url_item.set_callback(None)
            self._set_url_item.title = ""
        cleanup_menu.add(self._set_url_item)

        # --- Build Model submenu ---
        model_menu = rumps.MenuItem("Model")
        self._model_items = {}
        current_model = self._cfg.get("model", "sensevoice")
        for key in MODELS:
            display = MODEL_DISPLAY_NAMES.get(key, key)
            item = rumps.MenuItem(display, callback=self._select_model)
            item._model_key = key
            item.state = key == current_model
            self._model_items[key] = item
            model_menu.add(item)
        self._update_model_titles()

        # Menu items
        self.menu = [
            rumps.MenuItem("Dictation: Option+Space", callback=None),
            None,  # separator
            model_menu,
            None,  # separator
            cleanup_menu,
            None,  # separator
            rumps.MenuItem("Quit Whisper", callback=self._quit),
        ]

    def _effective_model(self):
        """Return the model name that will actually be used."""
        provider = self._cfg.get("cleanup_provider", "DeepSeek")
        custom_model = self._cfg.get("cleanup_custom_model", "")
        if custom_model:
            return custom_model
        if provider == "Custom":
            return "(not set)"
        defn = PROVIDERS.get(provider)
        return defn[1] if defn else "unknown"

    def _model_info_title(self):
        return f"Model: {self._effective_model()}"

    def _update_model_info(self):
        self._model_info_item.title = self._model_info_title()

    def _save(self):
        save_config(self._cfg)

    def _update_model_titles(self):
        """Update model titles with status suffixes: ✕ (downloaded), ↓ (not downloaded)."""
        active = self._cfg.get("model", "sensevoice")
        models_dir = self._cfg.get("models_dir", "")
        for key, item in self._model_items.items():
            display = MODEL_DISPLAY_NAMES.get(key, key)
            if key == active:
                item.title = display
            elif is_model_downloaded(key, models_dir):
                item.title = f"{display}  ✕"
            else:
                item.title = f"{display}  ↓"

    def _select_model(self, sender):
        if self._model_loading:
            return
        model_key = sender._model_key
        previous_key = self._cfg.get("model")
        if model_key == previous_key:
            return

        models_dir = self._cfg.get("models_dir", "")
        display = MODEL_DISPLAY_NAMES.get(model_key, model_key)

        if is_model_downloaded(model_key, models_dir):
            # Downloaded but not active — ask: switch or delete?
            resp = rumps.alert(
                title="Whisper",
                message=display,
                ok="Switch",
                cancel="Cancel",
                other="Delete local data",
            )
            if resp == 1:  # Switch
                self._switch_to_model(model_key, previous_key)
            elif resp == -1:  # Delete
                delete_model_data(model_key, models_dir)
                self._update_model_titles()
                rumps.notification("Whisper", "", f"{display} data removed")
        else:
            # Not downloaded — download + switch
            self._switch_to_model(model_key, previous_key)

    def _switch_to_model(self, model_key, previous_key):
        """Update radio state and trigger model reload."""
        for item in self._model_items.values():
            item.state = False
        self._model_items[model_key].state = True
        self._cfg["model"] = model_key
        self._save()
        self._update_model_titles()
        if self._on_model_change:
            self._model_loading = True
            self._on_model_change(model_key, previous_key)

    def _toggle_cleanup(self, sender):
        sender.state = not sender.state
        self._cfg["cleanup_enabled"] = bool(sender.state)
        self._save()

    def _select_provider(self, sender):
        # Radio behavior: uncheck all, check selected
        for item in self._provider_items.values():
            item.state = False
        sender.state = True
        provider = str(sender.title)
        self._cfg["cleanup_provider"] = provider
        # Clear custom model when switching providers
        self._cfg["cleanup_custom_model"] = ""
        self._save()

        # Show/hide model setting
        if provider in _NEEDS_MODEL_SETTING:
            self._set_model_item.title = "Set Model..."
            self._set_model_item.set_callback(self._set_custom_model)
        else:
            self._set_model_item.title = ""
            self._set_model_item.set_callback(None)

        # Show/hide Browse Models (OpenRouter only)
        if provider == "OpenRouter":
            self._browse_models_item.title = "Browse Models..."
            self._browse_models_item.set_callback(self._browse_models)
        else:
            self._browse_models_item.title = ""
            self._browse_models_item.set_callback(None)

        # Show/hide Custom URL
        if provider == "Custom":
            self._set_url_item.title = "Set Custom URL..."
            self._set_url_item.set_callback(self._set_custom_url)
        else:
            self._set_url_item.title = ""
            self._set_url_item.set_callback(None)

        self._update_model_info()

    def _set_api_key(self, sender):
        provider = self._cfg.get("cleanup_provider", "DeepSeek")
        w = rumps.Window(
            message=f"Enter API key for {provider}:",
            title="Whisper — API Key",
            default_text="",
            ok="Save",
            cancel="Cancel",
            secure=True,
        )
        resp = w.run()
        if resp.clicked and resp.text.strip():
            store_key(provider, resp.text.strip())
            rumps.notification("Whisper", "", f"API key saved for {provider}.")

    def _set_custom_url(self, sender):
        current = self._cfg.get("cleanup_custom_base_url", "")
        w = rumps.Window(
            message="Enter the OpenAI-compatible base URL\n(e.g. https://api.example.com/v1):",
            title="Whisper — Custom URL",
            default_text=current,
            ok="Save",
            cancel="Cancel",
        )
        resp = w.run()
        if resp.clicked:
            self._cfg["cleanup_custom_base_url"] = resp.text.strip()
            self._save()

    def _browse_models(self, sender):
        webbrowser.open("https://openrouter.ai/models")

    def _set_custom_model(self, sender):
        provider = self._cfg.get("cleanup_provider", "DeepSeek")
        current = self._cfg.get("cleanup_custom_model", "")
        # Show default model as placeholder
        default = ""
        defn = PROVIDERS.get(provider)
        if defn:
            default = defn[1]
        w = rumps.Window(
            message=f"Enter model name for {provider}:\n(e.g. {default})",
            title="Whisper — Model",
            default_text=current or default,
            ok="Save",
            cancel="Cancel",
        )
        resp = w.run()
        if resp.clicked:
            self._cfg["cleanup_custom_model"] = resp.text.strip()
            self._save()
            self._update_model_info()

    def _on_main(self, fn):
        """Dispatch a function to the main thread (required for AppKit UI updates)."""
        if AppKit.NSThread.isMainThread():
            fn()
        else:
            AppKit.NSRunLoop.mainRunLoop().performInModes_block_(
                [AppKit.NSDefaultRunLoopMode, AppKit.NSEventTrackingRunLoopMode],
                fn,
            )

    def set_recording(self, active: bool):
        if active:
            self.title = "W·"  # Dot indicates active recording
        else:
            self.title = "W"

    def set_download_progress(self, pct: int):
        def _do():
            self.title = f"W ↓{pct}%"
        self._on_main(_do)

    def set_download_done(self, display_name: str | None):
        def _do():
            self._model_loading = False
            self.title = "W"
            self._update_model_titles()
            if display_name:
                rumps.notification("Whisper", "", f"Model switched to {display_name}")
        self._on_main(_do)

    def revert_model_selection(self, previous_key: str):
        """Revert radio selection to previous model after a failed switch."""
        def _do():
            for item in self._model_items.values():
                item.state = False
            if previous_key in self._model_items:
                self._model_items[previous_key].state = True
            self._cfg["model"] = previous_key
            self._save()
            self._update_model_titles()
        self._on_main(_do)

    def _quit(self, sender):
        if self._on_quit:
            self._on_quit()
        rumps.quit_application()
