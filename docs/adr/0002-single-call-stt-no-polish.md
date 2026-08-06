# One speech-to-text call, no polish layer

A dictation is one API call. Record, POST the WAV to the chosen speech-to-text provider,
paste the response. Nothing runs between the provider and the text field.

Status: accepted (2026-08-05), supersedes [ADR-0001](0001-cloud-first-engine-with-offline-fallback.md)

## Why

The previous pipeline had four stages: cloud ASR (or a local 4 GB MLX engine on fallback),
an LLM polish pass through Groq, a deterministic local tidy, and vocabulary
canonicalisation. It existed because the ASR of the time returned verbatim, unpunctuated
text that was not pasteable.

That premise expired. Providers now do the cleanup inside transcription — ElevenLabs
`no_verbatim` removes fillers, false starts, repetitions and stuttering; xAI removes filler
words by default. A polish pass on top of that is a second model with its own latency,
failure modes, prompt, and opportunity to change what was actually said.

## Considered options

- **Keep the pipeline, add providers behind it** — rejected: the polish layer would mask the
  very differences between providers that need comparing.
- **One provider, no polish** — rejected: which provider is the open question. Chinese with
  embedded English technical terms is not something any vendor benchmarks.
- **Four providers, pick one, no polish** — chosen.

## Consequences

- **The provider choice is the product.** Whatever it returns is what gets pasted, so a bad
  choice is visible immediately rather than absorbed by a cleanup pass.
- **No offline dictation at all.** With the local engine gone, no network means a clear
  error. Acceptable: the local engine cost ~4 GB resident and was rarely the path taken.
- **Text quality can regress from the previous release** in ways the polish pass used to
  hide — Chinese/English spacing, half-width punctuation, self-corrections ("A，不对，B").
  `PostProcessor` did some of this deterministically and was removed with the rest; it is
  in git history and can come back per-symptom once real usage shows which symptoms are
  actually left standing.
- **The comparison is the point.** Four providers behind one hotkey with one keychain slot
  each means switching costs a menu click, so a real answer comes from real dictations
  rather than from vendor documentation.

## The four

| Provider | Native cleanup | Mixed CN/EN | Terms |
|---|---|---|---|
| ElevenLabs Scribe v2 | `no_verbatim`: fillers, false starts, repetitions, stuttering | English words stay English regardless of surrounding language (documented; examples are Indic, not Chinese) | 1000 keyterms |
| xAI Grok | filler words removed by default | undocumented — Chinese is absent from the published language table | 100 keyterms |
| Soniox v5 | none documented | explicitly handles languages mixed within one sentence | context: terms + free text, ~8k tokens |
| OpenAI gpt-transcribe | none | documented code-switching support | keywords + language hints |

Vendor documentation is where these claims come from, and for the one case that matters
most — Mandarin with embedded English technical terms — none of them publish a benchmark.
That is what the app is now shaped to answer.
