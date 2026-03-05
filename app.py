#!/usr/bin/env python3
"""Whisper — Voice-to-text dictation for macOS via OpenAI API."""

import os
import sys
import threading

import numpy as np

# Add project root to path
sys.path.insert(0, os.path.dirname(__file__))

from config import load_config
from core.asr_api import OpenAITranscriber
from core.audio import AudioRecorder
from platform_layer.macos import MacOSPlatform
from ui.overlay import OverlayPanel
from ui.tray import WhisperTray


class WhisperApp:
    def __init__(self):
        self.cfg = load_config()
        self.platform = MacOSPlatform()
        self.overlay = None
        self.recorder = None
        self.transcriber = OpenAITranscriber(
            model=self.cfg.get("asr_model", "gpt-4o-mini-transcribe"),
            timeout=float(self.cfg.get("asr_timeout_seconds", 30.0)),
        )
        self.tray = None
        self._dictation_active = False
        self._accessibility_granted = False
        self._transcriber_lock = threading.Lock()
        self._min_samples = int(0.12 * self.cfg["sample_rate"])
        self._silence_rms_threshold = 0.006

    def _on_audio_level(self, level: float):
        """Called from audio thread with RMS level."""
        if self.overlay:
            self.overlay.update_audio_level(level)

    def _on_dictation(self):
        """Toggle dictation mode."""
        if self._dictation_active:
            self._stop_dictation()
        else:
            self._start_dictation()

    def _start_dictation(self):
        self._dictation_active = True
        try:
            self.recorder.start()
        except Exception as e:
            self._dictation_active = False
            if self.tray:
                self.tray.set_recording(False)
                self.tray.notify_error("Microphone unavailable. Check Microphone permission.")
            print(f"[audio] failed to start microphone: {e}")
            print("[audio] check: System Settings -> Privacy & Security -> Microphone")
            return

        if self.overlay:
            self.overlay.show()
        if self.tray:
            self.tray.set_recording(True)

    def _stop_dictation(self):
        self._dictation_active = False
        if self.tray:
            self.tray.set_recording(False)

        if self.overlay:
            self.overlay.set_state("processing")
        if self.tray:
            self.tray.set_processing(True)

        audio = self.recorder.stop()

        def transcribe_and_paste():
            try:
                if len(audio) < self._min_samples:
                    return
                if float(np.sqrt(np.mean(audio ** 2))) < self._silence_rms_threshold:
                    return

                with self._transcriber_lock:
                    text = self.transcriber.transcribe(audio, self.cfg["sample_rate"])

                if text:
                    if self._accessibility_granted:
                        self.platform.paste_text(text)
                    else:
                        self.platform.copy_text(text)
                        print(f"[clipboard] {text}")
            except Exception as e:
                print(f"[asr] transcription failed: {e}")
                if self.tray:
                    self.tray.notify_error(str(e))
            finally:
                if self.overlay:
                    self.overlay.hide()
                if self.tray:
                    self.tray.set_processing(False)

        t = threading.Thread(target=transcribe_and_paste, daemon=True)
        t.start()

    def _on_quit(self):
        if self.recorder:
            self.recorder.shutdown()
        self.platform.cleanup()

    def run(self):
        print("Whisper — Voice-to-Text (OpenAI)")
        print("=" * 40)

        self.tray = WhisperTray(on_quit=self._on_quit)

        self._accessibility_granted = self.platform.request_accessibility()
        if not self._accessibility_granted:
            print("Accessibility permission not granted.")
            print("  Paste (Cmd+V) will not work until granted.")
            print("  System Settings -> Privacy & Security -> Accessibility")

        self.recorder = AudioRecorder(
            sample_rate=self.cfg["sample_rate"],
            on_level=self._on_audio_level,
        )
        try:
            self.recorder.prepare()
            print("Audio engine ready.")
        except Exception as e:
            print(f"[audio] engine init warning: {e}")
            print("[audio] grant microphone permission and retry dictation hotkey.")
            if self.tray:
                self.tray.notify_error("Audio engine init failed. Check Microphone permission.")

        self.overlay = OverlayPanel()
        self.platform.register_hotkey(on_dictation=self._on_dictation)

        print()
        print("Ready!")
        print("  Option+Space -> Dictation (speak -> paste)")
        print("  Set API key from tray menu: Set OpenAI API Key...")
        print()

        self.tray.run()


if __name__ == "__main__":
    app = WhisperApp()
    app.run()
