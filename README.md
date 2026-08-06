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

## One API call

A dictation is one API call: record, send, paste. Nothing runs in between — no cleanup pass,
no local model — so whatever 豆包 returns is exactly what lands at your cursor.

Speech recognition is 豆包 (Volcengine) 大模型录音文件识别极速版. Punctuation and spoken-number
normalisation ("百分之九十五" → "95%") are both switched on, because nothing downstream would
add them.

**Privacy, precisely:**

| What | Leaves your Mac? |
|---|---|
| Audio + your vocabulary terms | Yes — to Volcengine, subject to its data policy |
| Anything else | Nothing. No account, no telemetry, no subscription. |

The only credentials are your own Volcengine App ID and Access Token, in the macOS Keychain.
There is no offline mode: no network means a clear error, not a fallback.

---

## Quick start — about 5 minutes

**You need:** an Apple silicon Mac (M1 or newer) on macOS 13+.

1. **Download and open.** [⬇ Latest release](https://github.com/simonsysun/talktype/releases/latest) —
   unzip, drag to Applications. The first time you open it, macOS will refuse — free apps aren't
   signed with a paid certificate. Right-click the app ▸ **Open** ▸ **Open**, and macOS remembers.
2. **Allow two permissions.** The microphone, and "paste on your behalf". Both are required;
   TalkType can't grant them for you.
3. **Paste your key.** The dialog opens by itself on first launch: App ID and Access Token,
   both from the Volcengine console ▸ 语音技术 ▸ 应用管理.

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
- **API Key** — menu bar ▸ API Key…. Saved as typed; a wrong one announces itself on the first
  dictation. Leave the token blank when re-editing to keep the stored one.
- **Clipboard** — every transcript is also left on your clipboard, so ⌘V always works as a
  manual fallback.

## Troubleshooting

- **Stopped pasting after an update?** macOS ties the paste permission to the exact build, and
  TalkType isn't signed with a paid certificate — so a new version looks like a different app.
  TalkType spots this and offers a **Fix This** button; click it and switch TalkType back on when
  macOS asks. *(Releases from v2.0.2 share one certificate, so this shouldn't recur.)*
- **"还没填 API Key"?** Menu bar ▸ API Key…, fill in both fields.
- **"App ID 或 Access Token 不对"?** Volcengine answered and said no — usually a stray space or
  a token from the wrong app.
- **Chinese and English run together without a space?** That is the raw output. Nothing
  normalises it any more; that is deliberate, so the model's real behaviour is visible.

## How it compares

| | TalkType | Apple Dictation | Wispr Flow / Superwhisper |
|---|---|---|---|
| Price | Free (bring your own key) | Free | Subscription |
| Offline | No | Partly | Usually cloud |
| Voice leaves your Mac | Yes | Sometimes | Usually |
| Mixed Chinese + English | Yes | Poorly | Varies |
| Removes filler words | Whatever 豆包 does natively | No | Yes |
| Custom vocabulary | Yes | Limited | Yes |
| Open source | Yes (MIT) | No | No |

## Under the hood

One POST to `openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash` with the WAV
base64'd in the body, and the transcript comes back in the same response. Volcengine's
streaming interface is a WebSocket binary-frame protocol; the flash endpoint
(`volc.bigasr.auc_turbo`) is plain HTTP, which is all dictation needs.

Hot words go in `request.corpus.context` as a JSON *string*, not a nested object. That format
comes from the streaming docs and is unverified on the flash endpoint, so it is only attached
when the vocabulary is non-empty — if it turns out to be rejected, dictation without a
vocabulary still works.

Setting `TALKTYPE_STATE_DIR` points config and vocabulary somewhere else, which is how you
trial a setup without touching your real one.

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
