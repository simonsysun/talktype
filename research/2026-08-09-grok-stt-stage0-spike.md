# Grok STT Stage-0 spike — Doubao vs direct xAI

**Status:** complete for existing riverside clips (2026-08-09)  
**Scope:** evidence only. **Not** product truth. Default remains Doubao (D003)
until an explicit Stage-1 decision.

## Decision context

Simon chose **Stage 0 spike only** (2026-08-09): no app wiring until pass/fail
evidence exists.

## Method

Tool: [`scripts/stt_spike.py`](../scripts/stt_spike.py)

| Arm | Transport | Notes |
| --- | --- | --- |
| `doubao` | Volcengine file flash (`volc.bigasr.auc_turbo`) | Same product fallback client; hotwords via corpus context |
| `grok` | `POST https://api.x.ai/v1/stt` multipart WAV | No `format` / `language` (no official `zh`) |
| `grok_keyterms` | same + repeated `keyterm` | Vocabulary bias |

**Clips:** `source-materials/2026-08-03-asr-bakeoff/audio/riverside{4,5}.wav`  
**Keyterms:** TalkType, API Key, Claude Code, Cloud, ASR, TestFlight, GBD,
GPT-4o, xAI, Claude  

**Raw results (local/gitignored):**
`source-materials/2026-08-09-grok-stt-spike/results/spike-20260809-164852.json`

## Full comparison (2026-08-09)

### riverside4 — mixed dictation (TalkType / API Key / Cloud / GPT-4o / 3.8GB)

| Arm | s | Transcript |
| --- | ---: | --- |
| doubao | 2.15 | 明天下午3点把 TalkType 的 API Key 发给 Cloud 顺便确认一下 GPT 4的账单，3.8GB 的那个文件不用再下载了。 |
| grok | 0.85 | 明天下午三点把TalkType的API Key发给Cloud，顺便确认一下**GBD四楼**的账单，**三.八GB**的那个文件不用再下载了。 |
| grok_keyterms | **0.74** | 呃明天下午三点把TalkType的API Key发给Cloud，顺便确认一下**GPT-4o**的账单，**3.8GB**的那个文件不用再下载了。 |

### riverside5 — ASR bake-off speech (术语密集)

| Arm | s | Notable |
| --- | ---: | --- |
| doubao | 2.14 | `ASR Flash` 好；`GPT 4 o Transcribe` 碎；`xai`/`claude` 大小写弱；`Cloud 和 claude` |
| grok | 0.84 | `ASR-Flex` 错；`xia`/`call`/`Craw` 实体失败；无中文空格习惯 |
| grok_keyterms | **0.77** | `ASR Flash`、`xAI`、`Claude`、`Cloud和Claude` 明显救回；`Transcribed` 略漂；`testflight` 小写 |

Full grok_keyterms riverside5 text:

> 上周我们做了个ASR的对比测试，千问的ASR Flash在中文上的字错率大概是GPT-4o Transcribed的三分之一。 嗯，不过那一次只用了一段录音样本大小，所以这次这周要重新跑一遍，把 testflight 的安装包发给测试的人，让他们重点听 xAI 和 Claude 两个词。 Cloud和Claude特别容易听混

## Pass / fail against Stage-0 criteria

| Criterion | Result |
| --- | --- |
| 1. No systematic CN→EN translation | **Pass** — both clips stay Chinese-primary |
| 2. Mixed terms ≥ Doubao daily usability (with keyterms) | **Conditional pass** — keyterm arm matches or beats Doubao on GPT-4o / xAI / Claude; bare Grok loses entities |
| 3. Latency competitive | **Pass** — Grok REST ~0.7–0.9 s vs Doubao file ~2.1–2.2 s on these clips |
| 4. Simon OK to paste without rewrite | **Open** — owner call; residual: Chinese fillers (`呃`/`嗯`), spacing, no official `zh` SLA |

**Stage-0 recommendation:** evidence is **good enough to discuss Stage 1
exclusive switch** (default still Doubao; Grok optional; **vocabulary required
for parity**). **Not** good enough to replace Doubao as sole default without
more real-use days and owner taste on punctuation/fillers.

## Implications for a light product shape (if Stage 1)

1. **Exclusive switch only** — never Doubao↔Grok auto-fallback.
2. **Grok v1 = REST file + keyterms from vocabulary** — stream later if release
   latency bothers after quality is accepted.
3. **Do not enable `format`+`language=en`** for this user base.
4. Keychain service must be new (`talktype-xai-api-key`); legacy
   `talktype-stt-grok` is wiped by `removeLegacyKeys`.
5. Privacy table: xAI default **30-day** encrypted retention (team ZDR optional).

## Residual risks

- Chinese remains **undocumented / best-effort** on xAI language list.
- Keyterms cap 100×50; cannot express semantic context.
- us-east RTT may vary; this run was favorable.
- Only two historical clips — expand with CN-primary, EN-primary, self-correction
  before calling promotion-ready.

## Non-goals (still)

App menu, cross-provider fallback, Grok stream, polish layer, treating OpenRouter
as product evidence.
