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

WHISPER_PROMPT_BARE = "{vocab}"
WHISPER_PROMPT_CONTEXTUAL = "Previously mentioned: {vocab}"
WHISPER_PROMPT_TEMPLATE = WHISPER_PROMPT_BARE


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

    @staticmethod
    def _build_whisper_prompt(vocabulary_hints: list[str] | None) -> str | None:
        hints = [hint.strip() for hint in (vocabulary_hints or []) if hint and hint.strip()]
        if not hints:
            return None
        return WHISPER_PROMPT_TEMPLATE.format(vocab=", ".join(hints))

    @staticmethod
    def _build_openrouter_system_prompt(vocabulary_hints: list[str] | None) -> str:
        base_prompt = (
            "Transcribe the provided audio accurately. Return only the transcript text. "
            "Preserve the original language, punctuation, and casing."
        )
        hints = [hint.strip() for hint in (vocabulary_hints or []) if hint and hint.strip()]
        if not hints:
            return base_prompt
        return (
            f"{base_prompt}\n\n"
            "When transcribing, use these exact spellings for proper nouns and terms:\n"
            + ", ".join(hints)
        )

    def _transcribe_via_openrouter_chat(
        self,
        wav_bytes: bytes,
        vocabulary_hints: list[str] | None = None,
    ) -> str:
        audio_b64 = base64.b64encode(wav_bytes).decode("ascii")
        resp = self._client.chat.completions.create(
            model=self.model,
            temperature=0,
            messages=[
                {
                    "role": "system",
                    "content": self._build_openrouter_system_prompt(vocabulary_hints),
                },
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "Transcribe this audio."},
                        {
                            "type": "input_audio",
                            "input_audio": {"data": audio_b64, "format": "wav"},
                        }
                    ],
                },
            ],
        )
        return self._extract_chat_text(resp)

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
            raise RuntimeError(
                f"{self._provider_label()} API key is missing. Set it from Whisper tray menu."
            )
        self._ensure_client(api_key)

        wav_bytes = self._to_wav_bytes(audio, sample_rate)

        if self.provider == OPENROUTER_PROVIDER:
            text = self._transcribe_via_openrouter_chat(wav_bytes, vocabulary_hints)
            return (text or "").strip()

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
