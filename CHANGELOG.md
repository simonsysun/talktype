# Changelog

## v3.0.0 — 2026-08-05

TalkType is now a shell around one speech-to-text API call. Record, send, paste — nothing in
between.

### Changed

- **One call, four providers.** Pick ElevenLabs Scribe v2, xAI Grok, Soniox v5, or OpenAI
  `gpt-transcribe` from the menu bar. Each keeps its own key, so switching to compare costs a
  menu click. The quality-deciding parameters are set in code: `no_verbatim=true` and
  `tag_audio_events=false` for ElevenLabs, `filler_words=false` for Grok, both `zh` and `en`
  hints for Soniox and OpenAI, and no pinned language for ElevenLabs so mixed
  Chinese/English survives.
- **Vocabulary goes to the provider, not to a rewrite pass.** Terms are sent as `keyterm`,
  `keyterms`, `context.terms`, or `keywords[]` depending on the provider. Nothing is
  corrected locally afterwards, so a term that still comes out wrong is real signal about
  that provider.

### Removed

- **The polish pass** (Groq LLM) — providers now do filler removal inside transcription.
- **The local engine** — the ~4 GB MLX sidecar, its installer, the cloud→local fallback, and
  the reachability probe. There is no offline mode: no network is now a clear error.
- **All local text post-processing** — Chinese/English spacing, full-width punctuation,
  stutter collapsing, hallucination discarding, and vocabulary canonicalisation. Output is
  the provider's, unmodified. This can regress text quality in ways the old pipeline hid;
  the code is in git history and comes back per-symptom if real use calls for it.

### Notes

- Keys from the previous release (OpenRouter, Groq) are deliberately left in the Keychain, so
  going back to v2.3.2 does not mean setting it up again.
- `TALKTYPE_STATE_DIR` overrides where config and vocabulary live — useful for trialling a
  setup without touching the real one.

## v2.3.2 — 2026-08-05

The recording indicator now stays visually stable around Liquid Glass.

### Fixed

- **Stable overlay edges on macOS 26**: the outer glow no longer changes blur radius with
  every audio level update, and the Liquid Glass container is no longer scaled during its
  entrance. Voice activity stays in the seven bars, so the pill no longer produces a moving
  ring of pixels around itself.
- **Processing and Reduce Motion**: the processing breath now animates only the bars instead
  of the glass material, and the transition back to rest respects Reduce Motion.

## v2.3.1 — 2026-08-04

Bluetooth headset capture and paste feedback fixes.

### Fixed

- **Bluetooth (HFP) capture race**: the input format is re-read at every recording start
  and waited for to match the device's nominal rate (up to 0.8 s), so AirPods connect and
  work without a restart; a device that never settles now fails loudly instead of caching
  a bad format or crashing.
- **No beep when there is no text field**: pasting now checks the focused element and
  skips the synthesized ⌘V when nothing can receive text — the text goes to the clipboard
  with a hint instead of macOS playing the "can't do that" sound. The check is a
  blacklist, so self-drawn terminals keep working.
- **Failure paths now land in `~/.talktype/talktype.log`** (mic start, device/format,
  no-speech, transcription errors) — previously invisible when launched from Finder.

## v2.3.0 — 2026-08-04

Groq polish is back — the transcript (never the audio) is tidied by Qwen on Groq before
typing, with the deterministic local tidy as the always-on fallback.

### Added

- **Cloud polish restored** after the 2.2.0 simplification removed it. Setup has two keys
  again: OpenRouter (recognition) and Groq (polish, optional). Text only, ~0.3 s; any
  failure falls back to the local tidy after at most ~2.5 s.

### Changed

- **Automatic microphone follows the system default**, including a connected Bluetooth
  headset (AirPods). Recording through a Bluetooth mic switches the link into headset
  mode, so audio output drops to 24 kHz mono — measured to last several minutes after
  dictation ends, not just during it. The accepted price of "system default".

### Notes

- If you ran 2.2.0, its startup cleanup deleted the Groq key from your keychain — enter it
  again in Setup ▸ Cloud polish.

## v2.2.0 — 2026-08-04

One model, one provider, one key.

### Changed

