"""LLM text cleanup via OpenAI-compatible APIs."""

import re

from openai import OpenAI

from core.keychain import retrieve_key

# Provider definitions: name → (base_url, model)
PROVIDERS = {
    "DeepSeek": ("https://api.deepseek.com/v1", "deepseek-chat"),
    "OpenAI": ("https://api.openai.com/v1", "gpt-4o-mini"),
    "OpenRouter": ("https://openrouter.ai/api/v1", "deepseek/deepseek-chat"),
    "SiliconFlow": ("https://api.siliconflow.cn/v1", "deepseek-ai/DeepSeek-V3"),
    "Groq": ("https://api.groq.com/openai/v1", "llama-3.3-70b-versatile"),
    "MiniMax": ("https://api.minimax.chat/v1", "MiniMax-Text-01"),
}

CLEANUP_PROMPT = (
    "You are a speech-to-text post-processor. Clean up the following raw transcription:\n"
    "- Fix grammar, punctuation, and capitalization\n"
    "- Remove filler words (um, uh, like, you know)\n"
    "- Keep the original meaning and wording exactly; do NOT translate, rephrase, summarize, or paraphrase\n"
    "- Preserve the original language of each span exactly as spoken\n"
    "- If a phrase is Chinese, keep it Chinese. If a phrase is English, keep it English\n"
    "- Mixed Chinese/English code-switching is intentional and must be preserved\n"
    "- Do NOT convert English words into Chinese, and do NOT convert Chinese words into English\n"
    "- Keep product names, technical terms, code, APIs, file paths, class names, and identifiers in their original form\n"
    "- Keep numbers, times, and units faithful to the source\n"
    "- If unsure, prefer minimal edits rather than changing wording\n"
    "- Output only the cleaned text, with no explanation\n"
    "\n"
    "Examples:\n"
    "Input: 我今天有个 meeting 在下午 three 点\n"
    "Output: 我今天有个 meeting 在下午 three 点\n"
    "Input: 请帮我 open 一下 settings 然后点 save\n"
    "Output: 请帮我 open 一下 settings，然后点 save\n"
    "Input: 这个 API endpoint 我们明天再改\n"
    "Output: 这个 API endpoint 我们明天再改"
)

_LATIN_RE = re.compile(r"[A-Za-z]")
_CJK_RE = re.compile(r"[\u4e00-\u9fff]")


def _script_profile(text: str) -> tuple[bool, bool]:
    return bool(_CJK_RE.search(text)), bool(_LATIN_RE.search(text))


def _preserves_code_switching(source: str, cleaned: str) -> bool:
    """Reject cleanup output that collapses mixed zh/en into a single script."""
    src_has_cjk, src_has_latin = _script_profile(source)
    out_has_cjk, out_has_latin = _script_profile(cleaned)

    if src_has_cjk and src_has_latin:
        return out_has_cjk and out_has_latin
    if src_has_cjk and not src_has_latin:
        return out_has_cjk
    if src_has_latin and not src_has_cjk:
        return out_has_latin
    return True


def cleanup_text(text: str, provider: str, custom_base_url: str = "", custom_model: str = "") -> str | None:
    """Clean up transcribed text using an LLM API.

    Returns cleaned text, or None on any failure.
    """
    api_key = retrieve_key(provider)
    if not api_key:
        return None

    if provider == "Custom":
        if not custom_base_url:
            return None
        base_url = custom_base_url
        model = custom_model or "default"
    else:
        defn = PROVIDERS.get(provider)
        if not defn:
            return None
        base_url, default_model = defn
        model = custom_model or default_model

    try:
        client = OpenAI(base_url=base_url, api_key=api_key, timeout=10.0)
        resp = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": CLEANUP_PROMPT},
                {"role": "user", "content": text},
            ],
            temperature=0.0,
            max_tokens=2048,
        )
        cleaned = resp.choices[0].message.content.strip()
        if not cleaned:
            return None
        if not _preserves_code_switching(text, cleaned):
            print("[cleanup] rejected output because it changed zh/en script balance")
            return text
        return cleaned
    except Exception as e:
        print(f"[cleanup] API error ({provider}): {e}")
        return None
