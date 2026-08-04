# TalkType Context

TalkType is a macOS menu-bar dictation app: press a hotkey, speak, and the words appear at
your cursor. Chinese and English can be mixed inside one sentence.

## Language

**Dictation**:
One full cycle: press hotkey to start, speak, press again (or pause), and text lands at the cursor.
_Avoid_: session, recording (recording is only the capture phase)

**Speech Engine**:
The thing that turns audio into text. Chosen per dictation: Local or Cloud.
_Avoid_: ASR provider, backend

**Local Engine**:
Qwen3-ASR running on this Mac through a sidecar process. Audio never leaves the machine;
costs about 4 GB of memory while loaded.
_Avoid_: on-device model (vague)

**Cloud Engine**:
The recorded audio is sent to a third party (OpenRouter, currently) and transcribed there.
Costs almost no memory; needs a network.

**Offline Fallback**:
When the Cloud Engine cannot be reached, a dictation is handled by the Local Engine instead,
and the user is notified of every switch.
_Avoid_: fallback engine, failover (implies a downgrade; this is a deliberate switch)

**Refinement**:
Optional step that tidies the transcript (removes filler words, fixes punctuation) via Groq.
Only the text leaves the machine, never the audio.
_Avoid_: cleanup (ambiguous with the local tidy)

**Vocabulary**:
The user-maintained word list that biases transcription spelling.
_Avoid_: custom dictionary, keywords
