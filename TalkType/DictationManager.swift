import AVFoundation
import Cocoa
import Network

/// Central state machine: idle -> recording -> processing -> idle
final class DictationManager {
    enum State {
        case idle
        case recording
        case processing
    }

    private(set) var state: State = .idle

    private var config: AppConfig
    private let recorder: AudioRecorder
    let transcriber: Transcriber
    private let sidecar: SidecarManager
    private var cloudASR: CloudASRClient?
    private var refiner: TextRefiner
    private let vocabularyStore: VocabularyStore
    private let overlay: OverlayWindow
    private weak var trayDelegate: TrayDelegate?

    private let transcriberLock = NSLock()
    private var sessionID: Int = 0
    private var clipboardHintShown = false
    private var microphoneGranted = false
    private var micPermissionInFlight = false
    private var startAfterMicPermission = false

    // Reachability: cheap pre-check so an offline machine never pays a cloud timeout.
    private let reachabilityQueue = DispatchQueue(label: "talktype.reachability")
    private let pathMonitor = NWPathMonitor()
    private let reachabilityLock = NSLock()
    private var reachabilityState: NWPath.Status = .satisfied
    /// False until the monitor has delivered its first update. NWPathMonitor's initial
    /// snapshot can read as "unsatisfied" for a moment at launch, so the offline shortcut
    /// must not be trusted before the first real status arrives.
    private var reachabilityKnown = false

    /// The engine actually used by the last dictation (cloud vs local fallback). Nil
    /// until the first dictation; drives the menu state and transition notifications.
    private(set) var effectiveEngine: ASREngine?
    private var fallbackInProgress = false

    // Silence auto-stop
    private var lastSpeechTime: TimeInterval = 0

    // Focus restoration
    private var originApp: NSRunningApplication?

