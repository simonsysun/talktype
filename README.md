# TalkType

![TalkType logo](docs/assets/talktype-logo.png)

Native Swift macOS menu bar dictation app.

## What it does

- Start and stop dictation with `Option + Space`
- Transcribe with OpenAI speech-to-text
- Type directly into the current app when Accessibility is enabled
- Keep custom vocabulary for names, acronyms, and product terms

## Models

- Default: `gpt-4o-mini-transcribe`
- Optional: `gpt-4o-transcribe`

At around 30 minutes of dictation per day, `gpt-4o-mini-transcribe` costs about **$2.7/month** and `gpt-4o-transcribe` about **$5.4/month**, while Wispr Flow Pro is **$15/month**.

## API key storage

OpenAI API keys are stored locally in an encrypted file under `~/.talktype/keys/`.
The app uses a local random master key plus machine-bound encryption.
For extra safety, consider setting a monthly usage limit on your OpenAI account.

## Vocabulary

Use `Vocabulary` in the menu bar app to add words or phrases you want the model to prefer.

Current behavior is intentionally simple:

- saved terms are added to the transcription prompt
- saved terms are also used for conservative post-processing
- there is no fuzzy matching or automatic learning

## Requirements

- macOS
- OpenAI API key
- Microphone permission
- Accessibility permission for direct typing

## License

MIT
