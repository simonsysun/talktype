# Context-aware dictation landscape (2026-08-05)

> Status update — 2026-08-05: the terms-only product recommendation below is superseded by
> `context-anchor-ranking-2026-08-05.md`. The current implementation is a local-only AX probe;
> neither terms nor snippets are connected to production dictation or uploaded. Topic snippets
> remain a benchmark arm and require separate evidence before release.

## Question

What can TalkType safely copy from Wispr Flow and comparable dictation tools to
improve homophone/proper-noun accuracy without training a model or turning a
small utility into a privacy-heavy system?

## Bottom line

Public evidence supports this high-level Wispr pipeline:

1. collect structured client context (app, cursor text, page/conversation text,
   dynamic vocabulary and optionally a screenshot);
2. send audio plus context to a cloud pipeline;
3. run ASR plus a fine-tuned Llama cleanup stage;
4. reinforce results with dictionary boosting, explicit replacements and user
   corrections.

The server-side ranking, ASR-decoder integration and training data are not
public. A third-party Windows protocol reverse engineering confirms payload
shape, but cannot reveal model logic.

TalkType should therefore not imitate the whole stack. The first production
step should be local extraction of a very small list of nearby names and
technical terms, passed to the existing Polish request. Full text snippets and
screenshots are separate, materially more private features and should not be in
v1.

## What is confirmed about Wispr Flow

- Wispr's current Context Awareness reads the active app and limited text near
  the cursor. Dedicated conversation context is documented for Slack and Apple
  Messages; other apps receive generic nearby-text support.
- Its published API accepts audio plus structured context: app type, dynamic
  dictionary, cursor text, page text/HTML, screenshot and recent conversation
  messages. This is explicitly described as helping names and speech
  ambiguity, not only punctuation.
- Wispr uses fine-tuned Llama models for transcript cleanup in a multi-step
  cloud inference pipeline. Baseten reports a p99 end-to-end target below
  700 ms and over 100 LLM tokens in under 250 ms.
- Wispr's dictionary combines vocabulary boosting, explicit replacement rules
  and learning from corrections.
- Wispr engineering articles discuss context-conditioned ASR, topic history and
  speaker features, but their wording mixes current behavior with research
  direction. It is not evidence that every feature is deployed on every
  request.

Sources:

