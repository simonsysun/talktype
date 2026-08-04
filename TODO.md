# TODO

Single source of truth for what we're doing and what's done.
Design rationale → `PLAN.md`. Shipped history → `CHANGELOG.md`. Don't duplicate them here.

Last reviewed: 2026-08-03

**Current focus: macOS, local-only ASR.** iOS is parked by decision (2026-08-02).

---

## State of the project

- **macOS app (`TalkType/`)** — v2.0.2, shipped. Local Qwen3-ASR sidecar, optional Groq polish,
  first-run setup window, signed releases, GitHub release with a downloadable build.
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

## Open: playback stalls and the mouse freezes after a dictation (2026-08-02)

Reported: with a video playing through AirPods, a dictation ends and ~1–2 s later the audio
stalls and the Bluetooth mouse freezes for about a second. Two candidates, neither confirmed.

**Candidate A — TalkType degrades the Bluetooth link.** Measured read-only on Simon's machine:

- AirPods Pro are both the default input *and* the default output — one Bluetooth link doing both.
  `config.json` has `input_device_uid: ""`, so `AudioRecorder` follows the system default and opens
  the AirPods microphone on every dictation.
- Opening it reconfigures the link: the AirPods **output** device drops from `48000 Hz / 2ch` to
  `24000 Hz / 1ch`. Every app playing audio has to renegotiate against the new device format — that
  is a gap in playback, not a fade.
- It does not come back promptly. Last dictation 10:21:36; still 24 kHz mono at 10:27:28; back to
  48 kHz stereo by 10:29:03. Six to eight minutes of degraded playback after one dictation.
- MX Master 3 and MX KEYS S share the 2.4 GHz radio with the AirPods, so a link renegotiation
  starves their HID reports — which is what a frozen cursor looks like.

**Candidate B — the local inference burst.** 0.2–1.3 s of saturated GPU from a 4.1 GB-resident
process, starting exactly when the freeze is reported. Fits the cursor symptom as well as A does.

**What the evidence does not settle:** A explains the audio symptom better, but the one timing
sample puts the restore *minutes* after the dictation, not the reported 1–2 s. B lands in the right
window but should not stall an audio thread on its own. Do not pick one from the armchair.

**The 30-second test that decides it** — same video playing, one dictation each:

