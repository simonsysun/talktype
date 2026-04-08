import UIKit
import AVFoundation

class KeyboardViewController: UIInputViewController {

    // MARK: - State

    enum DictationState {
        case idle
        case recording
        case processing
        case error(String)
    }

    private var state: DictationState = .idle {
        didSet { animateStateChange() }
    }

    // MARK: - Components

    private var audioRecorder: AudioRecorder?
    private var transcriber: Transcriber?
    private var transcriptionTask: Task<Void, Never>?
    private var errorDismissTask: DispatchWorkItem?
    private var autoStopTimer: DispatchWorkItem?

    // MARK: - UI (minimal: 1 button, 1 ring, 1 label, 1 globe)

    private let micButton = UIButton(type: .custom)
    private let statusLabel = UILabel()
    private let ringLayer = CAShapeLayer()
    private let spinnerLayer = CAShapeLayer()
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    // MARK: - Layout

    private let buttonSize: CGFloat = 72
    private let keyboardHeight: CGFloat = 160
    private let maxRecordingSeconds: TimeInterval = 120

    // MARK: - Cached configs

    private let idleSymbolConfig = UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)
    private let recordingSymbolConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        feedbackGenerator.prepare()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadConfig()
        audioRecorder = AudioRecorder(sampleRate: 16000) { [weak self] level in
            DispatchQueue.main.async { self?.updateRingLevel(level) }
        }
        audioRecorder?.prepare()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        transcriptionTask?.cancel()
        transcriptionTask = nil
        autoStopTimer?.cancel()
        if case .recording = state {
            _ = audioRecorder?.stop()
        }
        audioRecorder?.shutdown()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func reloadConfig() {
        let config = ConfigManager.load()
        transcriber = Transcriber(
            provider: ASRProvider(rawValue: config.asrProvider) ?? .openai,
            model: config.asrModel,
            timeout: config.asrTimeoutSeconds
        )
    }

    // MARK: - UI Construction

    private func buildUI() {
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        // Mic button
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: idleSymbolConfig), for: .normal)
        micButton.tintColor = .label
        micButton.backgroundColor = .tertiarySystemBackground
        micButton.layer.cornerRadius = buttonSize / 2
        micButton.layer.shadowColor = UIColor.black.cgColor
        micButton.layer.shadowOffset = .init(width: 0, height: 1)
        micButton.layer.shadowRadius = 4
        micButton.layer.shadowOpacity = 0.08
        micButton.addTarget(self, action: #selector(micDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.addTarget(self, action: #selector(micUp), for: [.touchUpOutside, .touchCancel])
        view.addSubview(micButton)

        // Ring layer (audio level + spinner)
        let ringPath = UIBezierPath(
            arcCenter: .init(x: buttonSize / 2, y: buttonSize / 2),
            radius: buttonSize / 2 + 5,
            startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
        )
        ringLayer.path = ringPath.cgPath
        ringLayer.fillColor = nil
        ringLayer.strokeColor = UIColor.systemRed.withAlphaComponent(0.6).cgColor
        ringLayer.lineWidth = 2.5
        ringLayer.lineCap = .round
        ringLayer.strokeEnd = 0
        micButton.layer.addSublayer(ringLayer)

        // Spinner arc (processing)
        spinnerLayer.path = ringPath.cgPath
        spinnerLayer.fillColor = nil
        spinnerLayer.strokeColor = UIColor.tintColor.cgColor
        spinnerLayer.lineWidth = 2.5
        spinnerLayer.lineCap = .round
        spinnerLayer.strokeStart = 0
        spinnerLayer.strokeEnd = 0.25
        spinnerLayer.opacity = 0
        micButton.layer.addSublayer(spinnerLayer)

        // Status label
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.alpha = 0
        statusLabel.numberOfLines = 2
        view.addSubview(statusLabel)

        // Globe button
        let globe = UIButton(type: .system)
        globe.translatesAutoresizingMaskIntoConstraints = false
        globe.setImage(UIImage(systemName: "globe", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)), for: .normal)
        globe.tintColor = .secondaryLabel
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        view.addSubview(globe)

        NSLayoutConstraint.activate([
            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -6),
            micButton.widthAnchor.constraint(equalToConstant: buttonSize),
            micButton.heightAnchor.constraint(equalToConstant: buttonSize),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 8),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),

            globe.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            globe.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            globe.widthAnchor.constraint(equalToConstant: 40),
            globe.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: - Touch Feedback

    @objc private func micDown() {
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseIn) {
            self.micButton.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }
    }

    @objc private func micUp() {
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: []) {
            self.micButton.transform = .identity
        }
    }

    @objc private func micTapped() {
        micUp()
        switch state {
        case .idle, .error: startRecording()
        case .recording: stopAndTranscribe()
        case .processing: break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        feedbackGenerator.impactOccurred()

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, granted else {
                    self?.state = .error("Microphone access required. Enable in Settings.")
                    return
                }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .default)
                    try session.setActive(true)
                    try self.audioRecorder?.start()
                    self.state = .recording

                    self.autoStopTimer?.cancel()
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self, case .recording = self.state else { return }
                        self.stopAndTranscribe()
                    }
                    self.autoStopTimer = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.maxRecordingSeconds, execute: timer)
                } catch {
                    self.state = .error("Recording failed.")
                }
            }
        }
    }

    private func stopAndTranscribe() {
        feedbackGenerator.impactOccurred()
        autoStopTimer?.cancel()

        guard let audio = audioRecorder?.stop(), !audio.isEmpty else {
            state = .idle
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .processing

        let vocabStore = VocabularyStore()
        let hints = vocabStore.getActiveVocabulary()
        let vocabEntries = vocabStore.listEntries()

        transcriptionTask?.cancel()
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let transcriber else {
                    state = .error("No API key. Open TalkType app.")
                    return
                }

                let rms = AudioRecorder.calculateRMS(audio)
                let config = ConfigManager.load()
                if rms < Float(config.minTranscribeRms) { state = .idle; return }

                var text = try await transcriber.transcribeAsync(
                    audio: audio,
                    vocabularyHints: hints.isEmpty ? nil : hints
                )
                guard !Task.isCancelled else { return }

                if PostProcessor.isLikelyHallucination(text, audioRMS: rms, vocabEntries: vocabEntries) {
                    state = .idle; return
                }
                text = PostProcessor.postProcess(text: text, vocabEntries: vocabEntries)
                guard !Task.isCancelled else { return }

                if !text.isEmpty { textDocumentProxy.insertText(text) }
                state = .idle
            } catch {
                if !Task.isCancelled { state = .error("Transcription failed.") }
            }
        }
    }

    // MARK: - State Animations

    private func animateStateChange() {
        switch state {
        case .idle:      toIdle()
        case .recording: toRecording()
        case .processing: toProcessing()
        case .error(let msg): toError(msg)
        }
    }

    private func toIdle() {
        stopSpinner()

        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: []) {
            self.micButton.backgroundColor = .tertiarySystemBackground
            self.micButton.tintColor = .label
            self.micButton.transform = .identity
            self.statusLabel.alpha = 0
        }

        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: idleSymbolConfig), for: .normal)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        ringLayer.strokeEnd = 0
        ringLayer.opacity = 0
        CATransaction.commit()
    }

    private func toRecording() {
        stopSpinner()
        errorDismissTask?.cancel()

        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.65, initialSpringVelocity: 0.3, options: []) {
            self.micButton.backgroundColor = UIColor.systemRed
            self.micButton.tintColor = .white
            self.micButton.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
            self.statusLabel.alpha = 0
        }

        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: recordingSymbolConfig), for: .normal)

        ringLayer.strokeColor = UIColor.systemRed.withAlphaComponent(0.5).cgColor
        ringLayer.opacity = 1
    }

    private func toProcessing() {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: []) {
            self.micButton.backgroundColor = UIColor.tintColor
            self.micButton.tintColor = .white
            self.micButton.transform = .identity
        }

        micButton.setImage(UIImage(systemName: "waveform", withConfiguration: idleSymbolConfig), for: .normal)

        // Hide level ring
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.strokeEnd = 0
        ringLayer.opacity = 0
        CATransaction.commit()

        // Start spinner
        startSpinner()
    }

    private func toError(_ message: String) {
        toIdle()
        statusLabel.text = message
        UIView.animate(withDuration: 0.2) { self.statusLabel.alpha = 1 }

        errorDismissTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.statusLabel.alpha = 0 }
        }
        errorDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    // MARK: - Audio Level Ring

    private func updateRingLevel(_ level: Float) {
        guard case .recording = state else { return }
        let clamped = min(1.0, level * 1.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.strokeEnd = CGFloat(0.05 + clamped * 0.95)
        CATransaction.commit()
    }

    // MARK: - Spinner

    private func startSpinner() {
        spinnerLayer.opacity = 1
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 0.9
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        spinnerLayer.add(rotation, forKey: "spin")
    }

    private func stopSpinner() {
        spinnerLayer.removeAllAnimations()
        spinnerLayer.opacity = 0
    }

    // MARK: - Trait Changes

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if case .idle = state {
            micButton.layer.shadowColor = UIColor.black.cgColor
        }
    }
}
