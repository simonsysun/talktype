#!/usr/bin/env python3
"""Whisper — Voice-to-text dictation for macOS."""

import fcntl
import os
import sys
import threading
import time
from pathlib import Path

import AppKit
import AVFoundation as AVF
import numpy as np

# Add project root to path
sys.path.insert(0, os.path.dirname(__file__))

from config import load_config
from core.asr_api import (
    DEFAULT_OPENAI_ASR_MODEL,
    DEFAULT_OPENROUTER_ASR_MODEL,
    OPENAI_PROVIDER,
    OPENROUTER_PROVIDER,
    OpenAITranscriber,
)
from core.audio import AudioRecorder
from core.post_processor import post_process_transcript
from core.vocabulary import VocabularyStore
from platform_layer.macos import MacOSPlatform
from ui.overlay import OverlayPanel
from ui.tray import WhisperTray


class WhisperApp:
    def __init__(self):
        self.cfg = load_config()
        self.platform = MacOSPlatform()
        self.overlay = None
        self.recorder = None
        self.vocabulary = VocabularyStore()
        provider = self._current_provider()
        model = self._current_model(provider)
        self.transcriber = OpenAITranscriber(
            model=model,
            timeout=float(self.cfg.get("asr_timeout_seconds", 30.0)),
            provider=provider,
            openrouter_base_url=self.cfg.get(
                "openrouter_base_url", "https://openrouter.ai/api/v1"
            ),
        )
        self.tray = None
        self._dictation_active = False
        self._accessibility_granted = False
        self._transcriber_lock = threading.Lock()
        self._session_id = 0
        self._min_samples = int(0.12 * self.cfg["sample_rate"])
        self._silence_rms_threshold = float(self.cfg.get("silence_rms_threshold", 0.008))
        self._min_transcribe_rms = float(self.cfg.get("min_transcribe_rms", 0.003))
        self._clipboard_hint_shown = False
        self._microphone_granted = False
        self._mic_permission_request_in_flight = False
        self._start_after_mic_permission = False

        # Silence auto-stop
        self._silence_auto_stop = bool(self.cfg.get("silence_auto_stop_enabled", True))
        self._silence_timeout = float(self.cfg.get("silence_auto_stop_seconds", 20))
        self._last_speech_time = 0.0  # monotonic timestamp of last above-threshold audio

    def _current_provider(self) -> str:
        provider = (self.cfg.get("asr_provider", OPENAI_PROVIDER) or OPENAI_PROVIDER).lower()
        return OPENROUTER_PROVIDER if provider == OPENROUTER_PROVIDER else OPENAI_PROVIDER

    def _current_model(self, provider: str | None = None) -> str:
        p = provider or self._current_provider()
        if p == OPENROUTER_PROVIDER:
            return self.cfg.get("openrouter_asr_model", DEFAULT_OPENROUTER_ASR_MODEL)
        return self.cfg.get("asr_model", DEFAULT_OPENAI_ASR_MODEL)

    def _sync_transcriber_from_cfg(self):
        provider = self._current_provider()
        self.transcriber.provider = provider
        self.transcriber.model = self._current_model(provider)
        self.transcriber.timeout = float(self.cfg.get("asr_timeout_seconds", 30.0))
        self.transcriber.openrouter_base_url = self.cfg.get(
            "openrouter_base_url", "https://openrouter.ai/api/v1"
        )

    def _on_provider_change(self, provider: str):
        # Tray changed provider/model settings; reload and apply immediately.
        self.cfg = load_config()
        with self._transcriber_lock:
            self._sync_transcriber_from_cfg()
        print(f"[asr] provider switched to {provider}, model={self.transcriber.model}")

    def _on_audio_level(self, level: float):
        """Called from audio thread with RMS level."""
        if self.overlay:
            self.overlay.update_audio_level(level)

        if not self._dictation_active or not self._silence_auto_stop:
            return

        # level is already normalized: rms / 0.15, clamped to [0, 1]
        # Convert back to approximate RMS for threshold comparison.
        rms = level * 0.15
        now = time.monotonic()

        if rms >= self._silence_rms_threshold:
            self._last_speech_time = now
        elif self._last_speech_time > 0 and (now - self._last_speech_time) >= self._silence_timeout:
            # Prolonged silence — auto-stop
            self._last_speech_time = 0.0  # prevent re-firing
            print(f"[audio] silence for {self._silence_timeout}s, auto-stopping")
            self.platform.run_on_main(self._stop_dictation_on_silence)

    def _on_dictation(self):
        """Toggle dictation mode."""
        if self._dictation_active:
            self._stop_dictation()
        else:
            self._start_dictation()

    @staticmethod
    def _mic_auth_status() -> int:
        try:
            return int(
                AVF.AVCaptureDevice.authorizationStatusForMediaType_(AVF.AVMediaTypeAudio)
            )
        except Exception:
            # Avoid false negatives if API is unavailable in environment.
            return int(AVF.AVAuthorizationStatusAuthorized)

    @staticmethod
    def _mic_status_label(status: int) -> str:
        mapping = {
            int(AVF.AVAuthorizationStatusNotDetermined): "not_determined",
            int(AVF.AVAuthorizationStatusRestricted): "restricted",
            int(AVF.AVAuthorizationStatusDenied): "denied",
            int(AVF.AVAuthorizationStatusAuthorized): "authorized",
        }
        return mapping.get(int(status), f"unknown({status})")

    @staticmethod
    def _open_mic_settings():
        try:
            import subprocess as _sp
            _sp.Popen(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"])
        except Exception:
            pass

    def _handle_mic_permission_result(self, granted: bool):
        self._mic_permission_request_in_flight = False
        self._microphone_granted = bool(granted)
        print(f"[audio] microphone permission callback: {'granted' if granted else 'denied'}")

        if granted:
            should_start = self._start_after_mic_permission
            self._start_after_mic_permission = False
            if should_start:
                self._start_dictation()
            return

        self._start_after_mic_permission = False
        if self.tray:
            self.tray.notify_error(
                "Microphone access denied. Enable in System Settings → Privacy → Microphone."
            )
        self._open_mic_settings()

    def _start_dictation(self):
        # Check microphone permission (non-blocking).
        if not self._microphone_granted:
            status = self._mic_auth_status()
            if status == int(AVF.AVAuthorizationStatusAuthorized):
                self._microphone_granted = True
            elif status == int(AVF.AVAuthorizationStatusNotDetermined):
                # Trigger system permission dialog non-blocking.
                # Can't block main thread — dialog needs the run loop to display.
                self._start_after_mic_permission = True
                if self._mic_permission_request_in_flight:
                    print("[audio] microphone: permission request already in flight")
                else:
                    self._mic_permission_request_in_flight = True
                    print("[audio] microphone: not_determined — requesting permission")
                    AVF.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
                        AVF.AVMediaTypeAudio,
                        lambda granted: self.platform.run_on_main(
                            lambda: self._handle_mic_permission_result(bool(granted))
                        ),
                    )
                if self.tray:
                    self.tray.notify_info(
                        "Microphone permission required. Please allow the system prompt."
                    )
                return
            else:
                # denied or restricted
                self._start_after_mic_permission = False
                print(f"[audio] microphone: {self._mic_status_label(status)}")
                if self.tray:
                    self.tray.notify_error(
                        "Microphone access denied. Enable in System Settings → Privacy → Microphone."
                    )
                self._open_mic_settings()
                return

        self._dictation_active = True
        self._last_speech_time = time.monotonic()
        try:
            self.recorder.start()
            # Promote session only after recorder actually starts.
            self._session_id += 1
        except Exception as e:
            self._dictation_active = False
            if self.tray:
                self.tray.set_recording(False)
                self.tray.set_processing(False)
                self.tray.notify_error("Microphone unavailable. Check Microphone permission.")
            if self.overlay and self.overlay.is_visible:
                self.overlay.hide()
            print(f"[audio] failed to start microphone: {e}")
            print("[audio] check: System Settings -> Privacy & Security -> Microphone")
            self._open_mic_settings()
            return

        if self.overlay:
            self.overlay.show()
        if self.tray:
            self.tray.set_recording(True)

    def _stop_dictation_on_silence(self):
        """Called from main thread when silence auto-stop fires."""
        if not self._dictation_active:
            return
        self._stop_dictation(auto_stopped=True)

    def _stop_dictation(self, auto_stopped: bool = False):
        self._dictation_active = False
        self._last_speech_time = 0.0
        if self.tray:
            self.tray.set_recording(False)

        if self.overlay:
            self.overlay.set_state("processing")
        if self.tray:
            self.tray.set_processing(True)

        try:
            audio = self.recorder.stop()
        except Exception as e:
            print(f"[audio] failed to stop microphone: {e}")
            if self.overlay:
                self.overlay.hide()
            if self.tray:
                self.tray.set_processing(False)
                self.tray.notify_error("Failed to stop recording cleanly. Please try again.")
            return
        session = self._session_id

        def transcribe_and_paste():
            try:
                if len(audio) < self._min_samples:
                    if self.tray:
                        self.tray.notify_info("Recording too short.")
                    return
                rms = float(np.sqrt(np.mean(audio ** 2)))
                print(f"[audio] captured samples={len(audio)} rms={rms:.5f}")
                if rms == 0.0:
                    # All-zero buffer — mic is silently blocked by macOS
                    print("[audio] all-zero audio — microphone access likely blocked")
                    self._microphone_granted = False
                    if self.tray:
                        self.tray.notify_error(
                            "Microphone blocked. Enable in System Settings → Privacy → Microphone."
                        )
                    self._open_mic_settings()
                    return
                if rms < self._min_transcribe_rms:
                    if self.tray:
                        self.tray.notify_info(
                            "No speech detected. Speak louder or check microphone input."
                        )
                    return

                vocabulary_hints = self.vocabulary.get_active_vocabulary()
                with self._transcriber_lock:
                    text = self.transcriber.transcribe(
                        audio,
                        self.cfg["sample_rate"],
                        vocabulary_hints=vocabulary_hints,
                    )
                text = post_process_transcript(text, self.vocabulary.list_entries())

                if text:
                    if self._session_id != session:
                        # Stale result — user already started a new session
                        self.platform.copy_text(text)
                        return
                    if self._accessibility_granted:
                        self.platform.paste_text(text)
                    else:
                        self.platform.copy_text(text)
                        if self.tray and not self._clipboard_hint_shown:
                            self.tray.notify_info(
                                "Text copied to clipboard. Grant Accessibility for auto-paste."
                            )
                            self._clipboard_hint_shown = True
                        print(f"[clipboard] {text}")
                elif self.tray:
                    self.tray.notify_info("No text recognized. Try speaking more clearly.")
            except RuntimeError as e:
                # Our own errors (e.g., "API key missing") — show as-is
                print(f"[asr] {e}")
                if self.tray:
                    self.tray.notify_error(str(e))
            except Exception as e:
                print(f"[asr] transcription failed: {e}")
                if self.tray:
                    self.tray.notify_error("Transcription failed. Check network and API key.")
            finally:
                if self._session_id == session:
                    if self.overlay:
                        self.overlay.hide()
                    if self.tray:
                        self.tray.set_processing(False)
                    if auto_stopped and self.tray:
                        self.tray.notify_info("Stopped after silence.")

        t = threading.Thread(target=transcribe_and_paste, daemon=True)
        t.start()

    def _on_quit(self):
        if self.recorder:
            self.recorder.shutdown()
        self.platform.cleanup()

    def run(self):
        print("Whisper — Voice-to-Text")
        print("=" * 40)

        # In dev-launcher mode the child interpreter can appear as "Python" in the Dock.
        # Force accessory activation policy so the app stays menu-bar-only.
        try:
            AppKit.NSApplication.sharedApplication().setActivationPolicy_(
                AppKit.NSApplicationActivationPolicyAccessory
            )
        except Exception as e:
            print(f"[app] failed to set activation policy: {e}")

        if self.cfg.get("launch_at_login", False):
            try:
                if not self.platform.is_launch_at_login_enabled():
                    self.platform.set_launch_at_login(True)
            except Exception as e:
                print(f"[launch] failed to ensure launch-at-login: {e}")

        self.tray = WhisperTray(
            on_quit=self._on_quit,
            platform=self.platform,
            on_provider_change=self._on_provider_change,
            is_dictating=lambda: self._dictation_active,
            vocabulary_store=self.vocabulary,
        )

        # Passive check only — do NOT call requestAccess here.
        # The run loop isn't active yet; a blocking request would auto-deny.
        status = self._mic_auth_status()
        self._microphone_granted = status == int(AVF.AVAuthorizationStatusAuthorized)
        print(f"[audio] microphone status at startup: {self._mic_status_label(status)}")

        self._accessibility_granted = self.platform.request_accessibility()
        if not self._accessibility_granted:
            print("Accessibility permission not granted.")
            print("  Paste (Cmd+V) will not work until granted.")
            print("  System Settings -> Privacy & Security -> Accessibility")
            if self.tray:
                self.tray.notify_info(
                    "Accessibility not granted. Transcription will copy to clipboard only."
                )

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
        print(
            f"  ASR provider: {self._current_provider()} | model: {self._current_model()}"
        )
        print("  Set API key from tray menu: <Provider> API Key...")
        if self._silence_auto_stop:
            print(f"  Silence auto-stop: {self._silence_timeout}s")
        print()

        self.tray.run()


