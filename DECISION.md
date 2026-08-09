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
