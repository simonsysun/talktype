# TalkType Product Contract

## Document Contract

`PRODUCT.md` is the source of truth for TalkType's current product definition.

**This file does:**

- define the user, problem, product promise, scope, non-goals, and success criteria;
- define runtime authority, privacy boundary, and domain language;
- describe intended product behavior without claiming every detail is already shipped.

**This file does not:**

- track current work, blockers, or next steps; see [NOW.md](./NOW.md);
- preserve decision history or rejected alternatives; see [DECISION.md](./DECISION.md);
- hold research notes or raw source material; see `research/` and `source-materials/`;
- duplicate code, tests, build scripts, or release notes; those stay in the repo artifacts that own them.

Truth layers:

- `PRODUCT.md` defines the intended product contract.
- Code and tests prove only the behavior they exercise.
- A gap between contract and reality is work for `NOW.md`, not a reason to weaken this file.

## Product Promise

TalkType is a macOS menu-bar dictation app: press a hotkey anywhere, speak, press again
(or pause), and the words land at the cursor. It is built for someone who thinks in Chinese
and English at once, so mixed-language speech in one sentence is a first-class case.

A dictation is one recognition path: stream audio while speaking, finalise, paste.
Nothing rewrites the transcript afterwards — no second LLM polish pass, no local cleanup
layer that hides provider quality.

## Users and Problem

**Primary user:** Simon (and people with the same workflow): heavy keyboard users who want
speech as a first-class input on the Mac without switching apps or language modes.

**Problem:** System dictation and commercial tools are inconsistent on mixed Chinese/English,
opaque about what leaves the machine, or add rewrite layers that change what was said.

**Positioning:** personal tool first; open-source byproduct second. Free app; speech API usage
is billed by the provider the user configures.

## Product Principles

**TalkType must:**

- optimise for the hotkey → speak → text-at-cursor loop above all else;
- make provider output visible: paste what recognition returns;
- keep configuration minimal (hotkey, mic, vocabulary, one API key);
- fail clearly when network, key, or permissions are missing;
- stay open source (MIT) and free of product telemetry/accounts.

**TalkType must not:**

- present offline, multi-provider, or polish-layer behavior as live when it is not;
- silently rewrite transcripts after recognition;
- require a local multi-gigabyte model for normal use;
- invent billing, accounts, or cloud identity beyond the user's own provider key;
- expand into a general writing assistant, meeting notetaker, or always-on ambient recorder.

## Scope and Non-Goals

### In scope (current)

- macOS 13+ menu-bar app built from `TalkType.xcodeproj`;
- global hotkey dictation into the focused text field (synthesized paste, clipboard fallback);
- one speech provider: 豆包 / Volcengine;
  - default: 流式语音识别 2.0 (`bigmodel_nostream`), audio uploaded while speaking;
  - same-provider fallback: 录音文件识别 2.0 极速版 when the stream fails;
- native provider punctuation, ITN, and semantic smoothing (`enable_punc` / `enable_itn` /
  `enable_ddc`);
- user vocabulary sent as hot words on the same recognition request;
- one project API key in the macOS Keychain (`X-Api-Key`);
- microphone selection (including system default / Bluetooth devices).

### Non-goals (current)

- offline / local ASR engine;
- multi-provider picker or second polish model;
- iOS keyboard product (parked; code may exist but is not product truth until accepted);
- accounts, sync, team features, telemetry;
- automatic filler-word policy beyond what the provider returns natively.

## Authority and Refusal Model

| Actor | Owns | Does not own |
| --- | --- | --- |
| User | API key, vocabulary, hotkey, mic choice, when to dictate | Changing TalkType's product boundary by configuration alone |
| TalkType app | Recording, transport, paste insertion, clear error reporting | Rewriting meaning after recognition; storing audio beyond the dictation path |
| 豆包 / Volcengine | Speech recognition result and its data policy for audio + hot words | Local app behavior, keychain storage, paste into other apps |
| macOS (TCC) | Mic and Accessibility/paste permission | Dictation quality |

**Privacy, precisely:**

| What | Leaves the Mac? |
| --- | --- |
| Audio for the active dictation + vocabulary terms | Yes — to Volcengine under its policy |
| Everything else | No account, no telemetry, no subscription identity |

No offline mode: no network is a clear error, not a silent downgrade.

## Domain Language

| Term | Meaning | Avoid |
| --- | --- | --- |
| **Dictation** | One full cycle: hotkey start → speak → stop/pause → text at cursor | "Session" for the whole cycle |
| **Speech recognition / STT** | The Doubao streaming call, with file flash as same-provider fallback | Multi-engine pipelines unless product reverses |
| **API Key** | Single project key from the Doubao Voice console (`X-Api-Key`) | Old App ID + Access Token pair; IAM “API访问密钥” |
| **Vocabulary** | User word list sent as hot words on the recognition request | Local post-rewrite dictionary |
| **Polish** | Any second model or local rewrite after STT | Treating provider-native punc/ITN/DDC as a separate polish product |

## Intended Product Flow

```
press hotkey → record (+ stream PCM) → release / pause
  → finalise recognition → paste at cursor (clipboard always holds text)
```

Expected UI surfaces: menu bar control, recording overlay, hotkey change, API key entry,
microphone menu, vocabulary list. No settings window product is required for the core loop.

## Success and Validation

Critical success signal: Simon (and similar users) prefer TalkType over system dictation for
daily mixed Chinese/English typing.

Validation layers (not interchangeable):

| Claim | Needs |
| --- | --- |
| Reachably implemented | Code path + focused tests / local use |
| Locally verified | `swift test` and/or Release build as claimed |
| Accepted for daily use | Real dictations on the owner's machine |
| Ready for wider promotion | Name/collision and support decisions resolved (see `NOW.md`) |

## Expansion Boundary

Any of the following is a product reversal and needs an explicit decision, not a quiet PR:

- reintroducing a local engine or offline mode;
- adding a second STT provider or post-STT rewrite layer;
- shipping iOS as a supported product;
- collecting telemetry or requiring accounts;
- changing the privacy table above.

Parked iOS keyboard work under `TalkTypeiOS/` and `TalkTypeKeyboard/` is not current product
scope. Treat it as dormant code until `PRODUCT.md` and `NOW.md` say otherwise.
