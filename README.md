# TalkType

![TalkType logo](docs/assets/talktype-logo.png)

macOS menu bar dictation. Press a hotkey, speak, and the text is typed into whatever app
you were in. Your voice never leaves the machine.

## How it works

```
speak ──► local Qwen3-ASR ──► optional cloud polish ──► typed into the focused app
          0.3–0.9 s            0.2 s
          on-device            transcript only, never audio
```

Transcription runs entirely on your Mac through a small Python sidecar that keeps
[Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) resident in memory via MLX. Measured
against fourteen cloud transcription services on real recordings, the local model was
faster than all of them — there is no audio upload to wait for.

Polishing is optional and off-machine: the *transcript* — not the audio — goes to Groq,
which removes filler words, fixes punctuation, and resolves self-corrections. Turn it off
in the menu bar and everything stays local, with a deterministic rule-based tidy taking
its place.

## What it does

- Dictate with `Cmd+Shift+Space`, customisable
- Types directly into the focused app; falls back to the clipboard without Accessibility
- Returns focus to the app you started in, if you switched away mid-recording
- Handles mixed Chinese and English without being told which is which
- Custom vocabulary for names, acronyms and product terms
- Pick a specific microphone, or follow the system default
- Stops on its own after a stretch of silence

## Requirements

- macOS 13+ on Apple silicon — MLX is Metal-only
- Xcode, to build
- [`uv`](https://github.com/astral-sh/uv) for the Python environment: `brew install uv`
- ~4 GB of disk for the speech model
- Optional: a [Groq API key](https://console.groq.com/keys) for polishing

## Install

```bash
git clone git@github.com:simonsysun/talktype.git
cd talktype

./asr/install.sh                 # Python env + Qwen3-ASR weights, into ~/.talktype/asr
                                 # ./asr/install.sh 0.6B for a smaller, less accurate model

xcodebuild -scheme TalkType -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/TalkType-*/Build/Products/Release/TalkType.app /Applications/
open /Applications/TalkType.app
```

Then grant two permissions:

- **Microphone** — prompted on the first dictation
- **Accessibility** — System Settings ▸ Privacy & Security ▸ Accessibility ▸ add
  `/Applications/TalkType.app`. Without it, transcripts go to the clipboard instead of
  being typed.

To enable polishing, use `Groq API Key...` in the menu bar. The key is validated against
Groq before it is saved, and stored in your login keychain.

## Menu bar

| Item | What it does |
|---|---|
| Speech engine | Whether the local model is loaded, still loading, or missing |
| Polish with cloud AI | Toggles cloud polishing; off keeps everything on this machine |
| Groq API Key… | Add, replace or remove the key |
| Microphone | A specific input device, or Automatic |
| Vocabulary | Words to bias transcription towards |
| Change Hotkey… | Conflicts with system shortcuts are detected |

## Memory

The speech model is about 4 GB while loaded and is released after five minutes of
inactivity, dropping the sidecar to ~110 MB; the next dictation reloads it in ~0.25 s. The
app itself sits at ~60 MB. Neither grows with use.

## Vocabulary

Terms you add are sent to the model as a spelling bias, and are also used for conservative
post-processing — only distinctive terms (`API`, `GPT-4o`, `TalkType`) are auto-corrected,
never ordinary words. There is no fuzzy matching and no automatic learning.

Biasing has limits. `TestFlight` is recovered from "test flight"; `xAI` is not recovered
from "what's a ship", because the two are acoustically near-identical and no amount of
bias overcomes that.

## Privacy

| | Leaves the machine? |
|---|---|
| Audio | Never |
| Transcript | Only if polishing is on, and only to Groq |
| Vocabulary | Sent to the local model; not sent to Groq |

The sidecar runs with `HF_HUB_OFFLINE=1` and binds to loopback only. With polishing off,
TalkType makes no network requests at all.

## Status

A personal tool, built for one user, used daily. It is not signed or notarised, so on
another Mac Gatekeeper will require right-click ▸ Open the first time. There is no
installer and no release download — the steps above are the install.

An iOS keyboard extension exists in the repository but has never been compiled. See
`TODO.md` for what is done and what is not.

## License

MIT
