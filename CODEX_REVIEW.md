# Whisper 项目代码审查（当前版本）

审查范围：`/Users/siyuansun/Dev/whisper` 目录下现有源码（静态审查 + 语法检查），未执行端到端运行测试。

## Findings（按严重级别排序）

### P1

1. **跨线程调用 AppKit/WebKit，存在崩溃或未定义行为风险**
- **文件/行号**:
  - `app.py:49`（音频回调线程直接调用 `overlay.update_audio_level`）
  - `app.py:85`, `app.py:92`（后台转写线程直接调用 `overlay.set_state`）
  - `ui/overlay.py:112`（`WKWebView.evaluateJavaScript`）
- **问题**: AppKit/WebKit UI 操作需要在主线程执行；当前从 `sounddevice` 回调线程和后台转写线程直接触发 UI 更新。
- **修复建议**: 统一封装 `run_on_main_thread(fn, *args)`，在主线程执行所有 `OverlayPanel` 相关调用；例如用 `AppKit.NSApplication.sharedApplication().performSelectorOnMainThread...` 或主线程队列 + timer pump。

2. **并发转写共享同一个 VAD/Recognizer 状态，结果可能串音或状态污染**
- **文件/行号**:
  - `app.py:94`（每次停止录音都新开线程）
  - `core/transcriber.py:33`（`self.vad` 为实例级共享状态）
  - `core/transcriber.py:41-49`（复用同一 VAD 缓冲）
- **问题**: 若用户快速进行多次录音，多个后台线程会并发调用同一个 `Transcriber`，而内部 `vad`/解码状态非线程安全。
- **修复建议**: 二选一：
  - 给 `transcribe()` 加互斥锁串行化；
  - 或每次转写创建独立 VAD/stream（推荐），避免共享可变状态。

3. **配置支持 `firered`，但模型下载逻辑未实现，直接触发启动崩溃**
- **文件/行号**:
  - `config.py:5`（注释声明支持 `firered`）
  - `core/models.py:6-17`（`MODELS` 中仅有 `sensevoice` 和 `silero_vad`）
  - `core/models.py:35`（`MODELS[name]` 会在 `firered` 时 `KeyError`）
- **问题**: 对外能力声明与实现不一致，会在设置为 `firered` 时立即崩溃。
- **修复建议**: 补齐 FireRed 模型元数据与下载逻辑；若暂不支持，则在配置层限制可选值并给出明确错误提示。

4. **录音启动失败路径未处理，状态机会进入不一致状态**
- **文件/行号**:
  - `app.py:59-68`（先置 `_dictation_active=True` 再 `recorder.start()`）
  - `core/audio.py:31-38`（`InputStream` 创建/启动异常未捕获）
- **问题**: 麦克风不可用或设备异常时，`start()` 抛错会导致 `_dictation_active` 已置真，后续热键切换可能走到错误分支。
- **修复建议**: `start()` 外层 try/except，失败时回滚状态、提示用户并恢复 tray/overlay；必要时禁用 dictation 直到设备恢复。

### P2

5. **`sample_rate` 可配置但无重采样，和 VAD/模型 16k 假设冲突**
- **文件/行号**:
  - `config.py:10`（`sample_rate` 可改）
  - `core/audio.py:32`（按配置采样）
  - `core/transcriber.py:32`（VAD 固定 16000）
- **问题**: 用户将采样率改为非 16k 时，VAD/识别精度会显著下降或行为异常。
- **修复建议**: MVP 阶段强制 16k；或在转写前做重采样并校验。

6. **模型下载中断后会保留损坏文件，后续启动可能持续失败**
- **文件/行号**:
  - `core/models.py:21-31`（下载写入同一目标文件）
  - `core/models.py:38-40`, `core/models.py:49-55`（仅按“文件存在”判断）
- **问题**: 网络中断会留下半文件；下次检测到“已存在”即跳过下载，导致解析/加载失败。
- **修复建议**: 先下载到 `*.part`，完成后原子 rename；增加哈希校验或最小尺寸校验，失败自动重试。

7. **无效 YAML 会在启动时直接抛异常退出**
- **文件/行号**:
  - `config.py:25`（`yaml.safe_load` 未捕获解析错误）
- **问题**: 用户手改配置出错会导致应用不可启动。
- **修复建议**: 捕获 `yaml.YAMLError`，回退默认配置并提示“配置文件损坏，已忽略”。

8. **全局热键未过滤按键重复，长按可能触发多次开关**
- **文件/行号**:
  - `platform_layer/macos.py:35-47`
- **问题**: `KeyDown` 自动重复可能反复触发 start/stop，造成状态抖动。
- **修复建议**: 在 handler 里忽略 `event.isARepeat()`；或加最小触发间隔节流。

