import AVFoundation
import Cocoa

/// Central state machine: idle -> recording -> processing -> idle
///
/// The whole pipeline is: record, send the WAV to 豆包, paste what comes back. Nothing runs
/// between the API and the text field — no polish pass, no local tidy, no fallback engine.
/// What 豆包 returns is what lands in the document.
final class DictationManager {
    enum State {
        case idle
        case recording
        case processing
    }

    private(set) var state: State = .idle

    private var config: AppConfig
    private let recorder: AudioRecorder
    private var client: DoubaoSTTClient?
    private let vocabularyStore: VocabularyStore
    private let overlay: OverlayWindow
    private weak var trayDelegate: TrayDelegate?

    private let configLock = NSLock()
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
        self.client = Self.makeClient(config)

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
        configLock.lock()
        config = newConfig
        client = Self.makeClient(newConfig)
        configLock.unlock()
        applyInputSelection()
    }

    /// Nil until the App ID and Access Token are both stored — the one failure retrying
    /// cannot fix.
    private static func makeClient(_ config: AppConfig) -> DoubaoSTTClient? {
        guard let credentials = STTKeyStore.credentials() else { return nil }
        return DoubaoSTTClient(appID: credentials.appID, accessToken: credentials.accessToken)
    }

    var isConfigured: Bool { STTKeyStore.isConfigured }

    /// Empty config UID means Automatic: follow the system default, including a
    /// Bluetooth headset — see `AudioDevices.automaticInput`. An explicit pick wins.
    private func applyInputSelection() {
        // Leave the UID empty for Automatic; the recorder resolves the system default
        // at capture time so a device change does not wait for a restart.
        recorder.preferredDeviceUID = config.inputDeviceUID
    }

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

        // Give feedback before the audio engine warms up — a Bluetooth device can take
        // a moment to settle, and the user should see the pill instead of silence.
        overlay.show()
        // The main thread is about to busy-wait for the input format; commit the panel
        // now so it is actually drawn instead of queued behind the wait.
        CATransaction.flush()
        trayDelegate?.setRecording(true)
        do {
            try recorder.start()
            sessionID += 1
        } catch {
            state = .idle
            trayDelegate?.setRecording(false)
            trayDelegate?.setProcessing(false)
            let nsError = error as NSError
            let bluetoothSwitching = nsError.domain == "AudioRecorder" && nsError.code == 2
            trayDelegate?.notifyError(bluetoothSwitching
                ? error.localizedDescription
                : "Microphone unavailable. Check Microphone permission.")
            if overlay.isVisible { overlay.hide() }
            print("[audio] failed to start microphone: \(error)")
            Log.write("[mic] start failed: \(error.localizedDescription) device=\(recorder.captureDeviceName ?? "?")")
            if !bluetoothSwitching { openMicSettings() }
            return
        }
    }

    // MARK: - Stop dictation

    func stopDictation(autoStopped: Bool = false) {
        guard state == .recording else { return }
        state = .processing
        lastSpeechTime = 0

        trayDelegate?.setRecording(false)
        overlay.setState(.processing)
        trayDelegate?.setProcessing(true)

        let session = sessionID
        // Manual stop is a user-intent boundary, not an audio boundary. Keep the tap
        // alive for one measured render quantum so the final spoken sound reaches the
        // callback, while the UI moves to Processing immediately. Silence auto-stop has
        // already observed a long quiet tail and does not need this grace period.
        let tail = autoStopped ? 0 : recorder.manualStopTailDuration

        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
            guard let self = self else { return }
            guard self.state == .processing, self.sessionID == session else { return }

            let audio = self.recorder.stop()
            let minSamples = Int(0.12 * Double(self.config.sampleRate))
            let minRMS = self.config.minTranscribeRms

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
                    Log.write("[dict] too short: samples=\(audio.count)")
                    self.trayDelegate?.notifyInfo("Recording too short.")
                    return
                }

                let rms = AudioRecorder.calculateRMS(audio)
                print("[audio] captured samples=\(audio.count) rms=\(String(format: "%.5f", rms))")
                Log.write("[dict] samples=\(audio.count) rms=\(String(format: "%.5f", rms)) device=\(self.recorder.captureDeviceName ?? "?")")

                if rms == 0 {
                    print("[audio] all-zero audio - microphone access likely blocked")
                    self.microphoneGranted = false
                    Log.write("[dict] all-zero audio — mic blocked")
                    self.trayDelegate?.notifyError("Microphone blocked. Enable in System Settings -> Privacy -> Microphone.")
                    DispatchQueue.main.async { self.openMicSettings() }
                    return
                }

                if Double(rms) < minRMS {
                    Log.write("[dict] no speech detected (rms below \(self.config.minTranscribeRms))")
                    self.trayDelegate?.notifyInfo("No speech detected. Speak louder or check microphone input.")
                    return
                }

                do {
                    // Snapshot the pipeline under the lock, then call out of it: a long
                    // request must not freeze menu actions that reload the config.
                    self.configLock.lock()
                    let cfg = self.config
                    let client = self.client
                    self.configLock.unlock()

                    guard let client = client else { throw STTError.missingKey }

                    let wav = WAVEncoder.encode(samples: audio, sampleRate: cfg.sampleRate)
                    let terms = self.vocabularyStore.getActiveVocabulary()
                    let started = Date()
                    let text = try client.transcribe(wav: wav, terms: terms,
                                                     timeout: cfg.sttTimeoutSeconds)
                    let elapsed = Date().timeIntervalSince(started)
                    print("[stt] \(String(format: "%.2f", elapsed))s chars=\(text.count)")
                    Log.write("[stt] \(String(format: "%.2f", elapsed))s chars=\(text.count)")

                    guard !text.isEmpty else {
                        Log.write("[dict] 豆包 returned empty text")
                        self.trayDelegate?.notifyInfo("No text recognized. Try speaking more clearly.")
                        return
                    }

                    self.deliver(text, session: session)
                } catch let error as STTError {
                    print("[stt] \(error.userMessage)")
                    Log.write("[stt] \(error.userMessage)")
                    self.trayDelegate?.notifyError(error.userMessage)
                } catch {
                    print("[stt] transcription failed: \(error)")
                    Log.write("[stt] transcription failed: \(error)")
                    self.trayDelegate?.notifyError("听写失败。检查网络和 API Key。")
                }
            }
        }
    }

    // MARK: - Delivery

    /// Put the transcript where the user was typing: restore focus if they wandered off,
    /// then paste. The clipboard is the floor — the text is never lost, whatever fails.
    private func deliver(_ text: String, session: Int) {
        DispatchQueue.main.async {
            // Stale check — must read sessionID on main thread
            guard self.sessionID == session else {
                Log.write("[insert] stale session (\(session) != \(self.sessionID)) — clipboard only")
                self.originApp = nil
                TextInserter.copyToClipboard(text)
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

            let restored = needsRestore
            let insertBlock = { [weak self] in
                guard let self = self else { return }
                // No editable text field at the cursor: skip the synthesized ⌘V (it would
                // only make macOS beep) and leave the text on the clipboard with a hint.
                if !TextInserter.focusedElementAcceptsText() {
                    TextInserter.copyToClipboard(text)
                    Log.write("[insert] no text field focused — clipboard only")
                    self.trayDelegate?.notifyInfo("没有可粘贴的文字输入框，文字已复制到剪贴板。")
                    return
                }
                let pasted = TextInserter.insert(text)
                Log.write("[insert] pasted=\(pasted) chars=\(text.count) target=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") restored=\(restored)")
                guard !pasted else { return }

                // The only reason a paste fails is a missing Accessibility grant, and it
                // is worth interrupting for: without it every dictation silently ends in
                // a manual ⌘V.
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
    }

    // MARK: - Audio level & silence

    private func onAudioLevel(_ level: Float) {
        overlay.updateAudioLevel(level)

        // The auto-stop check reads shared state; hop to main so state/config are only
        // ever touched on the main thread.
        DispatchQueue.main.async { [weak self] in
            self?.considerSilenceAutoStop(level: level)
        }
    }

    private func considerSilenceAutoStop(level: Float) {
        guard state == .recording, config.silenceAutoStopEnabled else { return }

        let rms = level * 0.15
        let now = ProcessInfo.processInfo.systemUptime

        if Double(rms) >= config.silenceRmsThreshold {
            lastSpeechTime = now
        } else if lastSpeechTime > 0 && (now - lastSpeechTime) >= config.silenceAutoStopSeconds {
            lastSpeechTime = 0
            print("[audio] silence for \(config.silenceAutoStopSeconds)s, auto-stopping")
            stopDictation(autoStopped: true)
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