- [Wispr Context Awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)
- [Wispr request schema](https://wisprflow.mintlify.app/request_schema)
- [Baseten case study](https://www.baseten.co/resources/customers/wispr-flow/)
- [Wispr speech-recognition challenges](https://wisprflow.ai/post/speech-recognition-challenges)
- [Wispr technical challenges](https://wisprflow.ai/post/technical-challenges)
- [Wispr dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)

## Independent evidence and limits

- [`wisprflow-sdk`](https://github.com/ThisisShashwat/wisprflow-sdk) is a small,
  unaudited reverse engineering of the Windows protocol. Its
  [technical notes](https://github.com/ThisisShashwat/wisprflow-sdk/blob/main/TECHNICAL_DETAILS.md)
  show preferences, optional context and audio being sent, with separate raw
  and formatted outputs. Treat it only as corroboration of the public schema;
  it cannot reveal server ranking or prove the newest macOS client is identical.
- No credible independent paper or full teardown was found that reconstructs
  Wispr's server models, topic retrieval, long-term memory or training data.

## Open-source peer implementation

[Dictator](https://dictator.robgough.net/) provides the most useful inspectable
macOS implementation:

- capture starts asynchronously at hotkey press and does not block recording;
- it reads the focused field around the cursor using Accessibility, with a
  short timeout and graceful fallback;
- it mines distinctive names, acronyms and technical terms from a wider local
  text window, then sends a much smaller context packet to its local formatter;
- context is marked read-only and deterministic checks remove accidental
  context echo;
- it deliberately does not put prose context into Whisper because real tests
  caused no-speech rejection;
- unsupported and secure fields return no context rather than failing dictation.

This independently confirms TalkType's current safest route: focused-field AX
context, local minimization, one existing Polish call and deterministic output
guards. It does not solve generic access to a previous AI answer rendered in a
sibling web element.

## Privacy recommendation for TalkType

### v1 boundary

- One explicit setting: **Use nearby text to improve names and technical terms**.
- Default it off during the first release because TalkType's Polish provider is
  cloud-based and the existing privacy promise only covers transcript plus
  vocabulary.
- Read only the focused editable element; never take screenshots or scrape the
  whole window.
- Extract locally and send at most 12 candidate terms. Do not send the source
  paragraph.
- Hard-stop for secure/password fields and offer per-app exclusions before any
  broader capture.
- Keep context only for the current dictation; never persist or log it.
- If cloud Polish is disabled, do not capture context at all.
- Settings and README must say exactly that the selected terms leave the Mac
  with the transcript and identify the provider.

After real-world validation, terms-only could become the recommended default
for users who already enabled cloud Polish, but it should not silently change
existing data handling.

### Not in v1

- nearby paragraphs or conversation history;
- screenshots/OCR;
- long-term topic memory;
- automatic learning from all user edits;
- a bundled local LLM solely for context selection.

Topic-level semantics has an unavoidable trade-off with the current stack:
either send short source snippets to the cloud, or run a capable model locally.
There is no reliable privacy-free heuristic that reconstructs the topic from a
few extracted terms. Full snippets should therefore be a later, separately
explained opt-in only if terms-only benchmarks show a meaningful gap.

## Recommended engineering route

### Stage 0 — read-only probe

Measure, across the apps TalkType users actually use:

- whether the focused AX element exposes cursor range and nearby text;
- capture latency and failure rate;
- whether mined terms include the intended ambiguous word;
- whether password/custom secure fields are reliably rejected.

This is the remaining feasibility uncertainty. Generic best-effort support is
possible; guaranteed support in every app is not, because some apps do not
expose their text through Accessibility.

### Stage 1 — terms-only context

Hide platform and privacy complexity behind one module:

```swift
protocol DictationContextProviding {
    func begin(target: NSRunningApplication, sessionID: Int) -> ContextTicket
    func resolve(_ ticket: ContextTicket, rawTranscript: String) -> ContextHints
    func discard(_ ticket: ContextTicket)
}

struct ContextHints {
    let terms: [String]
}
```

- `begin` captures asynchronously while the user speaks.
- `resolve` uses the raw transcript to rank nearby candidate terms and returns
  no more than 12.
- The existing Polish request receives the terms as untrusted reference data,
  not instructions.
- A context-derived spelling may be accepted only when the raw transcript has a
  plausible same-sounding/nearby span. Add context-echo and large-edit guards.
- Do not pass prose context to the current Qwen ASR routes; prior TalkType and
  Dictator experience both show prompt-completion/no-speech failure modes.

### Stage 2 — only if the benchmark proves it necessary

Try one to three short topic snippets under a separate opt-in. Cap the total
payload, never persist it, and benchmark the incremental accuracy against the
terms-only version. This is the first route likely to disambiguate broad topic
meaning, but it materially expands what Groq receives.

### Stage 3 — context-aware ASR benchmark

If errors remain because the correct word is absent from the raw ASR output,
post-processing cannot recover it reliably. Benchmark an ASR provider that
accepts runtime context/hotwords or N-best hypotheses against the current
Qwen3-ASR route. Change providers only if the measured gain beats latency,
privacy and maintenance costs.

### Stage 4 — training or correction learning

Only consider fine-tuning/personal acoustic adaptation after TalkType has a
consented error corpus large enough to demonstrate that stages 1–3 cannot solve
the remaining mistakes. This is where Wispr's proprietary advantage lives and
is not a sensible first investment for TalkType.

## Acceptance gates

Do not ship Stage 1 unless all are true:

- no measurable recording-start delay;
- capture times out and degrades to current behavior rather than blocking;
- zero context persistence/logging in an instrumented run;
- secure fields produce zero context;
- no copied/continued text in a fixed adversarial context-echo test set;
- a blinded phrase set shows a material proper-noun/homophone improvement with
  no meaningful regression in already-correct transcripts;
- Settings and README accurately describe what is captured and sent.

## Recommendation

Proceed with the Stage 0 probe, then Stage 1 terms-only. Do not add snippets,
screenshots, a local LLM or model training until measurement proves the simpler
route insufficient.
