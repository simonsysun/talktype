import Cocoa

/// Setup window. One page, in the order things have to happen: choose the speech engine,
/// configure it (install the local model, or add the OpenRouter key), then the two
/// system permissions macOS will not grant on our behalf.
///
/// It opens by itself when something is missing, and from the menu bar afterwards.
final class SetupWindow: NSObject, NSWindowDelegate {

    /// Width every row is laid out to. Rows used to hardcode this number in nine places,
    /// which is how one of them ended up too narrow for its own buttons. Wide enough here
    /// that a base URL and a key are both readable without scrolling.
    private static let contentWidth: CGFloat = 548

    private var window: NSWindow?
    private var installTask: Process?

    // Engine choice
    private let enginePopup = NSPopUpButton()

    // Local engine
    private let engineStatus = NSTextField(labelWithString: "")
    private let engineButton = NSButton()
    private let pauseButton = NSButton()
    private let deleteEngineButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let logScroll = NSScrollView()
    private let logView = NSTextView()
    private let spinner = NSProgressIndicator()

    // Cloud engine
    private let cloudStatus = NSTextField(labelWithString: "")
    private let keyField = SecretField()
    private let keyButton = NSButton()
    private let keyRemoveButton = NSButton()
    private var cloudRows: [NSView] = []

    // Permissions
    private let micStatus = NSTextField(labelWithString: "")
    private let micButton = NSButton()
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton()

    private var refreshTimer: Timer?
    private var installOutputBuffer = ""
    /// Set when the user pauses or discards, so the installer exiting non-zero is reported
    /// as what it is rather than as a failure.
    private var userStoppedInstall = false
    /// Weights are removed after the installer has actually exited, never underneath it.
    private var deleteWeightsAfterStop = false
    private var verifyingCloudKey = false

