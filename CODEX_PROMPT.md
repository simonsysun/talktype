# Whisper — Free Local Voice-to-Text Dictation App for macOS

## Project Overview

Build a free, open-source, fully local voice-to-text dictation app for macOS that rivals SuperWhisper in quality and UX. The app must support **Mandarin Chinese and English at top-level accuracy**, including **code-switching** (混合中英文 in the same sentence), with a beautiful, minimal floating overlay animation inspired by Apple's design language.

Future goal: cross-platform support (Windows, Linux), but the initial build targets macOS only.

---

## Two Modes of Operation

### Mode 1: Dictation Mode (Option+Space)
- **Trigger**: Press `Option+Space` to start recording, press `Option+Space` again to stop
- **Audio source**: Microphone only
- **Behavior**: After stopping, transcribe the audio and auto-paste the result into the currently focused app (any text field in any app)
- **Use case**: Quick voice typing — emails, code comments, chat messages, notes

### Mode 2: Meeting/Class Recording Mode (Option+Shift+Space)
- **Trigger**: Press `Option+Shift+Space` to start, press again to stop
- **Audio source**: Both **system audio** (ScreenCaptureKit loopback) and **microphone**
- **Behavior**: Continuous transcription with timestamps, saved as a transcript file. Does NOT auto-paste — saves to file and shows live transcript in overlay
- **Use case**: Meeting notes, class lectures, podcast transcription
- **System audio capture**: A **Swift CLI helper** (`whisper-audio-tap`) using ScreenCaptureKit API (macOS 13+) that streams raw PCM to stdout. Python reads from subprocess. This avoids PyObjC/ScreenCaptureKit instability on macOS 15 (see [PyObjC issue #647](https://github.com/ronaldoussoren/pyobjc/issues/647))
- **Requires**: macOS 13+. Graceful error message on older macOS

---

## Tech Stack

### Core Runtime: sherpa-onnx
- Cross-platform, supports SenseVoice + FireRedASR + Silero VAD with same API
- Pre-built Python wheels: `pip install sherpa-onnx`
- Docs: https://k2-fsa.github.io/sherpa/onnx/index.html
- Key example: `vad-with-non-streaming-asr.py`

### ASR Models (auto-downloaded on first run → `~/.whisper/models/`)

| Model | Size | RTF | Latency (10s audio) | Purpose |
|-------|------|-----|---------------------|---------|
| **SenseVoice-Small (int8)** | 228 MB | 0.018 | ~180ms | **Default** — fast, good zh+en |
| **FireRedASR2S** | ~1.7 GB | 0.427 | ~4.3s | **Optional accuracy mode** — best code-switching |
| **Silero VAD** | ~2 MB | — | — | Voice activity detection (always loaded) |

**Why SenseVoice is default**: FireRedASR RTF=0.427 means 10s audio takes 4.3s — too slow for the <1s latency target. SenseVoice at RTF=0.018 delivers ~180ms for 10s audio, well within budget. FireRedASR is available as "Accuracy Mode" for users who prioritize code-switching quality over speed.

**Phase 0 benchmark needed**: Before implementation, record 10 mixed zh/en clips and benchmark SenseVoice vs FireRedASR on accuracy + latency to validate this default choice.

### UI Stack: rumps + NSPanel (PyObjC) — single NSApplication runloop

**Why NOT pywebview + pystray**: Both `pywebview.start()` and `pystray.Icon.run()` block the main thread on macOS. No clean way to coordinate them. Instead:
- **`rumps`**: Owns the NSApplication main runloop, provides menu bar icon
- **`NSPanel` (PyObjC)**: Non-focus-stealing floating overlay with `NSNonactivatingPanelMask`
- **`WKWebView` (PyObjC)**: Embedded inside NSPanel for HTML/CSS/JS animations

All in one NSApplication. No conflicts.

### Full Dependency List
```
sherpa-onnx                              # ASR + VAD runtime
sounddevice                              # Microphone capture
numpy                                    # Audio buffer processing
rumps                                    # macOS menu bar (owns NSApplication runloop)
pyobjc-framework-Cocoa                   # NSPanel, NSPasteboard, NSEvent
pyobjc-framework-Quartz                  # CGEvent (Cmd+V paste simulation)
pyobjc-framework-WebKit                  # WKWebView (overlay animations)
pyyaml                                   # Config file
requests                                 # Model download
tqdm                                     # Download progress bar
```

No pywebview. No pystray. No main-loop conflicts.

---

## Architecture

```
┌──────────────────────────────────────────┐
│  NSApplication Main Runloop (rumps)      │
│  ├─ NSStatusItem (menu bar icon)         │  via rumps
│  ├─ NSPanel (floating overlay)           │  PyObjC, non-activating
│  │   └─ WKWebView (HTML/CSS animations)  │  waveform + dots + checkmark
│  └─ NSEvent monitor (global hotkeys)     │  Option+Space, Option+Shift+Space
├──────────────────────────────────────────┤
│  Background Threads                      │
│  ├─ Audio capture (sounddevice)          │  16kHz mono mic input
│  ├─ System audio (Swift helper subprocess)│  Meeting mode: ScreenCaptureKit
│  ├─ Transcription (sherpa-onnx)          │  SenseVoice / FireRedASR
│  └─ Audio level → WKWebView             │  evaluateJavaScript for waveform
└──────────────────────────────────────────┘
```

---

## File Structure

```
whisper/
├── core/
│   ├── __init__.py
│   ├── audio.py              # Mic capture via sounddevice (16kHz mono)
│   ├── transcriber.py        # sherpa-onnx ASR (SenseVoice default, FireRedASR optional)
│   ├── models.py             # Auto-download, ~/.whisper/models/, checksums
│   └── vad.py                # Silero VAD via sherpa-onnx
├── platform/
│   ├── __init__.py
│   ├── base.py               # Abstract platform interface
│   └── macos.py              # NSEvent hotkeys + CGEvent paste + Swift helper bridge
├── helpers/
│   └── whisper-audio-tap/    # Swift CLI for ScreenCaptureKit system audio
│       ├── Package.swift
│       └── Sources/main.swift
├── ui/
│   ├── __init__.py
│   ├── tray.py               # rumps menu bar app
│   ├── overlay.py            # NSPanel + WKWebView controller (PyObjC)
│   ├── overlay.html          # Animation HTML structure
│   ├── overlay.css           # Waveform + pulse + fade animations
│   └── overlay.js            # JS: setState(), updateAudioLevel() called from Python
├── app.py                    # Main entry: init models, start rumps, coordinate
├── config.py                 # YAML config (~/.whisper/config.yaml)
├── history.py                # SQLite transcription history
├── requirements.txt
└── setup.py
```

---

## UX & Animation Design (Apple HIG)

### Design Philosophy
- **Purposeful**: Every animation communicates state — never decorative
- **Brief & precise**: Lightweight, non-intrusive
- **Fluid**: Smooth transitions between states
- **Respect Reduce Motion**: If enabled in macOS settings, use opacity-only transitions

### Floating Overlay (NSPanel + WKWebView)

**Shape**: Pill / capsule, ~200×44px, corner radius 22px
**Position**: Center-bottom, ~80px from bottom edge (configurable)
**Background**: Frosted glass effect
```css
backdrop-filter: blur(20px);
/* Light */ background: rgba(255, 255, 255, 0.72);
/* Dark  */ background: rgba(30, 30, 30, 0.72);
```
Auto-follows macOS appearance via `prefers-color-scheme`.
**Shadow**: `0 2px 12px rgba(0, 0, 0, 0.15)`
**Border**: `0.5px solid rgba(255, 255, 255, 0.18)`

**Window config (PyObjC)**:
```python
panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
    frame,
    NSNonactivatingPanelMask | NSTitledWindowMask | NSFullSizeContentViewWindowMask,
    NSBackingStoreBuffered,
    False
)
panel.setBecomesKeyOnlyIfNeeded_(True)
panel.setLevel_(NSFloatingWindowLevel)
panel.setTitlebarAppearsTransparent_(True)
panel.setTitleVisibility_(NSWindowTitleHidden)
panel.setMovableByWindowBackground_(False)
panel.setHasShadow_(True)
panel.setOpaque_(False)
panel.setBackgroundColor_(NSColor.clearColor())
```

### State Animations

#### 1. Appear (idle → recording)
- Scale 0.8→1.0, opacity 0→1
- Duration: 200ms, easing: `cubic-bezier(0.4, 0, 0.2, 1)`

#### 2. Recording
- **5 vertical bars** centered, 3px wide, 4px gap, rounded caps (1.5px radius)
- Heights driven by **real-time audio RMS** from Python
  - Streamed every ~50ms via `evaluateJavaScript("updateAudioLevel(0.73)")`
  - Per-bar multiplier: [0.6, 0.8, 1.0, 0.8, 0.6] for organic feel
  - Quiet: bars at 4px (gentle idle breathing)
  - Speaking: bars scale up to max ~28px
- Color: `#007AFF` (Apple Blue)
- CSS: `transition: height 80ms ease`
- Small mic icon (SF Symbol style) to the left

#### 3. Processing (recording → transcribing)
- Bars morph → **3 pulsing dots** (iMessage typing style)
- Dots: 6px diameter, `#007AFF`, 8px spacing
- Sequential scale pulse: 1.0→1.4→1.0, 150ms stagger, 600ms cycle
- Easing: `cubic-bezier(0.4, 0, 0.2, 1)`

#### 4. Done (transcribing → done)
- Dots → **animated checkmark** (SVG stroke-dashoffset draw, 300ms)
- Hold checkmark 400ms
- Fade out: opacity 1→0, scale 1.0→0.95, 300ms
- Total visible after done: ~700ms

#### 5. Meeting Mode Overlay
- Wider pill (~320px), positioned top-right corner
- Red pulsing dot (left) + scrolling live transcript (right, last 2 lines)
- Text: system monospace, 12px, 60% opacity

---

## Interaction Flow

### Dictation Mode
```
Option+Space pressed
  → overlay appears (scale+fade, 200ms)
  → waveform bars animate from real mic audio
  → user speaks (混合中英文 is fine)
Option+Space pressed again
  → recording stops
  → overlay → processing dots (300ms morph)
  → sherpa-onnx SenseVoice transcribes (~180ms for 10s audio)
  → result → NSPasteboard (clipboard) using NSPasteboardTypeString
  → CGEvent simulates Cmd+V → text pastes into focused app
  → overlay → checkmark (400ms) → fade out (300ms)
Total after stop: typically <500ms
```

### Meeting Mode
```
Option+Shift+Space pressed
  → meeting overlay appears (top-right, red dot)
  → spawn Swift helper subprocess (whisper-audio-tap) for system audio
  → start sounddevice for mic audio
  → process audio chunks every 5-10s (via VAD)
  → live transcript scrolls in overlay
  → full transcript → ~/Documents/Whisper/meetings/YYYY-MM-DD_HH-MM.txt
Option+Shift+Space pressed again
  → stop all capture
  → save final transcript
  → macOS notification: "Transcript saved"
  → overlay fades out
```

---

## Key Technical Details

### Audio Capture
```python
import sounddevice as sd
import numpy as np

# Mic input with callback for real-time levels
def audio_callback(indata, frames, time, status):
    rms = np.sqrt(np.mean(indata**2))
    audio_buffer.append(indata.copy())
    overlay.update_audio_level(rms)  # → evaluateJavaScript

stream = sd.InputStream(
    samplerate=16000, channels=1, dtype='float32',
    callback=audio_callback, blocksize=1024
)
```

### Transcription
```python
import sherpa_onnx

# SenseVoice (default — fast mode)
recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
    model="~/.whisper/models/model.int8.onnx",
    tokens="~/.whisper/models/tokens.txt",
    num_threads=2,
    use_itn=True,
)

# Process audio buffer
audio_data = np.concatenate(audio_buffer)
stream = recognizer.create_stream()
stream.accept_waveform(16000, audio_data)
recognizer.decode(stream)
text = stream.result.text
```

### Paste to Focused App
```python
from AppKit import NSPasteboard, NSPasteboardTypeString

# Copy to clipboard
pb = NSPasteboard.generalPasteboard()
pb.clearContents()
pb.setString_forType_(text, NSPasteboardTypeString)

# Simulate Cmd+V
from Quartz import CGEventCreateKeyboardEvent, CGEventSetFlags, CGEventPost
from Quartz import kCGHIDEventTap, kCGEventFlagMaskCommand

v_down = CGEventCreateKeyboardEvent(None, 9, True)   # keycode 9 = 'v'
v_up   = CGEventCreateKeyboardEvent(None, 9, False)
CGEventSetFlags(v_down, kCGEventFlagMaskCommand)
CGEventSetFlags(v_up, kCGEventFlagMaskCommand)
CGEventPost(kCGHIDEventTap, v_down)
CGEventPost(kCGHIDEventTap, v_up)
```

### Global Hotkey
```python
from AppKit import NSEvent, NSKeyDownMask

def hotkey_handler(event):
    flags = event.modifierFlags()
    keycode = event.keyCode()
    # Option+Space: keycode 49, option flag
    # Option+Shift+Space: keycode 49, option+shift flags
    ...

NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(NSKeyDownMask, hotkey_handler)
```

### NSPanel Overlay (Non-Focus-Stealing)
```python
from AppKit import (NSPanel, NSNonactivatingPanelMask, NSTitledWindowMask,
                    NSFullSizeContentViewWindowMask, NSBackingStoreBuffered,
                    NSFloatingWindowLevel, NSColor, NSWindowTitleHidden)
from WebKit import WKWebView, WKWebViewConfiguration

# Create non-activating panel
panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
    frame,
    NSNonactivatingPanelMask | NSTitledWindowMask | NSFullSizeContentViewWindowMask,
    NSBackingStoreBuffered,
    False
)
panel.setBecomesKeyOnlyIfNeeded_(True)
panel.setLevel_(NSFloatingWindowLevel)
panel.setOpaque_(False)
panel.setBackgroundColor_(NSColor.clearColor())

# Embed WKWebView
config = WKWebViewConfiguration.alloc().init()
webview = WKWebView.alloc().initWithFrame_configuration_(panel.contentView().bounds(), config)
panel.contentView().addSubview_(webview)

# Load animation HTML
webview.loadHTMLString_baseURL_(html_content, None)

# Send audio levels to JS
webview.evaluateJavaScript_completionHandler_(f"updateAudioLevel({level})", None)
```

### Swift Helper (System Audio Capture)
```swift
// helpers/whisper-audio-tap/Sources/main.swift
import ScreenCaptureKit
import Foundation

// Capture system audio via ScreenCaptureKit, output PCM to stdout
// 16kHz mono float32, written to FileHandle.standardOutput
// Python reads: subprocess.Popen(["./whisper-audio-tap"], stdout=PIPE)
```

---

## Configuration (~/.whisper/config.yaml)

```yaml
model: sensevoice          # "sensevoice" (fast) or "firered" (accuracy)
models_dir: ~/.whisper/models

dictation_hotkey: option+space
meeting_hotkey: option+shift+space

audio_device: default
sample_rate: 16000

overlay_position: center-bottom    # center-bottom or top-right
overlay_theme: auto                # auto, light, dark

meeting_output_dir: ~/Documents/Whisper/meetings
meeting_chunk_seconds: 10

launch_at_login: false
history_enabled: true
```

---

## Critical Constraints

1. **Must NOT steal focus** — NSPanel with `NSNonactivatingPanelMask` + `becomesKeyOnlyIfNeeded`
2. **Must work offline** — zero network calls during operation
3. **Must handle code-switching** — "我今天有个meeting在下午three点" should transcribe correctly
4. **Latency < 1 second** (SenseVoice default: ~180ms for 10s audio, plus paste overhead)
5. **No subscription, no API keys, no cloud**
6. **Accessibility permission** — graceful first-run prompt
7. **Cross-platform core** — `core/` is OS-agnostic. macOS-specific code in `platform/macos.py`
8. **macOS 13+ for meeting mode** — ScreenCaptureKit requirement. Dictation works on older macOS
9. **Single main thread** — `rumps` owns NSApplication. Audio + transcription on background threads

---

## Packaging & Distribution

**Development**: Run directly with `python whisper/app.py`
**Distribution**: `py2app` → standalone .app bundle
**Signing**: Apple Developer ID + `codesign --deep --force --sign "Developer ID Application: ..." Whisper.app`
**Notarization**: `xcrun notarytool submit Whisper.zip --apple-id ... --team-id ...`
**Entitlements**: `com.apple.security.device.audio-input`, `com.apple.security.automation.apple-events`
**Future**: Homebrew formula (`brew install --cask whisper`)
