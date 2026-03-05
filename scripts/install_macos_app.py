#!/usr/bin/env python3
"""Build and install Whisper.app to Applications."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def build_app(root: Path) -> Path:
    build_script = root / "scripts" / "build_macos_app.py"
    out = subprocess.check_output([sys.executable, str(build_script)], text=True).strip()
    return Path(out)


def install_app(app_src: Path, target_dir: Path) -> Path:
    target_dir.mkdir(parents=True, exist_ok=True)
    app_dst = target_dir / app_src.name
    if app_dst.exists():
        shutil.rmtree(app_dst)
    shutil.copytree(app_src, app_dst)
    return app_dst


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
    args = parser.parse_args()

    root = repo_root()
    app_src = build_app(root)
    app_dst = install_app(app_src, Path(args.target).expanduser())
    print(app_dst)

    if args.open:
        subprocess.run(["open", str(app_dst)], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
