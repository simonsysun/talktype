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
    args = parser.parse_args()

    bundle.APP_NAME = "Whisper-demo"
    bundle.BUNDLE_ID = "dev.whisper.local.demo"

    root = bundle.repo_root()
    app_path = bundle.build_app(root)
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
        final_path = bundle.install_app(app_path, Path(args.install).expanduser())
        print(f"Installed: {final_path}")

    if args.open:
        bundle.stop_running_instance(final_path)
        bundle.subprocess.run(["tccutil", "reset", "Microphone", bundle.BUNDLE_ID], check=False)
        bundle.time.sleep(0.5)
        bundle.subprocess.run(["open", str(final_path)], check=False)

    app_size_mb = sum(f.stat().st_size for f in final_path.rglob("*") if f.is_file()) / (1024 * 1024)
    print(f"App size: {app_size_mb:.0f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
