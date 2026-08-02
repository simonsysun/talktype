import Carbon
import Cocoa
import KeyboardShortcuts
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
    private let sidecar = SidecarManager()
    private var healthTimer: Timer?

    // Menu items needing dynamic updates
    private var engineItem: NSMenuItem!
    private var vocabMenu: NSMenu!
    private var launchItem: NSMenuItem!
    private var hotkeyDisplayItem: NSMenuItem!
    private var hotkeySettingsWindow: HotkeySettingsWindow!

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
        ConfigManager.save(config)

        // Start the local speech engine early — weights take about a second to load,
        // and the socket is up before then so the first dictation rarely waits.
        startSidecar()

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

        // Request notification permission once
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

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

        // Settings window
        hotkeySettingsWindow = HotkeySettingsWindow()

        // Observe hotkey changes to update menu display
        NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hotkeyDisplayItem?.title = "Dictation: \(self?.hotkeyDisplayString() ?? "?")"
        }

        // Launch at login sync
        if config.launchAtLogin {
            syncLaunchAtLogin()
        }

        let mode = hotkeyManager.captureMode.rawValue
        print()
        print("Ready!")
        print("  \(hotkeyDisplayString()) -> Dictation (speak -> type)")
        print("  Hotkey capture: \(mode)")
        print("  Speech engine: local, 127.0.0.1:\(config.asrPort)")
        if config.silenceAutoStopEnabled {
            print("  Silence auto-stop: \(config.silenceAutoStopSeconds)s")
        }
        print()

        if hotkeyManager.captureMode == .monitor {
            notifyError("Hotkey cannot override macOS until Accessibility is enabled. Open Accessibility Settings from the tray.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        dictationManager.shutdown()
        hotkeyManager.cleanup()
        sidecar.stop()
    }

    // MARK: - Menu bar setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "T"

        let menu = NSMenu()

        hotkeyDisplayItem = NSMenuItem(title: "Dictation: \(hotkeyDisplayString())", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyDisplayItem)

        let hotkeyItem = NSMenuItem(title: "Change Hotkey...", action: #selector(openHotkeySettings), keyEquivalent: "")
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        engineItem = NSMenuItem(title: "Speech engine: starting...", action: nil, keyEquivalent: "")
        menu.addItem(engineItem)

        let accessItem = NSMenuItem(title: "Accessibility Settings...", action: #selector(openAccessibility), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)

        menu.addItem(.separator())

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

    // MARK: - Local speech engine

    private func startSidecar() {
        let probe = Transcriber(port: config.asrPort)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let alreadyServing = probe.health() != .unreachable
            let state = self.sidecar.start(port: self.config.asrPort, alreadyServing: alreadyServing)
            if case .missing(let what) = state {
                self.notifyError("Local speech engine is not installed: \(what)")
            }
            DispatchQueue.main.async { self.startHealthPolling() }
        }
    }

    /// Poll fast while the weights load, then settle into a slow heartbeat that notices
    /// a sidecar that died without the app noticing.
    private func startHealthPolling() {
        healthTimer?.invalidate()
        refreshEngineStatus()

        var interval: TimeInterval = 1.0
        func schedule() {
            healthTimer?.invalidate()
            healthTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.refreshEngineStatus { health in
                    let next: TimeInterval = (health == .loading) ? 1.0 : 15.0
                    if next != interval {
                        interval = next
                    }
                    schedule()
                }
            }
        }
        schedule()
    }

    private func refreshEngineStatus(completion: ((SidecarHealth) -> Void)? = nil) {
        let probe = Transcriber(port: config.asrPort)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let health = probe.health()
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch health {
                case .ready(let model):
                    let short = model.split(separator: "/").last.map(String.init) ?? model
                    self.engineItem?.title = "Speech engine: ready (\(short))"
                case .loading:
                    self.engineItem?.title = "Speech engine: loading model..."
                case .unreachable:
                    let problem = self.sidecar.installState().problem
                    self.engineItem?.title = problem == nil
                        ? "Speech engine: not running"
                        : "Speech engine: not installed"
                }
                completion?(health)
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

    // MARK: - Hotkey settings

    @objc private func openHotkeySettings() {
        hotkeySettingsWindow.show()
    }

    private func hotkeyDisplayString() -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .dictation) else {
            return "Cmd+Shift+Space"
        }
        var parts: [String] = []
        let mods = shortcut.modifiers
        if mods.contains(.command) { parts.append("Cmd") }
        if mods.contains(.shift) { parts.append("Shift") }
        if mods.contains(.option) { parts.append("Opt") }
        if mods.contains(.control) { parts.append("Ctrl") }
        if let key = shortcut.key {
            parts.append(keyName(key))
        }
        return parts.joined(separator: "+")
    }

    private func keyName(_ key: KeyboardShortcuts.Key) -> String {
        // Common special keys
        switch key {
        case .space: return "Space"
        case .return: return "Return"
        case .tab: return "Tab"
        case .escape: return "Esc"
        case .delete: return "Delete"
        case .deleteForward: return "Fwd Delete"
        case .upArrow: return "Up"
        case .downArrow: return "Down"
        case .leftArrow: return "Left"
        case .rightArrow: return "Right"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        default:
            // Use Carbon to get the character for this keycode
            if let character = characterForKeyCode(UInt16(key.rawValue)) {
                return character.uppercased()
            }
            return "Key(\(key.rawValue))"
        }
    }

    private func characterForKeyCode(_ keyCode: UInt16) -> String? {
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source = source,
              let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0
        let result = layoutData.withUnsafeBytes { ptr -> OSStatus in
            guard let baseAddress = ptr.baseAddress else { return -1 }
            return UCKeyTranslate(
                baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
        }
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    // MARK: - Menu actions

    @objc private func openAccessibility() {
        TextInserter.openAccessibilitySettings()
    }

    @objc private func quitApp() {
        healthTimer?.invalidate()
        dictationManager.shutdown()
        hotkeyManager.cleanup()
        sidecar.stop()
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
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
