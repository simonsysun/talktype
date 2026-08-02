# TODO

Single source of truth for what we're doing and what's done.
Design rationale → `PLAN.md`. Shipped history → `CHANGELOG.md`. Don't duplicate them here.

Last reviewed: 2026-08-02

**Current focus: macOS, local-only ASR.** iOS is parked by decision (2026-08-02).

---

## State of the project

- **macOS app (`TalkType/`)** — v2.0.1, shipped. Local Qwen3-ASR sidecar, optional Groq polish,
  first-run setup window, GitHub release with a downloadable build.
- **iOS keyboard (`TalkTypeKeyboard/`) + companion app (`TalkTypeiOS/`)** — written 2026-04-07/08,
  then paused. **Never compiled, never run on a device.** Everything under "Parked: iOS" is a
  hypothesis until the targets build.

---

## Now — macOS

1. [ ] Deferred: overlay draggability. It is `ignoresMouseEvents = true` and fixed
       bottom-centre. Simon asked for it to move to the bottom (done) but has not said
       whether he wants to drag it.
2. [ ] Deferred: filler-word cleanup is handled by the Groq polish, with
       `PostProcessor.tidySpeech` as the offline floor. Revisit only if the floor proves weak.
3. The signing certificate's backup lives in `secrets/`, which `.gitignore` covers — verified
   that `git add -A` cannot stage it. Do not move it anywhere `.gitignore` does not reach.
   Losing it costs one extra grant for everyone, once, and nothing else.

---

## ASR decision (2026-08-02)

Benchmarked 14 cloud models plus local Qwen3-ASR on one real recording of Simon's voice
(Chinese-primary with embedded English). Measurements, not vendor claims:

| | latency | notes |
|---|---|---|
| **local Qwen3-ASR-1.7B (MLX)** | **0.30 s** short / **0.91 s** long | chosen |
| Soniox stt-async-v5 | 2.9–4.6 s | most accurate cloud model; only one that heard "Claude" |
| OpenAI gpt-4o-mini (old default) | 0.5–1.1 s | misheard 财报 as 采访 — a meaning error |
| Grok STT | 0.6 s | translated half the clip to English; no punctuation |
| Deepgram Nova-3, NVIDIA Parakeet, Google Chirp 3 | — | unusable on Chinese |

Local wins on latency *and* privacy *and* offline, and matched or beat cloud Qwen on accuracy —
the open 1.7B weights are not the downgrade they were assumed to be. Cost was never the deciding
factor: the whole cloud field spanned $0.60–$14.40/month at 30 min/day.

Things learned that constrain the implementation:

- **Vocabulary must be a bare comma list.** A prose context string made the model complete the
  prompt instead of transcribing: it translated a Chinese clip to English and invented a sentence
  that was never spoken. Same failure mode `PostProcessor.isLikelyHallucination` was written to
  catch on Whisper. `Transcriber.buildPrompt` already produces the safe form — keep it that way.
- **Language stays auto-detected.** Pinning `zh` slightly improved Chinese punctuation but Simon
  also dictates English-primary. Pinning does not corrupt the other language (a zh-pinned English
  clip transcribed perfectly), it only nudges punctuation conventions.
- **MLX's Metal stream is thread-local.** Inference must run on the thread that loaded the
  weights, or it fails with "There is no Stream(gpu, 0) in current thread". The sidecar queues
  jobs to a single worker.
- **No model removes filler words** (呃/嗯/啊). Faithful transcription is ASR's job. Deferred:
  decide after living with it whether a cleanup pass is worth the latency.
- `cloud` vs `Claude` is unfixable by vocabulary (common English word, correctly rejected by
  `isSafeForAutoReplace`). Accepted as an edge case.

Runtime lives in `~/.talktype/asr/`: `venv/` (Python 3.13 + qwen3-asr-mlx), `hf/` (3.8 GB
weights), `server.py`. Runs with `HF_HUB_OFFLINE=1`.

