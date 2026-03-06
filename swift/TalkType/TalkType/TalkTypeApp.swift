import Cocoa
import ServiceManagement
import UserNotifications

@main
final class TalkTypeApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var dictationManager: DictationManager!
    private var overlay: OverlayWindow!
    private var vocabularyStore: VocabularyStore!
    private var config: AppConfig!
    private var validationSeq = 0

    // Menu items needing dynamic updates
    private var asrItem: NSMenuItem!
    private var keyStatusItem: NSMenuItem!
    private var modelMiniItem: NSMenuItem!
    private var modelPremiumItem: NSMenuItem!
    private var vocabMenu: NSMenu!
    private var launchItem: NSMenuItem!

    static func main() {
        setbuf(stdout, nil)
        ensureSingleInstance()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // No dock icon
        let delegate = TalkTypeApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("TalkType - Voice-to-Text")
        print(String(repeating: "=", count: 40))
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        print("[app] bundle_id=\(bundleID)")
        print("[app] macOS=\(osVersion)")

        // Load config
        config = ConfigManager.load()

        // Normalize model
        if config.asrModel != defaultOpenAIASRModel && config.asrModel != premiumOpenAIASRModel {
            config.asrModel = defaultOpenAIASRModel
        }
        ConfigManager.save(config)

        // Initialize stores
        vocabularyStore = VocabularyStore()

        // Create overlay
        overlay = OverlayWindow()

        // Create dictation manager
        dictationManager = DictationManager(
            config: config,
            vocabularyStore: vocabularyStore,
            overlay: overlay
        )
        dictationManager.setTrayDelegate(self)

        // Setup menu bar
        setupStatusItem()

        // Check mic permission (passive)
        dictationManager.checkMicPermission()

        // Request accessibility
        let accessibilityGranted = TextInserter.accessibilityGranted(prompt: true)
        if !accessibilityGranted {
            print("Accessibility permission not granted.")
            print("  Direct typing will not work until granted.")
            notifyInfo("Accessibility not granted. Transcription will copy to clipboard only.")
        }

        // Prepare audio engine
        dictationManager.prepareAudio()

        // Register hotkey
        hotkeyManager = HotkeyManager()
        hotkeyManager.register { [weak self] in
            self?.dictationManager.toggleDictation()
        }

        // Launch at login sync
        if config.launchAtLogin {
            syncLaunchAtLogin()
        }

        let mode = hotkeyManager.captureMode.rawValue
        print()
        print("Ready!")
        print("  Option+Space -> Dictation (speak -> type)")
        print("  Hotkey capture: \(mode)")
        print("  ASR model: \(config.asrModel)")
        print("  API key: \(hasAPIKey() ? "present" : "missing")")
        if config.silenceAutoStopEnabled {
            print("  Silence auto-stop: \(config.silenceAutoStopSeconds)s")
        }
        print()

        if hotkeyManager.captureMode == .monitor {
            notifyError("Option+Space cannot override macOS until Accessibility is enabled. Open Accessibility Settings from the tray.")
        }

        // Validate key on startup
        if let key = currentAPIKey() {
            validateKey(key, notify: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationManager.shutdown()
        hotkeyManager.cleanup()
    }

    // MARK: - Menu bar setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "T"

        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Dictation: Option+Space", action: nil, keyEquivalent: ""))

        asrItem = NSMenuItem(title: "ASR: OpenAI / \(config.asrModel)", action: nil, keyEquivalent: "")
        menu.addItem(asrItem)

        keyStatusItem = NSMenuItem(title: hasAPIKey() ? "API Key: Saved" : "API Key: Missing", action: nil, keyEquivalent: "")
        menu.addItem(keyStatusItem)

        let accessItem = NSMenuItem(title: "Accessibility Settings...", action: #selector(openAccessibility), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)

        menu.addItem(.separator())

        let keyMenuItem = NSMenuItem(title: "OpenAI API Key...", action: #selector(setAPIKey), keyEquivalent: "")
        keyMenuItem.target = self
        menu.addItem(keyMenuItem)

        // Model submenu
        let modelMenu = NSMenu()
        modelMiniItem = NSMenuItem(title: "GPT-4o mini Transcribe", action: #selector(useModelMini), keyEquivalent: "")
        modelMiniItem.target = self
        modelPremiumItem = NSMenuItem(title: "GPT-4o Transcribe", action: #selector(useModelPremium), keyEquivalent: "")
        modelPremiumItem.target = self
        modelMenu.addItem(modelMiniItem)
        modelMenu.addItem(modelPremiumItem)
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        refreshModelUI()

        // Vocabulary submenu
        vocabMenu = NSMenu()
        let vocabItem = NSMenuItem(title: "Vocabulary", action: nil, keyEquivalent: "")
        vocabItem.submenu = vocabMenu
        menu.addItem(vocabItem)
        refreshVocabularyMenu()

        // Launch at login
        launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TalkType", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Model

    private func refreshModelUI() {
        asrItem?.title = "ASR: OpenAI / \(config.asrModel)"
        modelMiniItem?.state = config.asrModel == defaultOpenAIASRModel ? .on : .off
        modelPremiumItem?.state = config.asrModel == premiumOpenAIASRModel ? .on : .off
    }

    @objc private func useModelMini() { setModel(defaultOpenAIASRModel) }
    @objc private func useModelPremium() { setModel(premiumOpenAIASRModel) }

    private func setModel(_ model: String) {
        guard model != config.asrModel else { return }
        if dictationManager.state == .recording {
            notifyInfo("Cannot switch model during dictation.")
            return
        }
        validationSeq += 1
        config.asrModel = model
        ConfigManager.save(config)
        refreshModelUI()
        dictationManager.updateModel(model)
        notifyInfo("ASR model switched to \(model).")
    }

    // MARK: - API Key

    private func currentAPIKey() -> String? {
        if let envKey = ProcessInfo.processInfo.environment["TALKTYPE_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        return KeyStorage.retrieveKey(provider: openAIASRAccount)
            ?? KeyStorage.retrieveKey(provider: "OpenAI")
    }

    private func hasAPIKey() -> Bool {
        currentAPIKey() != nil
    }

    @objc private func setAPIKey() {
        let existing = currentAPIKey()
        if let existing = existing {
            let masked = maskKey(existing)
            let alert = NSAlert()
            alert.messageText = "TalkType - OpenAI API Key"
            alert.informativeText = "Current key: \(masked)"
            alert.addButton(withTitle: "Change Key")
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Clear Key")
            let response = alert.runModal()

            switch response {
            case .alertFirstButtonReturn: // Change
                promptNewKey()
            case .alertThirdButtonReturn: // Clear
                validationSeq += 1
                KeyStorage.deleteKey(provider: openAIASRAccount)
                KeyStorage.deleteKey(provider: "OpenAI")
                refreshKeyStatus()
                notifyInfo("OpenAI API key cleared.")
            default:
                break
            }
        } else {
            promptNewKey()
        }
    }

    private func promptNewKey() {
        let alert = NSAlert()
        alert.messageText = "TalkType - OpenAI API Key"
        alert.informativeText = "Enter OpenAI API key for speech transcription:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let key = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }

        if KeyStorage.storeKey(provider: openAIASRAccount, apiKey: key) {
            validateKey(key, notify: true)
        } else {
            notifyError("Failed to save API key.")
        }
    }

    private func refreshKeyStatus() {
        DispatchQueue.main.async {
            self.keyStatusItem?.title = self.hasAPIKey() ? "API Key: Saved" : "API Key: Missing"
        }
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 7 else { return "***" }
        return "\(key.prefix(3))...\(key.suffix(4))"
    }

    private func validateKey(_ key: String, notify: Bool) {
        validationSeq += 1
        let seq = validationSeq
        DispatchQueue.main.async { self.keyStatusItem?.title = "API Key: Checking..." }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.dictationManager.transcriber.validateKey(key)
                guard seq == self.validationSeq else { return }
                DispatchQueue.main.async {
                    self.keyStatusItem?.title = "API Key: Connected"
                }
                if notify { self.notifyInfo("OpenAI API key verified.") }
            } catch let error as TranscriberError where error == .invalidAPIKey {
                guard seq == self.validationSeq else { return }
                let current = self.currentAPIKey()
                guard current == key else { return }
                KeyStorage.deleteKey(provider: openAIASRAccount)
                KeyStorage.deleteKey(provider: "OpenAI")
                DispatchQueue.main.async { self.keyStatusItem?.title = "API Key: Invalid" }
                self.notifyError("OpenAI API key is invalid. Please enter a new one.")
            } catch {
                guard seq == self.validationSeq else { return }
                DispatchQueue.main.async { self.keyStatusItem?.title = "API Key: Saved (offline)" }
                if notify {
                    self.notifyInfo("OpenAI API key saved but couldn't verify (network error).")
                }
            }
        }
    }

    // MARK: - Vocabulary

    private func refreshVocabularyMenu() {
        vocabMenu.removeAllItems()

        let addItem = NSMenuItem(title: "Add Word...", action: #selector(addVocabWord), keyEquivalent: "")
        addItem.target = self
        vocabMenu.addItem(addItem)
        vocabMenu.addItem(.separator())

        let entries = vocabularyStore.listEntries().sorted { $0.addedAt > $1.addedAt }

        if entries.isEmpty {
            vocabMenu.addItem(NSMenuItem(title: "No saved words", action: nil, keyEquivalent: ""))
            return
        }

        for entry in entries {
            let item = NSMenuItem(title: entry.canonical, action: #selector(removeVocabWord(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            vocabMenu.addItem(item)
        }
    }

    @objc private func addVocabWord() {
        let alert = NSAlert()
        alert.messageText = "TalkType - Vocabulary"
        alert.informativeText = "Add a word or phrase to bias transcription spelling:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let value = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            notifyInfo("Vocabulary entry was empty.")
            return
        }

        do {
            let entry = try vocabularyStore.add(value)
            refreshVocabularyMenu()
            notifyInfo("Saved vocabulary word: \(entry.canonical)")
        } catch {
            notifyError("Failed to save vocabulary word: \(error.localizedDescription)")
        }
    }

    @objc private func removeVocabWord(_ sender: NSMenuItem) {
        guard let entryID = sender.representedObject as? String else { return }
        let canonical = sender.title

        let alert = NSAlert()
        alert.messageText = "TalkType - Vocabulary"
        alert.informativeText = "Remove '\(canonical)' from saved vocabulary?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if vocabularyStore.remove(entryID: entryID) {
            refreshVocabularyMenu()
            notifyInfo("Removed vocabulary word: \(canonical)")
        }
    }

    // MARK: - Launch at login

    @objc private func toggleLaunchAtLogin() {
        let target = launchItem.state != .on

        if #available(macOS 13.0, *) {
            do {
                if target {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchItem.state = target ? .on : .off
                config.launchAtLogin = target
                ConfigManager.save(config)
            } catch {
                notifyError("Failed to update launch-at-login: \(error.localizedDescription)")
            }
        } else {
            // Fallback: just save config
            launchItem.state = target ? .on : .off
            config.launchAtLogin = target
            ConfigManager.save(config)
        }
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return config.launchAtLogin
    }

    private func syncLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        }
    }

    // MARK: - Menu actions

    @objc private func openAccessibility() {
        TextInserter.openAccessibilitySettings()
    }

    @objc private func quitApp() {
        dictationManager.shutdown()
        hotkeyManager.cleanup()
        NSApp.terminate(nil)
    }

    // MARK: - Single instance

    private static func ensureSingleInstance() {
        let bundleID = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            print("[app] Another instance is already running. Exiting.")
            exit(0)
        }
    }
}

// MARK: - TrayDelegate

extension TalkTypeApp: TrayDelegate {
    func setRecording(_ active: Bool) {
        DispatchQueue.main.async {
            self.statusItem?.button?.title = active ? "T·" : "T"
        }
    }

    func setProcessing(_ active: Bool) {
        DispatchQueue.main.async {
            self.statusItem?.button?.title = active ? "T…" : "T"
        }
    }

    func notifyError(_ message: String) {
        sendNotification(title: "TalkType", subtitle: "Error", body: message)
    }

    func notifyInfo(_ message: String) {
        sendNotification(title: "TalkType", subtitle: "", body: message)
    }

    private func sendNotification(title: String, subtitle: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}

// Equatable for TranscriberError for pattern matching
extension TranscriberError: Equatable {
    static func == (lhs: TranscriberError, rhs: TranscriberError) -> Bool {
        switch (lhs, rhs) {
        case (.missingAPIKey, .missingAPIKey): return true
        case (.invalidAPIKey, .invalidAPIKey): return true
        case (.emptyResponse, .emptyResponse): return true
        case (.apiError(let a, _), .apiError(let b, _)): return a == b
        default: return false
        }
    }
}
