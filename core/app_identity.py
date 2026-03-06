from __future__ import annotations

import shutil
from pathlib import Path


STANDARD_APP_NAME = "TalkType"
STANDARD_BUNDLE_ID = "dev.talktype.local"
STANDARD_STATE_DIR = ".talktype"
STANDARD_KEYCHAIN_SERVICE = "com.talktype.api-keys"

LEGACY_APP_NAME = "Whisper"
LEGACY_BUNDLE_ID = "dev.whisper.local"
LEGACY_STATE_DIR = ".whisper"
LEGACY_KEYCHAIN_SERVICE = "com.whisper.api-keys"

def app_name() -> str:
    return STANDARD_APP_NAME


def bundle_id() -> str:
    return STANDARD_BUNDLE_ID


def state_dir() -> Path:
    target = Path.home() / STANDARD_STATE_DIR
    legacy = Path.home() / LEGACY_STATE_DIR
    if target.exists():
        return target
    if legacy.exists():
        try:
            shutil.move(str(legacy), str(target))
            return target
        except Exception:
            return legacy
    return target


def keychain_service() -> str:
    return STANDARD_KEYCHAIN_SERVICE


def legacy_keychain_services() -> list[str]:
    return [LEGACY_KEYCHAIN_SERVICE]