1. Microphone → AirPods Pro (today's behaviour). Freeze?
2. Microphone → MacBook Pro Microphone (pin it in the menu). Freeze?

Gone in (2) ⇒ Bluetooth ⇒ fix below. Still there in (2) ⇒ the inference burst ⇒ the cloud engine
below is the fix, plus look at GPU priority in the sidecar.

- [x] **Automatic input should skip Bluetooth.** When nothing is pinned, prefer a non-Bluetooth
      input over the raw system default. Implemented 2026-08-03: `AudioDevices` reads
      `kAudioDevicePropertyTransportType` and Automatic prefers a non-Bluetooth input (built-in
      first). An explicit pick still wins — someone on a noisy train wants the headset mic. Costs
      nothing in quality: the built-in array captures 48 kHz against the AirPods voice mic's 24 kHz.
      Compiled, not field-verified — the 30-second test above still stands for the next run.
- [x] **Show the reason in the Microphone menu.** "Automatic (MacBook Pro Microphone)" with a
      tooltip saying a connected headset was passed over on purpose, or it reads as a bug.
      Done 2026-08-03: the row shows the device actually used and the tooltip explains the pass-over.
- [ ] Consider releasing the input node after each dictation rather than only `engine.stop()`.
      Only matters for someone who pins a Bluetooth mic deliberately; check first whether it
      shortens the degraded window or just adds a second renegotiation.

---

## Cloud ASR as a switchable engine (2026-08-02)

Amends the ASR decision above: local Qwen3-ASR stays the default, but local-*only* no longer holds.
The sidecar is 4.1 GB resident with weights loaded and 3.8 GB on disk. On a 16 GB machine that is a
quarter of RAM for something used a few seconds at a time. Not only a small-Mac problem either —
this 64 GB machine was carrying 17 GB of swap while idle.

- [x] **A chosen engine, not a fallback.** Menu: Speech engine → Local (Qwen3-ASR) / Cloud (…).
      Local stays the default where the sidecar is installed. Whichever is chosen does all the work,
      so the same sentence never transcribes differently depending on what happened to be up.
      Done 2026-08-03: `config.asr_engine`, engine submenu, sidecar stopped when cloud is chosen.
- [x] **Say what leaves the machine.** The Groq polish sends the transcript; a cloud ASR sends the
      *audio*. That is a different promise from the one the README makes today, and the UI has to
      state it plainly at the moment of choosing.
      UI done 2026-08-03 (menu tooltip, setup copy, engine-switch notification). README rewrite
      waits for the release pass.
- [ ] Pick the provider from the numbers in "ASR decision", then re-measure — that bake-off was one
      clip. Soniox stt-async-v5 was the most accurate on Simon's Chinese-with-English but 2.9–4.6 s;
      OpenAI gpt-4o-mini was 0.5–1.1 s but made a meaning error (财报 → 采访).
      → Shortlist and recommendation in "Cloud engine research" below.
- [ ] Recover rather than reinvent: `KeyStorage.swift`, `ASRProvider`, and the multipart body
      building were deleted in the cut-over and are in git history.
      Done 2026-08-03 — rebuilt as `CloudASRClient` (three request shapes) + `CloudKeyStore`
      (per-provider keychain), informed by what git history kept.
- [x] Setup must stop assuming local. `SetupWindow` blocks on a missing venv today; with cloud
      chosen there is nothing to install and the 3.8 GB download has to be skippable.
      Done 2026-08-03: engine popup, cloud provider/URL/model/key section, local install shows a
      real download percentage.
- [ ] Vocabulary hints and `PostProcessor` must behave identically on both paths.
      Client-side done 2026-08-03 (bare comma list on all three shapes); cloud-Qwen behaviour is
      a bake-off question.

---

## Cloud engine research (2026-08-03)

Re-derived from the "ASR decision" numbers against what is current today. Facts are from provider
docs and public benchmarks; the deciding numbers still have to come from Simon's own clips.

**Shortlist, in fit order for TalkType:**

1. **Qwen3-ASR-Flash — recommended cloud engine.** Same model family as the local default, so
   output and vocabulary behaviour are the closest thing to "the same sentence never transcribes
   differently". Built for mixed-language audio with automatic detection — no language hint, which
   is exactly the CN/EN use case. Public Chinese WER ~3.97% vs gpt-4o-transcribe ~15.7% (Alibaba
   release tests, 2025-09) — the only cloud model whose Chinese is in the local model's league.
   OpenAI-compatible on both OpenRouter (`qwen/qwen3-asr-flash-2026-02-10`, $0.000035/s ≈ $0.13/h,
   so ~$1.9/month at 30 min/day) and DashScope (`qwen3-asr-flash`, Beijing/Singapore — OpenAI mode
   unavailable in the US region). Accepts base64 WAV and context text for vocabulary. OpenRouter
   key already exists from the bake-off; DashScope is the same API shape for Chinese-region hosting.
   Open question: does cloud Flash also "complete the prompt" when given prose context (the local
   bare-comma-list lesson)? Test vocab hints explicitly.

2. **gpt-4o-transcribe** — fastest to integrate (native OpenAI), ~0.5–1.1 s, $0.006/min
   (~$5.4/month). Public Chinese WER is ~4x Qwen's, and the old mini model made the 财报→采访
   meaning error. Keep as the comparison arm, not the default.

3. **Soniox stt-async-v5** — best measured accuracy on Simon's clip (the only one that heard
   "Claude"), strong context/vocabulary support, ~$0.10–0.12/h. But 2.9–4.6 s async latency and
   not OpenAI-compatible (own REST/WebSocket). Only wins if a re-measure shows accuracy far ahead
   of Qwen at acceptable latency; their real-time v5 streams sub-200 ms but means a new WebSocket
   integration.