    init(config: AppConfig, vocabularyStore: VocabularyStore, overlay: OverlayWindow, sidecar: SidecarManager) {
        self.config = config
        self.vocabularyStore = vocabularyStore
        self.overlay = overlay
        self.sidecar = sidecar

        self.transcriber = Transcriber(
            port: config.asrPort,
            timeout: config.asrTimeoutSeconds
        )
        self.cloudASR = Self.makeCloudClient(config)

        self.refiner = TextRefiner(
            model: config.refineModel,
            timeout: config.refineTimeoutSeconds
        )

        self.recorder = AudioRecorder(
            sampleRate: config.sampleRate,
            onLevel: nil
        )
        applyInputSelection()
        // Set level callback after init since it captures self
        self.recorder.onLevel = { [weak self] level in
            self?.onAudioLevel(level)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.reachabilityLock.lock()
            self.reachabilityState = path.status
            self.reachabilityKnown = true
            self.reachabilityLock.unlock()
        }
        pathMonitor.start(queue: reachabilityQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func setTrayDelegate(_ delegate: TrayDelegate?) {
        trayDelegate = delegate
    }

    // MARK: - Lifecycle

    func prepareAudio() {
        recorder.prepare()
    }

    func checkMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = (status == .authorized)
        print("[audio] microphone status at startup: \(micStatusLabel(status)) (raw=\(status.rawValue))")
    }

    func shutdown() {
        recorder.shutdown()
    }

    // MARK: - Dictation toggle

    func toggleDictation() {
        switch state {
        case .idle:
            startDictation()
        case .recording:
            stopDictation()
        case .processing:
            break // ignore during processing
        }
    }

    // MARK: - Config

    func reloadConfig(_ newConfig: AppConfig) {
        // Fallback state only dies when the engine choice itself changes. A microphone or
        // refine tweak mid-fallback must not orphan a running sidecar — the menu would
        // say Cloud while the ~4 GB process kept running.
        if newConfig.asrEngine != config.asrEngine {
            effectiveEngine = nil
            fallbackInProgress = false
        }
        transcriberLock.lock()
        config = newConfig
        transcriber.timeout = newConfig.asrTimeoutSeconds
        cloudASR = Self.makeCloudClient(newConfig)
        refiner = TextRefiner(model: newConfig.refineModel, timeout: newConfig.refineTimeoutSeconds)
        transcriberLock.unlock()
        applyInputSelection()
    }

    /// Called after the local engine is deleted: the fallback can no longer use it.
    func clearFallbackState() {
        effectiveEngine = nil
        fallbackInProgress = false
    }

    private static func makeCloudClient(_ config: AppConfig) -> CloudASRClient? {
        guard let key = CloudKeyStore.apiKey(for: config.cloudProvider) else { return nil }
        return CloudASRClient(
            baseURL: config.cloudBaseURL,
            apiKey: key,
            model: config.cloudModel,
            shape: config.cloudProvider.profile.requestShape,
            timeout: config.asrTimeoutSeconds
        )
    }

    // MARK: - Engine selection (cloud-first, automatic local fallback)

    private var isOffline: Bool {
        reachabilityLock.lock()
        defer { reachabilityLock.unlock() }
        return reachabilityKnown && reachabilityState != .satisfied
    }

    private static var localEngineInstalled: Bool {
        if case .ready = SidecarManager.installState() { return true }
        return false
    }

    /// Cloud-first with automatic local fallback. Any cloud failure — no key, offline,
    /// invalid key, quota, timeout, service error — falls back to the local engine when
    /// it is installed, so a dictation only fails when neither path can work.
    private func transcribeWithFallback(audio: [Float], hints: [String]?, config: AppConfig,
                                        cloud: CloudASRClient?, local: Transcriber) throws -> String {
        let policy = FallbackPolicy(localInstalled: Self.localEngineInstalled)

        // No cloud client means no API key stored. With the local engine installed the
        // dictation still works; otherwise the user gets the exact fix to make.
        guard let cloud = cloud else {
            if Self.localEngineInstalled {
                return try transcribeLocally(audio: audio, hints: hints,
                                             reason: "没有云端 key，已用本地。去设置添加 key。",
                                             config: config, local: local)
            }
            throw UserFacingError(message: "云端语音引擎没有 API key。去设置里添加 OpenRouter key。")
        }

        switch policy.plan(offline: isOffline) {
        case .cloud(let timeout):
            do {
                let text = try cloud.transcribeSync(
                    audio: audio, sampleRate: config.sampleRate,
                    vocabularyHints: hints, timeout: timeout)
                markCloudRecovered()
                return text
            } catch {
                let failure: CloudFailure
                if let cloudError = error as? CloudASRError {
                    failure = cloudError.classification
                } else if (error as? URLError)?.code == .timedOut {
                    failure = .timeout
                } else {
                    failure = .unknown
                }
                return try handleCloudFailure(failure, policy: policy, audio: audio, hints: hints,
                                              config: config, local: local)
            }
        case .local(let reason):
            return try transcribeLocally(audio: audio, hints: hints, reason: reason,
                                         config: config, local: local)
        case .blocked(let message):
            throw UserFacingError(message: message)
        }
    }

    private func handleCloudFailure(_ failure: CloudFailure, policy: FallbackPolicy,
                                    audio: [Float], hints: [String]?, config: AppConfig,
                                    local: Transcriber) throws -> String {
        switch policy.fallbackPlan(failure: failure) {
        case .local(let reason):
            return try transcribeLocally(audio: audio, hints: hints, reason: reason,
                                         config: config, local: local)
        case .blocked(let message):
            throw UserFacingError(message: message)
        case .cloud:
            preconditionFailure("fallbackPlan never plans to retry cloud")
        }
    }

    /// Run the local engine, starting the sidecar on demand. The sidecar stays alive
    /// while the fallback is in effect; `markCloudRecovered` stops it again.
    private func transcribeLocally(audio: [Float], hints: [String]?, reason: String,
                                   config: AppConfig, local: Transcriber) throws -> String {
        try ensureLocalSidecar(port: config.asrPort, timeout: config.asrTimeoutSeconds)
        let text = try local.transcribe(audio: audio, sampleRate: config.sampleRate,
                                        vocabularyHints: hints)
        if effectiveEngine != .local {
            effectiveEngine = .local
            fallbackInProgress = true
            trayDelegate?.notifyInfo(reason)
            trayDelegate?.engineStateDidChange(.local)
        }
        return text
    }

    /// Start the sidecar if needed, then wait for /health to report ready. A cold start
    /// binds the socket before loading the ~4 GB of weights, so an immediate /transcribe
    /// would hit a 503 and the dictation would be dropped — the audio is already in
    /// memory, so waiting here is free.
    private func ensureLocalSidecar(port: Int, timeout: TimeInterval) throws {
        var coldStart = false
        if !sidecar.isRunning {
            let probe = Transcriber(port: port)
            let alreadyServing = probe.health() != .unreachable
            let state = sidecar.start(port: port, alreadyServing: alreadyServing)
            if case .missing(let what) = state {
                throw UserFacingError(message: "本地引擎不可用：\(what)。联网，或在设置里安装本地引擎。")
            }
            if !alreadyServing {
                // The wait below can run tens of seconds while the weights load; without
                // this the user just sees the overlay spin with no explanation.
                coldStart = true
                trayDelegate?.notifyInfo("正在启动本地引擎，这一句会稍等几秒。")
            }
        }
        let probe = Transcriber(port: port)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // `== .ready` would be ambiguous — SidecarHealth.ready and
            // SidecarManager.InstallState.ready share the case name.
            if case .ready = probe.health() { return }
            if coldStart && !sidecar.isRunning {
                // The process we just spawned died (broken venv, OOM) — fail now
                // rather than grinding out the rest of the deadline.
                throw UserFacingError(message: "本地引擎启动失败（进程已退出）。到设置里重装，或查看 ~/.talktype/asr/server.log。")
            }
            usleep(250_000)
        }
        throw UserFacingError(message: "本地引擎启动超时。稍后再试，或到设置里查看状态。")
    }

