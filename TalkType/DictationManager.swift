import AVFoundation
import Cocoa

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

    // Silence auto-stop
    private var lastSpeechTime: TimeInterval = 0

    // Focus restoration
    private var originApp: NSRunningApplication?

    init(config: AppConfig, vocabularyStore: VocabularyStore, overlay: OverlayWindow) {
        self.config = config
        self.vocabularyStore = vocabularyStore
        self.overlay = overlay

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
        config = newConfig
        transcriberLock.lock()
        transcriber.timeout = newConfig.asrTimeoutSeconds
        cloudASR = Self.makeCloudClient(newConfig)
        refiner = TextRefiner(model: newConfig.refineModel, timeout: newConfig.refineTimeoutSeconds)
        transcriberLock.unlock()
        applyInputSelection()
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
                self.transcriberLock.lock()
                let text: String
                if self.config.asrEngine == .cloud {
                    guard let cloud = self.cloudASR else {
                        self.transcriberLock.unlock()
                        self.trayDelegate?.notifyError("Cloud speech engine has no API key. Add one under Setup.")
                        return
                    }
                    do {
                        text = try cloud.transcribeSync(audio: audio, sampleRate: self.config.sampleRate, vocabularyHints: hints)
                    } catch {
                        self.transcriberLock.unlock()
                        throw error
                    }
                } else {
                    do {
                        text = try self.transcriber.transcribe(audio: audio, sampleRate: self.config.sampleRate, vocabularyHints: hints)
                    } catch {
                        self.transcriberLock.unlock()
                        throw error
                    }
                }
                self.transcriberLock.unlock()

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
}
