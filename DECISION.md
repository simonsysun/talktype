# TalkType Decision Log

## Document Contract

`DECISION.md` records important choices whose rationale is not obvious from the
current product or code.

**This file does:**

- preserve the decision, why it was made, and the constraint it creates;
- preserve superseded choices when forgetting them would cause repeated work;
- state a reversal condition when one is known;
- link only evidence that materially carried the decision.

**This file does not:**

- redefine the current product; see [PRODUCT.md](./PRODUCT.md);
- track current work, blockers, or restart instructions; see [NOW.md](./NOW.md);
- copy research, raw sources, code, diffs, test output, or commit history;
- record ordinary implementation choices already clear from the artifact;
- serve as a chronological changelog (`CHANGELOG.md` owns shipped history).

A new entry must pass all three tests:

1. changing it later would be meaningfully costly;
2. a future contributor could reasonably choose differently without this context;
3. the decision resolved a real tradeoff.

Entries are newest first. IDs are permanent and never reused. When a decision
changes, add a new entry and mark the old one `Superseded`; do not rewrite the
old rationale. `Evidence` is optional and should normally link to one research
synthesis when research carried the choice.

## D007 — Mobile: iOS keyboard is architecturally blocked; Android is the path

**Date:** 2026-08-10 · **Status:** Active · **Type:** Scope / Architecture

**Extends:** D001 (macOS first, iOS parked); does **not** reverse it

**Decision:** Do not build an iOS keyboard extension. If TalkType ever ships on
mobile, the target is **Android**. Mobile stays deferred until Simon has an
Android device (intended purchase while in Hong Kong; no date). `TalkTypeiOS/`
and `TalkTypeKeyboard/` remain dormant and are not a resumable base.

**Why:** iOS app extensions cannot record audio at all — `AVAudioSession` returns
`AVAudioSessionErrorCodeCannotStartRecording` (561145187) for any extension, by
design, since a sandboxed keyboard with microphone access is an audio keylogger.
"Allow Full Access" grants network and a shared container, **not** the
microphone. The only legal iOS architecture is container-app-records /
keyboard-inserts across an App Group — what Wispr Flow does — and on iOS 26.4
Apple stopped returning the user automatically, so that flow now costs a manual
app switch per session. Android's `InputMethodService` may hold `RECORD_AUDIO`
directly; Wispr's own Android app (Feb 2026) uses a floating overlay with no
session bouncing. Same product, same year: the platform sets the ceiling.

**Consequence:** `TalkTypeKeyboard/KeyboardViewController.swift` is not stale
code, it is **impossible** code — it calls `requestRecordPermission` and starts
recording inside the extension. Do not repair it; it never ran and never could.
Android would be a Kotlin rewrite with no reuse of the Swift core. Free Apple
provisioning cannot supply App Groups either, so even the legal iOS design
requires the $99/yr program, which Simon declined. Deleting the dormant iOS
targets is permitted but not required.

**Revisit when:** Simon has an Android device in hand, or Apple permits
microphone access from app extensions.

**Evidence:** Apple *App Extension Programming Guide — Custom Keyboard* and
Technical Q&A QA1872 (extensions may not record audio); Wispr Flow help doc
"Adapting to iOS 26.4" (manual swipe-back) and its Feb 2026 Android launch.

## D006 — Exclusive STT switch: Doubao default, optional Grok (xAI)

**Date:** 2026-08-09 · **Status:** Active · **Type:** Product / Architecture

**Extends:** D003 (still one recognition call, no polish); does **not** restore
multi-engine auto-fallback (D002)

**Decision:** Menu-bar **exclusive** provider switch between 豆包 (default) and
Grok / xAI. One dictation uses exactly one provider. No automatic cascade if the
active provider fails. Grok v1 is REST file STT after stop with vocabulary as
`keyterm`; Doubao keeps stream + same-provider file flash. Separate Keychain
items per provider (`talktype-doubao-api-key`, `talktype-xai-api-key`).

**Why:** Stage-0 direct-xAI spike showed Grok REST+keyterms competitive on mixed
CN/EN clips and lower file latency, while bare Grok lost entities. An optional
path makes quality visible without hiding Doubao behind failover. Chinese remains
undocumented on xAI's formatting language list, so Doubao stays default.

**Consequence:** PRODUCT privacy table is per selected provider. Errors and API
Key dialogs name the active provider. Do not invent a large provider-plugin
framework for two clients. Grok stream is optional later only if release latency
hurts after quality is accepted.

**Revisit when:** Daily use shows Grok systematically better (consider default
swap) or worse (remove menu item); or xAI documents Chinese formatting with SLA.

**Evidence:** `research/2026-08-09-grok-stt-stage0-spike.md`

## D005 — Adopt portable project governance

**Date:** 2026-08-09 · **Status:** Active · **Type:** Process

