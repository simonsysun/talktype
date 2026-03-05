import threading
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

    def _tap_callback(self, buffer, when):
        frame_length = buffer.frameLength()
        if frame_length == 0:
            return

        # Extract channel 0 float data from AVAudioPCMBuffer
        ch0 = buffer.floatChannelData()[0]
        arr = np.array([ch0[i] for i in range(frame_length)], dtype=np.float32)

        with self._lock:
            recording = self._recording
            if recording:
                self._buffer.append(arr)

        if self.on_level and recording:
            rms = float(np.sqrt(np.mean(arr ** 2)))
            level = min(1.0, rms / 0.15)
            self.on_level(level)

    def prepare(self):
        """Create the audio engine once. Call at app startup."""
        self._engine = AVF.AVAudioEngine.alloc().init()
        input_node = self._engine.inputNode()
        self._hw_format = input_node.outputFormatForBus_(0)
        self._hw_sample_rate = int(self._hw_format.sampleRate())
        if self._hw_sample_rate % self.sample_rate != 0:
            raise RuntimeError(
                f"Hardware sample rate {self._hw_sample_rate} is not a multiple "
                f"of {self.sample_rate}. Use a different audio device."
            )
        self._ready = True

    def start(self):
        """Start recording — installs tap and starts engine."""
        if not self._ready:
            self.prepare()
        with self._lock:
            self._buffer = []
            self._recording = True

        input_node = self._engine.inputNode()
        input_node.installTapOnBus_bufferSize_format_block_(
            0, 4800, self._hw_format, self._tap_callback
        )

        success, error = self._engine.startAndReturnError_(None)
        if not success:
            raise RuntimeError(f"Failed to start audio engine: {error}")

    def stop(self) -> np.ndarray:
        """Stop recording and return audio as numpy array (float32, 16kHz mono)."""
        with self._lock:
            self._recording = False
            chunks = self._buffer
            self._buffer = []

        if self._engine:
            input_node = self._engine.inputNode()
            input_node.removeTapOnBus_(0)
            self._engine.stop()

        if chunks:
            audio = np.concatenate(chunks)
        else:
            audio = np.array([], dtype=np.float32)

        # Downsample from hardware rate to 16kHz
        ratio = self._hw_sample_rate // self.sample_rate
        if ratio > 1 and len(audio) > 0:
            audio = audio[::ratio]

        return audio

    def shutdown(self):
        """Tear down the audio engine. Call on app quit."""
        if self._engine:
            try:
                self._engine.inputNode().removeTapOnBus_(0)
            except Exception:
                pass
            self._engine.stop()
            self._engine = None
            self._ready = False

    @property
    def is_recording(self) -> bool:
        return self._recording
