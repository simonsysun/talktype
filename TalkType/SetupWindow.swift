import AVFoundation
import Cocoa

/// Setup window. One page, in the order things have to happen: pick which speech-to-text
/// API to use, paste its key, then the two system permissions macOS will not grant on our
/// behalf.
///
/// It opens by itself when the chosen provider has no key, and from the menu bar afterwards.
final class SetupWindow: NSObject, NSWindowDelegate {

    /// Width every row is laid out to. Rows used to hardcode this number in nine places,
    /// which is how one of them ended up too narrow for its own buttons.
    private static let contentWidth: CGFloat = 548

    private var window: NSWindow?

    // Provider choice
    private let providerPopup = NSPopUpButton()
    private let providerDetail = NSTextField(labelWithString: "")

    // Key
    private let keyField = SecretField()
    private let keyButton = NSButton()
    private let keyRemoveButton = NSButton()
    private let keyStatus = NSTextField(labelWithString: "")
    private let keyLinkButton = NSButton()

    // Permissions
    private let micStatus = NSTextField(labelWithString: "")
    private let micButton = NSButton()
    private let axStatus = NSTextField(labelWithString: "")
    private let axButton = NSButton()

    private var refreshTimer: Timer?
    /// While true, refresh() leaves the key status alone: a just-shown "saved" or error
    /// message must not be stamped over by the 1.5-second timer.
    private var keyStatusOwned = false

    /// Live config; the app reads the provider choice out of here.
    var config: AppConfig = AppConfig()
    /// Called when the provider or its key changes, so the app can persist and rebuild
    /// the dictation client.
    var onConfigChanged: ((AppConfig) -> Void)?
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
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 52, height: 380),
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

        // MARK: Provider choice
        root.addArrangedSubview(heading("Speech-to-text",
            "整段录音发给这一个 API，返回什么就粘贴什么——中间不做任何加工。"))

        // The window is rebuilt each time it opens (windowWillClose nils the window), so
        // clear first — addItems without removeAllItems would double the list.
        providerPopup.removeAllItems()
        for provider in STTProvider.allCases {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.setContentHuggingPriority(.required, for: .horizontal)

        let pickerRow = NSStackView(views: [providerPopup, NSView()])
        pickerRow.orientation = .horizontal
        pickerRow.spacing = 10
        pickerRow.alignment = .centerY
        pickerRow.translatesAutoresizingMaskIntoConstraints = false
        pickerRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        root.addArrangedSubview(pickerRow)

        providerDetail.font = .systemFont(ofSize: 11)
        providerDetail.textColor = .secondaryLabelColor
        root.addArrangedSubview(providerDetail)

        // MARK: Key
        keyField.onChange = { [weak self] in self?.syncKeyButtons() }
        root.addArrangedSubview(formRow(label: "API key", view: keyRow()))

        keyStatus.font = .systemFont(ofSize: 11)
        keyLinkButton.bezelStyle = .inline
        keyLinkButton.isBordered = false
        keyLinkButton.target = self
        keyLinkButton.action = #selector(openConsole)
        keyLinkButton.contentTintColor = .linkColor
        let statusRow = NSStackView(views: [keyStatus, keyLinkButton, NSView()])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        root.addArrangedSubview(statusRow)

        // MARK: Permissions
        root.addArrangedSubview(separator())
        root.addArrangedSubview(heading("Permissions",
            "macOS asks for these itself; TalkType cannot grant them."))
        root.addArrangedSubview(row(status: micStatus, button: micButton,
                                    action: #selector(openMicSettings)))
        root.addArrangedSubview(row(status: axStatus, button: axButton,
                                    action: #selector(openAXSettings)))

        let hint = NSTextField(wrappingLabelWithString: "Press ⌘⇧Space and talk.")
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
        return stack
    }

    /// Type or paste, Save, and Remove once it is stored. Save stays disabled until the
    /// field holds something, so the button always tells the truth about whether pressing
    /// it will do anything.
    private func keyRow() -> NSView {
        keyButton.title = "Save"
        keyRemoveButton.title = "Remove"
        keyRemoveButton.contentTintColor = .systemRed
        for (button, action) in [(keyButton, #selector(saveKey)),
                                 (keyRemoveButton, #selector(removeKey))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: [keyField, keyButton, keyRemoveButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        keyField.setContentHuggingPriority(.init(1), for: .horizontal)
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
        let provider = config.sttProvider

        if let idx = providerPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == provider.rawValue
        }) {
            providerPopup.selectItem(at: idx)
        }
        providerDetail.stringValue = provider.summary
        keyField.placeholderString = provider.keyPlaceholder
        keyLinkButton.title = "拿 key →"
        keyLinkButton.toolTip = provider.consoleURL

        // Never clear the key field here. refresh() runs on a 1.5-second timer, and wiping
        // the field would erase whatever the user is part-way through pasting.
        let key = STTKeyStore.apiKey(for: provider)
        if !keyStatusOwned {
            if let key = key {
                keyStatus.stringValue = "Key saved (\(Self.masked(key)))"
                keyStatus.textColor = .systemGreen
            } else {
                keyStatus.stringValue = "还没有 key，这个 provider 不能用"
                keyStatus.textColor = .systemOrange
            }
        }
        keyRemoveButton.isHidden = key == nil
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

    @objc private func providerChanged() {
        guard let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = STTProvider(rawValue: raw),
              provider != config.sttProvider
        else { return }
        config.sttProvider = provider
        // Each provider has its own keychain slot; a half-typed key for the previous one
        // has no meaning here.
        keyField.stringValue = ""
        keyStatusOwned = false
        onConfigChanged?(config)
        refresh()
    }

    private func syncKeyButtons() {
        keyButton.isEnabled = !keyField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Saved as typed, with no online check. Every provider would need its own probe
    /// endpoint, and a wrong key already announces itself on the first dictation as
    /// "拒绝了这个 API key" — which is the same information, one step later.
    @objc private func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        keyStatusOwned = true
        if STTKeyStore.store(key, for: config.sttProvider) {
            keyField.stringValue = ""
            keyStatus.stringValue = "Key saved (\(Self.masked(key)))"
            keyStatus.textColor = .systemGreen
            onConfigChanged?(config)
        } else {
            keyStatus.stringValue = "存到钥匙串失败。"
            keyStatus.textColor = .systemRed
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.keyStatusOwned = false
        }
        refresh()
    }

    @objc private func removeKey() {
        STTKeyStore.delete(for: config.sttProvider)
        keyField.stringValue = ""
        keyStatusOwned = false
        onConfigChanged?(config)
        refresh()
    }

    @objc private func openConsole() {
        open(config.sttProvider.consoleURL)
    }

    @objc private func openMicSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @objc private func openAXSettings() { onRepairAccessibility?() }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
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

enum AVCaptureDeviceAuthorization {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
