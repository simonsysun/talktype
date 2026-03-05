"""macOS key storage helper.

Primary storage is Keychain via Security framework. If Keychain operations fail
in unsigned/dev environments, a local fallback file is used so the app remains
functional.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import Security


_SERVICE = "com.whisper.api-keys"
_ERR_SUCCESS = 0
_ERR_ITEM_NOT_FOUND = -25300
_FALLBACK_DIR = Path.home() / ".whisper" / "keys"


def _normalize_status(result) -> tuple[int, object | None]:
    if isinstance(result, tuple) and len(result) == 2:
        return int(result[0]), result[1]
    return int(result), None


def _fallback_path(provider: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", provider)
    return _FALLBACK_DIR / f"{safe}.key"


def _store_fallback(provider: str, api_key: str) -> bool:
    try:
        _FALLBACK_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(_FALLBACK_DIR, 0o700)
        path = _fallback_path(provider)
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(api_key)
        return True
    except Exception:
        return False


def _retrieve_fallback(provider: str) -> str | None:
    path = _fallback_path(provider)
    try:
        if not path.exists():
            return None
        data = path.read_text(encoding="utf-8").strip()
        return data or None
    except Exception:
        return None


def _delete_fallback(provider: str) -> bool:
    path = _fallback_path(provider)
    try:
        if path.exists():
            path.unlink()
            return True
    except Exception:
        return False
    return False


def store_key(provider: str, api_key: str) -> bool:
    """Store an API key in Keychain. Falls back to local file if needed."""
    delete_key(provider)

    attrs = {
        Security.kSecClass: Security.kSecClassGenericPassword,
        Security.kSecAttrService: _SERVICE,
        Security.kSecAttrAccount: provider,
        Security.kSecValueData: api_key.encode("utf-8"),
        Security.kSecAttrAccessible: Security.kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    }
    status, _ = _normalize_status(Security.SecItemAdd(attrs, None))
    if status == _ERR_SUCCESS:
        return True

    return _store_fallback(provider, api_key)


def retrieve_key(provider: str) -> str | None:
    """Retrieve an API key from Keychain, then fallback file."""
    query = {
        Security.kSecClass: Security.kSecClassGenericPassword,
        Security.kSecAttrService: _SERVICE,
        Security.kSecAttrAccount: provider,
        Security.kSecReturnData: True,
        Security.kSecMatchLimit: Security.kSecMatchLimitOne,
    }
    status, result = _normalize_status(Security.SecItemCopyMatching(query, None))
    if status == _ERR_SUCCESS and result is not None:
        try:
            return bytes(result).decode("utf-8")
        except Exception:
            pass

    return _retrieve_fallback(provider)


def delete_key(provider: str) -> bool:
    """Delete an API key from Keychain and fallback file."""
    query = {
        Security.kSecClass: Security.kSecClassGenericPassword,
        Security.kSecAttrService: _SERVICE,
        Security.kSecAttrAccount: provider,
    }
    keychain_result = Security.SecItemDelete(query)
    status, _ = _normalize_status(keychain_result)
    keychain_deleted = status == _ERR_SUCCESS
    fallback_deleted = _delete_fallback(provider)
    if status in (_ERR_SUCCESS, _ERR_ITEM_NOT_FOUND):
        return keychain_deleted or fallback_deleted
    return fallback_deleted