- **Cloud engine is OpenRouter only** — Qwen3-ASR-Flash, fixed. The provider dropdown,
  custom base URL, and model field are gone; there is nothing left to misconfigure.
- **Settings window is two things:** your OpenRouter key, and the local engine's
  install/delete. Groq polish, its key, and the menu toggle are removed — the transcript
  is exactly what the engine heard, tidied by deterministic local rules.
- **Local engine unchanged** as the offline fallback: no network (or cloud unreachable)
  switches automatically, and back again when the cloud recovers.

## v2.1.0 — 2026-08-04

Cloud-first dictation with automatic local fallback.

### Added

- **Cloud engine is now the default** — Qwen3-ASR-Flash through OpenRouter (bring your own key,
  ≈ $2/month at 30 min/day). The ~4 GB local engine is an optional one-click download you can
  delete any time from Setup.
- **Automatic offline fallback** — no network (or the cloud unreachable) switches to the local
  engine on its own and tells you at the switch; it returns to cloud when the network is back.
  Cloud requests use a short 10 s deadline when the local engine is installed, so the fallback
  never makes you wait out a long timeout.
- **Delete local engine** in Setup, with a confirmation dialog.
- **README rewritten** as a product guide plus a manual (English / 中文), including an honest
  privacy table.

### Notes

- If you were on a local-only build, the new default is cloud: Setup will ask for an OpenRouter
  key. Choose Local in the menu if you'd rather audio never leave the machine.

## v2.0.2 — 2026-08-02

Dictation now reaches your cursor. It did not, before.

### Fixed

- **The transcript is pasted instead of typed.** Insertion was a stream of chunked unicode
  key events, which several apps — terminals and Electron ones especially — dropped or
  reordered the tail of. A synthesized ⌘V arrives whole and instantly, regardless of
  length. The transcript is deliberately left on the clipboard so a manual paste is always
  a working fallback.
- **The Accessibility permission survives updates.** An ad-hoc signature's designated
  requirement is a cdhash, so every new build silently revoked the grant while System
  Settings went on showing TalkType switched on — which is why dictation ended on the
  clipboard with no explanation. Releases are now signed with a self-signed certificate,
  making the requirement a certificate match that is identical across builds. Verified by
  granting one build and confirming a different binary kept the permission.
  `scripts/make-signing-cert.sh` creates it; `scripts/build.sh` uses it. Gatekeeper still
  asks for right-click ▸ Open on first launch — that needs the paid programme.
- **When pasting does fail, the app says so** and offers to repair it, clearing the stale
  permission record and asking macOS again. Telling someone to enable a switch that is
  already enabled is no help.
- **The overlay could come up empty.** Its bars were added to `NSVisualEffectView`'s layer,
  which is not guaranteed to exist yet.
- **`swift test` could not build at all** — `AudioRecorder` references `AudioDevices`, and
  the test package excluded it. 59 tests now run.

### Changed

- **The overlay is quiet.** No idle animation — only speech moves it. Appearing and leaving
  are plain fades rather than springs. Smaller: 67×22 with seven bars, resting as a level
  row of dots.
- **README rewritten** for people rather than engineers, with a Chinese translation, and the
  GitHub repository given a description and topics.

## v2.0.0 — 2026-08-02

Transcription moved onto the machine. This is a different product from v1.x: there are no
cloud speech providers, no API keys for transcription, and no network involved in hearing
what you said.

### Changed — local-only transcription

- **Speech recognition moved on-device.** Qwen3-ASR runs locally through an MLX sidecar;
  audio never leaves the machine. Chosen after benchmarking fourteen cloud services on
  real recordings — the local model was faster than all of them.
- **All cloud ASR providers removed**, along with `KeyStorage`, the provider and model
  menus, and every API key path they needed. There is no cloud fallback by design.
- **Optional cloud polishing**: the transcript — never the audio — can be sent to Groq to
  remove filler words, fix punctuation and resolve self-corrections. Off by one menu
  click, with a deterministic local tidy in its place.
- **New icon and overlay**: one waveform mark across the app icon, the menu bar and the
  dictation overlay.
- **First-run setup window** installs the speech engine, takes a Groq key, and shows the
  state of the two system permissions. The installer ships inside the app bundle and
  fetches `uv` and Python itself, so nothing has to be prepared by hand.
