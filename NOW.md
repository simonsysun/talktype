# TalkType Now

## Document Contract

`NOW.md` is TalkType's only task tracker and cross-agent restart point.

**This file does:**

- show current plain-language state and the exact next safe action;
- keep a short stage map without pretending the whole roadmap is fixed;
- expand at most one primary active stage with outcome and done predicates;
- compress completed stages to outcome + evidence + residual risk;
- change when predicates, blockers, next actions, or material risks change.

**This file does not:**

- redefine the product; see [PRODUCT.md](./PRODUCT.md);
- explain durable choices; see [DECISION.md](./DECISION.md);
- store research, raw sources, code diffs, routine test output, or commit narration;
- record every attempt or conversation;
- grow a permanent detailed history of finished work (`CHANGELOG.md` for releases);
- mark unverified predicates complete or redefine done when blocked.

Stage labels: `DONE`, `ACTIVE`, `NEXT`, `LATER`, `BLOCKED`.

## Resume Here

**Current state:** Exclusive STT switch is implemented (D006): menu 豆包 default /
Grok optional; no cross-provider failover. Owner should run a few real Grok
dictations after pasting the xAI key, then continue the real-usage window.

**Resume with:** Build/run the app → Speech Provider ▸ Grok → paste xAI key →
daily use. Log only material issues. Promotion still gated on name collision.

## Stage Map

1. **DONE — Single-provider Doubao v3 shell.** Stream + file fallback, Keychain
   key, hot words, no polish/local engine. Evidence: `CHANGELOG.md` v3.0.0 and
   current `TalkType/` sources.
2. **DONE — Repository governance migration.** Canonical files and directories match
   the portable standard; competing trackers retired to Git history.
3. **DONE — Grok STT Stage-0 spike.** Direct `api.x.ai` vs Doubao file; synthesis
   `research/2026-08-09-grok-stt-stage0-spike.md`.
4. **DONE — Grok exclusive switch (Stage 1).** Menu bar provider pick; Grok REST
   + keyterms; separate Keychain; D006 / PRODUCT / README updated. Residual:
   owner live acceptance on Grok; Chinese still best-effort on xAI; no Grok stream.
5. **ACTIVE — Real-usage batch (macOS).** Collect daily-use issues for at least a
   week; ship one small tested batch. Keep scope tight.
6. **NEXT — Pre-promotion gates.** Optional support link decision; TalkType name
   collision research before meaningful promotion.
7. **LATER — Grok stream (same provider only).** Only if REST release latency
   bothers after quality is accepted.
8. **LATER — Speech regression micro-set.** Tiny real-speech set before further
   request tuning (CN-primary, EN-primary, mixed terms, numbers, self-correction).
9. **LATER — Mobile.** iOS keyboard is architecturally impossible and the dormant
   targets are gone; Android is the only viable target and waits on hardware
   (D001, D007). Needs an explicit product decision before any stage opens.

## Active Stage — Real-usage batch (macOS)

**Outcome:** A short, evidence-backed list of daily-use defects or non-issues, with
any crash/privacy/upstream exceptions fixed promptly and the rest batched.

**Done predicates:**

- [ ] At least one week of real use has been observed (or Simon explicitly ends
      the window early with a reason).
- [ ] Open items below are either done, explicitly deferred with reason, or moved
      to a later stage — not left as silent drift.
- [ ] No known crash, security/privacy, data-loss, or upstream-break issue remains
      untracked here.

**Non-goals:** more STT providers, cross-provider auto-failover, iOS revive, large
UI redesign, automatic session diaries.

**Negative / fail-closed:** Do not call promotion-ready while the commercial
name-collision item is unaddressed. Do not reintroduce polish/local engine or
provider cascade without a new decision.

**Next action:** Use TalkType daily; log only material issues into this stage
(or fix immediately if they are crash/privacy/data-loss/upstream).

**Open items (batch candidates):**

1. [ ] Optional support / donation link on README/GitHub (provider choice TBD;
      payment must read as voluntary; crypto address is a separate decision).
2. [ ] Name collision: CareScribe ships a commercial dictation product named
      TalkType (`talk-type.com`). Research a distinct name before meaningful
      promotion; do not rush-rename the installed app.
