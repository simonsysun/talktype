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

## Four providers, one hotkey

A dictation is one API call: record, send, paste. Nothing runs in between — no cleanup pass,
no local model — so whatever the provider returns is exactly what lands at your cursor.

Pick one in the menu bar. Each keeps its own key, so switching to compare is a menu click.

| Provider | Price (file) | Removes fillers natively | Mixed CN/EN |
|---|---|---|---|
| **ElevenLabs Scribe v2** (default) | $0.22/h | Yes — `no_verbatim`: fillers, false starts, repetitions, stuttering | English words stay English regardless of surrounding language |
| **xAI Grok** | $0.10/h | Yes — filler words removed by default | Not documented; Chinese is absent from the published language table |
| **Soniox v5** | ~$0.10/h | No | Explicitly handles languages mixed within one sentence |
| **OpenAI gpt-transcribe** | $0.27/h | No | Documented code-switching support |

Which one is actually best for Mandarin with English technical terms is an open question —
no vendor benchmarks that case. Switching providers and dictating the same sentence is how
you find out.

**Privacy, precisely:**

| What | Leaves your Mac? |
|---|---|
| Audio + your vocabulary terms | Yes — to the provider you chose, subject to its data policy |
| Anything else | Nothing. No account, no telemetry, no subscription. |

The only credential is your own API key for the provider you picked, stored in the macOS
Keychain. There is no offline mode: no network means a clear error, not a fallback.

---

## Quick start — about 5 minutes

**You need:** an Apple silicon Mac (M1 or newer) on macOS 13+.

1. **Download and open.** [⬇ Latest release](https://github.com/simonsysun/talktype/releases/latest) —
   unzip, drag to Applications. The first time you open it, macOS will refuse — free apps aren't
   signed with a paid certificate. Right-click the app ▸ **Open** ▸ **Open**, and macOS remembers.
2. **Allow two permissions.** The microphone, and "paste on your behalf". Both are required;
   TalkType can't grant them for you.
3. **Pick a provider and paste its key.** Setup opens by itself when the chosen provider has
   no key. The "拿 key →" link goes to that provider's console.

Press **⌘⇧Space** and start talking.

---

## Manual

- **Hotkey** — default ⌘⇧Space; change it from the menu bar (Change Hotkey…).
- **Provider** — menu bar ▸ Speech-to-text ▸ pick one. The menu title shows which is active
  and whether it has a key.
- **Microphone** — pick one, or Automatic (follows the system default, including a Bluetooth
  headset; recording through a Bluetooth mic switches the link into headset mode, so playback
  drops to 24 kHz mono for a while).
- **Vocabulary** — add names and terms the model keeps mishearing. These are sent to the
  provider in whatever form it accepts: `keyterm` for Grok, `keyterms` for ElevenLabs,
  `context.terms` for Soniox, `keywords[]` for OpenAI. Nothing is rewritten locally
  afterwards, so a term that still comes out wrong is telling you something real about that
  provider.
- **Keys** — one slot per provider, in your login Keychain. Setup lets you add, replace, or
  remove them. They are saved as typed; a wrong key announces itself on the first dictation.
- **Clipboard** — every transcript is also left on your clipboard, so ⌘V always works as a
  manual fallback.

## Troubleshooting

- **Stopped pasting after an update?** macOS ties the paste permission to the exact build, and
  TalkType isn't signed with a paid certificate — so a new version looks like a different app.
  TalkType spots this and offers a **Fix This** button; click it and switch TalkType back on when
  macOS asks. *(Releases from v2.0.2 share one certificate, so this shouldn't recur.)*
- **"还没有 API key"?** Pick the provider in Setup and paste its key.
- **"拒绝了这个 API key"?** The provider answered and said no — usually a stray space, or the
  wrong provider's key. The eye button in Setup reveals what was actually saved.
- **Chinese and English run together without a space, or punctuation comes out half-width?**
  That is the provider's raw output. Nothing normalises it any more — try another provider.
- **Soniox feels slow?** It has no synchronous endpoint: a dictation costs an upload, a job
  creation, polling, and a fetch. The other three are one round trip.

## How it compares

| | TalkType | Apple Dictation | Wispr Flow / Superwhisper |
|---|---|---|---|
| Price | Free (bring your own key) | Free | Subscription |
| Offline | No | Partly | Usually cloud |
| Voice leaves your Mac | Yes | Sometimes | Usually |
| Mixed Chinese + English | Yes | Poorly | Varies |
| Removes filler words | Depends on the provider | No | Yes |
| Custom vocabulary | Yes | Limited | Yes |
| Open source | Yes (MIT) | No | No |

## Under the hood

One `STTClient` protocol, four implementations. Three are a single multipart POST; Soniox
uploads, creates a job, polls, then fetches. The parameters that decide output quality are
set in code rather than exposed as settings — `no_verbatim=true` and `tag_audio_events=false`
for ElevenLabs, `filler_words=false` for Grok, both language hints for Soniox and OpenAI.

`grok_language` in `~/.talktype/config.json` is the one escape hatch: xAI's `format` (spoken
numbers → written form) only applies when a language is also sent, but Chinese is absent from
xAI's published language table — so whether `zh` helps is empirical. Blank it to send neither.

Setting `TALKTYPE_STATE_DIR` points config and vocabulary somewhere else, which is how you
trial a second setup without touching your real one.

## Building from source

```bash
git clone https://github.com/simonsysun/talktype.git
cd talktype

./scripts/make-signing-cert.sh   # optional, once: keeps permissions valid across updates
./scripts/build.sh install
```

`swift test` runs the logic tests without Xcode. `TODO.md` tracks what is done and what isn't.
An iOS keyboard extension exists in the repository but is parked and never compiled.

## Licence

MIT — do what you like with it.
