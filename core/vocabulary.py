from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path


VOCABULARY_PATH = Path.home() / ".whisper" / "vocabulary.json"
DEFAULT_ACTIVE_LIMIT = 50
MAX_PROMPT_CHARS = 800


class VocabularyStore:
    """Persistent local vocabulary list used to bias transcription spelling."""

    def __init__(self, path: Path | None = None):
        self.path = path or VOCABULARY_PATH
        self._entries: list[dict] = []
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            self._entries = []
            return

        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            print(f"[vocab] failed to load vocabulary file: {e}")
            self._entries = []
            return

        entries = data.get("entries", [])
        if not isinstance(entries, list):
            print("[vocab] vocabulary file is invalid, ignoring contents")
            self._entries = []
            return

        normalized: list[dict] = []
        for raw in entries:
            if not isinstance(raw, dict):
                continue
            canonical = str(raw.get("canonical", "")).strip()
            if not canonical:
                continue
            normalized.append(
                {
                    "id": str(raw.get("id") or uuid.uuid4().hex[:8]),
                    "canonical": canonical,
                    "added_at": str(raw.get("added_at") or self._now_iso()),
                    "pinned": bool(raw.get("pinned", False)),
                    "last_used_at": raw.get("last_used_at"),
                }
            )
        self._entries = normalized

    @staticmethod
    def _now_iso() -> str:
        return datetime.now(timezone.utc).isoformat()

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"version": 1, "entries": self._entries}
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        tmp.replace(self.path)

    def list_entries(self) -> list[dict]:
        return [dict(entry) for entry in self._entries]

    def add(self, canonical: str) -> dict:
        canonical = " ".join((canonical or "").strip().split())
        if not canonical:
            raise ValueError("Word or phrase cannot be empty.")

        for entry in self._entries:
            if entry["canonical"].casefold() == canonical.casefold():
                return dict(entry)

        entry = {
            "id": uuid.uuid4().hex[:8],
            "canonical": canonical,
            "added_at": self._now_iso(),
            "pinned": False,
            "last_used_at": None,
        }
        self._entries.append(entry)
        self._save()
        return dict(entry)

    def remove(self, entry_id: str) -> bool:
        before = len(self._entries)
        self._entries = [entry for entry in self._entries if entry["id"] != entry_id]
        if len(self._entries) == before:
            return False
        self._save()
        return True

    def get_active_vocabulary(
        self,
        limit: int = DEFAULT_ACTIVE_LIMIT,
        max_chars: int = MAX_PROMPT_CHARS,
    ) -> list[str]:
        sorted_entries = sorted(
            self._entries,
            key=lambda entry: str(entry.get("added_at", "")),
            reverse=True,
        )
        active: list[str] = []
        total_chars = 0
        for entry in sorted_entries:
            word = entry["canonical"]
            extra = len(word) + (2 if active else 0)
            if active and total_chars + extra > max_chars:
                break
            active.append(word)
            total_chars += extra
            if len(active) >= limit:
                break
        return active
