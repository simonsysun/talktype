# TalkType Context

TalkType is a macOS menu-bar dictation app: press a hotkey, speak, and the words appear at
your cursor. Chinese and English can be mixed inside one sentence.

## Language

**Dictation**:
One full cycle: press the hotkey to start, speak, press again (or pause), and text lands at the
cursor. _Avoid_: session; recording is only the capture phase.

**Speech recognition**:
One Doubao/Volcengine 流式语音识别 2.0 connection. Audio is uploaded during recording; releasing
the hotkey finalises it and returns text with native punctuation, spoken-number normalisation,
and semantic smoothing. If that connection fails, the same audio is sent once to 录音文件识别
2.0 极速版. There is no provider picker, local engine, or second polish model.

**API Key**:
The single project key from the new Doubao Voice console. It is sent as `X-Api-Key` and stored in
the macOS Keychain. It is not the App ID + Access Token pair from the retired console, nor an IAM
“API访问密钥”.

**Vocabulary**:
The user-maintained word list sent with the same recognition call as hot words. Nothing rewrites
the transcript locally afterwards. _Avoid_: custom dictionary, keywords.
