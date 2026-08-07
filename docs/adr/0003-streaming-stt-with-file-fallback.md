# 流式识别为默认，文件识别为同厂兜底

录音开始时就连接豆包流式语音识别 2.0，并按 200 ms 发送 16 kHz PCM；停止录音时结束最后一帧并
等待文字。WebSocket 失败时，才把本地已保留的完整录音交给录音文件识别 2.0 极速版。

Status: accepted (2026-08-06), supersedes the transport choice in
[ADR-0002](0002-single-call-stt-no-polish.md)

## 为什么

文件极速版在多数短听写上约 1.3–1.7 秒，但实测存在 6–30 秒长尾和 504；长尾与录音长度不相关。
它说明服务开通和音频格式本身都没问题，慢发生在停止录音后的同步文件请求。

流式 `bigmodel_nostream` 在用户说话时就上传音频，松开时只需提交最后一帧。它仍由同一个豆包模型
完成标点、ITN、DDC 和热词偏置，没有增加 provider 或文字改写层。

## 结果

- 默认资源是 `volc.seedasr.sauc.duration`，endpoint 是
  `/api/v3/sauc/bigmodel_nostream`；沿用同一个项目 `X-Api-Key`。
- 音频 tap 只把 chunk 放进专用队列，不在实时回调线程做重采样或网络等待。
- 本地仍保留完整录音，用 `volc.bigasr.auc_turbo` 同步文件接口兜底；正常听写只有一条识别链路。
- 两项服务都没开通时明确报配置错误；流式短暂失败不会丢掉这次听写。
