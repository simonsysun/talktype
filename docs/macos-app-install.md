# Whisper macOS App Install

## 1) Prepare environment

```bash
cd <repo-root>
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
```

## 2) Build + install app

Install to `~/Applications` (no sudo needed):

```bash
./.venv/bin/python3 scripts/install_macos_app.py --open
```

This builds a standalone `.app` bundle via PyInstaller. For a lightweight dev build that links to the repo:

```bash
./.venv/bin/python3 scripts/install_macos_app.py --dev --open
```

## 3) First run setup

1. In menu bar app, click `OpenAI API Key...`
2. Grant `Microphone` permission in macOS Settings
3. Grant `Accessibility` permission (for auto-paste)

## 4) Usage

- `Option + Space`: start dictation
- `Option + Space`: stop dictation and paste

## 5) Keep running after reboot

In app menu, enable `Launch at Login`.
