# 2026-08-09 Grok STT Stage-0 spike inputs

**Status:** labeled raw inputs for Stage-0 research. Not product truth.
**Access date:** 2026-08-09
**Sensitivity:** may contain Simon's voice and API transcripts — **result
bytes stay local / gitignored**. This README is the tracked provenance record.

## What was obtained

| Path (local) | Kind | Notes |
| --- | --- | --- |
| `results/spike-*.json` | script output | From `scripts/stt_spike.py` (Doubao and/or direct xAI) |
| Clips reused | prior bake-off audio | `../2026-08-03-asr-bakeoff/audio/riverside{4,5}.wav` |

## Handling

- **Committed to Git:** no audio/results. Patterns already cover
  `source-materials/**/audio/` and `source-materials/**/results/`.
- **Related synthesis:** `research/` Stage-0 note when comparison is complete.

## How to re-run

```bash
export XAI_API_KEY=xai-...   # required for Grok arms
# DOUBAO_API_KEY optional; defaults to Keychain talktype-doubao-api-key

python3 scripts/stt_spike.py \
  --keyterm TalkType --keyterm 'API Key' --keyterm 'Claude Code' \
  --keyterm Cloud --keyterm ASR --keyterm TestFlight --keyterm GBD \
  source-materials/2026-08-03-asr-bakeoff/audio/riverside4.wav \
  source-materials/2026-08-03-asr-bakeoff/audio/riverside5.wav
```