3. [ ] Tiny real-speech regression set before further model-request tuning.
      Live checks already seen: ~1.2–1.8 s; hot words fixed “Cloud Code” →
      “Claude Code” in at least one trial.
4. [ ] Deferred unless requested: overlay dragging (`ignoresMouseEvents = true`,
      fixed bottom-centre).
5. Standing note: signing cert backup lives in `secrets/` (gitignored). Do not
   move it to a tracked path. Loss costs one extra Accessibility grant per
   machine after reinstall, once.
6. [x] **USB webcam mic (HD Pro Webcam C920) verified (2026-08-18).** With the
      lid closed and the webcam attached through its current USB 2.1 hub,
      AVFoundation captured 3 seconds / 48,000 non-zero samples. TalkType's
      current `AudioRecorder` then completed five consecutive captures at
      `16000 Hz x2`, with non-zero audio and no fallback; Automatic resolved to
      the C920. The same recorder also switched C920 → built-in → C920 →
      Automatic at the expected 16/48/16/16 kHz rates without fallback. This
      verifies the generic device-selection path, not a C920 special case;
      macOS microphone permission is app-wide, while TalkType chooses each
      input by stable device UID. Bluetooth uses the same path but was not
      connected for this check. The prior `AudioDeviceStart` / `EAGAIN` /
      isochronous-transfer failure was a transient device or USB state that
      disappeared after reconnecting. Do not add an `AVCaptureSession` fallback
      without a new reproducible failure; on recurrence, compare the system
      input meter and `~/.talktype/talktype.log` before changing capture code.
7. [ ] **Overlay pill hidden above some apps' windows.** Reported 2026-08-29: in
      certain frontmost apps the recording pill fails to appear; recording is
      unaffected (the pill is display-only, so the hotkey → speak → paste loop
      still works). Code review: the panel already has the standard HUD setup
      (`nonactivatingPanel`, `canJoinAllSpaces`, `stationary`,
      `fullScreenAuxiliary`, `orderFrontRegardless()`), but its level is
      `.statusBar` (25), which only outranks ordinary windows (layer 0). Any app
      window at layer ≥ 25 — presentation slideshows, always-on-top video,
      capture HUDs — covers it, and recent macOS has public reports of
      all-Spaces panels vanishing over fullscreen Spaces (Tauri #11488,
      BetterTouchTool forum). A live CGWindowList probe found no normal-app
      window above layer 0 at rest, so the trigger is app/mode specific and the
      failing app is not yet identified; next occurrence should note the app
      name. Proposed fix, one line, not yet applied: `panel.level =
      .screenSaver` (1000) in `OverlayWindow.init`, everything else unchanged;
      verify by reproducing in the affected app before/after. Secondary
      hardening, same touch: `reposition()` uses `NSScreen.main`, which on a
      multi-display setup can put the pill on the wrong screen — place it on the
      frontmost app's screen instead.
8. [ ] **Lid-closed built-in mic returns digital silence.** With
      `AppleClamshellState = Yes`, both the signed app and a separate test process
      read exactly `rms=0.00000` from `MacBook Pro Microphone`, so the new
      fall-back-to-another-input path cannot rescue a dictation in clamshell.
      Not yet confirmed against an open lid. If clamshell is the cause, decide
      whether falling back to a silent device is worse than failing loudly.

**Blockers:** None for daily use. Promotion is gated on item 2.

**Residual risk:** Bluetooth mic still trades playback quality (system headset
mode). Provider quality is fully visible; some former polish masks are gone by
design (D003).

## Residuals Carried Forward

- Dormant iOS targets were deleted (D007). Do not restore them. Mobile, if it
  ever happens, is Android and waits on hardware.
- Historical bake-off numbers and multi-engine designs live in `research/` and
  Git history; they do not authorize product reversals by proximity.
- `CHANGELOG.md` remains the release history surface for humans and GitHub.

## Completed Stage — Repository knowledge migration

**Outcome:** Root governance files and directories are the only project-management
authorities. Competing `TODO.md`, `CONTEXT.md`, `PLAN.md`, and `docs/adr/*` were
removed after content landed in the canonical owners; full prior text remains in
Git history. Agent process constraints were hardened to Petal-level must/must-not
lists.

**Evidence:** Governance commits on `main` after 2026-08-09.

**Residual:** Old filenames may still appear inside historical research notes;
those notes are not current instructions.
