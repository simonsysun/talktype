# TODO

Single source of truth for what we're doing and what's done.
Design rationale → `PLAN.md`. Shipped history → `CHANGELOG.md`. Don't duplicate them here.

Last reviewed: 2026-08-01

---

## State of the project

- **macOS app (`TalkType/`)** — v1.2.0, feature-complete and previously shipped. Not built on this
  machine (fresh clone, no Xcode).
- **iOS keyboard (`TalkTypeKeyboard/`) + companion app (`TalkTypeiOS/`)** — written in 4 commits on
  2026-04-07/08, then paused. **Never compiled, never run on a device.** Every item under
  "iOS: make it actually work" below is a hypothesis until the thing builds.

---

## Blocked — needs Simon

- [ ] **Install Xcode.** Nothing on the iOS side can be verified without it. `xcode-select` currently
      points at `/Library/Developer/CommandLineTools`. After install:
      `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- [ ] **Apple Developer Program membership + register IDs.** Needed for App Groups, keychain sharing,
      and TestFlight. Register: `dev.talktype.ios`, `dev.talktype.ios.keyboard`,
      App Group `group.dev.talktype`. Free personal team works for device testing but *not* TestFlight
      and *not* App Groups reliably.
- [ ] Decide: keep TestFlight-only, or just sideload to own device (7-day resign with free team).
      Changes how much of the icon/version/metadata work below matters.

---

## Now — get iOS to build

0. [ ] **Run `swift test` once Xcode is installed.** The suite in `Tests/TalkTypeCoreTests` is
       written but has never executed: XCTest ships with Xcode, not with Command Line Tools. The
       same 85 assertions were verified today through a throwaway harness, so this is a format
       check, not a logic check.
1. [ ] Open `TalkType.xcodeproj` in Xcode, build all 3 targets, fix whatever falls out.
       Expect real compile errors: the shared files are compiled into iOS targets by membership only,
       never type-checked against the iOS SDK.
2. [ ] **Add `Assets.xcassets` to the iOS app target.** `TalkTypeiOS` has
       `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` but an empty Resources build phase and no asset
       catalog → no app icon. TestFlight rejects builds without a 1024×1024 icon + `CFBundleIconName`.
       Source art: `docs/assets/talktype-logo.png`.
3. [ ] **Share the schemes** (`TalkType.xcodeproj/xcshareddata/xcschemes/`) so `xcodebuild -scheme`
       works from CLI and agents can verify builds without opening the IDE.
4. [ ] Commit `project.json` (currently untracked).

---

## Next — iOS: make it actually work

Ordered by "will it break on first use", highest first.

5. [ ] **Cap recording length / cut peak memory.** `KeyboardViewController.maxRecordingSeconds = 120`
       is dangerous. Keyboard extensions get a small memory budget (commonly cited ~30–60 MB). At a
       48 kHz hardware rate, 120 s of `Float` mono is ~23 MB in `AudioRecorder.buffer`, and
       `stop()` does `chunks.flatMap` → another ~23 MB live at the same instant, before WAV encoding
       adds ~8 MB more. Peak ≈ 46 MB+ → likely jetsam kill mid-transcription.
       Fix: drop to ~45 s, and/or resample per-chunk on capture instead of retaining hardware-rate audio.
6. [ ] **Request mic permission from the companion app.** A keyboard extension very likely cannot
       present the system mic prompt; when permission is undetermined `requestRecordPermission`
       returns denied with no UI (`KeyboardViewController.swift:196`), dead-ending first run with
       "Microphone access required" — and TalkType won't even appear under Settings → Privacy →
       Microphone until the *app* has asked once. Add the mic request + the "test dictation" button
       `PLAN.md` already committed to.
7. [ ] **Detect "Allow Full Access" being off.** Without it, network + App Group + keychain all fail
       and the user just sees "Transcription failed." Check `hasFullAccess` and show a real message
       pointing at the setting.
8. [ ] **Leading-space handling on insert.** `textDocumentProxy.insertText(text)`
       (`KeyboardViewController.swift:265`) concatenates into whatever is already there → "helloworld".
       Inspect `documentContextBeforeInput` and insert a separator when needed.
9. [ ] **Silence auto-stop on iOS.** `AppConfig` carries `silenceAutoStopEnabled/Seconds/RmsThreshold`
       and `PLAN.md` said reuse it; the keyboard only has the hard 120 s timer. macOS logic lives in
       `DictationManager`.
10. [ ] **Make `validateKey` async.** It blocks on `DispatchSemaphore` and `SettingsView.saveAPIKey`
       calls it from `Task.detached` — that still occupies a cooperative-pool thread, and the comment
       at `SettingsView.swift:158` claiming otherwise is wrong. `transcribeAsync` already shows the
       right shape.
11. [ ] **Surface keychain failures.** `KeyStorage.storeKey` swallows the `OSStatus`; the UI only says
       "Failed to save API key to keychain", which is useless when the real cause is a missing
       entitlement. Return/log the status.
12. [ ] Decide Groq on iOS. `SettingsView` hardcodes `provider = .openai` while the keyboard reads
       `config.asrProvider` — so the config knob exists but nothing can set it. Either expose the
       picker (Groq's free tier is genuinely attractive on mobile) or remove the dead knob.

---

## Later

- [ ] Undo affordance on the keyboard — a mis-transcription currently requires switching keyboards to
      fix. A delete key, or "undo last insert".
- [ ] Don't lose text when the keyboard is dismissed mid-transcription
      (`viewWillDisappear` cancels the task and the result is gone).
- [ ] Deprecation cleanup once the deployment target allows: `AVAudioSession.requestRecordPermission`
      → `AVAudioApplication` (iOS 17), `traitCollectionDidChange` → trait registration (iOS 17).
      Current override is also a no-op — it sets `shadowColor` to black in both light and dark.
- [ ] README covers macOS only — add the iOS keyboard once it works.

---

## Done

Shipped work is in `CHANGELOG.md` (macOS v1.0.0 → v1.2.0). iOS has shipped nothing yet.

- 2026-08-01 — Full project audit; this TODO created as the live tracker.
- 2026-08-01 — **Fixed a crash in `AudioRecorder.resample`.** When the interpolation path produced
  exactly one output sample, the ratio divided by zero and `Int(infinity)` trapped — a hard crash,
  not an exception. Needs a non-integer rate (44.1 kHz hardware → 16 kHz) plus a very short capture.
  Rare, but it would kill the menu bar app outright and make the iOS keyboard vanish mid-use.
- 2026-08-01 — Added `Package.swift` + `Tests/TalkTypeCoreTests` (94 assertions over WAV encoding,
  post-processing, vocabulary storage, RMS, resampling, response parsing). Verification only —
  the shipping products still build from `TalkType.xcodeproj`.
- 2026-08-01 — Deduplicated `Transcriber`: `transcribe` and `transcribeAsync` shared ~40 copy-pasted
  lines of multipart body construction. Now one `buildRequest` and one `parseResponse`; WAV encoding
  moved to a testable `WAVEncoder` (byte-identical output, ~20x faster but that's only ~10 ms on a
  30 s clip — the win here is that the two paths can no longer drift).
- 2026-08-01 — Hygiene: dropped the dead `dictation_hotkey` config field (the hotkey lives in
  KeyboardShortcuts' UserDefaults), macOS `MARKETING_VERSION` 1.0.0 → 1.2.0 to match the CHANGELOG,
  `.gitignore` cleared of Python-era entries.