9. **无障碍权限未就绪仍继续进入 Ready，用户感知与真实能力不一致**
- **文件/行号**:
  - `app.py:109-113`（仅打印提示）
  - `app.py:127`（仍打印 `Ready!`）
- **问题**: 未授权时粘贴热键链路可能失败，但 UI 显示可用。
- **修复建议**: 未授权时将状态标记为“降级模式”，禁用粘贴或持续提醒，并在 tray 中展示权限状态。

10. **Overlay 未显式忽略鼠标事件，可能遮挡底层点击**
- **文件/行号**:
  - `ui/overlay.py:32-47`（创建 panel 但未 `setIgnoresMouseEvents_(True)`）
- **问题**: 即使不抢键盘焦点，也可能截获鼠标交互，影响用户当前应用。
- **修复建议**: 设置 `self._panel.setIgnoresMouseEvents_(True)`。

### P3

11. **无用导入和冗余代码降低可维护性**
- **文件/行号**:
  - `ui/overlay.py:2`（`import objc` 未使用）
  - `app.py:48`（`from AppKit import NSObject` 未使用）
- **问题**: 无功能影响，但会增加代码噪音。
- **修复建议**: 删除未使用导入。

12. **功能文案与实现不一致（Meeting 模式仅占位）**
- **文件/行号**:
  - `app.py:97-99`（meeting 模式未实现）
  - `app.py:129`（启动提示仍显示 meeting 热键）
- **问题**: 用户预期与产品行为不一致。
- **修复建议**: 在菜单与启动文案中明确标注 “Coming soon”，或暂时移除该热键注册。

## False Positives（看起来可疑但当前是合理的）

1. `platform_layer/macos.py:17` 使用 `AppKit.NSPasteboardTypeString` 是正确的现代写法，不是旧 API。
2. `ui/overlay.py` 使用 `NSNonactivatingPanel` 方向是正确的，符合“不抢焦点”目标。
3. `core/models.py` 的 `tar.extractall(path=models_dir)` 在当前官方模型包结构下路径是可用的（但仍建议增加安全校验）。

## 测试与验证缺口

1. 尚未在 macOS 13/14/15 分别验证热键回调线程语义与 overlay 焦点行为。
2. 尚未验证“连续快速两次 dictation”下并发转写是否复现状态污染。
3. 尚未模拟网络中断与损坏模型缓存的恢复流程。

## 当前设计与效率补充 Review

### 设计上目前做得对的地方

1. `app.py` 里把音频引擎常驻初始化、录音时只挂 tap 的思路是对的，热键触发延迟比每次重新创建设备要低得多。
2. `ui/overlay.py` 已经把 `WKWebView` 调用切回主线程，并且 `NSPanel` 设为非激活窗口，这个方向是正确的。
3. `core/transcriber.py` 现在对识别器加了互斥锁，至少避免了并发转写直接打乱内部状态。
4. `core/models.py` 已经补上 `.part` 下载和原子 rename，模型缓存的健壮性比上一版明显更好。

### 当前效率上的主要瓶颈

1. `core/audio.py:32` 每个音频回调都用 Python 循环把 `AVAudioPCMBuffer` 拷进 `numpy`，这是当前最明显的 CPU 热点。
2. `core/transcriber.py:48` 仍然把 `numpy` 转成 Python list 再喂给 sherpa-onnx，会产生额外内存复制。
3. `app.py:140-149` 文本 cleanup 如果开启，会把“本地实时听写”变成“先本地 ASR，再走网络 LLM”，体感延迟会明显上升。
4. `platform_layer/macos.py:49-59` 粘贴前固定 sleep 50ms，虽然安全，但每次都会增加停止后的尾延迟。

### 建议优先优化项

1. 把 `core/audio.py` 的 PCM 提取改成零拷贝或少拷贝路径，避免 `[ch0[i] for i in range(frame_length)]` 这种逐样本 Python 循环。
2. 验证 sherpa-onnx Python 绑定是否能直接接受 `numpy.float32`，如果可以，去掉 `audio.tolist()`。
3. 把 cleanup 明确标成“可选后处理”，默认关闭；如果开启，UI 上要告诉用户这是慢路径。
4. 把粘贴链路改成“尽快 paste，失败再 fallback 重试”，而不是固定 sleep。
5. 如果后面要继续提升稳定性，建议把热键层统一收口在 Quartz event tap，不要同时长期维护两套语义不同的监听机制。

### 本轮已修复

1. `platform_layer/macos.py` 已改为优先使用 Quartz event tap 拦截 `Option+Space`，避免热键本身把空白字符输入到当前文本框。
2. 当 event tap 创建失败时，仍保留 `NSEvent` 监听兜底，保证功能不完全丢失。
