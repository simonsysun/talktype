# 单次 STT API：native polish 候选短名单

> **状态（2026-08-05）：** 本文的短名单已落地为代码。ElevenLabs、Grok、Soniox、OpenAI 四家
> 都已接进 app，可在菜单栏一键切换，polish 层和本地引擎已删除。见
> [ADR-0002](../adr/0002-single-call-stt-no-polish.md)。下面两处判断在落地前已修正，正文中
> 标注为「已修正」。

**日期：** 2026-08-05  
**决策对象：** TalkType（中文为主、中英混说、极简架构、价格敏感）  
**基线：** xAI Grok STT 文件接口 **$0.10/小时**；实时 **$0.20/小时**。

## 结论

可以砍成一次 STT 调用，但**现有官方资料不能证明任何厂商能稳定替代通用 LLM polish**。厂商所谓 formatting 通常只是标点、大小写、数字/日期格式；去口头语、假启动和重复是另一项能力；理解「周二，不对，周三」并只保留周三，又是更强的语义改写。原始研究也把 punctuation、capitalization、ITN、disfluency removal 当作四个不同任务联合建模，而不是一个统称为 formatting 的能力（[Four-in-One](https://arxiv.org/abs/2210.15063)）。

对 TalkType 最值得实测的只有三家：

1. **Soniox v5：整体单调用架构首选。** 与 xAI 接近的价格，官方明确支持中文、英文以及同一句/同一对话内混说，并允许一次 STT 调用带结构化 context、自由文本和 terms。缺点是官方没有承诺去 filler、重复或 false start，所以它是「中文 + context winner」，不是「polish winner」。
2. **ElevenLabs Scribe v2：native polish 首选。** `no_verbatim` 明确移除 fillers、false starts、repetitions、stuttering；这是可用中文候选中最接近当前 polish 层的官方承诺。批处理 $0.22/小时，绝对成本仍低。**修正（2026-08-05）：** 初版表格写「中英同句未承诺」是错的——官方明确说 English words 按 English 转写、不受周围语言影响，这正覆盖 TalkType 的核心场景；只是示例全为 Indic 语言，中文没有单独 benchmark。仍无明确 ITN 合约。
3. **OpenAI `gpt-transcribe`：context / code-switch 强候选。** 官方明确支持中文语言提示、多个语言提示、code-switching、自由文本 context 和 keywords；但没有 clean/no-verbatim 模式，也没有承诺删除 filler、重复、false start 或处理自我纠正。文件接口 $0.27/小时，约 xAI 的 2.7 倍。

**关于 xAI 的修正（2026-08-05）：** 官方 25 种语言表不含中文，这一条经复核属实。但它的含义是「没有 SLA、没承诺中文 formatting」，**不等于中文不准**——底层是大模型，中文能力不由文档决定。此前引用的 repo 实测走的是 OpenRouter 路由且未记录 `language`/`format` 参数，不能作为反面证据（见 [Grok 假设文档的撤回声明](grok-stt-single-stage-hypothesis.md)）。真实的剩余风险只有三条：`format=true`+`language=zh` 对中文是否真的生效、`keyterm` 对中英混句是否生效、服务端静默升级无版本可 pin。更稳的大胆方案是先只做一个 40–60 条真实语音的三臂 bake-off：`xAI`、`Soniox`、`ElevenLabs no_verbatim=true`。OpenAI 作为第四臂只在需要验证 context/code-switch 上限时加入。若 Soniox 的口头语残留可接受，就选 Soniox；若残留不可接受，选 ElevenLabs；只有实测证明 xAI 中文错误率没有产品影响时，才因成本选 xAI。

ElevenLabs 虽是 xAI 的 2.2 倍，但绝对差价只有 **$0.12/音频小时**。按每位用户每天说 10 分钟计算，每月约多 **$0.60/用户**（不含可选 keyterms）。对 TalkType，这通常不算“贵得多”；延迟和可直接粘贴率更重要。

## 证据表

图例：**明确** = 官方明确承诺；**部分** = 有相关能力但范围受限；**Unknown** = 官方资料没有承诺，不能当作支持；**不支持** = 官方明确限制。

| 厂商 / 模型 | 标点、大小写、ITN | filler / disfluency | 自我纠正 | context / keyterms | 中文 + 英文混说 | API | 官方价格 | TalkType 判断 |
|---|---|---|---|---|---|---|---|---|
| **xAI Grok STT** | **明确**：ITN 需 `format` + `language`；标点/格式化 | **明确**：默认 filler removal | **Unknown**：未承诺语义自我纠正 | keyterms，最多 100 个；无 rich prompt | **部分**：中文不在正式支持/格式化 25 种语言内，仅 best effort | 文件 REST；实时 WS | 文件 $0.10/h；实时 $0.20/h | 成本基线；最大风险是中文没有正式承诺 |
| **ElevenLabs Scribe v2** | **部分**：自然转写有标点；没有独立 ITN 合约 | **明确**：`no_verbatim` 删除 filler、false start、disfluency；更新说明还明确 repetitions、stuttering | **Unknown**：没有承诺理解并解决语义冲突 | keyterms：文件最多 1000、实时 50；+$0.05/h | **部分（已修正）**：官方承诺「English words in English, regardless of the surrounding language」，覆盖同句混说；但示例全是 Indic 语言，中文未单独 benchmark | 文件；实时 | 文件 $0.22/h；实时 $0.39/h | **polish winner；必须实测中英同句和数字格式** |
| **Soniox `stt-async-v5` / `stt-rt-v5`** | **明确/部分**：内建 punctuation；v5 明确改善 numbers、dates、times、emails、IDs/codes 等结构化格式 | **Unknown**：未找到 removal 承诺 | **Unknown** | **明确**：`general`、自由文本、`terms`，合计最高约 8k tokens / 10k chars | **明确**：中文和英文正式支持；可在同一句或对话中混合多语言 | 异步文件；实时 WS | 官方按 token 计费的典型折算：异步约 $0.10/h；实时约 $0.12/h，实际随语速变化 | **整体单调用 winner；cleanup 需实测** |
| **OpenAI `gpt-transcribe`** | **部分**：prompt 可改善 formatting，并可指定保留 punctuation/capitalization/fillers；无独立 ITN 合约 | **Unknown**：无 removal/no-verbatim 参数或承诺 | **Unknown** | **明确**：free-form prompt、keywords、多个 language hints；实时可自动沿用早先 turn | **明确**：支持 code-switching；支持 `cmn`、`yue`、`zh-cn`、`zh-tw`、`zh-hk` 等提示 | 完整文件、文件流式、Realtime committed turn；实时音频另用 `gpt-live-transcribe` | 文件 $0.0045/min = $0.27/h；live $0.017/min = $1.02/h | context/code-switch 强，**不能按官方证据称为 polish 替代品** |
| **Speechmatics Melia 1 / Standard** | **明确**：advanced punctuation/casing、numeral formatting | **部分**：官方写 disfluency detection；详细文档是标记英语 hesitation，不是删除，也不覆盖完整 stutter/false-start cleanup | **Unknown** | custom dictionary，最多 1000 项；无 rich semantic context | **部分**：普通话简/繁正式支持；Melia 1 支持多语言切换，但中文/英文同句质量未明确承诺 | 文件；实时（非 Melia 1） | Melia 1 文件 $0.129/h；Standard 文件/实时 $0.24/h | 可做廉价 code-switch 对照，但 native polish 不强于 xAI |
| **Azure Speech TrueText** | **明确**：punctuation、capitalization、ITN；中文 display format 正式支持 | **明确但语言范围不清**：官方展示删除 stutter、duplicate words、`uh/uhm`；示例为英文，未承诺中文等效 | **Unknown** | phrase list / custom speech；不等同 rich prompt | **不支持同句**：Continuous Language ID 可跨句/utterance 切换，不支持同一句切换；中英双语模型未承诺 | SDK 实时；fast / batch REST；TrueText 配置主要在 SDK | 地区相关；公开标准实时约 $1/h、batch 约 $0.36/h，以 Azure calculator 为准 | 传统 written-form 最完整，但约 10× xAI、中文同句不匹配，不进首轮 |

## 快速淘汰

- **Deepgram Nova-3：** 中文是正式语言，但 `language=multi` 的 code-switch 列表不含中文；非英文只保证标点/段落，filler 功能也只覆盖英文。文件约 $0.462/h，实时约 $0.288/h，明显不匹配。
- **Google Chirp 3：** 中文、标点和 phrase hints 都有，但官方明确说同一请求的 mixed/multiple language input 不支持；标准价 $0.96/h。淘汰。
- **AssemblyAI：** 能用 prompt 删除 filler、false start、repetition 的 Universal-3 Pro 不支持中文；支持中文的 Universal-2 没有这套 promptable polish。淘汰。
- **Mistral Voxtral：** 中文、文件/实时和 custom terms 有；但没有官方 disfluency、自我纠正或 ITN 承诺，$0.18/h 文件、$0.36/h 实时，不比 xAI 的 polish 合约强。淘汰。
- **Alibaba Qwen3-ASR-Flash：** 中文/英文混说和中英文 ITN 明确，国际价约 $0.126/h；但没有官方 filler、重复、false-start 或自我纠正承诺。它是不错的中文 ASR 对照，不是 polish winner。

## 建议测试门槛

不要只算 WER。每条真实语音分别打 5 个产品指标：

1. **Meaning preservation：** 是否改变事实、否定、时间、数字或中英文专有名词；一处严重误改即判失败。
2. **Correction resolution：** 「A，不对，B」最终是否只保留 B；这是所有候选的官方 **Unknown**，只能靠实测。
3. **Cleanup：** fillers、重复、stutter、false starts 的残留率。
4. **Written form：** 中文标点、英文大小写、数字/日期/金额/邮箱格式。
5. **Latency / cost：** 端到端 P50/P95 和实际账单，不用厂商典型值替代。

上线门槛建议：相比当前多层 pipeline，**严重 meaning error 不增加**，cleanliness 达到至少 95%，P95 更快且月成本可接受。这个 95% 是产品验收假设，不是任何厂商公布的能力保证。

## 官方来源

- xAI：[Speech-to-text capability](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text)、[models](https://docs.x.ai/developers/models/speech-to-text)、[pricing](https://docs.x.ai/developers/pricing)
- ElevenLabs：[Speech to Text](https://elevenlabs.io/docs/overview/capabilities/speech-to-text)、[`no_verbatim` update](https://elevenlabs.io/blog/scribe-v2-just-got-an-upgrade)、[API](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)、[keyterms](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting)、[pricing](https://elevenlabs.io/pricing/api?price.section=speech_to_text)
- Soniox：[language hints](https://soniox.com/docs/stt/concepts/language-hints)、[supported languages](https://soniox.com/docs/stt/concepts/supported-languages)、[context](https://soniox.com/docs/stt/concepts/context)、[models](https://soniox.com/docs/stt/models)、[pricing](https://soniox.com/pricing)
- OpenAI：[`gpt-transcribe`](https://developers.openai.com/api/docs/models/gpt-transcribe)、[transcription guide](https://developers.openai.com/api/docs/guides/transcription)、[file transcription / prompting / languages](https://developers.openai.com/api/docs/guides/speech-to-text)、[pricing](https://developers.openai.com/api/docs/pricing#transcription-models)
- Speechmatics：[pricing and feature matrix](https://www.speechmatics.com/pricing)、[job configuration](https://legacy.docs.speechmatics.com/en/cloud/configuring-job-request/)
- Azure：[post-processing](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-post-processing)、[display text format](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/display-text-format)、[custom display formatting / language support](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-custom-speech-display-text-format)、[pricing](https://azure.microsoft.com/en-us/pricing/details/ai-services/speech-services/)
- 其他淘汰项：[Deepgram models/languages](https://developers.deepgram.com/docs/models-languages-overview/)、[Google Chirp 3](https://docs.cloud.google.com/speech-to-text/v2/docs/chirp-model)、[Google mixed-language limitation](https://docs.cloud.google.com/speech-to-text/docs/troubleshooting)、[AssemblyAI prompting](https://www.assemblyai.com/docs/universal-streaming/prompting)、[Voxtral](https://docs.mistral.ai/studio-api/audio/speech_to_text)、[Qwen ASR](https://www.alibabacloud.com/help/en/model-studio/qwen-asr-api-reference)
