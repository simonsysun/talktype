#!/usr/bin/env python3
"""Build a development-friendly macOS app bundle for TalkType.

This creates a .app wrapper that launches the code directly from this repo
using the existing virtualenv. That keeps iteration fast while still giving
you a real app bundle for menu bar behavior, permissions, and Finder launch.
"""

from __future__ import annotations

import os
import plistlib
import shlex
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import AppKit
import Foundation


APP_NAME = "TalkType"
BUNDLE_ID = "dev.talktype.local"
MIN_SYSTEM_VERSION = "13.0"
ICON_FONT_CANDIDATES = (
    "Didot-Bold",
    "Baskerville-BoldItalic",
    "TimesNewRomanPS-BoldItalicMT",
    "Georgia-BoldItalic",
)
ICON_FILES = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def dist_dir(root: Path) -> Path:
    return root / "dist"


def app_bundle(root: Path) -> Path:
    return dist_dir(root) / f"{APP_NAME}.app"


def app_contents(root: Path) -> Path:
    return app_bundle(root) / "Contents"


def resources_dir(root: Path) -> Path:
    return app_contents(root) / "Resources"


def macos_dir(root: Path) -> Path:
    return app_contents(root) / "MacOS"


def choose_font(size: float):
    for name in ICON_FONT_CANDIDATES:
        font = AppKit.NSFont.fontWithName_size_(name, size)
        if font is not None:
            return font
    return AppKit.NSFont.boldSystemFontOfSize_(size)


def make_bitmap(size: int) -> AppKit.NSBitmapImageRep:
    rep = AppKit.NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bitmapFormat_bytesPerRow_bitsPerPixel_(
        None,
        size,
        size,
        8,
        4,
        True,
        False,
        AppKit.NSCalibratedRGBColorSpace,
        0,
        0,
        0,
    )
    return rep


def draw_icon(size: int, png_path: Path) -> None:
    rep = make_bitmap(size)
    AppKit.NSGraphicsContext.saveGraphicsState()
    context = AppKit.NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
    AppKit.NSGraphicsContext.setCurrentContext_(context)

    AppKit.NSColor.clearColor().set()
    AppKit.NSRectFill(AppKit.NSMakeRect(0, 0, size, size))

    inset = size * 0.075
    rect = AppKit.NSMakeRect(inset, inset, size - inset * 2, size - inset * 2)
    radius = size * 0.24

    base_path = AppKit.NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
        rect, radius, radius
    )
    gradient = AppKit.NSGradient.alloc().initWithColors_(
        [
            AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(0.97, 0.95, 0.91, 1.0),
            AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(0.89, 0.84, 0.76, 1.0),
        ]
    )
    gradient.drawInBezierPath_angle_(base_path, -90.0)

    stroke = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(0.27, 0.23, 0.18, 0.18)
    stroke.setStroke()
    base_path.setLineWidth_(max(1.0, size * 0.006))
    base_path.stroke()

    shadow = AppKit.NSShadow.alloc().init()
    shadow.setShadowOffset_(Foundation.NSMakeSize(0, -size * 0.018))
    shadow.setShadowBlurRadius_(size * 0.035)
    shadow.setShadowColor_(
        AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(0.18, 0.14, 0.10, 0.18)
    )
    shadow.set()

    letter = "T"
    font = choose_font(size * 0.62)
    paragraph = AppKit.NSParagraphStyle.defaultParagraphStyle().mutableCopy()
    paragraph.setAlignment_(AppKit.NSCenterTextAlignment)
    attrs = {
        AppKit.NSFontAttributeName: font,
        AppKit.NSForegroundColorAttributeName: AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
            0.14, 0.10, 0.08, 1.0
        ),
        AppKit.NSParagraphStyleAttributeName: paragraph,
    }
    text_rect = AppKit.NSMakeRect(0, size * 0.16, size, size * 0.62)
    AppKit.NSAttributedString.alloc().initWithString_attributes_(letter, attrs).drawInRect_(
        text_rect
    )

    AppKit.NSGraphicsContext.restoreGraphicsState()
    data = rep.representationUsingType_properties_(AppKit.NSPNGFileType, {})
    png_path.write_bytes(bytes(data))


