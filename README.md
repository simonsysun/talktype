# TalkType — talk instead of typing

*[中文说明](README.zh-CN.md)*

![TalkType logo](docs/assets/talktype-logo.png)

**Talk instead of typing.** Press a hotkey anywhere on your Mac and start talking; press it
again (or pause) — the words land where your cursor is. Slack, Notes, email, terminal…
anywhere you can type, you can talk.

Built by someone who thinks in two languages at once, so **mixing Chinese and English in one
sentence just works** — 你不用切换语言，说到哪算哪.

```
press hotkey → talk → press again / pause → text appears at your cursor
```

---

## Two engines, one hotkey

TalkType has two ways to turn your voice into words, and it picks for you:

| Engine | What it is | When it runs |
|---|---|---|
| **Cloud** (default) | Qwen3-ASR-Flash through [OpenRouter](https://openrouter.ai) — accurate mixed CN/EN, ~2 s a dictation, ≈ $2/month at 30 min/day | When you're online |
| **Local** | Qwen3-ASR on your Mac (MLX) — 0.3–0.9 s, audio never leaves the machine, ~4 GB download | Offline, or when the cloud is unreachable |

Cloud is the default because it keeps your Mac's memory free. When there's no network — or the
cloud is down — TalkType **switches to the local engine on its own and tells you it did**, so
dictation keeps working on a plane. If there's no local engine and no network, it says so
plainly instead of failing silently.

**Privacy, precisely:**

| What | Leaves your Mac? |
|---|---|
| Audio, cloud engine | Yes — to OpenRouter, subject to its data policy |
| Audio, local engine | No |

No account, no telemetry, no subscription. The only credential is your OpenRouter API key,
stored in the macOS Keychain.

---

## Quick start — about 5 minutes

**You need:** an Apple silicon Mac (M1 or newer) on macOS 13+.

1. **Download and open.** [⬇ Latest release](https://github.com/simonsysun/talktype/releases/latest) —
   unzip, drag to Applications. The first time you open it, macOS will refuse — free apps aren't
   signed with a paid certificate. Right-click the app ▸ **Open** ▸ **Open**, and macOS remembers.
2. **Allow two permissions.** The microphone, and "paste on your behalf". Both are required;
   TalkType can't grant them for you.
3. **Add your OpenRouter key.** Setup ▸ paste the key (get one at
   [openrouter.ai/keys](https://openrouter.ai/keys); a few dollars lasts a couple of months of
   normal use). Cloud dictation works immediately.
4. **Optional: install the local engine.** Setup ▸ Local engine ▸ **Install** — downloads ~4 GB
   once. You only need it if you dictate offline, or want the audio to stay on the machine.

Press **⌘⇧Space** and start talking.

---

## Manual

- **Hotkey** — default ⌘⇧Space; change it from the menu bar (Change Hotkey…).
- **Microphone** — pick one, or Automatic (Automatic passes over Bluetooth mics on purpose, so a
  headset doesn't stall your playback).
- **Vocabulary** — add names and terms the model keeps mishearing. Only distinctive spellings are
  auto-corrected: `TestFlight` is recoverable from "test flight"; `xAI` is not recoverable from
  "what's a ship" — those sound nearly identical, and no vocabulary fixes that. On the cloud
  engine the hints never reach the model — only this conservative client-side correction applies.
- **Engine** — menu bar ▸ Speech engine ▸ Cloud / Local. Cloud is the default; the menu shows
  which one is active.
- **Local engine** — install or reinstall it from Setup; the red "Delete local engine…" button
  frees the ~4 GB when you no longer need offline dictation.
- **Keys** — Setup lets you add, replace, or remove them; they live in your login Keychain.
- **Clipboard** — every transcript is also left on your clipboard, so ⌘V always works as a
  manual fallback.
- **Offline** — TalkType switches to the local engine on its own and notifies you at the switch.
  With no local engine and no network, it tells you to install the local engine or get online.

## Troubleshooting

- **Stopped pasting after an update?** macOS ties the paste permission to the exact build, and
  TalkType isn't signed with a paid certificate — so a new version looks like a different app.
  TalkType spots this and offers a **Fix This** button; click it and switch TalkType back on when
  macOS asks. *(Releases from v2.0.2 share one certificate, so this shouldn't recur.)*
- **"Cloud speech engine has no API key"?** Add an OpenRouter key in Setup.
- **Cloud feels slow?** Cloud adds ~2 s per dictation. If speed or privacy matters more than RAM,
  switch to Local.
- **"Cloud model unavailable"?** TalkType uses a fixed Qwen snapshot on OpenRouter. If OpenRouter
  ever retires it, set `"cloud_model_override": "new/model"` in `~/.talktype/config.json` and
  restart — or update TalkType for the new default.

## How it compares

| | TalkType | Apple Dictation | Wispr Flow / Superwhisper |
|---|---|---|---|
| Price | Free (bring your own keys) | Free | Subscription |
| Offline | Yes, with local engine | Partly | Usually cloud |
| Voice leaves your Mac | Only on the cloud engine | Sometimes | Usually |
| Mixed Chinese + English | Yes | Poorly | Varies |
| Removes filler words | Yes (automatic local tidy) | No | Yes |
| Custom vocabulary | Yes | Limited | Yes |
| Open source | Yes (MIT) | No | No |

## Under the hood

- **Cloud:** Qwen3-ASR-Flash through OpenRouter's `/audio/transcriptions` (base64 WAV). The default
  engine — ~2 s, ≈ $0.002/min, audio leaves the machine.
- **Local:** Qwen3-ASR via [MLX](https://github.com/ml-explore/mlx) in a small loopback-only Python
  helper that exits with the app. ~4 GB resident only while running.
- **Tidy:** deterministic local rules (呃/嗯, stutters, punctuation width) run on the machine —
  what the engine heard is what you get, minus the filler.

## Building from source

```bash
git clone https://github.com/simonsysun/talktype.git
cd talktype

./asr/install.sh                 # Python env + Qwen3-ASR weights, into ~/.talktype/asr
                                 # ./asr/install.sh 0.6B for a smaller, less accurate model

./scripts/make-signing-cert.sh   # optional, once: keeps permissions valid across updates
./scripts/build.sh install
```

`swift test` runs the logic tests without Xcode. `TODO.md` tracks what is done and what isn't.
An iOS keyboard extension exists in the repository but is parked and never compiled.

## Licence

MIT — do what you like with it.
