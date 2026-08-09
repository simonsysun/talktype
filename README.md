# TalkType — talk instead of typing

*[中文说明](README.zh-CN.md)*

![TalkType logo](docs/assets/talktype-logo.png)

**Talk instead of typing.** Press a hotkey anywhere on your Mac and start talking; press it
again (or pause) — the words land where your cursor is. Slack, Notes, email, terminal…
anywhere you can type, you can talk.

## Project docs (for contributors and agents)

| File | Purpose |
| --- | --- |
| [`PRODUCT.md`](./PRODUCT.md) | Current product contract |
| [`DECISION.md`](./DECISION.md) | Durable decisions and why |
| [`NOW.md`](./NOW.md) | Only task tracker and restart point |
| [`DEVLOG.md`](./DEVLOG.md) | Simon's optional personal development log |
| [`AGENTS.md`](./AGENTS.md) | Required workflow for every AI coding agent |
| [`CHANGELOG.md`](./CHANGELOG.md) | Shipped release history |
| [`research/`](./research/) | Dated research synthesis |
| [`source-materials/`](./source-materials/) | Labeled source provenance (private bytes may be local-only) |

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

## One recognition, no rewrite

A dictation is one recognition: stream while you speak, finalise, paste. Nothing rewrites the
result — no cleanup pass, no local model — so whatever 豆包 returns lands at your cursor.

Speech recognition is 豆包 (Volcengine) 流式语音识别 2.0. Its native punctuation, spoken-number
normalisation ("百分之九十五" → "95%"), and semantic smoothing are switched on. If the live
connection fails, TalkType retries once through 录音文件识别 2.0 极速版; neither path adds a
second LLM.

**Privacy, precisely:**

| What | Leaves your Mac? |
|---|---|
| Audio + your vocabulary terms | Yes — to Volcengine, subject to its data policy |
| Anything else | Nothing. No account, no telemetry, no subscription. |

The only credential is your own project-scoped Volcengine API Key, in the macOS Keychain.
There is no offline mode: no network means a clear error, not a fallback.

---

## Quick start — about 5 minutes

**You need:** macOS 13 or newer.

1. **Download and open.** [⬇ Latest release](https://github.com/simonsysun/talktype/releases/latest) —
   unzip, drag to Applications. The first time you open it, macOS will refuse — free apps aren't
   signed with a paid certificate. Right-click the app ▸ **Open** ▸ **Open**, and macOS remembers.
2. **Allow two permissions.** The microphone, and "paste on your behalf". Both are required;
   TalkType can't grant them for you.
3. **Paste your key.** The dialog opens by itself on first launch. Get the single key from the
   new Doubao Voice console ▸ **API Key 管理** — not IAM's “API访问密钥”. The project must have
   both **流式语音识别 2.0** and **录音文件识别 2.0** enabled.

Press **⌘⇧Space** and start talking.

---

## Manual

- **Hotkey** — default ⌘⇧Space; change it from the menu bar (Change Hotkey…).
- **Microphone** — pick one, or Automatic (follows the system default, including a Bluetooth
  headset; recording through a Bluetooth mic switches the link into headset mode, so playback
  drops to 24 kHz mono for a while).
- **Vocabulary** — add names and terms the model keeps mishearing; they are sent to 豆包 as
  hot words. Nothing is rewritten locally afterwards, so a term that still comes out wrong is
  telling you something real about the model.
- **API Key** — menu bar ▸ API Key…. A wrong one announces itself on the first dictation; leave
  the field blank when re-editing to keep the stored key.
- **Clipboard** — every transcript is also left on your clipboard, so ⌘V always works as a
  manual fallback.

## Troubleshooting

- **Stopped pasting after an update?** macOS ties the paste permission to the exact build, and
  TalkType isn't signed with a paid certificate — so a new version looks like a different app.
  TalkType spots this and offers a **Fix This** button; click it and switch TalkType back on when
  macOS asks. *(Releases from v2.0.2 share one certificate, so this shouldn't recur.)*
- **"还没填 API Key"?** Menu bar ▸ API Key…, paste the one project key.
- **"API Key 不对"?** Volcengine rejected it — usually a stray space or an IAM key instead of
  the key from the Doubao Voice console.
- **"requested grant not found"?** Enable **流式语音识别 2.0** and **录音文件识别 2.0** for that project.
- **Chinese and English run together without a space?** That is the raw output. Nothing
  normalises it any more; that is deliberate, so the model's real behaviour is visible.

## How it compares

| | TalkType | Apple Dictation | Wispr Flow / Superwhisper |
|---|---|---|---|
| Price | Free app; Doubao usage billed separately | Free | Subscription |
| Offline | No | Partly | Usually cloud |
| Voice leaves your Mac | Yes | Sometimes | Usually |
| Mixed Chinese + English | Yes | Poorly | Varies |
| Removes filler words | Whatever 豆包 does natively | No | Yes |
| Custom vocabulary | Yes | Limited | Yes |
| Open source | Yes (MIT) | No | No |

## Under the hood

The microphone's mono PCM is resampled to 16 kHz and sent in 200 ms binary WebSocket frames to
`/api/v3/sauc/bigmodel_nostream` using 流式语音识别 2.0 (`volc.seedasr.sauc.duration`). The last
audio frame is marked final when recording stops. If the socket fails, the captured WAV is sent
to `/api/v3/auc/bigmodel/recognize/flash` (`volc.bigasr.auc_turbo`) as a same-provider fallback.

Hot words go in `request.corpus.context` as a JSON *string*, not a nested object. They are attached
only when the vocabulary is non-empty.

Setting `TALKTYPE_STATE_DIR` points config and vocabulary somewhere else, which is how you
trial a setup without touching your real one.

## Building from source

```bash
git clone https://github.com/simonsysun/talktype.git
cd talktype

./scripts/make-signing-cert.sh   # optional, once: keeps permissions valid across updates
./scripts/build.sh install
```

`swift test` runs the logic tests without Xcode. `NOW.md` tracks what is active and what
is next. An iOS keyboard extension exists in the repository but is parked and never compiled.

## Licence

MIT — do what you like with it.
