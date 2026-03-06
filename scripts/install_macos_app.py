#!/usr/bin/env python3
"""Build and install Whisper.app to Applications.

Uses bundle_macos_app.py (PyInstaller) for a fully self-contained app,
or build_macos_app.py (dev wrapper) with --dev flag.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def stop_running_instance(app_path: Path) -> None:
    subprocess.run(
        ["pkill", "-f", str(app_path / "Contents" / "MacOS" / "Whisper")],
        check=False,
    )
    time.sleep(0.3)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and install Whisper.app")
    parser.add_argument(
        "--target",
        default=str(Path.home() / "Applications"),
        help="Installation directory (default: ~/Applications)",
    )
    parser.add_argument(
        "--open",
        action="store_true",
        help="Open the app after installation",
    )
    parser.add_argument(
        "--dev",
        action="store_true",
        help="Use dev build (repo-linked wrapper) instead of standalone bundle",
    )
    args = parser.parse_args()

    root = repo_root()

    if args.dev:
        # Dev build: thin .app wrapper that points to repo + .venv
        build_script = root / "scripts" / "build_macos_app.py"
        out = subprocess.check_output(
            [sys.executable, str(build_script)], text=True
        ).strip()
        app_src = Path(out)

        target_dir = Path(args.target).expanduser()
        target_dir.mkdir(parents=True, exist_ok=True)
        app_dst = target_dir / app_src.name
        if app_dst.exists():
            stop_running_instance(app_dst)
            subprocess.run(["rm", "-rf", str(app_dst)], check=True)
        subprocess.run(["ditto", str(app_src), str(app_dst)], check=True)
        print(app_dst)
        if args.open:
            # Kill any running Whisper instance before launching the new one
            stop_running_instance(app_dst)
            time.sleep(0.5)
            subprocess.run(["open", str(app_dst)], check=False)
    else:
        # Standalone build: fully self-contained via PyInstaller
        cmd = [
            sys.executable,
            str(root / "scripts" / "bundle_macos_app.py"),
            "--install", str(Path(args.target).expanduser()),
        ]
        if args.open:
            cmd.append("--open")
        subprocess.run(cmd, check=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
