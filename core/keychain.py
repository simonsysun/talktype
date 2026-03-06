"""Local encrypted API key storage.

Primary storage is an app-local encrypted file under the app state directory.
Legacy Keychain entries are read once for migration and then deleted.
"""

from __future__ import annotations

import base64
import hashlib
import os
import re
import secrets
import subprocess
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken

from core.app_identity import keychain_service, legacy_keychain_services, state_dir

_SECURITY = "/usr/bin/security"
_IOREG = "/usr/sbin/ioreg"


def _keys_dir() -> Path:
    return state_dir() / "keys"


def _master_key_path() -> Path:
    return _keys_dir() / "master.key"


def _encrypted_path(provider: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", provider)
    return _keys_dir() / f"{safe}.enc"


def _ensure_keys_dir() -> Path:
    keys_dir = _keys_dir()
    keys_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(keys_dir, 0o700)
    return keys_dir


def _load_or_create_master_secret() -> bytes:
    _ensure_keys_dir()
    path = _master_key_path()
    try:
        if path.exists():
            return path.read_bytes()
    except Exception:
        pass

    secret = secrets.token_bytes(32)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(secret)
    return secret


def _machine_binding() -> bytes:
    try:
        result = subprocess.run(
            [_IOREG, "-rd1", "-c", "IOPlatformExpertDevice"],
            check=True,
            capture_output=True,
            text=True,
        )
        match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', result.stdout)
        if match:
            return match.group(1).encode("utf-8")
    except Exception:
        pass
    return b"local-machine"


def _fernet() -> Fernet:
    master = _load_or_create_master_secret()
    digest = hashlib.sha256(master + b"\0" + _machine_binding()).digest()
    return Fernet(base64.urlsafe_b64encode(digest))


def _store_encrypted(provider: str, api_key: str) -> bool:
    try:
        token = _fernet().encrypt(api_key.encode("utf-8"))
        path = _encrypted_path(provider)
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(token)
        return True
    except Exception:
        return False


def _retrieve_encrypted(provider: str) -> str | None:
    path = _encrypted_path(provider)
    try:
        if not path.exists():
            return None
        token = path.read_bytes()
        value = _fernet().decrypt(token).decode("utf-8").strip()
        return value or None
    except InvalidToken:
        return None
    except Exception:
        return None


def _delete_encrypted(provider: str) -> bool:
    path = _encrypted_path(provider)
    try:
        if path.exists():
            path.unlink()
            return True
    except Exception:
        return False
    return False


def _retrieve_legacy_keychain(provider: str) -> str | None:
    services = [keychain_service(), *legacy_keychain_services()]
    seen: set[str] = set()
    for service in services:
        if service in seen:
            continue
        seen.add(service)
        try:
            result = subprocess.run(
                [
                    _SECURITY,
                    "find-generic-password",
                    "-s",
                    service,
                    "-a",
                    provider,
                    "-w",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            value = result.stdout.strip()
            if value:
                return value
        except Exception:
            continue
    return None


def _delete_legacy_keychain(provider: str) -> bool:
    deleted = False
    services = [keychain_service(), *legacy_keychain_services()]
    seen: set[str] = set()
    for service in services:
        if service in seen:
            continue
        seen.add(service)
        try:
            subprocess.run(
                [
                    _SECURITY,
                    "delete-generic-password",
                    "-s",
                    service,
                    "-a",
                    provider,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            deleted = True
        except Exception:
            continue
    return deleted


def store_key(provider: str, api_key: str) -> bool:
    """Store an API key in local encrypted storage."""
    delete_key(provider)
    return _store_encrypted(provider, api_key)


def retrieve_key(provider: str) -> str | None:
    """Retrieve an API key from local encrypted storage, migrating legacy Keychain on demand."""
    value = _retrieve_encrypted(provider)
    if value:
        return value

    legacy = _retrieve_legacy_keychain(provider)
    if legacy and _store_encrypted(provider, legacy):
        _delete_legacy_keychain(provider)
        return legacy

    return legacy


def delete_key(provider: str) -> bool:
    """Delete an API key from local encrypted storage and any legacy Keychain entry."""
    encrypted_deleted = _delete_encrypted(provider)
    legacy_deleted = _delete_legacy_keychain(provider)
    return encrypted_deleted or legacy_deleted