def generate_icon(root: Path) -> Path:
    iconset = dist_dir(root) / f"{APP_NAME}.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True, exist_ok=True)

    master_png = resources_dir(root) / f"{APP_NAME}.png"
    draw_icon(1024, master_png)

    for filename, size in ICON_FILES:
        out_path = iconset / filename
        subprocess.run(
            [
                "sips",
                "-z",
                str(size),
                str(size),
                str(master_png),
                "--out",
                str(out_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    icns_path = resources_dir(root) / f"{APP_NAME}.icns"
    try:
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return icns_path
    except subprocess.CalledProcessError:
        return master_png
    finally:
        shutil.rmtree(iconset, ignore_errors=True)


def apply_bundle_icon(root: Path, image_path: Path) -> None:
    image = AppKit.NSImage.alloc().initWithContentsOfFile_(str(image_path))
    if image is None:
        return
    AppKit.NSWorkspace.sharedWorkspace().setIcon_forFile_options_(
        image, str(app_bundle(root)), 0
    )


def write_info_plist(root: Path, icon_name: str | None) -> None:
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": APP_NAME,
        "CFBundleExecutable": APP_NAME,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": APP_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSApplicationCategoryType": "public.app-category.productivity",
        "LSMinimumSystemVersion": MIN_SYSTEM_VERSION,
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "TalkType records your microphone for local dictation.",
        "NSPrincipalClass": "NSApplication",
    }
    if icon_name:
        info["CFBundleIconFile"] = icon_name
    with (app_contents(root) / "Info.plist").open("wb") as fh:
        plistlib.dump(info, fh)


def write_launcher(root: Path) -> None:
    """Compile a native C launcher so macOS TCC attributes permissions to TalkType.app.

    The binary forks python3 as a child process while staying alive as the
    'responsible process' — macOS shows "TalkType" in permission dialogs instead
    of "python3.14".
    """
    launcher = macos_dir(root) / APP_NAME
    repo = root.resolve()
    python_bin = repo / ".venv" / "bin" / "python3"
    log_dir = Path.home() / "Library" / "Logs" / APP_NAME

    # Escape backslashes and quotes for C string literals
    def c_str(p: Path) -> str:
        return str(p).replace("\\", "\\\\").replace('"', '\\"')

    c_source = f'''\
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define REPO_ROOT  "{c_str(repo)}"
#define PYTHON_BIN "{c_str(python_bin)}"
#define SCRIPT     REPO_ROOT "/app.py"
#define LOG_DIR    "{c_str(log_dir)}"
#define LOG_FILE   LOG_DIR "/launcher.log"

static pid_t child_pid = 0;

static void forward_signal(int sig) {{
    if (child_pid > 0) kill(child_pid, sig);
}}

int main(int argc, char *argv[]) {{
    if (access(PYTHON_BIN, X_OK) != 0) {{
        fprintf(stderr, "Missing virtualenv Python at %s\\n", PYTHON_BIN);
        return 1;
    }}

    mkdir(LOG_DIR, 0755);

    child_pid = fork();
    if (child_pid < 0) {{
        perror("fork");
        return 1;
    }}

    if (child_pid == 0) {{
        /* Child: redirect stdout/stderr to log file, exec python */
        FILE *log = fopen(LOG_FILE, "a");
        if (log) {{
            int fd = fileno(log);
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            fclose(log);
        }}

        chdir(REPO_ROOT);
        setenv("PYTHONPATH", REPO_ROOT, 1);

        execl(PYTHON_BIN, "TalkType", "-u", SCRIPT, NULL);
        perror("execl");
        _exit(1);
    }}

    /* Parent: forward signals and wait — stays alive as 'responsible process' */
    signal(SIGTERM, forward_signal);
    signal(SIGINT, forward_signal);
    signal(SIGHUP, forward_signal);

    int status;
    waitpid(child_pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}}
'''
    c_file = macos_dir(root) / "launcher.c"
    c_file.write_text(c_source)

    subprocess.run(
        ["cc", "-O2", "-o", str(launcher), str(c_file)],
        check=True,
    )
    c_file.unlink()


def clean_bundle(root: Path) -> None:
    bundle = app_bundle(root)
    if bundle.exists():
        shutil.rmtree(bundle)
    legacy_master = dist_dir(root) / f"{APP_NAME}-master.png"
    legacy_master.unlink(missing_ok=True)


def ensure_structure(root: Path) -> None:
    macos_dir(root).mkdir(parents=True, exist_ok=True)
    resources_dir(root).mkdir(parents=True, exist_ok=True)


def main() -> int:
    root = repo_root()
    if not (root / ".venv" / "bin" / "python3").exists():
        print("Missing .venv/bin/python3", file=sys.stderr)
        return 1

    clean_bundle(root)
    ensure_structure(root)
    icon_path = generate_icon(root)
    write_info_plist(root, icon_path.name if icon_path.suffix == ".icns" else None)
    write_launcher(root)
    apply_bundle_icon(root, icon_path)
    print(app_bundle(root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