- **Microphone picker**, remembered by device UID so it survives reconnects.
- Key events are written to `~/.talktype/talktype.log`, since an app launched from Finder
  has nowhere to print.

### Bug Fixes

- **Crash on short recordings at non-integer sample rates**: `AudioRecorder.resample` divided by zero
  when the linear-interpolation path produced exactly one output sample, then trapped converting
  infinity to `Int`. Triggered by 44.1 kHz input hardware plus a very short capture.
- **The sidecar exited the moment it started when run by hand.** Its parent-watchdog reads
  stdin and exits on EOF; backgrounded from a shell, stdin closes immediately, which is
  indistinguishable from the app dying. The watchdog is now opt-in and only the app asks
  for it — the debugging command in the README could not have worked.
- **Long dictations came back shorter than they went in.** The refinement prompt licensed
  the model to reorder for readability, and it took that as permission to rewrite casual
  speech into formal prose, losing about 30% of the content. The plausibility gate missed
  it because its floor was a fixed fraction; deletions are now budgeted in characters.
- **Settings were silently reset by any new config key.** `AppConfig` used synthesised
  decoding, so a `config.json` written before a key existed failed to decode entirely.

### Code Quality

- `Transcriber.transcribe` and `transcribeAsync` no longer duplicate multipart body construction —
  both go through one `buildRequest` and one `parseResponse`, so the sync (macOS) and async (iOS)
  paths can't drift apart. A JSON response without a `text` field now yields an empty string instead
  of dumping raw JSON into the document.
- WAV encoding extracted to `WAVEncoder` with a single bulk PCM copy. Output is byte-identical.
- Added a `swift test` suite covering WAV encoding, post-processing, vocabulary storage, RMS,
  resampling, and response parsing.
- Removed the unused `dictation_hotkey` config field; the hotkey is owned by KeyboardShortcuts.

## v1.2.0 — 2026-04-07

### New Features

- **Groq provider**: Switch between OpenAI and Groq for speech-to-text from the menu bar (`Provider` submenu). Groq runs the same Whisper model on custom LPU hardware at ~200x speed with a generous free tier (2,000 requests/day).
- **Groq models**: `whisper-large-v3` (default) and `whisper-large-v3-turbo`.
- **Per-provider API keys**: Each provider stores its own encrypted API key. Environment variables: `TALKTYPE_API_KEY` (OpenAI), `TALKTYPE_GROQ_API_KEY` (Groq).
- **Dynamic model menu**: Model submenu updates automatically when switching providers.

## v1.1.0 — 2026-04-03

### New Features

- **Custom hotkey**: Change the dictation hotkey from the menu bar (`Change Hotkey...`). Uses the [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) library with built-in system shortcut conflict detection. Default: `Cmd+Shift+Space`.
- **Focus restore**: If you switch to another app during recording, TalkType automatically switches back to the original app before typing the transcription.
- **Always-on-top overlay**: The recording overlay now uses `.statusBar` window level, ensuring visibility above all normal windows including some fullscreen apps.

### Bug Fixes

- **Vocabulary hallucination fix**: Vocabulary hints are no longer sent to the Whisper API on low-volume audio, preventing the model from hallucinating vocab words on near-silent recordings.
- **Hotkey text corrected**: Menu and logs now correctly show `Cmd+Shift+Space` instead of `Option+Space`.

### Performance

- **KeyStorage caching**: Symmetric key is cached in memory — no longer spawns `/usr/sbin/ioreg` subprocess on every transcription.
- **AppIdentity.stateDir caching**: State directory path computed once at startup instead of checking the filesystem on every access.
- **Notification auth**: Permission requested once at startup instead of on every notification.

### Code Quality

- Thread safety: `VocabularyStore` entries protected with `NSLock`; `sessionID` reads moved to main thread; overlay audio level throttle moved to main thread.
- `transcriberLock` scope narrowed to prevent potential deadlock with delegate callbacks.
- Config propagation: model switch now calls `reloadConfig()` to sync all settings.
- Dead code removed: `AudioRecorder.ready`, unused `overlayPosition`/`overlayTheme` config fields.

## v1.0.0

Initial Swift release.
