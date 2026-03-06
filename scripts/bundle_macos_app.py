#!/usr/bin/env python3
"""Build a fully self-contained Whisper.app using PyInstaller.

The resulting .app embeds Python, all dependencies, and the app code.
Users do not need Python or any other tools installed.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path


APP_NAME = "Whisper"
BUNDLE_ID = "dev.whisper.local"
MIN_SYSTEM_VERSION = "13.0"

PYOBJC_FRAMEWORKS = [
    "AppKit",
    "ApplicationServices",
    "AVFoundation",
    "Cocoa",
    "CoreFoundation",
    "Foundation",
    "Quartz",
    "Security",
    "WebKit",
    "objc",
]


def _sign_app(app_path: Path, identity: str | None) -> None:
    sign_identity = identity or "-"

    subprocess.run(
        ["xattr", "-cr", str(app_path)],
        check=False,
    )

    def _codesign(path: Path) -> None:
        subprocess.run(
            [
                "codesign",
                "--force",
                "--sign",
                sign_identity,
                "--timestamp=none",
                str(path),
            ],
            check=True,
        )

    frameworks_dir = app_path / "Contents" / "Frameworks"
    if frameworks_dir.exists():
        nested_files = sorted(
            [
                p
                for p in frameworks_dir.rglob("*")
                if p.is_file() and p.suffix in {".so", ".dylib"}
            ]
        )
        for nested in nested_files:
            _codesign(nested)

        nested_frameworks = sorted(
            [p for p in frameworks_dir.rglob("*.framework") if p.is_dir()],
            key=lambda p: len(p.parts),
            reverse=True,
        )
        for framework in nested_frameworks:
            _codesign(framework)

        nested_execs = sorted(
            [
                p
                for p in frameworks_dir.iterdir()
                if p.is_file() and os.access(p, os.X_OK)
            ]
        )
        for nested in nested_execs:
            _codesign(nested)

    macos_dir = app_path / "Contents" / "MacOS"
    if macos_dir.exists():
        for executable in sorted([p for p in macos_dir.iterdir() if p.is_file()]):
            _codesign(executable)

    _codesign(app_path)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def stop_running_instance(app_path: Path) -> None:
    subprocess.run(
        ["pkill", "-f", str(app_path / "Contents" / "MacOS" / APP_NAME)],
        check=False,
    )
    time.sleep(0.3)


def generate_icon(root: Path, resources_dir: Path) -> Path | None:
    """Generate app icon using the existing build script's icon generation."""
    try:
        if APP_NAME != "Whisper":
            for existing in (
                root / "dist" / "Whisper.app" / "Contents" / "Resources" / "Whisper.icns",
                root / "build" / "resources" / "Whisper.icns",
            ):
                if existing.exists():
                    resources_dir.mkdir(parents=True, exist_ok=True)
                    icns_path = resources_dir / f"{APP_NAME}.icns"
                    shutil.copy2(existing, icns_path)
                    return icns_path

        # Import icon generation from the dev build script
        sys.path.insert(0, str(root / "scripts"))
        import build_macos_app as dev_build

        resources_dir.mkdir(parents=True, exist_ok=True)
        dev_build.dist_dir(root).mkdir(parents=True, exist_ok=True)

        # Temporarily point resources_dir helper to our output
        icns_path = resources_dir / f"{APP_NAME}.icns"
        png_path = resources_dir / f"{APP_NAME}.png"

        dev_build.draw_icon(1024, png_path)

        iconset = root / "dist" / f"{APP_NAME}.iconset"
        if iconset.exists():
            shutil.rmtree(iconset)
        iconset.mkdir(parents=True, exist_ok=True)

        for filename, size in dev_build.ICON_FILES:
            out_path = iconset / filename
            subprocess.run(
                ["sips", "-z", str(size), str(size), str(png_path), "--out", str(out_path)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )

        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        shutil.rmtree(iconset, ignore_errors=True)
        return icns_path
    except Exception as e:
        print(f"[icon] generation failed, continuing without icon: {e}")
        return None


def _check_pyinstaller() -> None:
    """Verify PyInstaller is installed before attempting build."""
    try:
        import PyInstaller  # noqa: F401
    except ImportError:
        raise RuntimeError(
            "PyInstaller is not installed. Run:\n"
            "  pip install pyinstaller\n"
            "Or use --dev flag for a dev build that doesn't require it."
        )


def build_app(root: Path, codesign_identity: str | None = None) -> Path:
    """Run PyInstaller to create the bundled .app."""
    _check_pyinstaller()
    dist = root / "dist"
    build = root / "build"

    hidden_imports = []
    for fw in PYOBJC_FRAMEWORKS:
        hidden_imports.extend(["--hidden-import", fw])

    # Also include sub-modules pyinstaller may miss
    extra_hidden = [
        "rumps",
        "yaml",
        "openai",
        "openai.resources",
        "openai.resources.audio",
        "openai.resources.audio.transcriptions",
        "httpx",
        "httpcore",
        "anyio",
        "anyio._backends",
        "anyio._backends._asyncio",
        "sniffio",
        "h11",
        "certifi",
        "pydantic",
        "pydantic.deprecated",
        "pydantic.deprecated.decorator",
        "pydantic_core",
        "annotated_types",
        "distro",
        "jiter",
    ]
    for mod in extra_hidden:
        hidden_imports.extend(["--hidden-import", mod])

    # Collect overlay.html as data
    overlay_html = root / "ui" / "overlay.html"

    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--name", APP_NAME,
        "--windowed",             # .app bundle, no console
        "--noconfirm",            # overwrite without asking
        "--clean",                # clean cache
        "--distpath", str(dist),
        "--workpath", str(build / "pyinstaller"),
        "--add-data", f"{overlay_html}:ui",
        "--osx-bundle-identifier", BUNDLE_ID,
        *hidden_imports,
        str(root / "app.py"),
    ]
    if codesign_identity:
        cmd.extend(["--codesign-identity", codesign_identity])

    # Add icon if we can generate one
    resources_tmp = build / "resources"
    icon_path = generate_icon(root, resources_tmp)
    if icon_path:
        cmd.extend(["--icon", str(icon_path)])

    print(f"Running PyInstaller...")
    env = dict(os.environ)
    env["PYINSTALLER_CONFIG_DIR"] = str(build / "pyinstaller-config")
    subprocess.run(cmd, check=True, cwd=str(root), env=env)

    app_path = dist / f"{APP_NAME}.app"
    if not app_path.exists():
        raise RuntimeError(f"PyInstaller did not produce {app_path}")

    # Patch Info.plist with our custom keys
    _patch_info_plist(app_path)
    _sign_app(app_path, codesign_identity)
    return app_path


