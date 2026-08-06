# TalkType —— 用说的，代替打字

*[English](README.md)*

![TalkType logo](docs/assets/talktype-logo.png)

**用说的，代替打字。** 在 Mac 上任何地方按一下快捷键开始说，再按一下（或停顿）——文字就落在光标处。Slack、备忘录、邮件、终端……凡是能打字的地方，都能说。

这是一个中英混说的人做给自己用的软件，所以**一句话里中英文混着说，它就是能听懂**——你不用切换语言，说到哪算哪。

```
按快捷键 → 说话 → 再按一下 / 停顿 → 文字出现在光标处
```

---

## 一起把 TalkType 做好

TalkType 要靠真实使用才能继续变好，尤其是一个人很难发现的那些小细节。如果哪里不顺、某个词总是听错，或者你想到一个能让听写更适合自己工作方式的功能，**欢迎直接[提交 GitHub Issue](https://github.com/simonsysun/talktype/issues/new)**。

Bug、还没成形的想法、功能建议，甚至一个很小的使用感受都可以。你不需要会写代码，也不需要先想好完整方案；我们可以一起讨论、一起把它做出来。也欢迎[看看并加入已有讨论](https://github.com/simonsysun/talktype/issues)。

---

## 四个 provider，一条快捷键

一次听写就是一次 API 调用：录音、发送、粘贴。中间什么都不做——没有润色、没有本地模型——所以 provider 返回什么，光标处就出现什么。

在菜单栏里选一个。每家各自存 key，切换只要点一下菜单。

| Provider | 价格（文件） | 原生去口头语 | 中英混说 |
|---|---|---|---|
| **ElevenLabs Scribe v2**（默认） | $0.22/小时 | 会——`no_verbatim` 去 filler、false start、重复、结巴 | 官方承诺英文词按英文转写，不受周围语言影响 |
| **xAI Grok** | $0.10/小时 | 会——默认去 filler | 官方语言表不含中文，没有承诺（不等于不准） |
| **Soniox v5** | 约 $0.10/小时 | 不会 | 明确支持同一句话内多语言混说 |
| **OpenAI gpt-transcribe** | $0.27/小时 | 不会 | 明确支持 code-switching |

「中文为主、夹大量英文术语」这个场景到底哪家最好，是个没有答案的问题——没有厂商 benchmark 它。切换 provider 说同一句话，就是找答案的方式。

**隐私，说精确点：**

| 什么 | 会离开你的 Mac 吗 |
|---|---|
| 音频 + 你的词库术语 | 会——发给你选的那家 provider，按它的数据政策处理 |
| 其它一切 | 没有了。没有账号、没有遥测、没有订阅。 |

唯一的凭证是你选的那家 provider 的 API key，存在 macOS 钥匙串里。没有离线模式：没网就是明确报错，不会偷偷降级。

---

## 快速上手——大约 3 分钟

**你需要：** Apple 芯片 Mac（M1 及以上），macOS 13 以上。

1. **下载并打开。** [⬇ 下载最新版](https://github.com/simonsysun/talktype/releases/latest)——解压，拖进"应用程序"。第一次打开 macOS 会拒绝——免费软件没买付费证书。右键点 App ▸ **打开** ▸ **打开**，之后它就记住了。
2. **给两个权限。** 麦克风，以及"允许帮你粘贴"。两个都必须给，TalkType 没法替你同意。
3. **选一个 provider，填它的 key。** 选中的 provider 没有 key 时，设置窗口会自己打开；「拿 key →」链接直接跳到那家的控制台。

按 **⌘⇧Space** 开始说。

---

## 使用手册

- **快捷键**——默认 ⌘⇧Space；在菜单栏"更改快捷键…"里改。
- **Provider**——菜单栏 ▸ Speech-to-text ▸ 选一个。菜单标题显示当前用哪家、有没有 key。
- **麦克风**——指定一个，或选自动（跟随系统默认，包括蓝牙耳机；用蓝牙麦录音时链路切到耳机模式，播放会降到 24kHz 单声道一段时间）。
- **词库**——把模型老听错的名字和术语加进去，会按各家的格式传过去：Grok 用 `keyterm`、ElevenLabs 用 `keyterms`、Soniox 用 `context.terms`、OpenAI 用 `keywords[]`。**之后不再做本地纠正**——所以一个词传了还是错，那就是那家 provider 的真实水平。
- **Key**——每家一个槽位，存在登录钥匙串里。设置里可添加、更换、删除。填进去不做在线校验；key 错了会在第一次听写时明确告诉你。
- **剪贴板**——每段转写也会留在剪贴板上，⌘V 永远是兜底。

## 常见问题

- **更新之后不粘贴了？** macOS 把"允许粘贴"权限绑定在具体版本上，TalkType 没有付费证书，所以新版本在 macOS 眼里是另一个 App。TalkType 会自己发现并给你 **Fix This** 按钮；点它，然后在 macOS 询问时重新打开 TalkType。（v2.0.2 起共用一张证书签名，以后更新不会再这样。）
- **提示"还没有 API key"？** 在设置里选 provider 并填它的 key。
- **提示"拒绝了这个 API key"？** 是 provider 回答说不行——通常是多了个空格，或者贴错了别家的 key。设置里的眼睛按钮能看到实际存进去的是什么。
- **中英文之间没空格、标点是半角？** 那就是 provider 的原始输出。现在没有任何本地规范化——换一家试试。
- **Soniox 觉得慢？** 它没有同步接口：一次听写要上传、建任务、轮询、取结果四步。另外三家都是一次往返。

## 和别的方案比

| | TalkType | 苹果自带听写 | Wispr Flow / Superwhisper |
|---|---|---|---|
| 价格 | 免费（自带 key） | 免费 | 订阅制 |
| 离线可用 | 不支持 | 部分 | 通常要联网 |
| 声音离开电脑 | 会 | 有时 | 通常会 |
| 中英混说 | 支持 | 很差 | 看产品 |
| 去掉口头禅 | 看你选哪家 provider | 不会 | 会 |
| 自定义词库 | 有 | 有限 | 有 |
| 开源 | 是（MIT） | 否 | 否 |

## 内部实现

一个 `STTClient` 协议，四个实现。其中三家是单次 multipart POST；Soniox 要上传、建任务、轮询、取结果。决定输出质量的参数写死在代码里，不做成设置项——ElevenLabs 的 `no_verbatim=true` 和 `tag_audio_events=false`、Grok 的 `filler_words=false`、Soniox 和 OpenAI 的中英双语言提示。

`~/.talktype/config.json` 里的 `grok_language` 是唯一的逃生口：xAI 的 `format`（口语数字转书面形式）必须配 `language` 才生效，但它公布的语言表里没有中文，所以传 `zh` 到底有没有用只能实测。留空则两个都不传。

设置 `TALKTYPE_STATE_DIR` 可以把配置和词库指到别处，用来试新配置而不动你正在用的那套。

## 从源码构建

```bash
git clone https://github.com/simonsysun/talktype.git
cd talktype

./scripts/make-signing-cert.sh   # 可选，一次：让权限在更新后仍然有效
./scripts/build.sh install
```

`swift test` 不需要 Xcode 就能跑逻辑测试。`TODO.md` 记录做完了什么、还差什么。仓库里还有一个从未编译、暂时搁置的 iOS 键盘扩展。

## 协议

MIT——随便用。
