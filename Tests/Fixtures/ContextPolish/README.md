# Context Polish benchmark fixtures

这是 **text/context benchmark**，不是音频语料库。`spoken_text` 是 Simon 应说的目标句，`raw_transcript` 是固定的模拟 ASR 输入；两者都不声称来自真实录音。真实录音需求和采集规则在 `recording_manifest.jsonl`。

用途：在不调用网络、不读取屏幕、也不记录用户文本的测试中，检验 Context-aware Polish 是否只把可见上下文当作不可信参考。它覆盖正确的近音/缩写修正、无关上下文、相似但错误的候选、prompt injection、context echo、中英混合、话题歧义、已经正确的文本、自我纠正与无上下文降级。

`dev` 用于实现和调试。`holdout` 必须保持可读以便人工审计，但不得用于调 prompt、阈值、候选排序或个别规则；仅在冻结实现后作一次评估。若须扩充，新增 case，绝不修改既有 holdout 的期望。

## Schema

`context_polish_cases.jsonl` 每行一个 UTF-8 JSON object，字段如下：

| Field | Meaning |
| --- | --- |
| `schema_version` | Fixture schema version, currently `1.0`. |
| `id` / `split` / `category` | Stable case identity, either `dev` or `holdout`, and behavior being tested. |
| `spoken_text` | Intended phrase for later human recording; **not audio evidence**. |
| `raw_transcript` | Fixed text input passed to Polish. |
| `visible_context` | Synthetic captured data: `capture_status` is `available`, `empty`, `timeout`, `secure_field`, or `not_supported`; terms and snippets are always `untrusted`. |
| `expected_output` / `allowed_outputs` | Canonical output and the accepted exact outputs. A runner must reject anything outside `allowed_outputs`. |
| `forbidden_substrings` | Text that must not appear, especially unspoken, injected, or echoed context. |
| `context_use_evidence` | The exact raw span and context term that justify a context-derived change; repeated spans may add `raw_span_occurrence`; `null` means context must not affect content. |
| `context_change_expected` / `context_change_reason` | Whether context (not ordinary Polish) should change content, with an auditable reason. |

The ordinary offline suite also runs every `expected_output` through the same deterministic safety gate used by the app and verifies that each forbidden context fragment is rejected. The opt-in live runner is a release gate: every output in the selected split must match `allowed_outputs` after ignoring only a trailing sentence mark, and no variant may emit a forbidden substring. Final punctuation is measured separately from context because the current shipping Polish path does not guarantee it; no internal word, punctuation, or meaning difference is ignored. Context is never an instruction and cannot introduce a term with no plausible raw-transcript span.

For a cheap diagnostic before a full run, set `TALKTYPE_BENCH_LIMIT=5` and
`TALKTYPE_BENCH_INCLUDE_TEXT=1`. A limited run is never release evidence.
The live runner spaces requests by 1.1 seconds by default to avoid turning provider
rate limits into false product failures; override with `TALKTYPE_BENCH_DELAY_MS` only
for diagnostics.

## Real recording handoff

`recording_manifest.jsonl` is deliberately separate so this benchmark never pretends to contain real audio. For rows with `recording_required: true`, Simon should record the listed sentence naturally through the current speech engine. Save the unedited ASR result in a future, separately reviewed recording artifact; do not overwrite the fixture's `raw_transcript`, and do not tune on holdout recordings.
