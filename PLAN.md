# TalkType iOS — Custom Keyboard Extension

## Problem

TalkType exists as a macOS menu bar dictation app. The same user (me) wants the same
speech-to-text experience on iPhone: speak into any text field, get accurate transcription.
iOS has system dictation, but it's inconsistent, doesn't support custom vocabulary, and
doesn't let you pick your ASR model. I want my own keyboard with one button that does
one thing well.

## Scope

Build an iOS custom keyboard extension + companion app. TestFlight distribution only.
No App Store submission planned. Personal tool.

### What it does

1. **Custom Keyboard Extension** — appears in keyboard list via globe icon switch
   - Minimal UI: single large microphone button, centered
   - Tap to start recording, tap again to stop
   - Speech converts to text and inserts into the active text field
   - Visual feedback during recording (animated bars, like macOS overlay)
   - Visual feedback during processing (animated dots)
   - Elegant, fast, beautiful. Not a full QWERTY keyboard — just the dictation button.

2. **Companion App** — simple settings screen
   - API Key entry (OpenAI)
   - Model selection (gpt-4o-mini-transcribe, gpt-4o-transcribe)
   - Vocabulary management (add/remove/pin words)
   - Maybe Groq support too, since the macOS app already has it

3. **Shared Code** — reuse from macOS app
   - Transcriber.swift (API calls)
   - VocabularyStore.swift (vocabulary persistence)
   - PostProcessor.swift (text normalization)
   - Config.swift (settings persistence)
   - KeyStorage.swift (API key encryption)

### What it does NOT do

- No full QWERTY keyboard layout (globe key switches back to system keyboard for typing)
- No App Store submission (TestFlight only)
- No on-device model (API-only, same as macOS)
- No iPad-specific layout (iPhone-first, iPad works but not optimized)
- No widget, no Siri shortcut, no other integrations

## Architecture

### Targets

```
TalkType.xcodeproj
├── TalkType (macOS app)          — existing
├── TalkTypeKeyboard (iOS ext)    — NEW: keyboard extension
├── TalkTypeiOS (iOS app)         — NEW: companion app
└── TalkTypeShared (framework)    — NEW: shared code
```

### iOS Keyboard Extension Constraints

- Memory limit: ~30MB (iOS kills extensions that exceed this)
- Must declare `RequestsOpenAccess` in Info.plist for microphone + network
- User must explicitly enable keyboard in Settings → General → Keyboard → Keyboards
- User must grant "Allow Full Access" for network/microphone
- Text insertion via `textDocumentProxy.insertText()` (not CGEvent)
- No access to system resources outside the extension sandbox
- App Group (`group.dev.talktype`) for shared UserDefaults + file storage

### Data Flow

```
[User taps mic button]
  → AudioRecorder starts capture (AVAudioEngine, 16kHz)
  → Visual: animated bars showing audio level
[User taps mic button again]
  → AudioRecorder stops, returns PCM buffer
  → Visual: animated dots (processing)
  → Transcriber encodes WAV, sends to OpenAI/Groq API
  → PostProcessor normalizes text, applies vocabulary
  → textDocumentProxy.insertText(result)
  → Visual: return to idle state
```

### Shared Code Strategy

Move these files to a shared framework target:
- `Transcriber.swift` — API calls are URLSession-based, works on both platforms
- `VocabularyStore.swift` — change file paths to use App Group container
- `PostProcessor.swift` — pure text processing, no platform deps
- `Config.swift` — adapt paths for App Group container
- `KeyStorage.swift` — replace macOS `ioreg` machine binding with iOS equivalent
  (use `UIDevice.current.identifierForVendor` or Keychain `kSecAttrAccessGroup`)

### Companion App (SwiftUI)

Simple single-screen app with sections:
- **API Key** — SecureField + provider picker (OpenAI/Groq)
- **Model** — Picker with available models
- **Vocabulary** — List with add/delete, search, pin toggle
- **Status** — Keyboard enabled? Full access granted? Quick setup guide.

### Keyboard Extension UI

Single-view UIKit-based keyboard (not SwiftUI — UIInputViewController requires UIKit):
- Background: system keyboard background color (adapts to light/dark mode)
- Center: large circular microphone button (~80pt diameter)
- States:
  - **Idle**: mic icon, subtle border
  - **Recording**: pulsing ring animation + audio level bars (reuse OverlayWindow style)
  - **Processing**: rotating dots animation
  - **Error**: brief error message, auto-dismiss
- Bottom row: globe button (system-provided `handleInputModeList(from:with:)`)
- Height: standard keyboard height (216pt iPhone, 264pt iPad)

### Interaction Model: Tap-to-Toggle

Tap once to start recording. Tap again to stop and transcribe.

Why not press-and-hold:
- Holding finger on screen for 10+ seconds is uncomfortable
- Finger covers the button, blocking visual feedback
- Accidental lift cancels the recording
- iOS system dictation uses tap-to-toggle
- One-hand operation is easier with two taps than sustained hold

### Logo

Use existing logo from `docs/assets/talktype-logo.png` for the iOS app icon.

## Build Sequence

1. Create shared framework target, move reusable files
2. Create iOS app target with SwiftUI settings screen
3. Create keyboard extension target with mic button UI
4. Wire up audio recording + transcription in extension
5. Add App Group for data sharing
6. Add recording animations
7. Test on device via TestFlight

## Open Questions

- Should the keyboard show a small text preview of what was transcribed?
- Should there be haptic feedback on tap? → YES, add haptic on tap start/stop
- Auto-stop on silence (like macOS) or manual stop only? → YES, reuse silence detection
- Should the companion app also have a "test dictation" button? → YES, good for first-run validation

## CEO Review Findings (2026-04-08)

Reviewed by Claude subagent + Codex. Key decisions:

1. **Keyboard extension confirmed** — globe-switch friction accepted as tradeoff for direct text insertion
2. **Mic access validated** — iOS keyboard extensions CAN record audio with Full Access + RequestsOpenAccess
3. **Code reuse scoped realistically** — Transcriber (async refactor), AudioRecorder, PostProcessor portable. KeyStorage = full rewrite. Config/VocabularyStore need App Group paths.
4. **Build order**: Validate mic access in bare extension FIRST, then layer features
5. **Cut Groq from v1** — OpenAI only to reduce scope. Add Groq later.
6. **KeyStorage on iOS** — Use iOS Keychain Services API directly, drop ChaChaPoly file scheme
7. **Transcriber async** — Convert DispatchSemaphore to async/await for iOS
