# 2026-08-03 ASR bake-off inputs (local provenance)

**Status:** labeled raw inputs for historical research. Not product truth.
**Access date:** 2026-08-03
**Sensitivity:** contains Simon's voice and derived scores — **bytes stay local /
gitignored**. This README is the tracked provenance record only.

## What was obtained

| Path (local) | Kind | Notes |
| --- | --- | --- |
| `audio/riverside4.wav` | retained recording | Real mixed-language clip used in bake-offs |
| `audio/riverside5.wav` | retained recording | Second real clip |
| `results/bakeoff-20260803-181234.json` | retained run output | Scripted arm comparison |
| `results/grok-20260803.json` | retained run output | Grok-related arm snapshot |

## Handling

- **Downloaded/retained:** yes, on Simon's machine under this directory.
- **Committed to Git:** no. Audio and results match `.gitignore` patterns
  `source-materials/**/audio/` and `source-materials/**/results/`.
- **Not independently third-party verified:** personal recordings and local script output.

## Related synthesis

Historical discussion lives in repository research notes and Git history of the
pre-governance `TODO.md`. Current product transport is Doubao stream + file
fallback (`DECISION.md` D003–D004), not a multi-engine bake-off product.