---

## Now — macOS

1. [ ] **Run `swift test`.** The suite in `Tests/TalkTypeCoreTests` is written but has never executed:
       XCTest ships with Xcode, not with Command Line Tools. The same 94 assertions were verified
       through a throwaway harness, so this is a format check, not a logic check.
2. [ ] **Build and run the macOS app** — first build on this machine. Confirm the menu bar item,
       hotkey, and a real dictation round trip.
3. [ ] **Share the macOS scheme** (`TalkType.xcodeproj/xcshareddata/xcschemes/`) so
       `xcodebuild -scheme TalkType` works from the CLI without opening the IDE.
4. [x] **ASR bake-off** — done, see "ASR decision" above. Local Qwen3-ASR chosen.
5. [ ] **Cut over to the local sidecar.** Delete every cloud path (~580 lines):
       `KeyStorage.swift` entirely, `ASRProvider`, the multipart/HTTPS body building in
       `Transcriber`, and the Provider / Model / API Key menus in `TalkTypeApp`. `Transcriber`
       becomes a POST of raw WAV bytes to `127.0.0.1:8756/transcribe` with an
       `X-TalkType-Context` header. Keep `WAVEncoder`, `PostProcessor`, `VocabularyStore`.
       **Removes the cloud fallback** — if the sidecar is down there is no dictation, by decision.
6. [ ] **Sidecar lifecycle in Swift.** Spawn `~/.talktype/asr/venv/bin/python server.py` at launch
       with `HF_HUB_OFFLINE=1`, poll `/health` until ready, terminate it on quit, and show a real
       menu bar state when it is missing or still loading (weights take ~1 s cold).
7. [ ] **Menu bar icon.** `statusItem.button?.title = "T"` is a literal letter while the project has
       real icon art (`docs/assets/talktype-logo.png`, `Assets.xcassets`). Use a template image.
8. [ ] Deferred: filler-word cleanup (呃/嗯/啊). No ASR model removes them. Decide after living with
       the raw output for a few days — do not build it speculatively.

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

Shipped work is in `CHANGELOG.md` (macOS v1.0.0 → v2.0.1). iOS has shipped nothing yet.

- 2026-08-02 — **Released v2.0.2, signed with a self-signed certificate.** Ad-hoc signing
  makes the designated requirement a cdhash, so every update silently revoked the
  Accessibility grant while System Settings still showed the app switched on. A certificate
  makes it `identifier "..." and certificate root = H"..."`, identical across builds.
  Verified end to end: granted build 202, installed build 203 (different cdhash, no new
  grant), and the app launched without logging a missing permission. `scripts/build.sh`
  signs when the certificate is present and warns when it is not, so a plain clone still
  builds.

- 2026-08-02 — **Pasting instead of typing.** Dictation ended on the clipboard needing a manual
  ⌘V, because the Accessibility grant had gone stale (ad-hoc cdhash changes every build) and
  nothing in the app said so. Insertion is now a synthesized ⌘V, which also fixes long paragraphs
  losing their tail in terminals and Electron apps; the transcript stays on the clipboard so a
  manual paste is always a working fallback. Failure now offers a Fix button that clears the stale
  TCC record and re-asks, because telling someone to enable an already-enabled switch is no help.
- 2026-08-02 — Overlay reworked to be quiet: no idle animation (only speech moves it), plain fades
  instead of springs, 67×22 with seven bars resting as a level row of dots. Its bars had been
  added to `NSVisualEffectView`'s layer, which is not guaranteed to exist yet.
- 2026-08-02 — **`swift test` could not build at all** — `AudioRecorder` references `AudioDevices`
  and the package excluded it. 59 tests now run.
- 2026-08-02 — README rewritten for people rather than engineers, and the GitHub repo given a
  description and topics (both were empty, which is most of why nothing could find it).
- 2026-08-02 — Released v2.0.0: local-only ASR, Groq polish, setup window, memory flat under load.

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