**Ruled out or parked:** Groq whisper-large-v3(-turbo) — free tier (2,000 req/day) and fast, but
weak CN/EN code-switching and no Chinese punctuation (the refiner covers punctuation, and the
hallucination guard exists; still, the Grok bake-off result and the Chinese Linux voice-input
project's 17-pattern hallucination blacklist are warning signs). Deepgram Nova-3 and Google
Chirp 3 now claim Chinese but measured unusable in the bake-off; NVIDIA Parakeet same. 讯飞/火山/
腾讯/MiniMax are strong on Chinese but ship non-OpenAI-compatible SDKs with registration overhead —
not a fit for a one-key personal app. AssemblyAI Universal-3.5 Pro ($0.21/h async) is async-first
and not OpenAI-compatible; real-time is $0.45/h.

**Next: re-bake-off** (plural clips — the 财报/Claude recordings plus a fresh mixed dictation),
measuring latency, word accuracy, and vocabulary-hint behaviour per path:

- [ ] Arms: Qwen3-ASR-Flash (OpenRouter + DashScope), gpt-4o-transcribe, Soniox stt-async-v5, and
      Groq whisper-large-v3-turbo as the free arm.
- [ ] Send vocab hints exactly the way the app does (bare comma list) and watch for prompt-completion
      hallucination on cloud Qwen too.
- [ ] Check provider retention/training terms before writing the privacy copy — audio leaving the
      machine changes the README's promise regardless of which engine wins.

---

## Cloud engine — implementation (2026-08-03)

Architecture and current state, so the next session can pick up without re-deriving it:

- `config.json` gains `asr_engine` (`local` | `cloud`), `cloud_provider`, `cloud_model`,
  `cloud_base_url`. All decode with defaults, so old configs keep working.
- Cloud keys live in the login keychain, one slot per provider
  (`talktype-asr-<provider>`, `CloudKeyStore`). Provider is auto-detected from the pasted base
  URL (OpenRouter / OpenAI / DashScope / Groq / custom); key prefix `sk-or-` is a secondary hint.
  The Setup window fills model + URL from the detected provider and validates the key against
  `{base}/models` before saving.
- `CloudASRClient` speaks the three dialects: OpenRouter base64 JSON (`/audio/transcriptions`),
  OpenAI/Groq multipart, DashScope chat-completions `input_audio`. Vocabulary is a bare comma
  list on every path (`buildPrompt`), same rule as the local sidecar's `X-TalkType-Context`.
- Engine switch stops the sidecar when going cloud (frees ~4 GB) and starts it when going local.
  Launch only spawns the sidecar for local; cloud with no key opens Setup instead of blocking.
- Local install (`asr/install.sh`) now emits `[progress] NN` while the weights download, and the
  Setup window drives a real percentage bar off it.

Verified: 74 `swift test` cases green (15 new: provider detection, three request shapes, response
parsing, config round-trip) and a Release `xcodebuild` passes. **Not verified on hardware** —
Simon asked not to run the app; the re-bake-off and a real dictation are the field tests.

Still open:

- [ ] Re-bake-off with Simon's clips + keys: Qwen3-ASR-Flash (OpenRouter + DashScope),
      gpt-4o-transcribe, Soniox stt-async-v5, Groq whisper-large-v3-turbo (free arm).
- [x] Vocab-hint behaviour on cloud Qwen — answered 2026-08-04: OpenRouter does NOT forward vocab
      hints (qwen-flash's supported params have no prompt/context; top-level `prompt` and
      `provider.options` both no-op). No prompt-completion risk, but cloud vocab is dead — accept
      client-side correction; real cloud vocab would need DashScope official (parked).
- [x] README + privacy copy for the cloud engine — done 2026-08-04: rewritten as a product blurb
      plus manual; privacy copy says audio leaves on cloud, transcript-only to Groq.
- [ ] Local model size choice (1.7B vs 0.6B) in Setup — server.py currently hardcodes 1.7B, so
      this needs the sidecar to know its installed size first.
- [x] "Delete local engine" affordance in Setup — done 2026-08-04: confirmation dialog, stops the
      sidecar, removes the ~4 GB; auto-switches to cloud when local was the chosen engine.
- [x] Auto fallback cloud→local when offline/unreachable — done 2026-08-04 (commit 10f604f):
      NWPathMonitor pre-check, 10 s cloud timeout when local is installed, transition-only
      notification, sidecar started on demand and stopped on recovery (see next section).
- [x] `CloudASRClient.validate()` could not detect a bad OpenRouter key (public `/models` returns
      200 with no auth) — done 2026-08-04: OpenRouter keys now validate against `/auth/key`.

## OpenRouter 实测 + 设计决定 (2026-08-04)

OpenRouter 实测（2 clips × 6 arms, 全 200）: qwen-flash 稳定且与昨日结果一致, ~2 s, $0.002/min;
gpt-4o-transcribe ~1–1.7 s; x-ai/grok-stt-1.0 最快但中文最差; Grok 走 OpenRouter 与官方 x.ai
结果一致, 仅多 0.1–0.2 s。用 git 历史恢复的朗读脚本做了确定性打分（非靠耳朵）。

Grill 后确定的设计（README 已按此写）:
- 定位 A: 个人工具 + 开源副产品。云默认 (OpenRouter qwen-flash), 本地 Qwen 可选下载/删除,
  目前只接 OpenRouter 一家。
- 离线/云端失败 → 自动回退本地并只在切换时通知。判定: NWPathMonitor 预检 + 云端 10 s 短超时
  （仅本地已装时启用）。
- 本地 sidecar 生命周期: 按需启动, 断网期间常驻, 网络恢复后停止。
- 云端失败提示分三类: 没网 / key 无效或额度用完 / 服务故障——人话 + 下一步。
- 润色留在 Groq（0.3 s vs OpenRouter 2.4–4.5 s, 同一模型质量相同; 第二把 key 可选但推荐,
  README 写明）。
- 词库: OpenRouter 不透传（见上）, 客户端纠错兜底。

---

## Now — macOS

1. [x] **Run `swift test`** — 59 tests green (2026-08-02, re-verified 2026-08-03).
2. [x] **Build and run the macOS app** — shipped as v2.0.0/v2.0.2; Release builds green.
3. [x] **Share the macOS scheme** — added with the sidecar cut-over (bed5df5); `xcodebuild -scheme
       TalkType` works from the CLI.
4. [x] **ASR bake-off** — done, see "ASR decision" above. Local Qwen3-ASR chosen.
5. [x] **Cut over to the local sidecar.** Done (bed5df5). Delete every cloud path (~580 lines):
       `KeyStorage.swift` entirely, `ASRProvider`, the multipart/HTTPS body building in
       `Transcriber`, and the Provider / Model / API Key menus in `TalkTypeApp`. `Transcriber`
       becomes a POST of raw WAV bytes to `127.0.0.1:8756/transcribe` with an
       `X-TalkType-Context` header. Keep `WAVEncoder`, `PostProcessor`, `VocabularyStore`.
       **Removes the cloud fallback** — if the sidecar is down there is no dictation, by decision.
6. [x] **Sidecar lifecycle in Swift.** Done — `SidecarManager` spawns
       `~/.talktype/asr/venv/bin/python server.py` at launch with `HF_HUB_OFFLINE=1`, polls
       `/health`, terminates on quit, and reports missing/loading state in the menu.
7. [x] **Menu bar icon.** Done — template SF Symbol waveform, not a literal "T".
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

Shipped work is in `CHANGELOG.md` (macOS v1.0.0 → v2.0.2). iOS has shipped nothing yet.

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
