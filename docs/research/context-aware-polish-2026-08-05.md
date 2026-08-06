# Context-aware transcription without model training

> Status update — 2026-08-05: this initial terms-only proposal is superseded by
> `context-anchor-ranking-2026-08-05.md`. Current code stops at a local-only preview; it does not
> send nearby text during dictation. Terms plus short topic evidence remain an experiment until
> real AX coverage and the fixed safety benchmark pass.

Date: 2026-08-05

## Conclusion

Simon’s hypothesis is substantially correct, and it does not require training a
custom model. Wispr Flow publicly confirms that Context Awareness reads the active
app, limited text near the cursor, on-screen text, screenshots, and—in supported
messaging apps—conversation history. It says this context improves proper-noun
accuracy, capitalization, style, and formatting. Wispr does not disclose its model
architecture or exactly which context enters ASR versus a later language-model pass,
so that part cannot be claimed as fact.

For TalkType, the smallest safe version is **not** a screenshot or full-conversation
reader. Capture the active app and a short, bounded set of visible candidate terms at
recording start; pass those terms only to the existing Polish call; and allow a term
to replace text only when the raw transcript contains a close match. This can repair
cases such as `cloud code -> Claude Code` and `LM -> LLM` without fine-tuning and
without changing the ASR provider.

## What Wispr Flow officially discloses

Wispr’s own Context Awareness documentation says:

- It identifies the active app and, in browsers, the specific website.
- It reads a limited amount of text near the cursor.
- Visible names and context improve proper-noun recognition and capitalization.
- Slack and Apple Messages have dedicated conversation-context support; other apps
  receive general nearby-text reading.
- Context sent with each dictation request can include app information, textbox text
  before/at/after the cursor, on-screen text, code/file names, a screenshot, and
  conversation history with participant IDs, roles, and message content.
- It requires Accessibility permission on macOS, excludes standard password fields,
  can be disabled, and has a Privacy Mode.

