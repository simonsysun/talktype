import Cocoa

/// First-run setup. Everything TalkType needs before it can dictate, on one page, in the
/// order it has to happen: speech engine, then optional polishing, then the two system
/// permissions macOS will not grant on our behalf.
///
/// It opens by itself when the engine is missing, and from the menu bar afterwards.
final class SetupWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var installTask: Process?

    // Engine
    private let engineStatus = NSTextField(labelWithString: "")
    private let engineButton = NSButton()
    private let logScroll = NSScrollView()
    private let logView = NSTextView()
    private let spinner = NSProgressIndicator()

    // Polish
    private let polishStatus = NSTextField(labelWithString: "")
    private let polishButton = NSButton()

    // Permissions
    private let micStatus = NSTextField(labelWithString: "")
    private let micButton = NSButton()
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton()

    private var refreshTimer: Timer?

    /// Called when the engine finishes installing, so the app can start the sidecar.
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "TalkType Setup"
        w.delegate = self
        w.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 24, right: 26)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(heading("Speech engine",
            "Runs on this Mac. Around 4 GB, downloaded once. Your voice never leaves the machine."))
        root.addArrangedSubview(row(status: engineStatus, button: engineButton,
                                    action: #selector(installEngine)))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

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

    /// Status on the left, action on the right, every row the same. Letting the button
    /// sit wherever the label ended made the column of actions look accidental.
    private func row(status: NSTextField, button: NSButton, action: Selector) -> NSView {
        status.font = .systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        var views: [NSView] = [status]
        if button === engineButton { views.append(spinner) }
        views.append(contentsOf: [spacer, button])

        let stack = NSStackView(views: views)
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

        switch SidecarManager.installState() {
        case .ready:
            engineStatus.stringValue = "Installed"
            engineStatus.textColor = .systemGreen
            engineButton.title = "Reinstall"
            engineButton.isEnabled = !installing
        case .missing:
            engineStatus.stringValue = installing ? "Installing…" : "Not installed"
            engineStatus.textColor = installing ? .secondaryLabelColor : .systemOrange
            engineButton.title = "Install"
            engineButton.isEnabled = !installing
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

    // MARK: - Actions

    @objc private func editKey() { onEditKey?() }
    @objc private func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
    @objc private func openAXSettings() { onRepairAccessibility?() }
    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    @objc private func installEngine() {
        guard installTask?.isRunning != true else { return }
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            appendLog("Cannot find install.sh inside the app bundle.\n")
            return
        }

        logView.string = ""
        logScroll.isHidden = false
        spinner.startAnimation(nil)
        refresh()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        // The script copies server.py from beside itself, which inside the bundle is
        // Resources — so both files must ship together.
        proc.currentDirectoryURL = script.deletingLastPathComponent()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendLog(text) }
        }

        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.spinner.stopAnimation(nil)
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
