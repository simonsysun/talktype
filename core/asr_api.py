import io
import wave

import numpy as np
from openai import OpenAI

from core.keychain import retrieve_key


DEFAULT_OPENAI_ASR_MODEL = "gpt-4o-mini-transcribe"
OPENAI_ASR_ACCOUNT = "OpenAI-ASR"


class OpenAITranscriber:
    """Speech-to-text via OpenAI transcription API."""

    def __init__(self, model: str = DEFAULT_OPENAI_ASR_MODEL, timeout: float = 30.0):
        self.model = model
        self.timeout = timeout
        self._cached_key = None
        self._client = None

    @staticmethod
    def _to_wav_bytes(audio: np.ndarray, sample_rate: int) -> bytes:
        pcm = np.clip(audio, -1.0, 1.0)
        pcm16 = (pcm * 32767.0).astype(np.int16)

        buf = io.BytesIO()
        with wave.open(buf, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm16.tobytes())
        return buf.getvalue()

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        if len(audio) == 0:
            return ""

        api_key = retrieve_key(OPENAI_ASR_ACCOUNT) or retrieve_key("OpenAI")
        if not api_key:
            raise RuntimeError(
                "OpenAI API key is missing. Set it from Whisper tray menu."
            )
        if self._client is None or self._cached_key != api_key:
            self._client = OpenAI(api_key=api_key, timeout=self.timeout)
            self._cached_key = api_key

        wav_bytes = self._to_wav_bytes(audio, sample_rate)
        file_obj = io.BytesIO(wav_bytes)
        file_obj.name = "speech.wav"

        resp = self._client.audio.transcriptions.create(
            model=self.model,
            file=file_obj,
        )
        text = getattr(resp, "text", "")
        if not text and isinstance(resp, dict):
            text = resp.get("text", "")
        return (text or "").strip()
