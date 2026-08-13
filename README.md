# TalkType — talk instead of typing

*[中文说明](README.zh-CN.md)*

<p align="center">
  <img src="docs/assets/talktype-logo.png" alt="TalkType" width="128" height="128">
</p>

**Talk instead of typing.** Press a hotkey anywhere on your Mac, speak, press again (or pause) — the words land where your cursor is. Slack, Notes, email, terminal… anywhere you can type, you can talk.

Built for people who mix **Chinese and English in one sentence** — no language switching.

```
press hotkey → talk → press again / pause → text at cursor
```

**Free app (MIT).** You bring your own speech API key; usage is billed by that provider. No TalkType account, no subscription, no telemetry. Not an offline / on-device engine — audio goes to the provider you pick.

---

## Install (about 5 minutes)

**Needs:** macOS 13+ (Intel or Apple silicon), a network connection, and a 豆包 or xAI API key.

1. **Download** the latest macOS build:  
   **[⬇ latest zip](https://github.com/simonsysun/talktype/releases/latest)**  
   Unzip → drag `TalkType.app` into **Applications**. Ignore 2.x zips — those were a different, on-device product.

2. **Open it the first time.** This build is not signed with a paid Apple Developer certificate, so macOS may block it:  
   right-click TalkType → **Open** → **Open**.  
   If that still fails: **System Settings → Privacy & Security** → **Open Anyway**.

3. **Allow two permissions** when asked:
   - **Microphone**
   - **Accessibility** (so TalkType can paste for you)

4. **Paste an API key** for the provider you want (dialog opens if missing):

   | Provider | Menu | Where to get a key | Notes |
   | --- | --- | --- | --- |
   | **豆包 / Volcengine** (default) | API Key… | [Doubao Voice console](https://console.volcengine.com/) → **API Key 管理** (not IAM “API访问密钥”). Enable **流式语音识别 2.0** and **录音文件识别 2.0**. | Streams while you speak; same-provider file retry if the stream fails. |
   | **Grok / xAI** (optional) | Speech Provider → Grok, then API Key… | [console.x.ai](https://console.x.ai) → API Keys | REST after you stop. Chinese works in practice but is **not** on xAI’s official formatting language list (best-effort). |

Press **⌘⇧Space** and start talking. Change the hotkey anytime from the menu bar.

---

## What it does (and does not)

- **One recognition per dictation** — no second “polish” model, no local multi‑GB engine.
- **One cloud provider at a time** — pick 豆包 or Grok in **Speech Provider**. TalkType never fails over between them behind your back.
- **Vocabulary** — names the model mishears; sent as Doubao hot words or Grok `keyterm`s. Nothing rewrites text after STT.
- **Clipboard** — every transcript is also copied, so ⌘V always works as a backup.

### Privacy

| What | Leaves your Mac? |
| --- | --- |
| Audio for this dictation + vocabulary terms | **Yes** — to the provider **you selected** (Volcengine or xAI), under that provider’s policy |
| Everything else | **No** — no TalkType account, no telemetry, no subscription identity |

No offline mode: no network → a clear error.

---

## Manual

| Item | Where |
| --- | --- |
| Hotkey | Menu bar → Change Hotkey… (default ⌘⇧Space) |
| Speech provider | Menu bar → Speech Provider |
| API key (active provider) | Menu bar → API Key… |
| Microphone | Menu bar → Microphone (or Automatic) |
| Vocabulary | Menu bar → Vocabulary |
| Launch at login | Menu bar → Launch at Login |

**Bluetooth tip:** Recording through a Bluetooth headset often switches the link into headset mode; system playback may drop to 24 kHz mono for a while. That is macOS behavior, not a TalkType bug.

---

## Troubleshooting

| Symptom | What to try |
| --- | --- |
| macOS won’t open the app | Right-click → Open → Open. Still blocked: System Settings → Privacy & Security → Open Anyway |
| Stopped pasting after an update | Menu bar / prompt → **Fix This**, re-enable TalkType under Privacy → Accessibility. Builds that share the same signing cert keep the grant. |
| “还没填 API Key” | Menu bar → API Key… for the **current** provider |
| Doubao: wrong key / “requested grant not found” | Use the Voice console project key (not IAM); enable 流式 + 录音文件识别 2.0 |
| Grok: wrong key | Paste a full xAI API key from console.x.ai (no spaces / masked `***`) |
| AirPods won’t start recording | Retry once, or switch Microphone to the MacBook mic; Bluetooth handoff is flaky on macOS |
| CN/EN stuck together with no space | Raw model output by design — no local rewrite |

---

## Cost

- **TalkType:** free.
- **Speech API:** you pay the provider you pick. List prices move; check the console. As of mid-2026, a few minutes a day is pocket change:
  - 豆包 流式语音识别 2.0 ≈ **¥1 / audio hour**
  - Grok REST file STT = **$0.10 / audio hour** (streaming, if we add it later, is $0.20)

---

## How it compares

| | TalkType | Apple Dictation | Wispr Flow / Superwhisper |
| --- | --- | --- | --- |
| Price | Free app; STT billed by your provider | Free | Subscription |
| Offline | No | Partly | Usually cloud |
| Voice leaves your Mac | Yes (to the provider you pick) | Sometimes | Usually |
| Mixed Chinese + English | Yes | Poorly | Varies |
| Open source | Yes (MIT) | No | No |

---

## Building from source

```bash
git clone https://github.com/simonsysun/talktype.git
cd talktype

./scripts/make-signing-cert.sh   # optional, once: keep Accessibility across rebuilds
./scripts/build.sh install       # Release build → /Applications/TalkType.app
# or: ./scripts/build.sh release # also writes dist/TalkType-<version>.zip
```

- Logic tests (no Xcode GUI): `swift test`
- Packaging helpers: `scripts/build.sh`, `scripts/make-signing-cert.sh`
- macOS only. There is no iOS target in this repository.

---

## Help shape TalkType

TalkType gets better through **real daily use**. When something feels off, a word is always
misheard, or you have an idea — even a half-formed one — please put it in a
**[GitHub Issue](https://github.com/simonsysun/talktype/issues/new)**.

That is the main place we look: bugs, rough ideas, and tiny usability notes all count. You do
not need a complete design. We can work out what to build together.

You can also [browse existing discussions](https://github.com/simonsysun/talktype/issues).

---

## Under the hood (short)

- **豆包:** 16 kHz PCM over WebSocket 流式语音识别 2.0 (`bigmodel_nostream`); on failure, same audio to 录音文件识别 2.0 极速版. Hot words in `request.corpus.context` as a JSON **string**.
- **Grok:** WAV upload to `POST https://api.x.ai/v1/stt` with optional repeated `keyterm` fields (no `format`/`language=en` for mixed CN/EN).
- Config / vocabulary live under `~/.talktype` (override with `TALKTYPE_STATE_DIR`).

---

## Licence

[MIT](./LICENSE) — do what you like with it.
