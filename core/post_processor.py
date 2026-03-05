from __future__ import annotations

import re
import unicodedata


_ZERO_WIDTH_RE = re.compile(r"[\u200b\u200c\u200d\ufeff]")
_MULTI_SPACE_RE = re.compile(r" {2,}")


def safe_normalize(text: str) -> str:
    normalized = unicodedata.normalize("NFKC", text or "")
    normalized = _ZERO_WIDTH_RE.sub("", normalized)
    normalized = _MULTI_SPACE_RE.sub(" ", normalized)
    return normalized.strip()


def is_safe_for_auto_replace(canonical: str) -> bool:
    canonical = (canonical or "").strip()
    if not canonical:
        return False

    alpha_chars = [c for c in canonical if c.isalpha()]
    if len(alpha_chars) >= 2 and all(c.isupper() for c in alpha_chars):
        return True
    if any(c.isdigit() for c in canonical):
        return True
    if len(canonical) > 1 and any(c.isupper() for c in canonical[1:]):
        return True
    if " " in canonical:
        return True
    if any(ord(c) > 127 for c in canonical):
        return True
    return False


def _pattern_for_canonical(canonical: str) -> re.Pattern[str]:
    escaped = re.escape(canonical)
    if canonical.isascii():
        return re.compile(rf"\b{escaped}\b", re.IGNORECASE)
    return re.compile(escaped, re.IGNORECASE)


def post_process_transcript(text: str, vocab_entries: list[dict]) -> str:
    text = safe_normalize(text)
    for entry in vocab_entries:
        canonical = str(entry.get("canonical", "")).strip()
        if not canonical or not is_safe_for_auto_replace(canonical):
            continue
        text = _pattern_for_canonical(canonical).sub(canonical, text)
    return text
