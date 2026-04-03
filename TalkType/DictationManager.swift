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
            model: config.asrModel,
            timeout: config.asrTimeoutSeconds
        )

        self.recorder = AudioRecorder(
            sampleRate: config.sampleRate,
            onLevel: nil
        )
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

    // MARK: - Model change

    func updateModel(_ model: String) {
        transcriberLock.lock()
        transcriber.model = model
        transcriberLock.unlock()
        print("[asr] model switched to \(model)")
    }

    func reloadConfig(_ newConfig: AppConfig) {
        config = newConfig
        transcriberLock.lock()
        transcriber.model = newConfig.asrModel
        transcriber.timeout = newConfig.asrTimeoutSeconds
        transcriberLock.unlock()
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
                do {
                    text = try self.transcriber.transcribe(audio: audio, sampleRate: self.config.sampleRate, vocabularyHints: hints)
                } catch {
                    self.transcriberLock.unlock()
                    throw error
                }
                self.transcriberLock.unlock()

                let vocabEntries = self.vocabularyStore.listEntries()
                let processed = PostProcessor.postProcess(text: text, vocabEntries: vocabEntries)

                if PostProcessor.isLikelyHallucination(processed, audioRMS: rms, vocabEntries: vocabEntries) {
                    print("[asr] hallucination detected: \"\(processed)\" with rms=\(String(format: "%.5f", rms))")
                    self.trayDelegate?.notifyInfo("No speech detected (transcription discarded).")
                    return
                }

                guard !processed.isEmpty else {
                    self.trayDelegate?.notifyInfo("No text recognized. Try speaking more clearly.")
                    return
                }

                DispatchQueue.main.async {
                    // Stale check — must read sessionID on main thread
                    guard self.sessionID == session else {
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
                    let insertBlock = { [weak self] in
                        guard let self = self else { return }
                        let hasAccessibility = TextInserter.accessibilityGranted(prompt: false)
                        if hasAccessibility {
                            TextInserter.typeText(processed)
                        } else {
                            TextInserter.copyToClipboard(processed)
                            if !self.clipboardHintShown {
                                self.trayDelegate?.notifyInfo("Text copied to clipboard. Grant Accessibility for direct typing.")
                                self.clipboardHintShown = true
                            }
                            print("[clipboard] \(processed)")
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
}