Source: [Wispr Flow: Context Awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness).
Wispr also says its personal dictionary learns corrected spellings and that it uses
surrounding context for uncommon names: [Wispr Flow features](https://wisprflow.ai/features).

This proves the broad product technique. It does **not** prove that Wispr feeds the
same payload directly into its acoustic model; a later correction/reranking model
could produce the same behavior.

## What macOS exposes to TalkType

### Active application: cheap and low sensitivity

`NSWorkspace.shared.frontmostApplication` returns the app receiving key events. It
provides enough information to label a request as, for example, Claude, Messages, or
VS Code. App identity alone can choose formatting style, but cannot recover an unusual
term that appeared only in the previous answer.

Source: [Apple: `NSWorkspace.frontmostApplication`](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication).

### Focused text and caret neighborhood: supported, but incomplete

With Accessibility permission, TalkType can obtain the system-wide focused element
or create an AX object for the frontmost process, then read attributes with
`AXUIElementCopyAttributeValue`. For editable text:

- `kAXSelectedTextRangeAttribute` gives the selected character range.
- `kAXStringForRangeParameterizedAttribute`, together with
  `AXUIElementCopyParameterizedAttributeValue`, can return a bounded substring around
  that range instead of copying an entire document.
- `kAXValueAttribute` may expose the editable field’s value where the target app
  implements it.

Sources: [Apple: `AXUIElementCreateSystemWide`](https://developer.apple.com/documentation/applicationservices/1462095-axuielementcreatesystemwide),
[`kAXSelectedTextRangeAttribute`](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute),
[`kAXStringForRangeParameterizedAttribute`](https://developer.apple.com/documentation/applicationservices/kaxstringforrangeparameterizedattribute),
and [`kAXValueAttribute`](https://developer.apple.com/documentation/applicationservices/kaxvalueattribute).

Important limitation: in ChatGPT or Claude, the previous AI answer is normally a
different UI element from the focused reply box. Reading only the focused textbox
therefore often returns an empty field and does not solve Simon’s example. Getting the
previous answer requires a bounded walk of the active window’s accessibility tree, or
a screenshot plus OCR. Third-party apps can omit attributes or fail AX calls; Apple
documents `kAXErrorNotImplemented` and `kAXErrorCannotComplete`, so this must always be
best-effort with a timeout and a no-context fallback.

Source: [Apple: `AXUIElement.h`](https://developer.apple.com/documentation/applicationservices/axuielement_h).

### Permission and privacy boundary

TalkType already asks for Accessibility access for insertion. Apple’s
`AXIsProcessTrustedWithOptions` is the supported way to test that authorization and
optionally prompt the user. Reusing the existing permission avoids another OS prompt,
but reading and sending text is a materially broader user expectation than simulating
Paste, so it still needs an explicit product toggle and clear disclosure.

Source: [Apple: `AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).

Screenshots are not part of the recommended MVP. ScreenCaptureKit requires Screen
Recording permission and a usage description, adding a second sensitive permission
and much more data than this accuracy problem requires.

Source: [Apple: ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).

## Where context can enter without training

### Recommended now: existing Polish stage

The current Polish request already sends structured JSON containing the transcript
and approved spellings to Qwen on Groq. Add two bounded data fields later:

```json
{
  "transcript": "我感觉 cloud code 应该已经登录了",
  "approved_spellings": ["LLM"],
  "active_app": "Claude",
  "context_terms": ["Claude Code"]
}
```

The system rule should treat all context as untrusted reference data, never as
instructions, and use a context term only when the transcript contains a plausible
near match. `Claude Code` versus `cloud code`, and `LLM` versus `LM`, both fit that
guard. If the call times out, the context read fails, or output validation fails,
TalkType retains today’s transcript path unchanged.

This is ordinary inference-time context injection, not learning. Groq’s official
prompting guide explicitly treats context as a normal prompt component, recommends
including only what is needed because excess context can add latency and reduce
accuracy, and supports deterministic low-temperature extraction-style work.

Source: [Groq: Prompt Basics](https://console.groq.com/docs/prompting).

### ASR-stage context: possible, but not with the current cloud path

Alibaba’s official accuracy guide documents exactly the mechanism Simon described
for its Qwen-Audio 3.0 ASR models: callers may send recent user transcripts and model
replies before the current audio. The service says this can significantly improve
proper nouns and domain terms, keeps up to five recent turns with 400 characters per
turn, and works mainly by matching original terms present in the context. Merely
describing the topic without including the exact term has limited effect.

This means a prior answer containing `Claude Code` is a strong context signal without
fine-tuning. However, the documented support table is for Qwen-Audio-3.0-ASR and
selected Fun-ASR models, not TalkType’s current OpenRouter Qwen3-ASR route. The repo’s
2026-08-04 experiment also found that OpenRouter accepted but ignored the current
prompt field. Moving this feature into ASR would therefore require a provider/model
change and a new benchmark; it is not the minimal first step.

Source: [Alibaba Model Studio: improve ASR accuracy](https://help.aliyun.com/zh/model-studio/improve-asr-accuracy).

The official open-source Qwen3-ASR API currently documents audio and language inputs,
but not conversation context in its standard `transcribe` call:
[Qwen3-ASR official repository](https://github.com/QwenLM/Qwen3-ASR).

## Recommended MVP

This is a future implementation plan, not a change made by this research.

1. **Opt-in toggle, off by default:** “Use nearby text to improve names and technical
   terms.” State that selected context terms—not screenshots—may be sent with Polish.
2. **Snapshot at recording start:** asynchronously remember bundle ID/app name and
   inspect only the active window. Never wait for this work when recording stops.
3. **Strict acquisition budget:** stop after roughly 100 ms, a bounded number of AX
   nodes, or a small text budget. Skip secure text fields and an explicit sensitive-app
   denylist. Unsupported or slow apps return no context.
4. **Local minimization:** from visible AX strings, retain at most about 20 likely
   names/terms—acronyms, Title Case phrases, camelCase/snake_case identifiers, and
   filenames. Do not retain or send full conversation prose in v1.
5. **Guarded Polish only:** send `active_app` and `context_terms` as JSON data. A term
   may correct only an acoustically/orthographically plausible form already present;
   never add unrelated context. Reuse the existing language, length, and
   no-invention checks and extend them to ephemeral context terms.
6. **Ephemeral by design:** keep the snapshot in memory for one dictation, never log
   its content, never persist it, and discard it immediately after insertion.

The key design choice is local minimization. It captures the high-value spelling
signal from an answer such as `Claude Code`, while avoiding Wispr’s much broader
screenshot and conversation-history collection.

## Acceptance and rollback

Before shipping, create a fixed corpus containing raw ASR, relevant visible context,
and Simon’s expected output. It must include target fixes (`cloud code -> Claude Code`,
`LM -> LLM`), unrelated visible terms, prompt-injection-like screen text, empty reply
boxes, unsupported apps, and Chinese-English dictation.

Ship only if:

- target terms improve on repeated runs;
- zero unrelated context terms are inserted;
- no meaning, completeness, or current Polish cases regress;
- context capture never delays the normal stop-to-paste path;
- permission denied, AX timeout, empty context, and network failure all produce the
  current behavior;
- logs and persistent files contain no captured text.

Rollback is one feature flag: stop supplying the two context fields. No model,
database, or user data migration is required.

## Recommendation

Prototype and A/B the **candidate-term Polish MVP** before considering a provider
switch. It addresses the concrete acronym/proper-name problem without model training,
without a screenshot permission, and with a clean fallback. If it cannot recover
terms from AI-chat accessibility trees often enough, then benchmark DashScope’s
documented Qwen-Audio 3.0 context path; only after that evidence should TalkType accept
the provider and privacy expansion.