def _ensure_single_instance():
    """Prevent duplicate instances. Exit silently if another is running."""
    import AppKit

    bundle_id = AppKit.NSBundle.mainBundle().bundleIdentifier()
    if bundle_id and bundle_id != "org.python.python":
        # Bundled app — check by bundle identifier
        running = AppKit.NSRunningApplication.runningApplicationsWithBundleIdentifier_(bundle_id)
        if len(running) > 1:
            print("[app] Another instance is already running. Exiting.")
            sys.exit(0)
    else:
        # Dev mode — use file lock
        lock_dir = Path.home() / ".whisper"
        lock_dir.mkdir(parents=True, exist_ok=True)
        lock_file = lock_dir / ".lock"
        # Keep the file handle alive for the process lifetime
        _ensure_single_instance._lock_fh = open(lock_file, "w")
        try:
            fcntl.flock(_ensure_single_instance._lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("[app] Another instance is already running. Exiting.")
            sys.exit(0)


def _setup_logging():
    """Redirect stdout/stderr to log file for bundled (--windowed) app."""
    try:
        log_dir = Path.home() / "Library" / "Logs" / "Whisper"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_file = log_dir / "whisper.log"
        if log_file.exists():
            log_file.rename(log_dir / "whisper.log.prev")
        fh = open(log_file, "w", buffering=1)  # line-buffered
        sys.stdout = sys.stderr = fh
    except Exception:
        pass  # keep default stdout/stderr


if __name__ == "__main__":
    _ensure_single_instance()
    _setup_logging()
    app = WhisperApp()
    app.run()
