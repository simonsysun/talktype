# TalkType Context

TalkType is a macOS menu-bar dictation app: press a hotkey, speak, and the words appear at
your cursor. Chinese and English can be mixed inside one sentence.

## Language

**Dictation**:
One full cycle: press the hotkey to start, speak, press again (or pause), and text lands at the
cursor. _Avoid_: session; recording is only the capture phase.

**Speech recognition**:
One synchronous call to Doubao/Volcengine 大模型录音文件识别极速版. It sends the recorded audio
and returns text with native punctuation, spoken-number normalisation, and semantic smoothing.
There is no provider picker, local engine, fallback, or second polish model.

**API Key**:
The single project key from the new Doubao Voice console. It is sent as `X-Api-Key` and stored in
the macOS Keychain. It is not the App ID + Access Token pair from the retired console, nor an IAM
“API访问密钥”.

**Vocabulary**:
The user-maintained word list sent with the same recognition call as hot words. Nothing rewrites
the transcript locally afterwards. _Avoid_: custom dictionary, keywords.