def _patch_info_plist(app_path: Path) -> None:
    """Add macOS-specific keys that PyInstaller doesn't set."""
    plist_path = app_path / "Contents" / "Info.plist"
    with plist_path.open("rb") as f:
        info = plistlib.load(f)

    info.update({
        "LSUIElement": True,  # menu bar app, no dock icon
        "LSMinimumSystemVersion": MIN_SYSTEM_VERSION,
        "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "Whisper records your microphone for voice-to-text dictation.",
        "NSPrincipalClass": "NSApplication",
        "LSApplicationCategoryType": "public.app-category.productivity",
    })

    with plist_path.open("wb") as f:
        plistlib.dump(info, f)


def install_app(app_src: Path, target_dir: Path, icon_path: Path | None = None) -> Path:
    target_dir.mkdir(parents=True, exist_ok=True)
    app_dst = target_dir / app_src.name
    if app_dst.exists():
        stop_running_instance(app_dst)
        shutil.rmtree(app_dst)
    subprocess.run(
        ["ditto", str(app_src), str(app_dst)],
        check=True,
    )
    return app_dst


def main() -> int:
    parser = argparse.ArgumentParser(description="Bundle and install standalone Whisper.app")
    parser.add_argument(
        "--install",
        default="",
        help="Install to directory (e.g. ~/Applications)",
    )
    parser.add_argument(
        "--open",
        action="store_true",
        help="Open the app after build/install",
    )
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

    root = repo_root()
    env_identity = os.environ.get("WHISPER_CODESIGN_IDENTITY", "").strip()
    codesign_identity = None if args.adhoc else (args.codesign_identity.strip() or env_identity or None)
    if codesign_identity:
        print(f"Using code signing identity: {codesign_identity}")
    else:
        print("Using ad hoc signing.")

    app_path = build_app(root, codesign_identity=codesign_identity)
    print(f"Built: {app_path}")

    final_path = app_path
    if args.install:
        target = Path(args.install).expanduser()
        icon_path = app_path / "Contents" / "Resources" / f"{APP_NAME}.icns"
        final_path = install_app(app_path, target, icon_path=icon_path)
        print(f"Installed: {final_path}")

    if args.open:
        # Kill any running Whisper instance before launching the new one
        stop_running_instance(final_path)
        time.sleep(0.5)
        subprocess.run(["open", str(final_path)], check=False)

    app_size_mb = sum(f.stat().st_size for f in final_path.rglob("*") if f.is_file()) / (1024 * 1024)
    print(f"App size: {app_size_mb:.0f} MB")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
