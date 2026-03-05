import threading
import ctypes
import numpy as np
import AVFoundation as AVF


class AudioRecorder:
    """Records audio using AVAudioEngine.

    The engine is created once at startup (fast re-start). The microphone tap is
    installed only while recording, so the orange mic indicator only appears
    during active dictation.
    """

    def __init__(self, sample_rate: int = 16000, on_level=None):
        self.sample_rate = sample_rate
        self.on_level = on_level
        self._buffer = []
        self._engine = None
        self._recording = False
        self._lock = threading.Lock()
        self._hw_sample_rate = 48000
        self._hw_format = None
        self._ready = False
        self._tap_installed = False

    def _tap_callback(self, buffer, when):
        frame_length = buffer.frameLength()
        if frame_length == 0:
            return

        ch0 = buffer.floatChannelData()[0]
        arr = self._extract_float_channel(ch0, frame_length)

        with self._lock:
            recording = self._recording
            if recording:
                self._buffer.append(arr)

        if self.on_level and recording:
            rms = float(np.sqrt(np.mean(arr ** 2)))
            level = min(1.0, rms / 0.15)
            try:
                self.on_level(level)
            except Exception as e:
                print(f"[audio] level callback failed: {e}")

    @staticmethod
    def _extract_float_channel(ch0, frame_length: int) -> np.ndarray:
        """Extract channel 0 from AVAudioPCMBuffer.

        Prefer PyObjC sequence access for correctness across macOS/PyObjC variants.
        Some pointer-cast fast paths can silently yield zeros on certain systems.
        """
        try:
            return np.fromiter((ch0[i] for i in range(frame_length)), dtype=np.float32, count=frame_length)
        except Exception:
            pass

        try:
            ptr = ctypes.cast(ch0, ctypes.POINTER(ctypes.c_float))
            return np.ctypeslib.as_array(ptr, shape=(frame_length,)).copy()
        except Exception:
            return np.array([ch0[i] for i in range(frame_length)], dtype=np.float32)

    def prepare(self):
        """Create the audio engine once. Call at app startup."""
        self._engine = AVF.AVAudioEngine.alloc().init()
        input_node = self._engine.inputNode()
        self._hw_format = input_node.outputFormatForBus_(0)
        self._hw_sample_rate = int(self._hw_format.sampleRate())
        print(f"[audio] hardware sample rate: {self._hw_sample_rate} Hz")
        self._ready = True

    def start(self):
        """Start recording — installs tap and starts engine."""
        if not self._ready:
            self.prepare()
        with self._lock:
            if self._recording:
                return
            self._buffer = []
            self._recording = True

        input_node = self._engine.inputNode()
        try:
            if self._tap_installed:
                input_node.removeTapOnBus_(0)
                self._tap_installed = False
            input_node.installTapOnBus_bufferSize_format_block_(
                0, 4800, self._hw_format, self._tap_callback
            )
            self._tap_installed = True
            success, error = self._engine.startAndReturnError_(None)
        except Exception:
            success, error = False, "tap install failed"

        if not success:
            # If start fails, ensure tap/recording state is cleaned up so next retry can work.
            with self._lock:
                self._recording = False
                self._buffer = []
            try:
                input_node.removeTapOnBus_(0)
            except Exception:
                pass
            self._tap_installed = False
            raise RuntimeError(f"Failed to start audio engine: {error}")

    def stop(self) -> np.ndarray:
        """Stop recording and return audio as numpy array (float32, 16kHz mono)."""
        with self._lock:
            if not self._recording and not self._tap_installed:
                return np.array([], dtype=np.float32)
            self._recording = False
            chunks = self._buffer
            self._buffer = []

        if self._engine:
            try:
                if self._tap_installed:
                    self._engine.inputNode().removeTapOnBus_(0)
            except Exception:
                pass
            self._tap_installed = False
            self._engine.stop()

        if chunks:
            audio = np.concatenate(chunks)
        else:
            audio = np.array([], dtype=np.float32)

        # Resample from hardware rate to target rate
        if self._hw_sample_rate != self.sample_rate and len(audio) > 0:
            if self._hw_sample_rate % self.sample_rate == 0:
                # Integer ratio — simple decimation (48k→16k)
                audio = audio[:: self._hw_sample_rate // self.sample_rate]
            else:
                # Non-integer ratio (e.g. 44.1k→16k) — linear interpolation
                n_target = int(len(audio) * self.sample_rate / self._hw_sample_rate)
                x_old = np.linspace(0, 1, len(audio), endpoint=False)
                x_new = np.linspace(0, 1, n_target, endpoint=False)
                audio = np.interp(x_new, x_old, audio).astype(np.float32)

        return audio

    def shutdown(self):
        """Tear down the audio engine. Call on app quit."""
        if self._engine:
            try:
                if self._tap_installed:
                    self._engine.inputNode().removeTapOnBus_(0)
            except Exception:
                pass
            self._tap_installed = False
            self._engine.stop()
            self._engine = None
            self._ready = False

    @property
    def is_recording(self) -> bool:
        return self._recording