**Decision:** Use the Portable Project Governance standard as TalkType's default
repository OS: `PRODUCT.md`, `DECISION.md`, `NOW.md`, `DEVLOG.md`, `AGENTS.md`,
plus `research/`, `source-materials/`, and narrow `docs/` when needed. Search
existing material before creating more. No second product spec, decision log,
task tracker, or agent process.

**Why:** Prior docs mixed product truth, history, status, research, and
implementation notes (`TODO.md`, `CONTEXT.md`, `PLAN.md`, `docs/adr/*`). The same
facts drifted across files and cost agents repeated reconciliation.

**Consequence:** Agents must not invent competing root management files. Retired
filenames (`TODO.md`, `CONTEXT.md`, `PLAN.md`, `docs/adr/*`) were removed after
migration; recover prior text only from Git history, never as live authority.
Depth stays lightweight for a personal macOS app; roles stay full-strength.
Process failure modes (false completion, competing trackers, inferred reversals)
are enforced in `AGENTS.md` must/must-not lists, not only in prose.

**Revisit when:** A genuine constraint makes literal conformance unsafe or
impossible, with explicit human approval recorded here.

**Evidence:** Portable standard adopted from Petal practice; source document was
the external `PORTABLE_PROJECT_GOVERNANCE.md` used for this migration.

## D004 — Stream by default; same-provider file flash as fallback

**Date:** 2026-08-06 · **Status:** Active · **Type:** Architecture

**Supersedes:** transport choice inside D003

**Decision:** Start 豆包 流式语音识别 2.0 when recording begins and send 16 kHz
PCM on ~200 ms frames. On stream failure only, send the retained full recording
once to 录音文件识别 2.0 极速版. Both paths use the same project API key and
native punc/ITN/DDC/hot words. No second provider and no post-STT rewrite.

**Why:** File flash alone measured ~1.3–1.7 s typically but also 6–30 s tails and
504s unrelated to clip length. Streaming uploads during speech so release mainly
finalises the last frame, while keeping one model family.

**Consequence:** Default resource is `volc.seedasr.sauc.duration` /
`bigmodel_nostream`. Local audio is retained for fallback. Missing service
enablement must surface as configuration error, not a silent empty result.

**Revisit when:** Measured stream reliability is worse than file flash for real
use, or Doubao changes the transport contract.

**Evidence:** Prior ADR-0003 content (now retired into this log).

## D003 — One recognition call, no polish layer, single provider

**Date:** 2026-08-05 · **Status:** Active · **Type:** Product / Architecture

**Supersedes:** D002; multi-provider experiments from mid-v2/v3 prep

**Decision:** A dictation is one speech-to-text path to 豆包. Delete the local
MLX engine, cloud↔local engine switch, and any second-model or local rewrite
polish. Paste provider text as returned. Vocabulary is hot words on the same
request only.

**Why:** Modern STT already returns punctuation, ITN, and semantic smoothing.
Extra polish added latency, failure modes, and rewrites that hid provider
quality. Multi-provider switching was unvalidated for the Chinese+English case
and multiplied adapters without evidence.

**Consequence:** No offline dictation. Quality regressions that polish used to
mask (spacing, self-correction, half-width punctuation) are accepted until real
usage names a symptom worth a targeted fix. Adding another provider requires a
new decision and should not invent abstraction "just in case."

**Revisit when:** Daily use proves provider-native quality unacceptable, or a
measured bake-off shows another provider clearly better on mixed CN/EN terms.

**Evidence:** `research/stt-native-polish-shortlist-2026-08-05.md` (historical
shortlist; product settled on Doubao); prior ADR-0002.

## D002 — Cloud-first with local offline fallback (superseded)

**Date:** 2026-08-04 · **Status:** Superseded by D003 · **Type:** Architecture

**Decision (historical):** Prefer cloud ASR when reachable; automatically fall
back to a local ~4 GB engine offline, with switch notifications.

**Why:** Save resident memory most of the time while still offering offline
dictation.

**Consequence (while active):** Dual engines, install/delete local weights,
fallback policy, and dual privacy copy.

**Why superseded:** Memory savings did not justify the dual-engine product and
ops cost once Doubao single-call quality was accepted; offline path was rare.

**Evidence:** Prior ADR-0001.

## D001 — macOS first; iOS parked

**Date:** 2026-08-02 · **Status:** Active · **Type:** Scope

**Decision:** Ship and improve the macOS menu-bar app first. Park the iOS
keyboard extension and companion app until the phone becomes the priority.

**Why:** macOS is the daily driver and already a real product loop. iOS targets
were never compiled or run on device; treating them as live scope produced false
progress and split attention.

**Consequence:** iOS code may remain in tree as dormant. It is not product scope,
not a restart target, and not a claim of mobile readiness. Resume only through
an explicit product decision and a new `NOW.md` stage.

**Revisit when:** Simon prioritises phone dictation and is willing to pay the
Apple Developer / TestFlight setup cost.
