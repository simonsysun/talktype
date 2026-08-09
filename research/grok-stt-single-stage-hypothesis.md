# Grok STT 能否替代 TalkType 的多层语音管线？

**Status:** historical research note; not current product fact  
**Access date:** 2026-08-05  
**Scope:** whether Grok STT could replace a multi-stage STT+polish pipeline

> **状态标注（2026-08-09）：** 当前产品是豆包单路径（`DECISION.md` D003–D004）。本文不是
> 现行架构说明；旧 ADR/TODO 链接已失效，以根目录治理文件为准。
>
> **结论已撤回（2026-08-05）。** 下面「95% 效果」那一栏的负面判断，依据是 repo 里两轮 raw
> 实测——而那两轮走的是 **OpenRouter 的 `x-ai/grok-stt-1.0` 路由，不是 xAI direct
> `POST /v1/stt`，并且没有记录是否传过 `language` / `format` / `keyterm`**。xAI 明确要求
> `format` 必须配 `language` 才生效；缺参数的中文音频恰好会表现为「无中文标点、半段漂成
> 英文」，也就是那两轮观察到的症状。所以那次测的很可能是**参数缺失，不是模型能力**。
>
> Simon 在另一个产品里日常用 Grok 转中文和中英混说，准确度没有问题。官方语言表不列中文，
> 真实含义是「没有 SLA、没承诺中文 formatting」，不是「中文不准」。
>
> **下面第 1 节的官方事实（价格、端点、格式、限流、参数语义）仍然有效**，其余判断不要再当
> 结论引用。

研究日期：2026-08-05
范围：xAI 官方文档、公告、价格与条款；必要的原始研究；TalkType repo 内已有实测。没有使用二手评测来判断质量。

## 结论

**“一个强 STT 吞掉一部分 polish，从而简化管线”这个架构方向成立；“当前 Grok STT 能以约 95% 效果替代 TalkType 的 STT + polish + context”尚未成立，现有 raw 证据对 TalkType 的核心中英混说场景不利。**

| 假设 | 判断 | 原因 |
|---|---|---|
| 一层 API 会更简单 | **成立** | 少一次或两次串行网络调用、少一套 prompt/超时/失败回退；xAI 的 STT 也确实内置了 ITN、filler-word removal、keyterm biasing。 |
| 会更快 | **大概率成立，但仅相对当前云端串行管线** | TalkType 已测到 Grok 约 0.6 s，当前 OpenRouter Qwen 约 2 s，polish 还会再占时间；但 xAI 没发布 p50/p95 或完整 latency benchmark，且 Grok 不一定快过本地 Qwen 0.3–0.9 s。 |
| 会更便宜 | **方向成立，幅度被高估** | xAI REST 是 $0.10/h；当前 Qwen 云 ASR 约 $0.13/h，30 min/day 只差约 $0.45/月。真正省下的是 polish/context LLM token，但个人工具的绝对金额仍很小；Streaming $0.20/h 反而高于当前 ASR。 |
| 能保留约 95% 产品效果 | **没有证据，raw 证据反对** | 官方没有中文、code-switch、punctuation、disfluency、semantic fidelity 或 context-aware rewriting benchmark；官方 25 种 supported/formatted language 列表不含中文；repo 两轮 raw 实测中 Grok 都是中文最差，并出现半段翻成英文、无中文标点。尚未测的 `keyterm` arm 是可能的 rescue path。 |
| 可替代 polish | **只能替代一部分** | 能替代数字/货币/单位格式化和简单 filler removal；没有文档承诺处理结巴、重说、自我更正、中文/英文 typography、语气保留、完整性约束或防止翻译。 |
| 可替代 context 层 | **不成立** | API 没有自由文本 prompt/system instruction/app context；只有最多 100 个、每个 50 字符的 `keyterm`，它是 vocabulary bias，不是语义 context。 |

**建议：不要把 Grok STT 直接升为默认，但值得做一个极小的 direct-xAI `keyterm` spike。** TalkType 已有 raw 实测发现会影响核心用途的实体错误和一次翻译硬失败；另一方面，两条最新 direct 结果的普通中文正文其实大体可用，主要错误集中在已知技术实体，而现有 artifact 没记录是否传入 `format` / `language` / `keyterm`。因此当前证据足以否定“未经调参即可达到 95%”，还不足以否定 keyterm bias 后的上限。即使 keyterm 能救实体，它仍只替代 narrow vocabulary context，不能证明完整 polish/context 已被替代。

