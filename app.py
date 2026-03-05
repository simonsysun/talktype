#!/usr/bin/env python3
"""Whisper — Free local voice-to-text dictation for macOS."""

import sys
import os
import threading

# Add project root to path
sys.path.insert(0, os.path.dirname(__file__))

from config import load_config
from core.models import ensure_all_models, MODEL_DISPLAY_NAMES
from core.audio import AudioRecorder
from core.transcriber import Transcriber
from core.cleanup import cleanup_text
from ui.overlay import OverlayPanel
from ui.tray import WhisperTray

from platform_layer.macos import MacOSPlatform


class WhisperApp:
    def __init__(self):
        self.cfg = load_config()
        self.platform = MacOSPlatform()
        self.overlay = None
        self.recorder = None
        self.transcriber = None
        self.tray = None
        self._dictation_active = False
        self._accessibility_granted = False
        self._model_loading = False
        self._transcriber_lock = threading.Lock()

    def _init_models(self):
        """Download and load models."""
        print("Checking models...")
        paths = ensure_all_models(self.cfg["models_dir"], self.cfg["model"])
        print("Loading transcriber...")
        self.transcriber = Transcriber(
            model_type=self.cfg["model"],
            model_path=paths.get("model", ""),
            tokens_path=paths["tokens"],
            encoder_path=paths.get("encoder", ""),
            decoder_path=paths.get("decoder", ""),
        )
        print("Models loaded.")

    def _reload_model(self, model_name, previous_model=None):
        """Reload transcriber with a different model in a background thread."""
        if self._model_loading:
            return
        if previous_model is None:
            previous_model = model_name  # no-op revert on failure
        self._model_loading = True
        display_name = MODEL_DISPLAY_NAMES.get(model_name, model_name)

        def _do_reload():
            try:
                print(f"Switching to model: {model_name}...")

                def on_progress(downloaded, total):
                    if total <= 0:
                        return
                    pct = int(downloaded * 100 / total)
                    if self.tray:
                        self.tray.set_download_progress(pct)

                paths = ensure_all_models(
                    self.cfg["models_dir"], model_name, on_progress=on_progress
                )
                new_transcriber = Transcriber(
                    model_type=model_name,
                    model_path=paths.get("model", ""),
                    tokens_path=paths["tokens"],
                    encoder_path=paths.get("encoder", ""),
                    decoder_path=paths.get("decoder", ""),
                )
                with self._transcriber_lock:
                    self.transcriber = new_transcriber
                print(f"Model {model_name} loaded.")
                if self.tray:
                    self.tray.set_download_done(display_name)
            except Exception as e:
                print(f"Model switch failed: {e}")
                if self.tray:
                    self.tray.revert_model_selection(previous_model)
                    self.tray.set_download_done(None)
            finally:
                self._model_loading = False

        t = threading.Thread(target=_do_reload, daemon=True)
        t.start()

    def _on_audio_level(self, level: float):
        """Called from audio thread with RMS level."""
        if self.overlay:
            self.overlay.update_audio_level(level)

    def _on_dictation(self):
        """Toggle dictation mode."""
        if self._model_loading:
            return
        if self._dictation_active:
            self._stop_dictation()
        else:
            self._start_dictation()

    def _start_dictation(self):
        self._dictation_active = True
        self.recorder.start()
        if self.overlay:
            self.overlay.show()
        if self.tray:
            self.tray.set_recording(True)

    def _stop_dictation(self):
        self._dictation_active = False
        if self.tray:
            self.tray.set_recording(False)

        # Hide overlay immediately — processing happens in background
        if self.overlay:
            self.overlay.hide()

        # Stop recording and transcribe in background thread
        audio = self.recorder.stop()

        def transcribe_and_paste():
            if len(audio) < 1600:  # Less than 0.1s of audio
                return

            with self._transcriber_lock:
                transcriber = self.transcriber
            if transcriber is None:
                return
            text = transcriber.transcribe(audio, self.cfg["sample_rate"])
            if text:
                output = text
                if self.cfg.get("cleanup_enabled"):
                    cleaned = cleanup_text(
                        text,
                        provider=self.cfg.get("cleanup_provider", "DeepSeek"),
                        custom_base_url=self.cfg.get("cleanup_custom_base_url", ""),
                        custom_model=self.cfg.get("cleanup_custom_model", ""),
                    )
                    if cleaned:
                        output = cleaned
                        print(f"[cleanup] {text!r} → {cleaned!r}")
                if self._accessibility_granted:
                    self.platform.paste_text(output)
                else:
                    self.platform.copy_text(output)
                    print(f"[clipboard] {output}")

        t = threading.Thread(target=transcribe_and_paste, daemon=True)
        t.start()

    def _on_quit(self):
        if self.recorder:
            self.recorder.shutdown()
        self.platform.cleanup()

    def run(self):
        print("Whisper — Local Voice-to-Text")
        print("=" * 40)

        # Check accessibility permission
        self._accessibility_granted = self.platform.request_accessibility()
        if not self._accessibility_granted:
            print("⚠ Accessibility permission not granted.")
            print("  Paste (Cmd+V) will not work until granted.")
            print("  → System Settings → Privacy & Security → Accessibility")
            print("  Then restart Whisper for full functionality.")

        # Init models (downloads if needed)
        self._init_models()

        # Start persistent audio engine (eliminates hotkey latency)
        self.recorder = AudioRecorder(
            sample_rate=self.cfg["sample_rate"],
            on_level=self._on_audio_level,
        )
        self.recorder.prepare()
        print("Audio engine ready.")

        # Create overlay
        self.overlay = OverlayPanel()

        # Register hotkey
        self.platform.register_hotkey(on_dictation=self._on_dictation)

        print()
        print("Ready!")
        print("  Option+Space → Dictation (speak → paste)")
        print()

        # Start menu bar app (this blocks — runs NSApplication main loop)
        self.tray = WhisperTray(on_quit=self._on_quit, cfg=self.cfg, on_model_change=self._reload_model)
        self.tray.run()


if __name__ == "__main__":
    app = WhisperApp()
    app.run()
