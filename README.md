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

## Help shape TalkType

TalkType gets better through real daily use — especially the small details one person cannot
discover alone. If something feels off, a word is repeatedly misheard, or you have an idea that
would make dictation fit your workflow better, **please [open a GitHub issue](https://github.com/simonsysun/talktype/issues/new)**.

Bug reports, rough ideas, feature requests, and tiny usability observations are all welcome. You
do not need to know how to code or arrive with a complete solution. We can work out what to build
together. You can also [browse and join existing discussions](https://github.com/simonsysun/talktype/issues).

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
| Audio + active vocabulary hints, cloud engine | Yes — to OpenRouter, subject to its data policy |
| Audio, local engine | No |
| Transcript + active vocabulary → polish (optional) | Text only, to Groq — never audio |

No account, no telemetry, no subscription. The only credentials are your own API keys
(OpenRouter for recognition, Groq for optional polish), stored in the macOS Keychain.

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
5. **Optional: add a Groq key for polish.** Setup ▸ Cloud polish ▸ paste the key (free at
   [console.groq.com/keys](https://console.groq.com/keys)). Polish removes 呃/嗯 and fixes
   punctuation — transcript only, never audio. Without it, a local tidy still runs.

Press **⌘⇧Space** and start talking.

---

## Manual

- **Hotkey** — default ⌘⇧Space; change it from the menu bar (Change Hotkey…).
- **Microphone** — pick one, or Automatic (follows the system default, including a Bluetooth
  headset; recording through a Bluetooth mic switches the link into headset mode, so playback
  drops to 24 kHz mono for a while).
- **Vocabulary** — add names and terms the model keeps mishearing. OpenRouter currently ignores
  the speech engine's hint field, so TalkType also gives these terms to optional Polish as
  approved spellings — only when the transcript clearly contains the term — and applies a final
  conservative spelling correction locally.
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
- **Told "云端语音引擎没有 API key"?** Add an OpenRouter key in Setup.
- **Cloud feels slow?** Cloud adds ~2 s per dictation. If speed or privacy matters more than RAM,
  switch to Local.
- **Told "云端模型不可用"?** TalkType uses a fixed Qwen snapshot on OpenRouter. If OpenRouter
  ever retires it, set `"cloud_model_override": "new/model"` in `~/.talktype/config.json` and
  restart — or update TalkType for the new default.

## How it compares

| | TalkType | Apple Dictation | Wispr Flow / Superwhisper |
|---|---|---|---|
| Price | Free (bring your own keys) | Free | Subscription |
| Offline | Yes, with local engine | Partly | Usually cloud |
| Voice leaves your Mac | Only on the cloud engine | Sometimes | Usually |
| Mixed Chinese + English | Yes | Poorly | Varies |
| Removes filler words | Yes (optional cloud polish) | No | Yes |
| Custom vocabulary | Yes | Limited | Yes |
| Open source | Yes (MIT) | No | No |

## Under the hood

- **Cloud:** Qwen3-ASR-Flash through OpenRouter's `/audio/transcriptions` (base64 WAV). The default
  engine — ~2 s, ≈ $0.002/min, audio leaves the machine.
- **Local:** Qwen3-ASR via [MLX](https://github.com/ml-explore/mlx) in a small loopback-only Python
  helper that exits with the app. ~4 GB resident only while running.
- **Polish:** Qwen on [Groq](https://groq.com) — ~0.3 s, transcript only, with strict guards
  against rewriting or translating what you said. The deterministic local tidy is the fallback
  when polish is off or unreachable.

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
