# TalkType

![TalkType logo](docs/assets/talktype-logo.png)

Native Swift macOS menu bar dictation app.

## What it does

- Start and stop dictation with `Cmd+Shift+Space` (customizable)
- Transcribe with OpenAI or Groq speech-to-text
- Type directly into the current app when Accessibility is enabled
- Automatically restore focus to the original app if you switch away during recording
- Keep custom vocabulary for names, acronyms, and product terms

## Providers

Switch providers from the menu bar under `Provider`.

### OpenAI

- Models: `gpt-4o-mini-transcribe` (default), `gpt-4o-transcribe`
- ~30 min/day costs about **$2.7/month** (mini) or **$5.4/month** (premium)
- Requires an [OpenAI API key](https://platform.openai.com/api-keys)

### Groq

- Models: `whisper-large-v3` (default), `whisper-large-v3-turbo`
- Runs the same open-source Whisper model on Groq's LPU hardware — **~200x faster** than GPU
- **Free tier**: 2,000 requests/day, 25 MB max file size, no credit card required
- Requires a [Groq API key](https://console.groq.com/keys)

Both providers use the same Whisper architecture, so transcription accuracy is equivalent.

## Custom hotkey

Click `Change Hotkey...` in the menu bar to set your preferred key combination. System shortcut conflicts are detected automatically.

## API key storage

API keys are stored locally in an encrypted file under `~/.talktype/keys/`.
The app uses a local random master key plus machine-bound encryption.
Each provider's key is stored separately. You can also set keys via environment variables: `TALKTYPE_API_KEY` (OpenAI) or `TALKTYPE_GROQ_API_KEY` (Groq).

## Vocabulary

Use `Vocabulary` in the menu bar app to add words or phrases you want the model to prefer.

Current behavior is intentionally simple:

- saved terms are added to the transcription prompt
- saved terms are also used for conservative post-processing
- there is no fuzzy matching or automatic learning

## Requirements

- macOS 13.0+
- API key (OpenAI or Groq)
- Microphone permission
- Accessibility permission for direct typing

## License

MIT
