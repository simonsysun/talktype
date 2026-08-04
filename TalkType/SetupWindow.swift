import Cocoa

/// Setup window. One page, in the order things have to happen: choose the speech engine,
/// configure it (download the local model, or point the cloud engine at a provider),
/// then the two system permissions macOS will not grant on our behalf.
///
/// It opens by itself when something is missing, and from the menu bar afterwards.
final class SetupWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var installTask: Process?

    // Engine choice
    private let enginePopup = NSPopUpButton()

    // Local engine
    private let engineStatus = NSTextField(labelWithString: "")
    private let engineButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let logScroll = NSScrollView()
    private let logView = NSTextView()
    private let spinner = NSProgressIndicator()

    // Cloud engine
    private let cloudStatus = NSTextField(labelWithString: "")
    private let providerPopup = NSPopUpButton()
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyButton = NSButton()
    private let detectLabel = NSTextField(labelWithString: "")
    private var cloudRows: [NSView] = []

    // Polish
    private let polishStatus = NSTextField(labelWithString: "")
    private let polishButton = NSButton()

    // Permissions
    private let micStatus = NSTextField(labelWithString: "")
    private let micButton = NSButton()
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton()

    private var refreshTimer: Timer?
    private var installOutputBuffer = ""

    /// Live config; the app reads engine/provider/model choices out of here.
    var config: AppConfig = AppConfig()
    /// Called when engine/provider/model/URL/key changes so the app can persist and
    /// rebuild the dictation pipeline (start/stop the sidecar, reload the cloud client).
    var onConfigChanged: ((AppConfig) -> Void)?
    /// Called when the local engine finishes installing, so the app can start the sidecar.
    var onEngineInstalled: (() -> Void)?
    /// Called when the user asks to enter a Groq key; the app owns that dialog already.
    var onEditKey: (() -> Void)?
    /// Called to clear a stale Accessibility grant and ask again; the app owns that dialog.
    var onRepairAccessibility: (() -> Void)?

    // MARK: - Presentation

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refresh()
            return
        }
        build()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()

        // The two permissions are granted outside the app, so poll while it is open
        // rather than making people come back and reopen it to see the change.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window = nil
    }

    // MARK: - Layout

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "TalkType Setup"
        w.delegate = self
        w.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)
        root.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Engine choice
        root.addArrangedSubview(heading("Speech engine",
            "Local runs Qwen3-ASR on this Mac (voice never leaves, ~4 GB once). "
            + "Cloud sends the audio to a provider — faster to start, costs a little."))

        enginePopup.addItems(withTitles: [
            "Local — Qwen3-ASR on this Mac",
            "Cloud — send audio to a provider",
        ])
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        enginePopup.setContentHuggingPriority(.required, for: .horizontal)

        let engineRow = NSStackView(views: [enginePopup, engineStatus, spinner, engineButton])
        engineRow.orientation = .horizontal
        engineRow.spacing = 10
        engineRow.alignment = .centerY
        engineRow.translatesAutoresizingMaskIntoConstraints = false
        engineRow.widthAnchor.constraint(equalToConstant: 468).isActive = true
        engineStatus.setContentHuggingPriority(.required, for: .horizontal)
        root.addArrangedSubview(engineRow)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        // Download progress (local weights)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.isHidden = true
        let progressRow = NSStackView(views: [progressBar, progressLabel])
        progressRow.orientation = .horizontal
        progressRow.spacing = 10
        progressRow.alignment = .centerY
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        progressRow.widthAnchor.constraint(equalToConstant: 468).isActive = true
        root.addArrangedSubview(progressRow)

        logView.isEditable = false
        logView.drawsBackground = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.isHidden = true
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        logScroll.widthAnchor.constraint(equalToConstant: 468).isActive = true
        root.addArrangedSubview(logScroll)

        // MARK: Cloud configuration
        providerPopup.addItems(withTitles: CloudProvider.allCases.map { $0.profile.name })
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.setContentHuggingPriority(.required, for: .horizontal)
        providerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        cloudRows.append(formRow(label: "Provider", view: providerPopup))

        baseURLField.placeholderString = "https://… (OpenAI-compatible base URL)"
        baseURLField.target = self
        baseURLField.action = #selector(baseURLEdited)
        cloudRows.append(formRow(label: "API base URL", view: baseURLField))

        modelField.placeholderString = "model id"
        modelField.target = self
        modelField.action = #selector(modelEdited)
        cloudRows.append(formRow(label: "Model", view: modelField))

        let keyStack = NSStackView(views: [keyField, keyButton])
        keyStack.orientation = .horizontal
        keyStack.spacing = 8
        keyStack.alignment = .centerY
        keyStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        keyField.placeholderString = "API key"
        keyButton.bezelStyle = .rounded
        keyButton.target = self
        keyButton.action = #selector(saveKey)
        cloudRows.append(formRow(label: "API key", view: keyStack))

        detectLabel.font = .systemFont(ofSize: 11)
        detectLabel.textColor = .secondaryLabelColor
        cloudRows.append(formRow(label: "", view: detectLabel))

        let cloudStatusRow = NSStackView(views: [cloudStatus])
        cloudStatusRow.orientation = .horizontal
        cloudStatusRow.alignment = .centerY
        cloudStatusRow.translatesAutoresizingMaskIntoConstraints = false
        cloudStatusRow.widthAnchor.constraint(equalToConstant: 468).isActive = true
        cloudRows.append(cloudStatusRow)

        for row in cloudRows {
            root.addArrangedSubview(row)
        }

        root.addArrangedSubview(separator())
        root.addArrangedSubview(heading("Cloud polish  (optional)",
            "Tidies filler words and punctuation through Groq. Sends the transcript only, never audio. "
            + "Leave it off and everything stays here."))
        root.addArrangedSubview(row(status: polishStatus, button: polishButton,
                                    action: #selector(editKey)))

        root.addArrangedSubview(separator())
        root.addArrangedSubview(heading("Permissions",
            "macOS asks for these itself; TalkType cannot grant them."))
        root.addArrangedSubview(row(status: micStatus, button: micButton,
                                    action: #selector(openMicSettings)))
        root.addArrangedSubview(row(status: axStatus, button: axButton,
                                    action: #selector(openAXSettings)))

        let hint = NSTextField(wrappingLabelWithString:
            "When the engine says ready, press ⌘⇧Space anywhere and start talking.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        root.addArrangedSubview(hint)

        w.contentView = NSView()
        w.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
        ])
        w.setContentSize(root.fittingSize)
        window = w
    }

    private func heading(_ title: String, _ detail: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(t)

        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.preferredMaxLayoutWidth = 468
        stack.addArrangedSubview(d)
        return stack
    }

    /// Label on the left, control on the right, every row the same width.
    private func formRow(label: String, view: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12)
        labelField.textColor = .secondaryLabelColor
        labelField.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [labelField, view])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 468).isActive = true
        if let field = view as? NSTextField {
            field.setContentHuggingPriority(.init(1), for: .horizontal)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        return stack
    }

    /// Status on the left, action on the right.
    private func row(status: NSTextField, button: NSButton, action: Selector) -> NSView {
        status.font = .systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [status, spacer, button])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        status.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 468).isActive = true
        return stack
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 468).isActive = true
        return line
    }

    // MARK: - State

    func refresh() {
        let installing = installTask?.isRunning ?? false

        enginePopup.selectItem(at: config.asrEngine == .cloud ? 1 : 0)

        switch SidecarManager.installState() {
        case .ready:
            engineStatus.stringValue = config.asrEngine == .cloud ? "Installed (not running)" : "Installed"
            engineStatus.textColor = .systemGreen
            engineButton.title = "Reinstall"
            engineButton.isEnabled = !installing
        case .missing:
            engineStatus.stringValue = installing ? "Installing…" : "Not installed"
            engineStatus.textColor = installing ? .secondaryLabelColor : .systemOrange
            engineButton.title = "Install"
            engineButton.isEnabled = !installing
        }

        // Cloud section
        let isCloud = config.asrEngine == .cloud
        for row in cloudRows { row.isHidden = !isCloud }
        providerPopup.selectItem(at: CloudProvider.allCases.firstIndex(of: config.cloudProvider) ?? 0)
        baseURLField.stringValue = config.cloudBaseURL
        modelField.stringValue = config.cloudModel
        detectLabel.stringValue = detectedProviderText()

        let key = CloudKeyStore.apiKey(for: config.cloudProvider)
        if let key = key {
            cloudStatus.stringValue = "Key saved (\(Self.masked(key)))"
            cloudStatus.textColor = .systemGreen
            keyButton.title = "Replace"
            keyField.stringValue = ""
        } else {
            cloudStatus.stringValue = "No key saved"
            cloudStatus.textColor = .secondaryLabelColor
            keyButton.title = "Save"
        }

        if TextRefiner.apiKey() != nil {
            polishStatus.stringValue = "Groq key saved"
            polishStatus.textColor = .systemGreen
            polishButton.title = "Change"
        } else {
            polishStatus.stringValue = "Not configured"
            polishStatus.textColor = .secondaryLabelColor
            polishButton.title = "Add Groq key"
        }

        let mic = AVCaptureDeviceAuthorization.isGranted
        micStatus.stringValue = mic ? "Microphone: granted" : "Microphone: not granted"
        micStatus.textColor = mic ? .systemGreen : .systemOrange
        micButton.title = "Open Settings"
        micButton.isHidden = mic

        let ax = TextInserter.accessibilityGranted(prompt: false)
        axStatus.stringValue = ax
            ? "Accessibility: granted"
            : "Accessibility: not granted — TalkType can only copy, not paste"
        axStatus.textColor = ax ? .systemGreen : .systemOrange
        axButton.title = "Fix"
        axButton.isHidden = ax
    }

    private func detectedProviderText() -> String {
        let detected = CloudProvider.detect(baseURL: baseURLField.stringValue)
        if detected == .custom {
            return "Custom base URL — requests go to it as-is."
        }
        return "Detected: \(detected.profile.name)"
    }

    private static func masked(_ key: String) -> String {
        guard key.count > 10 else { return "•••" }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }

    // MARK: - Actions

    @objc private func engineChanged() {
        let engine: ASREngine = enginePopup.indexOfSelectedItem == 1 ? .cloud : .local
        guard engine != config.asrEngine else { return }
        config.asrEngine = engine
        onConfigChanged?(config)
        refresh()
    }

    @objc private func providerChanged() {
        let index = providerPopup.indexOfSelectedItem
        guard CloudProvider.allCases.indices.contains(index) else { return }
        let provider = CloudProvider.allCases[index]
        guard provider != config.cloudProvider else { return }
        config.cloudProvider = provider
        config.cloudBaseURL = provider.profile.defaultBaseURL
        config.cloudModel = provider.profile.defaultModel
        onConfigChanged?(config)
        refresh()
    }

    @objc private func baseURLEdited() {
        let url = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.cloudBaseURL = url
        // Auto-detect: a pasted official/OpenRouter/DashScope URL flips the provider and
        // fills the model id, unless the user already typed their own.
        let detected = CloudProvider.detect(baseURL: url)
        if detected != .custom, detected != config.cloudProvider {
            config.cloudProvider = detected
            config.cloudModel = detected.profile.defaultModel
            providerPopup.selectItem(at: CloudProvider.allCases.firstIndex(of: detected) ?? 0)
        }
        onConfigChanged?(config)
        refresh()
    }

    @objc private func modelEdited() {
        config.cloudModel = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfigChanged?(config)
    }

    @objc private func saveKey() {
        let provider = config.cloudProvider
        if let existing = CloudKeyStore.apiKey(for: provider) {
            let alert = NSAlert()
            alert.messageText = "\(provider.profile.name) API key"
            alert.informativeText = "Current key: \(Self.masked(existing))\n\n"
                + "Only the recorded audio is sent to \(provider.profile.name)."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Remove")
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertThirdButtonReturn:
                CloudKeyStore.deleteAPIKey(for: provider)
                onConfigChanged?(config)
                refresh()
                return
            default:
                refresh()
                return
            }
        }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyButton.isEnabled = false
        keyButton.title = "Verifying…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let valid = CloudASRClient.validate(apiKey: key, baseURL: self?.config.cloudBaseURL ?? "")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.keyButton.isEnabled = true
                self.keyButton.title = "Save"
                guard valid else {
                    self.cloudStatus.stringValue = "That key was rejected by \(self.config.cloudProvider.profile.name)."
                    self.cloudStatus.textColor = .systemOrange
                    return
                }
                guard CloudKeyStore.storeAPIKey(key, for: self.config.cloudProvider) else {
                    self.cloudStatus.stringValue = "Could not write the key to the keychain."
                    self.cloudStatus.textColor = .systemOrange
                    return
                }
                self.onConfigChanged?(self.config)
                self.refresh()
            }
        }
    }

    @objc private func editKey() { onEditKey?() }
    @objc private func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
    @objc private func openAXSettings() { onRepairAccessibility?() }
    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Local engine install

    @objc private func installEngine() {
        guard installTask?.isRunning != true else { return }
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            appendLog("Cannot find install.sh inside the app bundle.\n")
            return
        }

        logView.string = ""
        logScroll.isHidden = false
        spinner.startAnimation(nil)
        progressBar.isHidden = true
        progressLabel.isHidden = true
        installOutputBuffer = ""
        refresh()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        proc.currentDirectoryURL = script.deletingLastPathComponent()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consumeInstallOutput(text) }
        }

        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.spinner.stopAnimation(nil)
                self.progressBar.isHidden = true
                self.progressLabel.isHidden = true
                self.installTask = nil
                if finished.terminationStatus == 0 {
                    self.appendLog("\nDone. Starting the engine…\n")
                    self.onEngineInstalled?()
                } else {
                    self.appendLog("\nInstall failed (exit \(finished.terminationStatus)).\n")
                }
                self.refresh()
            }
        }

        do {
            try proc.run()
            installTask = proc
        } catch {
            spinner.stopAnimation(nil)
            appendLog("Could not start the installer: \(error.localizedDescription)\n")
            refresh()
        }
    }

    /// install.sh emits `[progress] NN` while the weights download; everything else goes
    /// to the log. Lines can arrive split across reads, so keep a buffer.
    private func consumeInstallOutput(_ chunk: String) {
        installOutputBuffer += chunk
        var lines: [String] = []
        while let newline = installOutputBuffer.firstIndex(of: "\n") {
            lines.append(String(installOutputBuffer[..<newline]))
            installOutputBuffer.removeSubrange(...newline)
        }
        for line in lines {
            if line.hasPrefix("[progress] ") {
                guard let pct = Int(line.dropFirst("[progress] ".count)) else { continue }
                progressBar.isHidden = false
                progressLabel.isHidden = false
                progressBar.doubleValue = Double(pct)
                progressLabel.stringValue = "Downloading model weights… \(pct)%"
                engineStatus.stringValue = "Downloading… \(pct)%"
            } else if !line.isEmpty {
                appendLog(line + "\n")
            }
        }
    }

    private func appendLog(_ text: String) {
        logView.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        logView.scrollToEndOfDocument(nil)
    }
}

// MARK: - Microphone authorisation

import AVFoundation

enum AVCaptureDeviceAuthorization {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
