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
        didSet { updateUI() }
    }

    // MARK: - Components

    private var audioRecorder: AudioRecorder?
    private var transcriber: Transcriber?
    private var transcriptionTask: Task<Void, Never>?
    private var errorDismissTask: DispatchWorkItem?
    private var autoStopTimer: DispatchWorkItem?

    // MARK: - UI

    private let micButton = UIButton(type: .custom)
    private let statusLabel = UILabel()
    private let ringLayer = CAShapeLayer()
    private var levelBars: [CALayer] = []
    private var processingDots: [CALayer] = []
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Constants

    private let buttonSize: CGFloat = 88
    private let barCount = 9
    private let dotCount = 3
    private let keyboardHeight: CGFloat = 200
    private let maxRecordingSeconds: TimeInterval = 120

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.translatesAutoresizingMaskIntoConstraints = false
        setupLayout()
        setupTranscriber()
        feedbackGenerator.prepare()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setupTranscriber()
        audioRecorder = AudioRecorder(sampleRate: 16000) { [weak self] level in
            DispatchQueue.main.async { self?.updateLevelBars(level) }
        }
        audioRecorder?.prepare()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if case .recording = state {
            _ = audioRecorder?.stop()
        }
        audioRecorder?.shutdown()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Setup

    private func setupTranscriber() {
        let config = ConfigManager.load()
        transcriber = Transcriber(
            provider: ASRProvider(rawValue: config.asrProvider) ?? .openai,
            model: config.asrModel,
            timeout: config.asrTimeoutSeconds
        )
    }

    private func setupLayout() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let heightConstraint = container.heightAnchor.constraint(equalToConstant: keyboardHeight)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heightConstraint,
        ])

        // Mic button
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        container.addSubview(micButton)

        NSLayoutConstraint.activate([
            micButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
            micButton.widthAnchor.constraint(equalToConstant: buttonSize),
            micButton.heightAnchor.constraint(equalToConstant: buttonSize),
        ])

        configureMicButton()
        setupRingLayer()
        setupLevelBars()
        setupProcessingDots()

        // Status label (for errors)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.alpha = 0
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        // Globe button (switch keyboards)
        let globeButton = UIButton(type: .system)
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        let globeImage = UIImage(systemName: "globe")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        )
        globeButton.setImage(globeImage, for: .normal)
        globeButton.tintColor = .label
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        container.addSubview(globeButton)

        NSLayoutConstraint.activate([
            globeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            globeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            globeButton.widthAnchor.constraint(equalToConstant: 44),
            globeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureMicButton() {
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        let micImage = UIImage(systemName: "mic.fill", withConfiguration: config)
        micButton.setImage(micImage, for: .normal)
        micButton.tintColor = .label
        micButton.backgroundColor = .secondarySystemBackground
        micButton.layer.cornerRadius = buttonSize / 2
        micButton.layer.borderWidth = 2
        micButton.layer.borderColor = UIColor.separator.cgColor

        micButton.layer.shadowColor = UIColor.black.cgColor
        micButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        micButton.layer.shadowRadius = 8
        micButton.layer.shadowOpacity = 0.1
    }

    private func setupRingLayer() {
        let ringPath = UIBezierPath(
            arcCenter: CGPoint(x: buttonSize / 2, y: buttonSize / 2),
            radius: buttonSize / 2 + 6,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        ringLayer.path = ringPath.cgPath
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.systemRed.cgColor
        ringLayer.lineWidth = 3
        ringLayer.opacity = 0
        micButton.layer.addSublayer(ringLayer)
    }

    private func setupLevelBars() {
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 4
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (buttonSize - totalWidth) / 2

        for i in 0..<barCount {
            let bar = CALayer()
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            bar.frame = CGRect(x: x, y: buttonSize / 2 - 2, width: barWidth, height: 4)
            bar.backgroundColor = UIColor.systemRed.cgColor
            bar.cornerRadius = barWidth / 2
            bar.opacity = 0
            micButton.layer.addSublayer(bar)
            levelBars.append(bar)
        }
    }

    private func setupProcessingDots() {
        let dotSize: CGFloat = 6
        let dotSpacing: CGFloat = 10
        let totalWidth = CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * dotSpacing
        let startX = (buttonSize - totalWidth) / 2

        for i in 0..<dotCount {
            let dot = CALayer()
            let x = startX + CGFloat(i) * (dotSize + dotSpacing)
            dot.frame = CGRect(x: x, y: buttonSize / 2 - dotSize / 2, width: dotSize, height: dotSize)
            dot.backgroundColor = UIColor.systemBlue.cgColor
            dot.cornerRadius = dotSize / 2
            dot.opacity = 0
            micButton.layer.addSublayer(dot)
            processingDots.append(dot)
        }
    }

    // MARK: - Actions

    @objc private func micTapped() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .processing:
            break
        }
    }

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

                    // Auto-stop after max duration to prevent OOM in extension
                    self.autoStopTimer?.cancel()
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self, case .recording = self.state else { return }
                        self.stopAndTranscribe()
                    }
                    self.autoStopTimer = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.maxRecordingSeconds, execute: timer)
                } catch {
                    self.state = .error("Could not start recording: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopAndTranscribe() {
        feedbackGenerator.impactOccurred()

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
                    state = .error("No API key configured. Open TalkType app to set up.")
                    return
                }

                let rms = AudioRecorder.calculateRMS(audio)
                let config = ConfigManager.load()
                if rms < Float(config.minTranscribeRms) {
                    state = .idle
                    return
                }

                var text = try await transcriber.transcribeAsync(
                    audio: audio,
                    vocabularyHints: hints.isEmpty ? nil : hints
                )

                guard !Task.isCancelled else { return }

                if PostProcessor.isLikelyHallucination(text, audioRMS: rms, vocabEntries: vocabEntries) {
                    state = .idle
                    return
                }

                text = PostProcessor.postProcess(text: text, vocabEntries: vocabEntries)

                guard !Task.isCancelled else { return }

                if !text.isEmpty {
                    textDocumentProxy.insertText(text)
                }
                state = .idle
            } catch {
                if !Task.isCancelled {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - UI Updates

    private func updateUI() {
        switch state {
        case .idle:
            showIdleState()
        case .recording:
            showRecordingState()
        case .processing:
            showProcessingState()
        case .error(let message):
            showError(message)
        }
    }

    private func showIdleState() {
        micButton.tintColor = .label
        micButton.backgroundColor = .secondarySystemBackground
        micButton.layer.borderColor = UIColor.separator.cgColor

        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)

        // Hide ring
        ringLayer.removeAllAnimations()
        ringLayer.opacity = 0

        // Hide bars
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelBars.forEach { $0.opacity = 0 }
        CATransaction.commit()

        // Hide dots
        processingDots.forEach {
            $0.removeAllAnimations()
            $0.opacity = 0
        }

        statusLabel.alpha = 0
    }

    private func showRecordingState() {
        micButton.tintColor = .white
        micButton.backgroundColor = .systemRed
        micButton.layer.borderColor = UIColor.systemRed.cgColor

        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)

        // Pulsing ring
        ringLayer.opacity = 1
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ringLayer.add(pulse, forKey: "pulse")

        // Show bars
        levelBars.forEach { $0.opacity = 1 }

        // Hide dots
        processingDots.forEach { $0.opacity = 0 }

        statusLabel.alpha = 0
    }

    private func showProcessingState() {
        micButton.tintColor = .white
        micButton.backgroundColor = .systemBlue
        micButton.layer.borderColor = UIColor.systemBlue.cgColor

        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        micButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)

        // Hide ring and bars
        ringLayer.removeAllAnimations()
        ringLayer.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelBars.forEach { $0.opacity = 0 }
        CATransaction.commit()

        // Animated dots
        for (i, dot) in processingDots.enumerated() {
            dot.opacity = 1
            let bounce = CABasicAnimation(keyPath: "transform.scale")
            bounce.fromValue = 0.5
            bounce.toValue = 1.2
            bounce.duration = 0.4
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.beginTime = CACurrentMediaTime() + Double(i) * 0.15
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(bounce, forKey: "bounce")
        }
    }

    private func showError(_ message: String) {
        showIdleState()
        statusLabel.text = message
        statusLabel.alpha = 1

        errorDismissTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) {
                self?.statusLabel.alpha = 0
            }
        }
        errorDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    private func updateLevelBars(_ level: Float) {
        guard case .recording = state else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let center = barCount / 2
        for (i, bar) in levelBars.enumerated() {
            let distance = abs(i - center)
            let dampening = 1.0 - Float(distance) / Float(center + 1) * 0.6
            let barLevel = level * dampening
            let minHeight: CGFloat = 4
            let maxHeight: CGFloat = 30
            let height = minHeight + CGFloat(barLevel) * (maxHeight - minHeight)
            bar.frame = CGRect(
                x: bar.frame.origin.x,
                y: buttonSize / 2 - height / 2,
                width: bar.frame.width,
                height: height
            )
        }

        CATransaction.commit()
    }

    // MARK: - Trait Changes

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        micButton.layer.borderColor = UIColor.separator.cgColor
        if case .recording = state {
            micButton.layer.borderColor = UIColor.systemRed.cgColor
        }
        if case .processing = state {
            micButton.layer.borderColor = UIColor.systemBlue.cgColor
        }
    }
}
