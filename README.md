# TalkType — free, offline dictation for Mac

*[中文说明](README.zh-CN.md)*

![TalkType logo](docs/assets/talktype-logo.png)

**Talk instead of typing.** Press a hotkey anywhere on your Mac, say what you mean, press it
again — the words appear where your cursor is. In Slack, in Notes, in your email, in a
terminal. Anywhere you can type, you can talk.

Everything happens **on your own Mac**. Your voice is never uploaded, never stored, and
never used to train anything. There is no account, no subscription, and no monthly fee.
TalkType is free and open source.

It was built by someone who thinks in two languages at once, so **mixing Chinese and
English in one sentence just works** — 你不用切换语言，说到哪算哪。

```
press hotkey  ──►  talk  ──►  press again  ──►  text appears at your cursor
                                                 about a second later
```

---

## Download

**[⬇ Download the latest version](https://github.com/simonsysun/talktype/releases/latest)** —
unzip it, drag `TalkType.app` to your Applications folder, and open it.

You'll need a **Mac with Apple silicon** (M1 or newer) running **macOS 13 or later**.

The first time you open it, macOS will refuse, because TalkType is not signed with a paid
Apple developer certificate. This is normal for free open-source apps. Right-click the app
▸ **Open** ▸ **Open**, and macOS will remember.

Then the setup window walks you through three things:

1. **Speech engine** — click Install. It downloads about 4 GB once, then never again. This
   is the part that turns your voice into words, and it lives on your Mac.
2. **Permissions** — macOS asks for the microphone, and for permission to paste on your
   behalf. Both are required; TalkType cannot grant them for you.
3. **Cloud polish** *(optional, skip it if you like)* — see below.

That's it. Press **⌘⇧Space** and start talking.

---

## Common questions

**Is it really free?**
Yes. No account, no subscription, no trial. The code is here and the licence is MIT.

**Does my voice get sent anywhere?**
No. Speech recognition runs on your Mac. With the optional polish turned off, TalkType makes
no network requests at all — you can use it on a plane.

**What is "cloud polish", then?**
An optional extra that tidies the *text* — removing "um" and "uh", fixing punctuation, and
cleaning up when you correct yourself mid-sentence. It sends the transcript, never the
audio, to [Groq](https://console.groq.com/keys). It's off unless you add a key, and there's
a local rule-based tidy that does a decent job without it.

**Does it handle Chinese? Mixed Chinese and English?**
Yes, and that was the point. It detects the language itself — you never tell it which you're
about to speak, and you can switch mid-sentence.

**How fast is it?**
Roughly 0.3–0.9 seconds after you stop talking. Because nothing is uploaded, it beat all
fourteen cloud transcription services measured against it on the same recordings.

**Will it slow my Mac down?**
The speech model uses about 4 GB of memory while it's loaded, and TalkType releases it after
five minutes of not being used. Coming back takes about a second. Neither the app nor
the engine grows with use.

**It stopped pasting after I updated. What happened?**
macOS ties the "allow this app to paste" permission to the exact version it was granted to,
and TalkType isn't signed with a paid certificate, so a new version looks like a different
app — even though System Settings still shows TalkType switched on. TalkType notices this
and offers a **Fix This** button; click it, and switch TalkType on again when macOS asks.

*(From v2.0.2 releases are signed with one certificate, so this should not recur on future
updates.)*

**Do I need to know anything technical?**
No. Download, open, click Install, allow two permissions.

---

## How it compares

| | TalkType | Apple Dictation | Wispr Flow / Superwhisper |
|---|---|---|---|
| Price | Free | Free | Subscription |
| Runs offline | Yes | Partly | Usually cloud |
| Voice leaves your Mac | Never | Sometimes | Usually |
| Mixed Chinese + English | Yes | Poorly | Varies |
| Removes filler words | Yes | No | Yes |
| Custom vocabulary | Yes | Limited | Yes |
| Open source | Yes | No | No |

If you want something polished, supported, and with a company behind it, buy one of the paid
apps — they're good. TalkType exists for people who want the same thing without a
subscription, and without their voice going to a server.

---

## What it can do

- Dictate anywhere with **⌘⇧Space** — change it to whatever you like
- Pastes straight into whatever app you were in, and returns you there if you wandered off
- Understands mixed Chinese and English without being told which is coming
- **Custom vocabulary** for names, acronyms and product terms it keeps mishearing
- Choose a specific microphone, or follow whatever the system is using
- Stops on its own after a stretch of silence
- Lives in the menu bar; no Dock icon, no window in your way

---

## Under the hood

Speech recognition is [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR), running through
[MLX](https://github.com/ml-explore/mlx) on your Mac's GPU. TalkType keeps it resident in a
small Python helper process so that dictating doesn't wait for a model to load; the helper
binds to loopback only, runs with `HF_HUB_OFFLINE=1`, and exits when TalkType does.

```
speak ──► local Qwen3-ASR ──► optional cloud polish ──► pasted into the focused app
          0.3–0.9 s            0.2 s
          on-device            transcript only, never audio
```

**Privacy, precisely:**

| | Leaves your Mac? |
|---|---|
| Audio | Never |
| Transcript | Only if you turned polish on, and only to Groq |
| Custom vocabulary | Goes to the local model; never to Groq |

**Vocabulary has limits.** Terms you add bias the model's spelling and are used for
conservative correction afterwards — only distinctive terms (`API`, `GPT-4o`, `TalkType`)
are auto-corrected, never ordinary words. `TestFlight` is recoverable from "test flight";
`xAI` is not recoverable from "what's a ship", because those sound nearly identical and no
amount of biasing fixes that.

**Menu bar:**

| Item | What it does |
|---|---|
| Speech engine | Whether the local model is loaded, still loading, or missing |
| Polish with cloud AI | Toggles cloud polishing; off keeps everything on this machine |
| Groq API Key… | Add, replace or remove the key (stored in your login keychain) |
| Microphone | A specific input device, or Automatic |
| Vocabulary | Words to bias transcription towards |
| Change Hotkey… | Conflicts with system shortcuts are detected |
| Setup… | The first-run window again, any time |

---

## Building from source

```bash
git clone git@github.com:simonsysun/talktype.git
cd talktype

./asr/install.sh                 # Python env + Qwen3-ASR weights, into ~/.talktype/asr
                                 # ./asr/install.sh 0.6B for a smaller, less accurate model

./scripts/make-signing-cert.sh   # optional, once: keeps permissions valid across updates
./scripts/build.sh install
```

`swift test` runs the logic tests without Xcode. `TODO.md` tracks what is done and what
isn't.

An iOS keyboard extension exists in the repository but has never been compiled, and is
parked.

## Licence

MIT — do what you like with it.
