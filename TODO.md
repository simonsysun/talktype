# TODO

Single source of truth for what we're doing and what's done.
Design rationale → `PLAN.md`. Shipped history → `CHANGELOG.md`. Don't duplicate them here.

Last reviewed: 2026-08-02

**Current focus: macOS.** iOS is parked by decision (2026-08-02) — see "Parked: iOS" below.

---

## State of the project

- **macOS app (`TalkType/`)** — v1.2.0, feature-complete and previously shipped. Never built on this
  machine until now (fresh clone 2026-08-01).
- **iOS keyboard (`TalkTypeKeyboard/`) + companion app (`TalkTypeiOS/`)** — written in 4 commits on
  2026-04-07/08, then paused. **Never compiled, never run on a device.** Every item under
  "Parked: iOS" is a hypothesis until the thing builds.
- **Transcription** — STT only, no LLM. OpenAI `gpt-4o-mini-transcribe` (default) / `gpt-4o-transcribe`,
  Groq `whisper-large-v3` / `-turbo`. Vocabulary rides on the API's `prompt` parameter;
  `PostProcessor` is regex, not a model.

---

## Blocked — needs Simon

- [ ] **Accept the Xcode license**, required for any `xcodebuild` use including macOS:
      `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`
      (Xcode 26.6 is installed and selected. macOS *and* iOS SDKs are both present —
      `-downloadPlatform iOS` would only add simulator runtimes, not needed for device builds.)
- [ ] **Push access.** `git push` fails: the SSH key authenticates as `simonsunxiphi`, the repo is
      `simonsysun/talktype`. Two commits are sitting local.

---

## Now — macOS

1. [ ] **Run `swift test`.** The suite in `Tests/TalkTypeCoreTests` is written but has never executed:
       XCTest ships with Xcode, not with Command Line Tools. The same 94 assertions were verified
       through a throwaway harness, so this is a format check, not a logic check.
2. [ ] **Build and run the macOS app** — first build on this machine. Confirm the menu bar item,
       hotkey, and a real dictation round trip.
3. [ ] **Share the macOS scheme** (`TalkType.xcodeproj/xcshareddata/xcschemes/`) so
       `xcodebuild -scheme TalkType` works from the CLI without opening the IDE.
4. [ ] **ASR bake-off.** Compare providers on one real 中英混 clip — the current default
       (`gpt-4o-mini-transcribe`) is neither the cheapest nor code-switching-optimised, and Whisper
       is a known weak point for mixed-language speech. Script exists; needs an `OPENROUTER_API_KEY`
       (13 of 18 candidates behind one key). Decide the macOS default from the result.
       **Do not route the product through OpenRouter** — it documents `prompt` as "accepted but
       ignored", which would silently disable the vocabulary feature.
5. [ ] **Menu bar icon.** `statusItem.button?.title = "T"` is a literal letter while the project has
       real icon art (`docs/assets/talktype-logo.png`, `Assets.xcassets`). Use a template image.
6. [ ] Decide on an LLM cleanup pass after transcription (spacing between CJK and Latin, full-width
       vs half-width punctuation, filler removal, keeping English technical terms in English). This is
       what Wispr Flow does and what `PostProcessor`'s regex cannot do. Costs ~300 tokens per
       dictation; the real price is +300–800 ms of latency. Revisit once the bake-off is in.

---

## Parked: iOS

Resume when the phone becomes the priority. Nothing here is verified — the targets have never
compiled.

**Gates before any of it matters:**

- [ ] **Apple Developer Program membership + register IDs** for App Groups, keychain sharing, and
      TestFlight: `dev.talktype.ios`, `dev.talktype.ios.keyboard`, App Group `group.dev.talktype`.
      A free personal team works for device testing but not TestFlight and not App Groups reliably.
- [ ] Decide TestFlight vs. sideload-to-own-device. Changes how much of the icon/version/metadata
      work below matters.

**Then:**

1. [ ] Build all 3 targets and fix whatever falls out. Expect real compile errors — the shared files
       are compiled into the iOS targets by membership only, never type-checked against the iOS SDK.
2. [ ] **Add `Assets.xcassets` to the iOS app target.** `TalkTypeiOS` has
       `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` but an empty Resources build phase and no asset
       catalog → no app icon. TestFlight rejects builds without a 1024×1024 icon + `CFBundleIconName`.
       Source art: `docs/assets/talktype-logo.png`.

Ordered by "will it break on first use", highest first:

3. [ ] **Cap recording length / cut peak memory.** `KeyboardViewController.maxRecordingSeconds = 120`
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

Nice-to-have once it runs at all:

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
- 2026-08-02 — **Decision: macOS first, iOS parked.** This TODO was ordered iOS-first from the
  original audit; reordered to match. Xcode 26.6 installed — both macOS and iOS SDKs shipped with it,
  so no platform download is needed either now or for iOS device builds later.
- 2026-08-02 — ASR provider research. 13 transcription models are reachable through a single
  OpenRouter key; ElevenLabs Scribe and Soniox are not on it. Whole price range is
  $0.04–$0.96/hour, i.e. $0.60–$14.40/month at 30 min/day — small enough that accuracy and latency
  should decide, not cost. Bake-off script written (18 candidates, one clip); unrun, no keys yet.