---

## 1. xAI 官方明确事实

### 1.1 产品、API 与发布日期

- xAI release notes 记录 Speech to Text 于 **2026-04-15 GA**；产品公告发布于 **2026-04-17**。[Release Notes](https://docs.x.ai/developers/release-notes) / [官方公告](https://x.ai/news/grok-stt-and-tts-apis)
- Direct API 不要求也不接受公开的 model slug：
  - file/REST：`POST https://api.x.ai/v1/stt`
  - streaming：`wss://api.x.ai/v1/stt`
  [STT guide](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text) / [API reference](https://docs.x.ai/developers/rest-api-reference/inference/speech-to-text)
- 因此 repo 测试里 OpenRouter 的 `x-ai/grok-stt-1.0` 是 OpenRouter 的路由名，不是 xAI direct API 文档中的可 pin 模型名。xAI 没给 STT 暴露版本选择或日期快照；服务端升级的一致性/回归策略未知。
- xAI 文档把文件接口称为 REST 或 file-based batch，但这是一次同步 `POST /v1/stt`，不要和 xAI 的异步 Batch API 混为一谈。异步 Batch API 的折扣说明只适用于 text/language models，并且 ZDR 下不可用。[Pricing](https://docs.x.ai/developers/pricing)

### 1.2 价格、region 与 rate limit

| 项目 | 官方值 |
|---|---|
| REST/file | **$0.10 / audio hour** |
| Streaming | **$0.20 / audio hour** |
| Region | **us-east-1** |
| REST rate limit | 10 RPS |
| Streaming rate limit | 10 RPS；100 concurrent sessions / team |

来源：[STT model page](https://docs.x.ai/developers/models/speech-to-text) / [xAI Pricing](https://docs.x.ai/developers/pricing)

按 TalkType 以前统一使用的 30 min/day 场景：REST 约 **$1.50/月**，Streaming 约 **$3.00/月**。当前 repo 记录的 OpenRouter Qwen 约 $0.13/h，即约 $1.95/月；所以单看 ASR，REST 只省约 $0.45/月，并不是数量级变化。（历史 ASR 笔记原在已退役的 `TODO.md`，见 Git history。）

当前 polish 使用 Groq 上的 `qwen/qwen3.6-27b`；Groq 官方价是 $0.60/M input tokens、$3.00/M output tokens，标称约 500 tokens/s。实际每小时成本取决于每段 dictation 的长度、system prompt 重复次数和输出长度，repo 没有完整 token telemetry，不能精确声称省多少。[Groq pricing](https://groq.com/pricing) / [Groq model page](https://console.groq.com/docs/model/qwen/qwen3.6-27b) / [TextRefiner.swift](../../TalkType/TextRefiner.swift)

### 1.3 文件、音频格式与限制

REST 可上传 `file` 或提供 server-side download 的 `url`；最大文件 **500 MB**。官方没有写最长 audio duration。

详细 guide 列出 12 种格式：

- container：WAV、MP3、OGG、Opus、FLAC、AAC、MP4、M4A、MKV；
- raw/headerless：PCM16 little-endian、G.711 μ-law、G.711 A-law；
- sample rate：8k、16k、22.05k、24k、44.1k、48k Hz；
- multichannel：最多 8 channels。

来源：[STT guide — formats and limits](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text#supported-audio-formats)

**文档冲突：** model summary 页把 WebM 列为支持格式，但详细 guide 的“12 formats”没有 WebM，反而列了 Opus/FLAC/AAC/MP4/MKV。WebM 应视为“需实际验证”，不能只凭 summary 依赖。[STT model page](https://docs.x.ai/developers/models/speech-to-text)

Streaming 只收 raw PCM/μ-law/A-law binary frames；官方建议 16 kHz PCM、100 ms 一包。没有公开最大 session 时长。[Streaming guide](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text#streaming-speech-to-text-websocket)

### 1.4 支持语言：关键 blocker

xAI release notes 说 GA 支持 **25 languages**。详细 STT guide 的 25 种是：Arabic、Czech、Danish、Dutch、English、Filipino、French、German、Hindi、Indonesian、Italian、Japanese、Korean、Macedonian、Malay、Persian、Polish、Portuguese、Romanian、Russian、Spanish、Swedish、Thai、Turkish、Vietnamese。

**Chinese / Mandarin 不在官方 supported/formatted language 列表中。** 公告写的是“25+ languages”，但没有给额外语言；最新详细文档和 release notes 都只明确 25 种。模型事实上能 best-effort 转中文（repo direct 实测已有中文输出），所以不能写成“完全不能识别”；严谨的产品含义是：**中文目前是 undocumented / unsupported best-effort，formatting 也没有 `zh` contract，不能依赖 SLA 或 vendor benchmark。**[Supported Languages](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text#supported-languages) / [Release Notes](https://docs.x.ai/developers/release-notes)

`language` 参数不是普通的 recognition language pin：guide 说模型在上述语言中无论是否设置都能识别；设置它是为了启用该语言的 formatting。官方文档对 response 的 language detection 还有冲突：guide 示例返回 `English`，REST reference 则写 detected language currently empty、尚未启用。不能把自动语言检测当稳定 routing signal。[Guide response](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text#response) / [REST reference](https://docs.x.ai/developers/rest-api-reference/inference/speech-to-text)

### 1.5 输出与 STT 内置的“polish”到底是什么

官方明确提供：

- full transcript；
- audio duration；
- word-level `start` / `end` timestamps；
- diarization 后每个 word 的 speaker id；
- multichannel per-channel transcripts；
- `format=true` + `language` 时的 **Inverse Text Normalization (ITN)**：把口述数字、货币、单位等转成书写格式；
- `filler_words=false`（默认）：自动移除 `uh` / `um` / `er` 类 filler words；
- `keyterm`：最多 100 个，每个最多 50 字符，用于 proper nouns / domain vocabulary bias；
- VAD threshold 与 streaming Smart Turn。

来源：[STT request/response](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text#request-body) / [官方公告](https://x.ai/news/grok-stt-and-tts-apis)

官方**没有**为 standalone STT 承诺或暴露：

- arbitrary prompt、system instruction、application/window context；
- style、tone、format instructions；
- 结巴/重复开头清理；
- “周二……不对，周三”这类 self-correction resolution；
- 防翻译 / 保持中英 code-switch 的指令；
- 中文全角标点、中英文空格等 typography；
- semantic completeness、no-rewrite、no-summary guardrail；
- custom output schema 或 temperature/decoder 控制。

换句话说，Grok STT 内置的是 **ASR text formatting**，不是 TalkType 当前 general LLM polish 的完整职责。当前 `TextRefiner` 还处理自我更正、重说、结巴、中文 filler 的歧义、语义断句、approved spellings，并用确定性 guard 拒绝翻译、截断和未说过的词；这些在 Grok STT 文档里没有对应保证。[TextRefiner.swift](../../TalkType/TextRefiner.swift) / [PostProcessor.swift](../../TalkType/PostProcessor.swift)

`keyterm` 能承接词库或从 app context 提取出的候选名词，但它不能表达“这是 Slack 消息”“保留用户口吻”“上一段在讨论某个 bug”这种语义 context。把 keyterm bias 叫 context replacement 会混淆两个不同问题。

### 1.6 Streaming 与延迟

官方可量化的 streaming 行为：

- `interim_results=true` 时约每 **500 ms** 出 partial；
- locked chunk 约每 **3 s speech** finalized；
- `endpointing` 范围 0–5000 ms，默认 10 ms；
- Smart Turn 在 VAD silence boundary 判断是否真正说完，并可设 1–5000 ms timeout；
- PTT 可在松键时发 `Finalize`，不关 session。

来源：[Streaming events and Smart Turn](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text#streaming-speech-to-text-websocket)

xAI 公告只说 REST 可在“milliseconds”内处理大文件、streaming 是低延迟，没有公布：

- audio duration 对应的 processing time / real-time factor；
- cold / warm p50、p95、p99；
- final flush latency；
- region/network 条件；
- diarization、format、keyterms 对延迟的影响。

所以“官方已经证明比现有管线快很多”不成立；能说的是：**少掉串行 polish/context hop 必然减少 API orchestration overhead，而 TalkType 自己的现有 0.6 s 实测支持 Grok 比当前 cloud Qwen 快。**

另一个产品约束：xAI STT guide 明确说不要在 client-side 暴露 API key，并要求 WebSocket 经 backend proxy。xAI 的 ephemeral-token 文档目前只明确覆盖 Speech-to-Speech realtime，不明确覆盖 standalone STT。对 BYOK macOS app，这不是不能做，但“直接从客户端简单连 WS”不符合官方推荐部署形态，需要确认 key 风险或增加 backend。[STT streaming security note](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text#streaming-speech-to-text-websocket) / [Ephemeral Tokens](https://docs.x.ai/developers/model-capabilities/audio/ephemeral-tokens)

### 1.7 Accuracy benchmark：能说明什么、不能说明什么

xAI 自报 WER：

| Domain | Grok STT WER |
|---|---:|
| Phone Call Entities | 5.0% |
| Video / Podcasts | 2.4% |
| Meetings | 10.9% |
| Telephone | 9.3% |
| Overall | **6.9%** |

同一表中 xAI 报 ElevenLabs 9.0%、Deepgram 11.0%、AssemblyAI 12.9%。[xAI announcement](https://x.ai/news/grok-stt-and-tts-apis)

这组数字只能作为“Grok 在 xAI 选定的商业英语型数据上有竞争力”的弱证据，不能推出 TalkType 有 95% 效果：

1. 公告没公布 dataset 名称、样本量、语言组成、录音时长、噪音条件、speaker 分布、scoring normalization、竞争模型版本、参数或是否开启 formatting/keyterms；无法独立复现。
2. 表中 domain 和示例都是英语业务场景；没有中文或 code-switch 分项。
3. WER 是 `(substitutions + deletions + insertions) / reference words`。NIST 也明确提醒：不同 transcript quality、test-set selection 和 word mapping 的 WER 不能直接横比。[NIST ASR metrics](https://trec.nist.gov/pubs/trec9/sdrt9_slides/tsld017.htm)
4. 6.9% WER 不等于“93.1% 产品质量”，更不能等于“现有管线的 93.1%”。WER 不衡量标点可读性、ITN、用户纠正成本、语义严重度、翻译、风格保留或 context correctness。一个 `财报 → 采访` 的替换和一个冠词错误在 WER 里都只算一次，但产品损失完全不同。

因此没有官方数字可以验证“95%”。最接近的 overall WER 甚至是 6.9%，但把它反推成 93.1% 仍是错误使用指标。

### 1.8 数据保留与隐私

- xAI API 默认把 request/response **加密静态保存 30 天**用于审计；默认不拿 API input/output 训练模型。[xAI API Security FAQ](https://docs.x.ai/developers/faq/security)
- 可用时可在 team 级开启 Zero Data Retention；所有 key 自动生效，response header `x-zero-data-retention` 可验证。ZDR 不支持依赖存储的 Stateful Responses、Files、Collections、异步 Batch 等。STT 没被列入禁用项，但 FAQ 也没有逐项明确承诺 STT under ZDR，正式产品应实测/向 xAI 确认。[ZDR FAQ](https://docs.x.ai/developers/faq/security#what-is-zero-data-retention-zdr)
- Enterprise Terms 还要求：如果有 personal data，应通过 ZDR-enabled API 处理；普通 dictation 很容易包含姓名、邮件、工作内容。若未来不是个人 BYOK 而是 TalkType 用自己的 proxy key 服务终端用户，这需要在上线前做条款与 DPA 确认。[Enterprise Terms](https://x.ai/legal/terms-of-service-enterprise)

---

## 2. 专业判断：为什么“一层化”有道理，但这次不能直接成立

### 2.1 一体化 STT 的技术方向是真的

现代 end-to-end ASR 可以把传统的 acoustic、pronunciation、language-model components 吸收到一个网络里，减少模块边界；Google 的原始研究在 dictation/voice search 上已经展示这一方向。[Sequence-to-sequence ASR paper](https://research.google/pubs/state-of-the-art-speech-recognition-with-sequence-to-sequence-models/)

而“written-form transcript”也完全可以用专用的小模型统一处理 ITN、punctuation、capitalization、disfluency，不必每次调用 general-purpose LLM。`Four-in-One` 原始论文就是用一个 tagging model 联合完成这四项，再用 WFST 做 ITN。[Four-in-One paper](https://arxiv.org/abs/2210.15063)

所以 Simon 的第一性原理判断是对的：**如果产品目标只是 faithful transcript + predictable formatting，general LLM polish 很可能是过重的。** 更好的长期方向可能是强 ASR + deterministic/minimal formatter，而不是永远叠更多 LLM。

### 2.2 但 ITN 不是 semantic polish

ITN 主要解决 spoken form → written form，例如 “one hundred dollars” → `$100`。它没有天然回答：

- 哪个 filler 是无意义停顿，哪个“那个”在修饰名词；
- 用户说了一半重来，应该保留哪一版；
- 中英混说中哪个词是 `cloud`、哪个是 `Claude`；
- app 当前 context 是否足以改写同音词；
- 怎样保留语气且不总结、不补写、不翻译。

Google 的 normalization 研究也指出：总体准确率很高的 neural normalization 仍会产生少见但传达完全错误意思的结果，因此工业系统会加 grammar/filter 约束。[Neural text normalization](https://research.google/pubs/neural-models-of-text-normalization-for-speech-applications/) / [RNN text normalization](https://research.google/pubs/an-rnn-model-of-text-normalization/)

这恰好支持 TalkType 目前 deterministic guardrail 的价值，而不是说明所有 polish 都能安全藏进不可控的 STT 黑盒。

### 2.3 Context 对 rare words 有真实价值，不能从 API 层数推出它没用

Contextual ASR 原始研究显示，给识别器正确的动态 context 可把一个 voice-search test 的 WER 从 9.2% 降到 3.8%；另一个 all-neural contextual ASR 在任务上做到最高 68% relative WER improvement。[Contextual beam-search paper](https://research.google/pubs/contextual-speech-recognition-in-end-to-end-neural-network-systems-using-beam-search/) / [Deep Context paper](https://research.google/pubs/deep-context-end-to-end-contextual-speech-recognition/)

这不代表 TalkType 必须保留独立 context LLM；它说明的是：**context 的信号有用，最佳位置可能是在 ASR decoding 内，而不是 transcript 之后重写。** Grok 的 `keyterm` 正是窄版本的 decoder-time context，但当前 API 只收短词/短语列表，不收 rich app context。

### 2.4 真正可行的“一次模型调用”架构

如果 `keyterm` spike 通过，最小管线可以变成：

```text
录音 + 并行读取附近候选词
  → 本机筛出少量 keyterms
  → xAI /v1/stt（一次模型调用）
  → 本机确定性 typography / hallucination guard
  → 粘贴
```

这会删除第二次 LLM polish，但不会也不应该删除廉价的本机规则与安全检查；“少模型层”不等于“零后处理”。Context 层也不是消失，而是从 post-ASR semantic rewrite 缩成 pre-ASR candidate selection。

这里有一个真实能力损失：TalkType 当前 context 方案可以拿到 raw transcript 后，再用 `cloud code` 去附近文字里检索 `Claude Code`；direct STT 的 keyterms 必须在解码前提供，只能按位置、词形和 app 信息预选。传太多无关候选会增加误偏置风险，而 xAI 没提供 topic snippets、每词权重、negative constraints 或解码后的二次选择。因此这个单调用架构很适合 terms-only context，不等价于带话题证据的 semantic context。

---

## 3. 与 TalkType 当前管线逐项对照

| 当前需求/能力 | Grok STT 单层是否覆盖 | 判断依据 |
|---|---|---|
| 基础 STT | 是 | REST + streaming。 |
| 数字/货币/单位书写格式 | 是 | `format=true` + supported `language`。 |
| 去英文 filler words | 是 | `filler_words=false` 默认。中文 filler 行为未说明。 |
| 自定义词库 | 部分 | `keyterm` 最多 100 × 50 chars；比 OpenRouter 当前不透传 hints 更好。 |
| word timestamps / diarization | 是，而且强于当前需求 | 官方支持。 |
| 中文识别 | **best-effort；官方未支持** | direct 实测能出中文，但 25-language supported/formatted list 无 Chinese。 |
| 中英 code-switch | **没有证据** | 官方只笼统说 multilingual switching；没有中文或 code-switch benchmark。 |
| 中文标点/中英 typography | 否/未知 | 中文不在 formatting languages；没有 punctuation contract。 |
| 结巴、重说、自我更正 | 未承诺 | 无相关参数或 benchmark。 |
| 保持语气、禁止改写/总结/翻译 | 未承诺且不可配置 | 无 prompt/instruction。 |
| approved spelling 的“说到才用”约束 | 部分 | keyterm 会 bias，但没有 negative-insertion guarantee。 |
| rich app/window/conversation context | 否 | 没有 arbitrary context interface。 |
| output plausibility guard | 否 | 仍需 client-side deterministic check。 |
| offline fallback / privacy | 否 | 云 API，us-east-1；默认留存 30 天。 |

TalkType 当前实测是最直接的产品证据：

- 2026-08-02：Grok STT 约 **0.6 s**，但“translated half the clip to English; no punctuation”；
- 2026-08-04：2 clips × 6 arms，Grok 经 OpenRouter 与 direct xAI 结果一致，direct 只快 0.1–0.2 s，且 `x-ai/grok-stt-1.0` **中文最差**；
- 本轮保留的两条 direct-xAI 结果是 **0.470641 s / 0.680167 s**，速度非常强，但关键实体错误集中：`Claude → Cloud`、`GPT-4o → GBD 四楼`；以及 `ASR-Flash → ASR-Flex`、`xAI → xia`、`Claude → call/Craw`。artifact 没记录 request 是否启用了 `format` / `language` / `keyterm`。因此它支持“低延迟”判断，也说明 baseline request 的实体质量不够，**但不等于 explicit-keyterm arm 已经失败**；[direct-xAI artifact（gitignored local evidence）](../../bakeoff-results/grok-20260803.json)
- 当前 Qwen cloud 约 2 s，本地 Qwen 0.3–0.9 s，现有 polish 是 optional、失败时 deterministic tidy fallback。

来源：历史 `TODO.md` ASR decision / OpenRouter 实测（Git history） / 当时的 TextRefiner.swift（已删） / [README](../README.md)

这些结果和最新官方支持表相互印证：现有失败更像 capability boundary，不像偶发 provider integration 问题。

---

## 4. “95%”应该怎样定义，才有可讨论性

不要用 vendor overall WER，也不要用一句主观“差不多”。对 dictation 产品，建议把 95% 定义成 **相对当前 pipeline 的 non-inferiority**：

1. **Critical semantic error / translation rate：不得变差。** 财报→采访、中文→英文、删除有效内容属于 hard fail，不能被大量简单句平均掉。
2. **Correction effort：** 每 100 字符的人工修改字符数或修改时间，Grok 不超过当前 pipeline 的 105%。
3. **Meaning completeness：** 自我更正保留最终版本；不能漏句、总结或补写。
4. **Mixed-language fidelity：** 中文、英文、中英混说分别计分，不能只报 overall。
5. **Formatting/readability：** 标点、断句、数字/单位、中文/英文 spacing 单独评分；WER 不覆盖这些。
6. **Latency：** 从 stop/finalize 到 text insert 的 warm/cold p50/p95；REST 与 streaming 分开。
7. **Cost：** 按真实 audio hours、请求数和 polish/context token telemetry 算，不按 list price 猜。

当前最值得做的不是大规模迁移，而是一个两段录音、两臂的 rescue spike：保持 direct xAI baseline 不变；另一臂显式传 `keyterm=Claude`、`GPT-4o`、`ASR-Flash`、`xAI`、`TestFlight` 等已知词，核对实体、未说词误插入与延迟。`format=true` 需要 supported `language`，官方又没有 `zh`，所以不要把 `language=en` 和 keyterm 混在同一臂；否则无法知道改善/退化来自哪里。只有这个 spike 能证明 keyterm 是否能救当前最集中的错误。

若该 spike 通过，再扩到中文主导、中英 code-switch、English-primary、proper nouns/词库、数字日期金额、filler/结巴、自我更正、噪声/低音量；若已知实体在 explicit keyterm 下仍失败，就可以低成本关闭当前假设。现有两轮失败已经足以阻止默认切换，但未测试 keyterm 的参数缺口也足以支持这个极小实验。

## 最终建议

1. **保留“减少 LLM 层数”作为产品方向，但不要把它等同于“换 Grok STT”。** 可以继续问：当前 polish 哪些规则能下沉到 deterministic formatter，哪些真正需要 LLM。
2. **当前不接 Grok 作为默认。** 中文仍是 undocumented/unsupported best-effort，repo baseline 实测已出现产品级错误，95% 假设尚未成立。
3. **做一个极小 `keyterm` spike，而不是完整迁移。** 同两条 clip 加明确技术词，测实体 rescue 与误插入；这直接填补现有 artifact 的最大参数缺口。
4. **速度/成本方向已经够清楚：** direct Grok 约 0.5–0.7 s、$0.10/h，确实快且略便宜；下一步只需回答 core quality 能否被 keyterm 救起，以及未被覆盖的 semantic polish/context 是否仍值得保留。
