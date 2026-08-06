# Improving Polish Accuracy Without Destabilizing TalkType

Date: 2026-08-05

## Conclusion

Do not fine-tune or replace the current models yet. The remaining gap is mostly
personal terminology and context, not general transcription quality. The safest
next step is a small regression corpus followed by one narrowly scoped Polish
experiment.

## What explains the gap

- Wispr Flow combines transcription with a personal dictionary, learned
  corrections, app/conversation context, styles, and developer-specific syntax.
  Matching all of that would be a product program, not a prompt tweak.
- `LLM -> LM` is a one-character deletion. TalkType's current guarded Polish
  path can safely repair such a near match when `LLM` is an approved spelling;
  exact post-processing alone cannot.
- Current OpenRouter Qwen3-ASR does not apply TalkType's vocabulary prompt, so
  cloud ASR terminology cannot be fixed by merely sending more prompt text.

## Recommended sequence

1. Keep the shipped behavior unchanged.
2. Collect 10–20 real pairs: raw output and Simon's preferred result, especially
   acronyms, Chinese-English terms, names, and fast speech.
3. Add exact canonical terms such as `LLM` to the existing vocabulary.
4. Offline A/B test one small Polish rule/example: use an approved spelling only
   when the transcript contains a close spoken form and context supports it.
5. Ship only if the corpus shows the target fixes with no meaning changes,
   omissions, or invented vocabulary.

If canonical vocabulary proves insufficient, the next small feature is an
explicit per-term alias such as `LM -> LLM`, used only by Polish and protected by
the existing anti-invention checks. Do not implement automatic learning until
repeated evidence justifies the privacy and interaction complexity.

## Options not recommended now

- Fine-tuning: requires labeled audio-text data, GPU training, regression work,
  and a deployment/conversion path compatible with TalkType's MLX runtime.
- A second LLM call, model voting, or retranscription: adds latency, cost, and
  another failure surface for a small remaining gain.
- Reading screen/conversation context: potentially effective but materially
  expands privacy scope and product complexity.
- Switching to a provider/model with hotwords: technically promising, but adds
  another provider/key path. Benchmark later rather than treating it as a small
  fix.

## Evidence

- [Qwen3-ASR official repository](https://github.com/QwenLM/Qwen3-ASR) and
  [fine-tuning guide](https://github.com/QwenLM/Qwen3-ASR/tree/main/finetuning)
- [Alibaba Cloud: improve ASR accuracy](https://help.aliyun.com/zh/model-studio/improve-asr-accuracy)
- [Groq prompting guide](https://console.groq.com/docs/prompting)
- [Wispr Flow features](https://wisprflow.ai/features) and
  [context awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)
