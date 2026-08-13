# TalkType —— 用说的，代替打字

*[English](README.md)*

![TalkType logo](docs/assets/talktype-logo.png)

**用说的，代替打字。** 在 Mac 上任意处按快捷键开始说，再按一下（或停顿）——文字落在光标处。Slack、备忘录、邮件、终端……能打字的地方都能说。

为**一句话里中英混说**的人做的：不用切换输入法语言。

```
按快捷键 → 说话 → 再按 / 停顿 → 文字出现在光标处
```

**App 免费（MIT）。** 你自己准备语音 API Key，用量按对应云厂商计费。没有 TalkType 账号、没有订阅、没有遥测。

---

## 安装（大约 5 分钟）

**需要：** macOS 13 及以上

1. **下载**最新 macOS 安装包：  
   **[⬇ Releases](https://github.com/simonsysun/talktype/releases/latest)**  
   解压 → 把 `TalkType.app` 拖进 **「应用程序」**。

2. **第一次打开。** 免费软件没有苹果付费开发者证书，系统可能拦：  
   右键 TalkType → **打开** → **打开**。之后会记住。

3. **两个权限**（弹出时都要允许）：
   - **麦克风**
   - **辅助功能**（才能替你粘贴）

4. **填 API Key**（缺 key 时会自动弹窗）：

   | Provider | 菜单 | 去哪拿 Key | 说明 |
   | --- | --- | --- | --- |
   | **豆包 / 火山**（默认） | API Key… | [豆包语音控制台](https://console.volcengine.com/) → **API Key 管理**（不是 IAM「API 访问密钥」）。开通 **流式语音识别 2.0** 和 **录音文件识别 2.0**。 | 边说边传；流式失败才用同家文件识别重试 |
   | **Grok / xAI**（可选） | Speech Provider → Grok，再 API Key… | [console.x.ai](https://console.x.ai) → API Keys | 松键后 REST 转写。中文实际能用，但不在 xAI 官方 formatting 语言表（best-effort） |

按 **⌘⇧Space** 开始说。快捷键可在菜单栏随时改。

---

## 做什么 / 不做什么

- **一次听写 = 一次识别**——没有第二层「润色」模型，也没有几 GB 本地引擎。
- **同一时间只用一个云**——菜单栏 **Speech Provider** 选豆包或 Grok；**不会**在两家之间偷偷切换。
- **词库**——常听错的名字/术语；豆包作热词，Grok 作 `keyterm`。识别后不做本地改写。
- **剪贴板**——每次结果都会复制一份，⌘V 永远能兜底。

### 隐私

| 什么 | 会离开 Mac 吗 |
| --- | --- |
| 本次听写的音频 + 词库术语 | **会**——发给**你选中的**厂商（火山或 xAI），按其政策处理 |
| 其它一切 | **不会**——无 TalkType 账号、无遥测、无订阅身份 |

没有离线模式：没网就是明确报错。

---

## 使用手册

| 项目 | 位置 |
| --- | --- |
| 快捷键 | 菜单栏 → 更改快捷键…（默认 ⌘⇧Space） |
| 语音厂商 | 菜单栏 → Speech Provider |
| API Key（当前厂商） | 菜单栏 → API Key… |
| 麦克风 | 菜单栏 → Microphone（或自动） |
| 词库 | 菜单栏 → Vocabulary |
| 开机启动 | 菜单栏 → Launch at Login |

**蓝牙提示：** 用蓝牙耳机麦录音时，系统常切到耳机模式，播放可能降到 24 kHz 单声道一段时间——这是 macOS 行为，不是 TalkType 单独的锅。

---

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 系统不让打开 | 右键 → 打开 → 打开（未付费签名） |
| 更新后不能粘贴 | 点 **Fix This**，在 隐私 → 辅助功能 里重新打开 TalkType。共用同一签名证书的版本可保住授权 |
| 「还没填 API Key」 | 菜单栏 → API Key…（**当前** provider） |
| 豆包 key 不对 / grant not found | 用语音控制台项目 Key（不是 IAM）；开通流式 + 录音文件 2.0 |
| Grok key 不对 | 从 console.x.ai 贴完整 Key（不要空格/星号遮罩） |
| AirPods 起录失败 | 再试一次，或麦克风改成 Mac 内置；蓝牙切换本身不稳定 |
| 中英文中间没空格 | 就是模型原文——故意不做本地改写 |

---

## 费用

- **TalkType：** 免费。
- **语音 API：** 按你选的厂商计费（豆包 / xAI 各自账单）。每天几分钟听写通常很便宜；以控制台最新标价为准。

---

## 和别的方案比

| | TalkType | 苹果听写 | Wispr Flow / Superwhisper |
| --- | --- | --- | --- |
| 价格 | App 免费；STT 按你的 Key 计费 | 免费 | 订阅 |
| 离线 | 否 | 部分 | 通常上云 |
| 声音离开电脑 | 会（到你选的厂商） | 有时 | 通常会 |
| 中英混说 | 是 | 差 | 看产品 |
| 开源 | 是（MIT） | 否 | 否 |

---

## 从源码构建

```bash
git clone https://github.com/simonsysun/talktype.git
cd talktype

./scripts/make-signing-cert.sh   # 可选，一次：更新后辅助功能权限更稳
./scripts/build.sh install       # Release → /Applications/TalkType.app
# 或: ./scripts/build.sh release  # 额外打出 dist/TalkType-<version>.zip
```

- 逻辑测试（不必开 Xcode GUI）：`swift test`
- 打包：`scripts/build.sh`、`scripts/make-signing-cert.sh`
- 只做 macOS。仓库里没有 iOS 目标。

---

## 一起把 TalkType 做好

TalkType 靠**真实日用**才会变好。哪里不顺、哪个词总听错、有半成品想法——  
请丢到 **[GitHub Issue](https://github.com/simonsysun/talktype/issues/new)** 里。

这是我们主要看的地方：Bug、吐槽、一句话建议都可以，不用先想完整方案。  
有问题就放 Issue，我们可以一起讨论、一起改。

也欢迎[看看已有讨论](https://github.com/simonsysun/talktype/issues)。

---

## 项目文档（贡献者 / Agent）

| 文件 | 用途 |
| --- | --- |
| [`PRODUCT.md`](./PRODUCT.md) | 产品合同 |
| [`DECISION.md`](./DECISION.md) | 重要决策 |
| [`NOW.md`](./NOW.md) | 任务与重启点 |
| [`AGENTS.md`](./AGENTS.md) | Agent 工作流 |
| [`CHANGELOG.md`](./CHANGELOG.md) | 版本历史 |
| [`research/`](./research/) | 研究笔记 |

---

## 协议

[MIT](./LICENSE)——随便用。