    /// Live config; the app reads engine/provider/model choices out of here.
    var config: AppConfig = AppConfig()
    /// Called when engine/provider/model/URL/key changes so the app can persist and
    /// rebuild the dictation pipeline (start/stop the sidecar, reload the cloud client).
    var onConfigChanged: ((AppConfig) -> Void)?
    /// Called when the local engine finishes installing, so the app can start the sidecar.
    var onEngineInstalled: (() -> Void)?
    /// Called after the user confirms deleting the local engine; the app stops the sidecar
    /// and removes the ~4 GB of weights.
    var onEngineDeleted: (() -> Void)?
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
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 52, height: 460),
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
            "Cloud via OpenRouter, or Local on this Mac. Offline, Local takes over."))

        // The window is rebuilt each time it opens (windowWillClose nils the window), so
        // clear first — addItems without removeAllItems would double the list on the
        // second open and silently shift which item is "Cloud".
        enginePopup.removeAllItems()
        enginePopup.addItems(withTitles: [
            "Local — Qwen3-ASR on this Mac",
            "Cloud — OpenRouter (Qwen3-ASR-Flash)",
        ])
        enginePopup.item(at: 0)?.representedObject = ASREngine.local.rawValue
        enginePopup.item(at: 1)?.representedObject = ASREngine.cloud.rawValue
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        enginePopup.setContentHuggingPriority(.required, for: .horizontal)

        // The engine picker gets a row to itself. Sharing one with the status and the
        // buttons is what left no room for "Reinstall" and clipped it to "Rei…".
        let pickerRow = NSStackView(views: [enginePopup, NSView()])
        pickerRow.orientation = .horizontal
        pickerRow.spacing = 10
        pickerRow.alignment = .centerY
        pickerRow.translatesAutoresizingMaskIntoConstraints = false
        pickerRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        root.addArrangedSubview(pickerRow)

        for button in [engineButton, pauseButton, deleteEngineButton] {
            button.bezelStyle = .rounded
            button.target = self
            // Buttons say what they do; a squeezed row must take space from the status
            // text, which can afford to wrap, never from a label that turns into "Rei…".
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        engineButton.action = #selector(installEngine)
        pauseButton.action = #selector(pauseInstall)
        pauseButton.isHidden = true
        deleteEngineButton.action = #selector(deleteEngine)
        deleteEngineButton.contentTintColor = .systemRed
        deleteEngineButton.isHidden = true

        engineStatus.setContentHuggingPriority(.init(1), for: .horizontal)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let engineRow = NSStackView(views: [
            engineStatus, spinner, statusSpacer, engineButton, pauseButton, deleteEngineButton,
        ])
        engineRow.orientation = .horizontal
        engineRow.spacing = 8
        engineRow.alignment = .centerY
        engineRow.translatesAutoresizingMaskIntoConstraints = false
        engineRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
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
        // The window rebuilds on every open; drop stale constraints so they do not
        // accumulate one identical pair per open.
        if !progressBar.constraints.contains(where: { $0.firstAttribute == .width }) {
            progressBar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.isHidden = true
        let progressRow = NSStackView(views: [progressBar, progressLabel])
        progressRow.orientation = .horizontal
        progressRow.spacing = 10
        progressRow.alignment = .centerY
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        progressRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
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
        if !logScroll.constraints.contains(where: { $0.firstAttribute == .height }) {
            logScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        }
        if !logScroll.constraints.contains(where: { $0.firstAttribute == .width }) {
            logScroll.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }
        root.addArrangedSubview(logScroll)

        // MARK: Cloud configuration
        cloudRows.removeAll()
        keyField.placeholderString = "sk-or-…"
        keyField.onChange = { [weak self] in self?.syncKeyButtons() }
        cloudRows.append(formRow(label: "OpenRouter API key", view: keyRow(
            field: keyField, save: keyButton, saveAction: #selector(saveKey),
            remove: keyRemoveButton, removeAction: #selector(removeKey))))

        let cloudStatusRow = NSStackView(views: [cloudStatus])
        cloudStatusRow.orientation = .horizontal
        cloudStatusRow.alignment = .centerY
        cloudStatusRow.translatesAutoresizingMaskIntoConstraints = false
        cloudStatusRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        cloudRows.append(cloudStatusRow)

        for row in cloudRows {
            root.addArrangedSubview(row)
        }

        root.addArrangedSubview(separator())
        root.addArrangedSubview(heading("Permissions",
            "macOS asks for these itself; TalkType cannot grant them."))
        root.addArrangedSubview(row(status: micStatus, button: micButton,
                                    action: #selector(openMicSettings)))
        root.addArrangedSubview(row(status: axStatus, button: axButton,
                                    action: #selector(openAXSettings)))

        let hint = NSTextField(wrappingLabelWithString:
            "Press ⌘⇧Space and talk.")
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
        d.preferredMaxLayoutWidth = Self.contentWidth
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
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        if let field = view as? NSTextField {
            field.setContentHuggingPriority(.init(1), for: .horizontal)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        return stack
    }

    /// The one API key: type or paste, Save, and Remove once it is stored. Save stays
    /// disabled until the field holds something, so the button always tells the truth
    /// about whether pressing it will do anything.
    private func keyRow(field: SecretField, save: NSButton, saveAction: Selector,
                        remove: NSButton, removeAction: Selector) -> NSView {
        save.title = "Save"
        remove.title = "Remove"
        remove.contentTintColor = .systemRed
        for (button, action) in [(save, saveAction), (remove, removeAction)] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: [field, save, remove])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        field.setContentHuggingPriority(.init(1), for: .horizontal)
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
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return stack
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return line
    }

    // MARK: - State

    func refresh() {
        let installing = installTask?.isRunning ?? false

        if let idx = enginePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == config.asrEngine.rawValue
        }) {
            enginePopup.selectItem(at: idx)
        }

        switch SidecarManager.installState() {
        case .ready:
            engineStatus.stringValue = config.asrEngine == .cloud ? "Installed (not running)" : "Installed"
            engineStatus.textColor = .systemGreen
            engineButton.title = "Reinstall"
            engineButton.isHidden = false
            engineButton.isEnabled = !installing
            pauseButton.isHidden = true
            deleteEngineButton.title = "Delete local engine…"
            deleteEngineButton.isHidden = installing
        case .missing where installing:
            // consumeInstallOutput owns this label while percentages are arriving; the
            // refresh timer must not stamp over them every 1.5 seconds.
            if !engineStatus.stringValue.hasPrefix("Downloading") {
                engineStatus.stringValue = "Installing…"
            }
            engineStatus.textColor = .secondaryLabelColor
            engineButton.isHidden = true
            pauseButton.title = "Pause"
            pauseButton.isHidden = false
            deleteEngineButton.title = "Delete"
            deleteEngineButton.isHidden = false
        case .missing where SidecarManager.hasPartialDownload:
            engineStatus.stringValue = "Paused — partly downloaded"
            engineStatus.textColor = .systemOrange
            engineButton.title = "Resume"
            engineButton.isHidden = false
            engineButton.isEnabled = true
            pauseButton.isHidden = true
            deleteEngineButton.title = "Delete"
            deleteEngineButton.isHidden = false
        case .missing:
            engineStatus.stringValue = "Not installed"
            engineStatus.textColor = .systemOrange
            engineButton.title = "Install"
            engineButton.isHidden = false
            engineButton.isEnabled = true
            pauseButton.isHidden = true
            deleteEngineButton.isHidden = true
        }

        // Cloud section
        let isCloud = config.asrEngine == .cloud
        for row in cloudRows { row.isHidden = !isCloud }

        // Never clear the key fields here. refresh() runs on a 1.5-second timer, and wiping
        // the field was erasing whatever the user was part-way through typing or pasting.
        let cloudKey = CloudKeyStore.apiKey()
        if let cloudKey = cloudKey {
            cloudStatus.stringValue = "Key saved (\(Self.masked(cloudKey)))"
            cloudStatus.textColor = .systemGreen
        } else {
            cloudStatus.stringValue = "No key saved"
            cloudStatus.textColor = .secondaryLabelColor
        }
        keyRemoveButton.isHidden = cloudKey == nil
        syncKeyButtons()

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

    private static func masked(_ key: String) -> String {
        guard key.count > 10 else { return "•••" }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }

    // MARK: - Actions

    @objc private func engineChanged() {
        guard let raw = enginePopup.selectedItem?.representedObject as? String,
              let engine = ASREngine(rawValue: raw)
        else { return }
        guard engine != config.asrEngine else { return }
        config.asrEngine = engine
        onConfigChanged?(config)
        refresh()
    }

    /// Save is only live when there is something to save, so pressing it always does
    /// something. Held down while a key is being checked, so it cannot be double-fired.
    private func syncKeyButtons() {
        guard !verifyingCloudKey else { return }
        keyButton.title = "Save"
        keyButton.isEnabled = !keyField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        verifyingCloudKey = true
        keyButton.isEnabled = false
        keyButton.title = "Checking…"
        cloudStatus.stringValue = "Checking the key with OpenRouter…"
        cloudStatus.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = CloudASRClient.validate(apiKey: key)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.verifyingCloudKey = false
                switch result {
                case .valid:
                    break
                case .rejected:
                    self.cloudStatus.stringValue =
                        "OpenRouter did not accept that key. Nothing was saved."
                    self.cloudStatus.textColor = .systemOrange
                    self.syncKeyButtons()
                    return
                case .unreachable(let message):
                    let hint = message.hasPrefix("HTTP ")
                        ? "OpenRouter is having a bad moment (\(message)). Nothing was saved — try again shortly."
                        : "Could not reach OpenRouter (\(message)). Nothing was saved — check your network."
                    self.cloudStatus.stringValue = hint
                    self.cloudStatus.textColor = .systemOrange
                    self.syncKeyButtons()
                    return
                case .invalidURL:
                    self.cloudStatus.stringValue =
                        "OpenRouter's address is invalid. Nothing was saved."
                    self.cloudStatus.textColor = .systemOrange
                    self.syncKeyButtons()
                    return
                }
                guard CloudKeyStore.storeAPIKey(key) else {
                    self.cloudStatus.stringValue = "Could not write the key to the keychain."
                    self.cloudStatus.textColor = .systemOrange
                    self.syncKeyButtons()
                    return
                }
                self.keyField.stringValue = ""
                self.onConfigChanged?(self.config)
                self.refresh()
            }
        }
    }

    @objc private func removeKey() {
        CloudKeyStore.deleteAPIKey()
        keyField.stringValue = ""
        onConfigChanged?(config)
        refresh()
    }

    @objc private func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
    @objc private func openAXSettings() { onRepairAccessibility?() }
    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Local engine install

    /// Stop the installer without losing what it has already fetched. The download resumes
    /// from whatever is on disk, so pausing costs nothing but the time already spent.
    @objc private func pauseInstall() {
        stopInstall()
        appendLog("\nPaused. Resume continues from here.\n")
    }

    private func stopInstall() {
        guard let task = installTask, task.isRunning else { return }
        userStoppedInstall = true
        // Signal the whole process group. The script is its own group leader, and the
        // download itself runs in a Python child — signalling only the script would leave
        // that child running, still writing gigabytes nobody is watching any more.
        kill(-task.processIdentifier, SIGTERM)
    }

    @objc private func deleteEngine() {
        let installed = SidecarManager.installState() == .ready
        let running = installTask?.isRunning == true

        if installed && !running {
            let alert = NSAlert()
            alert.messageText = "Delete the local engine?"
            alert.informativeText = "Removes about 4 GB. Offline dictation stops working; "
                + "cloud keeps working. You can reinstall any time."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            onEngineDeleted?()
            return
        }

        let alert = NSAlert()
        alert.messageText = running ? "Stop the download and delete it?" : "Delete the partial download?"
        alert.informativeText = "Removes what has downloaded so far. The Python environment "
            + "stays, so reinstalling is quick."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if running {
            // Deleted once the installer has exited, so nothing is pulled out from under it.
            deleteWeightsAfterStop = true
            stopInstall()
        } else {
            SidecarManager.deleteDownloadedWeights()
            appendLog("Downloaded data removed.\n")
            refresh()
        }
    }

    @objc private func installEngine() {
        guard installTask?.isRunning != true else { return }
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            appendLog("Cannot find install.sh inside the app bundle.\n")
            return
        }

        logView.string = ""
        logScroll.isHidden = false
        userStoppedInstall = false
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

                if self.deleteWeightsAfterStop {
                    self.deleteWeightsAfterStop = false
                    SidecarManager.deleteDownloadedWeights()
                    self.appendLog("\nStopped, and the downloaded data was removed.\n")
                } else if self.userStoppedInstall {
                    // Not a failure: the exit code just reflects the signal we sent.
                } else if finished.terminationStatus == 0 {
                    self.appendLog("\nDone. Starting the engine…\n")
                    self.onEngineInstalled?()
                } else {
                    self.appendLog("\nInstall failed (exit \(finished.terminationStatus)).\n")
                }
                self.userStoppedInstall = false
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
                progressLabel.stringValue = "Downloading… \(pct)%"
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

// MARK: - Secret field

/// A key field you can look at.
///
/// Masked by default, because someone may be standing behind you. But a key you cannot
/// read is a key you cannot check, and "the provider rejected it" is almost always either
/// a stray space or the wrong provider's key pasted in — both invisible behind dots. The
/// eye is what turns a dead end into a two-second check.
final class SecretField: NSView, NSTextFieldDelegate {
    private let masked = NSSecureTextField()
    private let shown = NSTextField()
    private let reveal = NSButton()
    private var isRevealed = false

    /// Called on every keystroke, so a Save button can enable itself only when there is
    /// something to save.
    var onChange: (() -> Void)?

    var placeholderString: String? {
        didSet {
            masked.placeholderString = placeholderString
            shown.placeholderString = placeholderString
        }
    }

    var stringValue: String {
        get { (isRevealed ? shown : masked).stringValue }
        set { masked.stringValue = newValue; shown.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for field in [masked as NSTextField, shown] {
            field.font = .systemFont(ofSize: 12)
            field.delegate = self
            field.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        shown.isHidden = true

        reveal.bezelStyle = .texturedRounded
        reveal.setButtonType(.momentaryPushIn)
        reveal.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show the key")
        reveal.imagePosition = .imageOnly
        reveal.target = self
        reveal.action = #selector(toggleReveal)
        reveal.setContentHuggingPriority(.required, for: .horizontal)
        reveal.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [masked, shown, reveal])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleReveal() {
        let text = stringValue
        isRevealed.toggle()
        masked.stringValue = text
        shown.stringValue = text
        masked.isHidden = isRevealed
        shown.isHidden = !isRevealed
        reveal.image = NSImage(
            systemSymbolName: isRevealed ? "eye.slash" : "eye",
            accessibilityDescription: isRevealed ? "Hide the key" : "Show the key")
        window?.makeFirstResponder(isRevealed ? shown : masked)
    }

    func controlTextDidChange(_ obj: Notification) { onChange?() }
}

// MARK: - Microphone authorisation

import AVFoundation

enum AVCaptureDeviceAuthorization {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
