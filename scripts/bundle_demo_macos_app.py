#!/usr/bin/env python3
"""Build a distributable Whisper-demo.app with offline license enforcement."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

import bundle_macos_app as bundle


def main() -> int:
    parser = argparse.ArgumentParser(description="Bundle and optionally install Whisper-demo.app")
    parser.add_argument("--install", default="", help="Install to directory (e.g. ~/Applications)")
    parser.add_argument("--open", action="store_true", help="Open the app after build/install")
    parser.add_argument(
        "--codesign-identity",
        default="",
        help="macOS code signing identity to use",
    )
    parser.add_argument(
        "--adhoc",
        action="store_true",
        help="Disable identity-based signing and use the default ad hoc signing path",
    )
    args = parser.parse_args()

    bundle.APP_NAME = "Whisper-demo"
    bundle.BUNDLE_ID = "dev.whisper.local.demo"

    root = bundle.repo_root()
    env_identity = bundle.os.environ.get("WHISPER_CODESIGN_IDENTITY", "").strip()
    codesign_identity = None if args.adhoc else (args.codesign_identity.strip() or env_identity or None)
    if codesign_identity:
        print(f"Using code signing identity: {codesign_identity}")
    else:
        print("Using ad hoc signing.")

    app_path = bundle.build_app(root, codesign_identity=codesign_identity)
    print(f"Built: {app_path}")
    zip_path = root / "dist" / "Whisper-demo-macOS.zip"
    if zip_path.exists():
        zip_path.unlink()
    subprocess.run(
        [
            "ditto",
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            str(app_path),
            str(zip_path),
        ],
        check=True,
    )
    print(f"Zipped: {zip_path}")

    final_path = app_path
    if args.install:
        icon_path = app_path / "Contents" / "Resources" / "Whisper-demo.icns"
        final_path = bundle.install_app(
            app_path,
            Path(args.install).expanduser(),
            icon_path=icon_path,
        )
        print(f"Installed: {final_path}")

    if args.open:
        bundle.stop_running_instance(final_path)
        bundle.time.sleep(0.5)
        bundle.subprocess.run(["open", str(final_path)], check=False)

    app_size_mb = sum(f.stat().st_size for f in final_path.rglob("*") if f.is_file()) / (1024 * 1024)
    print(f"App size: {app_size_mb:.0f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
