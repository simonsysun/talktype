from __future__ import annotations

from pathlib import Path


STANDARD_APP_NAME = "Whisper"
STANDARD_BUNDLE_ID = "dev.whisper.local"
STANDARD_STATE_DIR = ".whisper"
STANDARD_KEYCHAIN_SERVICE = "com.whisper.api-keys"

def app_name() -> str:
    return STANDARD_APP_NAME


def bundle_id() -> str:
    return STANDARD_BUNDLE_ID


def state_dir() -> Path:
    return Path.home() / STANDARD_STATE_DIR


def keychain_service() -> str:
    return STANDARD_KEYCHAIN_SERVICE