    /// A cloud dictation succeeded — if the local fallback was active, free the ~4 GB
    /// resident model and tell the user we are back on cloud.
    private func markCloudRecovered() {
        guard effectiveEngine == .local, fallbackInProgress else { return }
        fallbackInProgress = false
        effectiveEngine = .cloud
        sidecar.stop()
        trayDelegate?.notifyInfo("已回到云端引擎。")
        trayDelegate?.engineStateDidChange(.cloud)
    }

    /// Empty config UID means Automatic: follow the system default, except skip a
    /// Bluetooth default — see `AudioDevices.automaticInput`. An explicit pick wins.
    private func applyInputSelection() {
        let automatic = AudioDevices.automaticInput()
        recorder.preferredDeviceUID = config.inputDeviceUID.isEmpty
            ? automatic.device?.uid
            : config.inputDeviceUID
    }

    // MARK: - Refinement

    /// Cloud refinement, with the local tidy as the floor. Whatever happens — refinement
    /// disabled, no API key, offline, slow, or output that failed the plausibility
    /// check — the caller still gets usable text.
    private func refine(_ text: String) -> String {
        let fallback = PostProcessor.tidySpeech(text)
        guard config.refineEnabled else { return fallback }

        transcriberLock.lock()
        let refiner = self.refiner
        transcriberLock.unlock()

        let started = Date()
        guard let refined = refiner.refine(text) else { return fallback }
        print("[refine] \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return refined
    }

    /// Open the connection to the refiner ahead of first use.
    func prewarmRefiner() {
        guard config.refineEnabled else { return }
        transcriberLock.lock()
        let refiner = self.refiner
        transcriberLock.unlock()
        refiner.prewarm()
    }

    var refinerConfigured: Bool { refiner.isConfigured }

    // MARK: - Start dictation

    private func startDictation() {
        // Check mic permission
        if !microphoneGranted {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .authorized {
                microphoneGranted = true
            } else if status == .notDetermined {
                startAfterMicPermission = true
                guard !micPermissionInFlight else {
                    print("[audio] microphone: permission request already in flight")
                    return
                }
                micPermissionInFlight = true
                print("[audio] microphone: not_determined - requesting permission")
                NSApp.activate(ignoringOtherApps: true)

                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        self?.handleMicPermissionResult(granted)
                    }
                }
                trayDelegate?.notifyInfo("Microphone permission required. Please allow the system prompt.")
                return
            } else {
                // denied or restricted
                startAfterMicPermission = false
                print("[audio] microphone: \(micStatusLabel(status))")
                trayDelegate?.notifyError("Microphone access denied. Enable in System Settings -> Privacy -> Microphone.")
                openMicSettings()
                return
            }
        }

