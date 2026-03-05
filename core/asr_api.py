import base64
import io
import wave

import numpy as np
from openai import OpenAI

from core.keychain import retrieve_key


OPENAI_PROVIDER = "openai"
OPENROUTER_PROVIDER = "openrouter"

DEFAULT_OPENAI_ASR_MODEL = "gpt-4o-mini-transcribe"
DEFAULT_OPENROUTER_ASR_MODEL = "openai/gpt-4o-mini"

OPENAI_ASR_ACCOUNT = "OpenAI-ASR"
OPENROUTER_ASR_ACCOUNT = "OpenRouter-ASR"


class OpenAITranscriber:
    """Speech-to-text via OpenAI or OpenRouter (OpenAI-compatible SDK)."""

    def __init__(
        self,
        model: str = DEFAULT_OPENAI_ASR_MODEL,
        timeout: float = 30.0,
        provider: str = OPENAI_PROVIDER,
        openrouter_base_url: str = "https://openrouter.ai/api/v1",
    ):
        self.model = model
        self.timeout = timeout
        self.provider = (provider or OPENAI_PROVIDER).lower()
        self.openrouter_base_url = openrouter_base_url
        self._client = None
        self._client_api_key = None
        self._client_provider = None
        self._client_base_url = None
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

    def _provider_label(self) -> str:
        return "OpenRouter" if self.provider == OPENROUTER_PROVIDER else "OpenAI"

    def _provider_account(self) -> str:
        return OPENROUTER_ASR_ACCOUNT if self.provider == OPENROUTER_PROVIDER else OPENAI_ASR_ACCOUNT

    def _load_api_key(self) -> str | None:
        if self.provider == OPENROUTER_PROVIDER:
            return retrieve_key(OPENROUTER_ASR_ACCOUNT) or retrieve_key("OpenRouter")
        return retrieve_key(OPENAI_ASR_ACCOUNT) or retrieve_key("OpenAI")

    def _ensure_client(self, api_key: str) -> None:
        if (
            self._client is not None
            and self._client_api_key == api_key
            and self._client_provider == self.provider
            and self._client_base_url == (
                self.openrouter_base_url if self.provider == OPENROUTER_PROVIDER else None
            )
            and self._client_timeout == self.timeout
        ):
            return

        kwargs = {
            "api_key": api_key,
            "timeout": self.timeout,
        }
        if self.provider == OPENROUTER_PROVIDER:
            kwargs["base_url"] = self.openrouter_base_url
        self._client = OpenAI(**kwargs)
        self._client_api_key = api_key
        self._client_provider = self.provider
        self._client_base_url = kwargs.get("base_url")
        self._client_timeout = self.timeout

    @staticmethod
    def _extract_chat_text(resp) -> str:
        choices = getattr(resp, "choices", None) or []
        if not choices:
            return ""
        msg = getattr(choices[0], "message", None)
        if msg is None:
            return ""
        content = getattr(msg, "content", "")
        if isinstance(content, str):
            return content.strip()
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, dict):
                    text = item.get("text")
                else:
                    text = getattr(item, "text", None)
                if text:
                    parts.append(str(text))
            return "\n".join(parts).strip()
        return ""

    def _transcribe_via_openrouter_chat(self, wav_bytes: bytes) -> str:
        audio_b64 = base64.b64encode(wav_bytes).decode("ascii")
        prompt = (
            "Transcribe this audio accurately. Return only the transcript text, "
            "preserve the original language (Chinese/English/mixed), punctuation, and casing."
        )

        resp = self._client.chat.completions.create(
            model=self.model,
            temperature=0,
            messages=[
                {"role": "user", "content": [
                    {"type": "text", "text": prompt},
                    {"type": "input_audio", "input_audio": {"data": audio_b64, "format": "wav"}},
                ]}
            ],
        )
        return self._extract_chat_text(resp)

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> str:
        if len(audio) == 0:
            return ""

        api_key = self._load_api_key()
        if not api_key:
            raise RuntimeError(
                f"{self._provider_label()} API key is missing. Set it from Whisper tray menu."
            )
        self._ensure_client(api_key)

        wav_bytes = self._to_wav_bytes(audio, sample_rate)

        if self.provider == OPENROUTER_PROVIDER:
            text = self._transcribe_via_openrouter_chat(wav_bytes)
            return (text or "").strip()

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
