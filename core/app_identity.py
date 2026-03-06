from __future__ import annotations

from functools import lru_cache
from pathlib import Path


STANDARD_APP_NAME = "Whisper"
STANDARD_BUNDLE_ID = "dev.whisper.local"
STANDARD_STATE_DIR = ".whisper"
STANDARD_KEYCHAIN_SERVICE = "com.whisper.api-keys"

DEMO_APP_NAME = "Whisper-demo"
DEMO_BUNDLE_ID = "dev.whisper.local.demo"
DEMO_STATE_DIR = ".whisper-demo"
DEMO_KEYCHAIN_SERVICE = "com.whisper-demo.api-keys"


@lru_cache(maxsize=1)
def current_app_identity() -> dict[str, str | bool]:
    bundle_name = ""
    bundle_id = ""
    try:
        import AppKit

        bundle = AppKit.NSBundle.mainBundle()
        if bundle is not None:
            bundle_name = str(bundle.objectForInfoDictionaryKey_("CFBundleName") or "")
            bundle_id = str(bundle.bundleIdentifier() or "")
    except Exception:
        pass

    is_demo = bool(bundle_id.endswith(".demo") or bundle_name.endswith("-demo"))
    if is_demo:
        return {
            "app_name": DEMO_APP_NAME,
            "bundle_id": DEMO_BUNDLE_ID,
            "state_dir_name": DEMO_STATE_DIR,
            "keychain_service": DEMO_KEYCHAIN_SERVICE,
            "is_demo": True,
        }

    return {
        "app_name": STANDARD_APP_NAME,
        "bundle_id": STANDARD_BUNDLE_ID,
        "state_dir_name": STANDARD_STATE_DIR,
        "keychain_service": STANDARD_KEYCHAIN_SERVICE,
        "is_demo": False,
    }


def app_name() -> str:
    return str(current_app_identity()["app_name"])


def bundle_id() -> str:
    return str(current_app_identity()["bundle_id"])


def is_demo_build() -> bool:
    return bool(current_app_identity()["is_demo"])


def state_dir() -> Path:
    return Path.home() / str(current_app_identity()["state_dir_name"])


def keychain_service() -> str:
    return str(current_app_identity()["keychain_service"])
