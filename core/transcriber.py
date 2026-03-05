import threading

import sherpa_onnx
import numpy as np


class Transcriber:
    """Offline speech-to-text using sherpa-onnx."""

    def __init__(self, model_type: str = "sensevoice", num_threads: int = 2,
                 model_path: str = "", tokens_path: str = "",
                 encoder_path: str = "", decoder_path: str = ""):
        self.model_type = model_type
        self._lock = threading.Lock()

        if model_type == "sensevoice":
            self.recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
                model=model_path,
                tokens=tokens_path,
                num_threads=num_threads,
                use_itn=True,
            )
        elif model_type == "paraformer":
            self.recognizer = sherpa_onnx.OfflineRecognizer.from_paraformer(
                paraformer=model_path,
                tokens=tokens_path,
                num_threads=num_threads,
            )
        elif model_type == "whisper":
            self.recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
                encoder=encoder_path,
                decoder=decoder_path,
                tokens=tokens_path,
                num_threads=num_threads,
                language="",       # auto-detect per utterance
                decoding_method="greedy_search",
            )
        else:
            raise ValueError(f"Unknown model type: {model_type!r}")

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        """Transcribe audio numpy array (float32, mono) to text."""
        if len(audio) == 0:
            return ""

        with self._lock:
            stream = self.recognizer.create_stream()
            stream.accept_waveform(sample_rate, audio.tolist())
            self.recognizer.decode_stream(stream)
            return stream.result.text.strip()