        state = .recording
        lastSpeechTime = ProcessInfo.processInfo.systemUptime

        // Capture the frontmost app for focus restoration after transcription
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            originApp = front
        } else {
            originApp = nil
        }

        do {
            try recorder.start()
            sessionID += 1
        } catch {
            state = .idle
            trayDelegate?.setRecording(false)
            trayDelegate?.setProcessing(false)
            trayDelegate?.notifyError("Microphone unavailable. Check Microphone permission.")
            if overlay.isVisible { overlay.hide() }
            print("[audio] failed to start microphone: \(error)")
            openMicSettings()
            return
        }

        overlay.show()
        trayDelegate?.setRecording(true)
    }

    // MARK: - Stop dictation

    func stopDictation(autoStopped: Bool = false) {
        guard state == .recording else { return }
        state = .processing
        lastSpeechTime = 0

        trayDelegate?.setRecording(false)
        overlay.setState(.processing)
        trayDelegate?.setProcessing(true)

        let audio = recorder.stop()
        let session = sessionID
        let minSamples = Int(0.12 * Double(config.sampleRate))
        let minRMS = config.minTranscribeRms

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    if self.sessionID == session {
                        self.overlay.hide()
                        self.trayDelegate?.setProcessing(false)
                        if autoStopped {
                            self.trayDelegate?.notifyInfo("Stopped after silence.")
                        }
                    }
                    if self.state == .processing {
                        self.state = .idle
                    }
                }
            }

            guard audio.count >= minSamples else {
                self.trayDelegate?.notifyInfo("Recording too short.")
                return
            }

            let rms = AudioRecorder.calculateRMS(audio)
            print("[audio] captured samples=\(audio.count) rms=\(String(format: "%.5f", rms))")

            if rms == 0 {
                print("[audio] all-zero audio - microphone access likely blocked")
                self.microphoneGranted = false
                self.trayDelegate?.notifyError("Microphone blocked. Enable in System Settings -> Privacy -> Microphone.")
                DispatchQueue.main.async { self.openMicSettings() }
                return
            }

            if Double(rms) < minRMS {
                self.trayDelegate?.notifyInfo("No speech detected. Speak louder or check microphone input.")
                return
            }

            do {
                // Skip vocab hints on low-confidence audio to prevent hallucination
                let hints: [String]?
                if rms < PostProcessor.hallucinationRmsThreshold {
                    hints = nil
                    print("[asr] low RMS (\(String(format: "%.5f", rms))) — skipping vocabulary hints")
                } else {
                    hints = self.vocabularyStore.getActiveVocabulary()
                }
                // Snapshot the pipeline under the lock, then transcribe outside it: a long
                // cloud request (up to 60 s without local) must not freeze menu actions
                // that reload the config.
                self.transcriberLock.lock()
                let cfg = self.config
                let localTranscriber = self.transcriber
                let cloud = self.cloudASR
                self.transcriberLock.unlock()

                let text: String
                if cfg.asrEngine == .cloud {
                    text = try self.transcribeWithFallback(
                        audio: audio, hints: hints, config: cfg, cloud: cloud, local: localTranscriber)
                } else {
                    text = try localTranscriber.transcribe(
                        audio: audio, sampleRate: cfg.sampleRate, vocabularyHints: hints)
                }

                let vocabEntries = self.vocabularyStore.listEntries()

                // Check for hallucination on the raw transcript, before spending a network
                // round trip refining something that is about to be thrown away.
                if PostProcessor.isLikelyHallucination(text, audioRMS: rms, vocabEntries: vocabEntries) {
                    print("[asr] hallucination detected: \"\(text)\" with rms=\(String(format: "%.5f", rms))")
                    self.trayDelegate?.notifyInfo("No speech detected (transcription discarded).")
                    return
                }

                // Cloud refinement if enabled and reachable; the local tidy otherwise.
                // Vocabulary canonicalisation runs last so the spellings the user chose
                // survive whatever the refiner did.
                let refined = self.refine(text)
                let processed = PostProcessor.postProcess(text: refined, vocabEntries: vocabEntries)

                guard !processed.isEmpty else {
                    self.trayDelegate?.notifyInfo("No text recognized. Try speaking more clearly.")
                    return
                }

                DispatchQueue.main.async {
                    // Stale check — must read sessionID on main thread
                    guard self.sessionID == session else {
                        Log.write("[insert] stale session (\(session) != \(self.sessionID)) — clipboard only")
                        self.originApp = nil
                        TextInserter.copyToClipboard(processed)
                        return
                    }

                    // Restore original app focus if user switched away
                    let needsRestore: Bool
                    if let origin = self.originApp,
                       !origin.isTerminated,
                       origin.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier {
                        origin.activate()
                        needsRestore = true
                    } else {
                        needsRestore = false
                    }
                    self.originApp = nil

                    // Insert text (with short delay if restoring focus)
                    let restored = needsRestore
                    let insertBlock = { [weak self] in
                        guard let self = self else { return }
                        let pasted = TextInserter.insert(processed)
                        Log.write("[insert] pasted=\(pasted) chars=\(processed.count) target=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") restored=\(restored)")
                        guard !pasted else { return }

                        // The only reason a paste fails is a missing Accessibility grant,
                        // and it is worth interrupting for: without it every dictation
                        // silently ends in a manual ⌘V.
                        Log.write("[insert] clipboard only — accessibility not granted")
                        if !self.clipboardHintShown {
                            self.clipboardHintShown = true
                            self.trayDelegate?.accessibilityMissing()
                        }
                    }

                    if needsRestore {
                        // Give window server time to complete activation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: insertBlock)
                    } else {
                        insertBlock()
                    }
                }
            } catch let error as UserFacingError {
                print("[asr] \(error.message)")
                self.trayDelegate?.notifyError(error.message)
            } catch let error as TranscriberError {
                print("[asr] \(error.localizedDescription)")
                self.trayDelegate?.notifyError(error.localizedDescription)
            } catch {
                print("[asr] transcription failed: \(error)")
                self.trayDelegate?.notifyError("Transcription failed. Check network and API key.")
            }
        }
    }

    // MARK: - Audio level & silence

    private func onAudioLevel(_ level: Float) {
        overlay.updateAudioLevel(level)

        guard state == .recording, config.silenceAutoStopEnabled else { return }

        let rms = level * 0.15
        let now = ProcessInfo.processInfo.systemUptime

        if Double(rms) >= config.silenceRmsThreshold {
            lastSpeechTime = now
        } else if lastSpeechTime > 0 && (now - lastSpeechTime) >= config.silenceAutoStopSeconds {
            lastSpeechTime = 0
            print("[audio] silence for \(config.silenceAutoStopSeconds)s, auto-stopping")
            DispatchQueue.main.async { [weak self] in
                self?.stopDictation(autoStopped: true)
            }
        }
    }

    // MARK: - Mic permission

    private func handleMicPermissionResult(_ granted: Bool) {
        micPermissionInFlight = false
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = granted || status == .authorized

        if microphoneGranted {
            let shouldStart = startAfterMicPermission
            startAfterMicPermission = false
            if shouldStart { startDictation() }
            return
        }

        startAfterMicPermission = false
        if status == .denied || status == .restricted {
            trayDelegate?.notifyError("Microphone access denied. Enable in System Settings -> Privacy -> Microphone.")
            openMicSettings()
        }
    }

    private func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func micStatusLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}

/// Protocol for tray menu callbacks from dictation manager.
protocol TrayDelegate: AnyObject {
    func setRecording(_ active: Bool)
    func setProcessing(_ active: Bool)
    func notifyError(_ message: String)
    func notifyInfo(_ message: String)
    /// Pasting failed for want of an Accessibility grant; the transcript is on the clipboard.
    func accessibilityMissing()
    /// The engine actually used by dictation changed (cloud ↔ local fallback).
    func engineStateDidChange(_ engine: ASREngine)
}
