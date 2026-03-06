import io
import wave

import numpy as np
from openai import OpenAI

from core.keychain import retrieve_key


OPENAI_PROVIDER = "openai"

DEFAULT_OPENAI_ASR_MODEL = "gpt-4o-mini-transcribe"
PREMIUM_OPENAI_ASR_MODEL = "gpt-4o-transcribe"

OPENAI_ASR_ACCOUNT = "OpenAI-ASR"

WHISPER_PROMPT_BARE = "{vocab}"
WHISPER_PROMPT_CONTEXTUAL = "Previously mentioned: {vocab}"
WHISPER_PROMPT_TEMPLATE = WHISPER_PROMPT_BARE


class OpenAITranscriber:
    """Speech-to-text via the OpenAI transcription API."""

    def __init__(
        self,
        model: str = DEFAULT_OPENAI_ASR_MODEL,
        timeout: float = 30.0,
    ):
        self.model = model
        self.timeout = timeout
        self._client = None
        self._client_api_key = None
        self._client_timeout = None

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

    def _load_api_key(self) -> str | None:
        return retrieve_key(OPENAI_ASR_ACCOUNT) or retrieve_key("OpenAI")

    def _ensure_client(self, api_key: str) -> None:
        if (
            self._client is not None
            and self._client_api_key == api_key
            and self._client_timeout == self.timeout
        ):
            return

        kwargs = {
            "api_key": api_key,
            "timeout": self.timeout,
        }
        self._client = OpenAI(**kwargs)
        self._client_api_key = api_key
        self._client_timeout = self.timeout

    @staticmethod
    def _build_whisper_prompt(vocabulary_hints: list[str] | None) -> str | None:
        hints = [hint.strip() for hint in (vocabulary_hints or []) if hint and hint.strip()]
        if not hints:
            return None
        return WHISPER_PROMPT_TEMPLATE.format(vocab=", ".join(hints))


    def transcribe(
        self,
        audio: np.ndarray,
        sample_rate: int = 16000,
        vocabulary_hints: list[str] | None = None,
    ) -> str:
        if len(audio) == 0:
            return ""

        api_key = self._load_api_key()
        if not api_key:
            raise RuntimeError("OpenAI API key is missing. Set it from Whisper tray menu.")
        self._ensure_client(api_key)

        wav_bytes = self._to_wav_bytes(audio, sample_rate)

        file_obj = io.BytesIO(wav_bytes)
        file_obj.name = "speech.wav"
        kwargs = {
            "model": self.model,
            "file": file_obj,
        }
        prompt = self._build_whisper_prompt(vocabulary_hints)
        if prompt:
            kwargs["prompt"] = prompt

        resp = self._client.audio.transcriptions.create(**kwargs)
        text = getattr(resp, "text", "")
        if not text and isinstance(resp, dict):
            text = resp.get("text", "")
        return (text or "").strip()
