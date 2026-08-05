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
    private var engineStatusItem: NSMenuItem!
    private var engineLocalItem: NSMenuItem!
    private var engineCloudItem: NSMenuItem!
    private var vocabMenu: NSMenu!
    private var launchItem: NSMenuItem!
    private var inputMenu: NSMenu!
    private var hotkeyDisplayItem: NSMenuItem!
    private var hotkeySettingsWindow: HotkeySettingsWindow!
    private let setupWindow = SetupWindow()

    static func main() {
        setbuf(stdout, nil)
        ensureSingleInstance()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // No dock icon
        app.mainMenu = makeMainMenu()
        let delegate = TalkTypeApp()
        app.delegate = delegate
        app.run()
    }

    /// A menu bar we never show, purely so ⌘C/⌘V/⌘X/⌘A work.
    ///
    /// AppKit routes command-key equivalents through the main menu before anything else
    /// sees them. An agent app has no menu bar, so without this there is nothing to route
    /// them to and every text field in the app silently ignores paste — which is a hard
    /// place to be when the first thing setup asks for is a pasted API key. The titles
    /// below never appear on screen; only the key equivalents matter.
    private static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        // Close the frontmost window, the one shortcut people reach for without thinking.
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let main = NSMenu()
        for submenu in [edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
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
        // Providers other than OpenRouter were removed in 2.2.0; drop their stale
        // keychain slots in one pass.
        CloudKeyStore.removeLegacyKeys()

        // Start the speech engine early. Local weights take about a second to load, and
        // the socket is up before then so the first dictation rarely waits. Cloud means
        // the sidecar never runs — that is where the ~4 GB saving comes from.
        if config.asrEngine == .local {
            startSidecar()
        }

        // Initialize stores
        vocabularyStore = VocabularyStore()

        // Create overlay
        overlay = OverlayWindow()

        // Create dictation manager
        dictationManager = DictationManager(
            config: config,
            vocabularyStore: vocabularyStore,
            overlay: overlay,
            sidecar: sidecar
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
            Log.write("[perm] accessibility NOT granted")
            print("  Pasting will not work until granted.")
            notifyInfo("Accessibility not granted. Dictation will only copy to the clipboard.")
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
        print("  Speech engine: \(config.asrEngine == .local ? "local, 127.0.0.1:\(config.asrPort)" : "cloud, \(CloudDefaults.model)")")
        if config.silenceAutoStopEnabled {
            print("  Silence auto-stop: \(config.silenceAutoStopSeconds)s")
        }
        print()

        if hotkeyManager.captureMode == .monitor {
            notifyError("Hotkey cannot override macOS until Accessibility is enabled. Open Accessibility Settings from the tray.")
        }

        // Lead with setup when the chosen engine cannot work yet: local weights missing,
        // or cloud configured without a key. Never block on the engine we are not using.
        configureSetupWindow()
        let needsSetup = config.asrEngine == .local
            ? SidecarManager.installState() != .ready
            : CloudKeyStore.apiKey() == nil
        if needsSetup {
            setupWindow.show()
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
        setStatusSymbol(.idle)

        let menu = NSMenu()

        hotkeyDisplayItem = NSMenuItem(title: "Dictation: \(hotkeyDisplayString())", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyDisplayItem)

        let hotkeyItem = NSMenuItem(title: "Change Hotkey...", action: #selector(openHotkeySettings), keyEquivalent: "")
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        let engineMenu = NSMenu()
        engineItem = NSMenuItem(title: "Speech engine", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)
        configureEngineMenu()

        let setupItem = NSMenuItem(title: "Setup...", action: #selector(openSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        inputMenu = NSMenu()
        inputMenu.delegate = self          // rebuilt on open; devices come and go
        let inputItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        inputItem.submenu = inputMenu
        menu.addItem(inputItem)
        rebuildInputMenu()

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

    // MARK: - Status item

    private enum StatusSymbol {
        case idle, recording, processing

        /// Template SF Symbols, so the menu bar tints them for light and dark itself.
        /// The waveform matches the overlay, and a plain letter "T" sat badly among the
        /// icon-based items around it.
        var symbolName: String {
            switch self {
            case .idle: return "waveform"
            case .recording: return "waveform.circle.fill"
            case .processing: return "ellipsis.circle"
            }
        }

        var label: String {
            switch self {
            case .idle: return "TalkType"
            case .recording: return "TalkType — recording"
            case .processing: return "TalkType — transcribing"
            }
        }
    }

    private func setStatusSymbol(_ symbol: StatusSymbol) {
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: symbol.symbolName, accessibilityDescription: symbol.label)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = symbol.label
        // Fall back to text if the symbol is ever unavailable, rather than an empty item.
        button.title = image == nil ? "T" : ""
    }

    // MARK: - Microphone selection

    /// Rebuilt every time the submenu opens: AirPods connect and disconnect, and a list
    /// captured at launch would be wrong most of the time.
    private func rebuildInputMenu() {
        guard let menu = inputMenu else { return }
        menu.removeAllItems()

        let automatic = AudioDevices.automaticInput()
        let autoName = automatic.device?.name
        let auto = NSMenuItem(title: autoName.map { "Automatic (\($0))" } ?? "Automatic",
                              action: #selector(selectInputDevice(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = config.inputDeviceUID.isEmpty ? .on : .off
        auto.toolTip = automatic.skippedBluetooth
            ? "A connected Bluetooth headset was passed over on purpose — recording through it stalls the link. Pick it explicitly to use its mic."
            : "Follow the system input device."
        menu.addItem(auto)
        menu.addItem(.separator())

        let devices = AudioDevices.inputDevices()
        if devices.isEmpty {
            menu.addItem(NSMenuItem(title: "No input devices", action: nil, keyEquivalent: ""))
            return
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = config.inputDeviceUID == device.uid ? .on : .off
            menu.addItem(item)
        }

        // A device chosen earlier and since unplugged: show it so the choice is visible
        // rather than silently reverting to Automatic.
        if !config.inputDeviceUID.isEmpty,
           !devices.contains(where: { $0.uid == config.inputDeviceUID }) {
            menu.addItem(.separator())
            let missing = NSMenuItem(title: "Chosen device not connected", action: nil, keyEquivalent: "")
            missing.state = .on
            missing.toolTip = "Recording falls back to the system default until it returns."
            menu.addItem(missing)
        }
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        guard uid != config.inputDeviceUID else { return }
        config.inputDeviceUID = uid
        persistConfig()
        dictationManager.reloadConfig(config)
        rebuildInputMenu()
        notifyInfo(uid.isEmpty ? "Microphone: following the system default."
                               : "Microphone: \(sender.title).")
    }

    /// Persist a config change made from the menu bar. The Setup window keeps its own
    /// copy, and any edit there sends that copy back wholesale through onConfigChanged —
    /// so it must be kept in step or a stale copy would silently revert menu changes.
    private func persistConfig() {
        ConfigManager.save(config)
        setupWindow.config = config
    }

    // MARK: - Setup

    @objc private func openSetup() {
        // Refresh what the window shows before opening — the engine/key/mic can have
        // changed from the menu since the window was last configured.
        setupWindow.config = config
        setupWindow.show()
    }

    private func configureSetupWindow() {
        setupWindow.config = config
        setupWindow.onConfigChanged = { [weak self] updated in
            guard let self = self else { return }
            self.config = updated
            ConfigManager.save(updated)
            self.dictationManager.reloadConfig(updated)
            if updated.asrEngine == .cloud {
                self.sidecar.stop()
                self.healthTimer?.invalidate()
            } else {
                self.startSidecar()
            }
            self.refreshEngineStatus()
            self.configureEngineMenu()
        }
        setupWindow.onRepairAccessibility = { [weak self] in self?.promptAccessibilityRepair() }
        setupWindow.onEngineInstalled = { [weak self] in
            guard let self = self else { return }
            if self.config.asrEngine == .local {
                self.startSidecar()
            }
            self.notifyInfo("Speech engine installed. Press \(self.hotkeyDisplayString()) to dictate.")
        }
        setupWindow.onEngineDeleted = { [weak self] in
            guard let self = self else { return }
            self.healthTimer?.invalidate()
            if let error = self.sidecar.uninstall() {
                self.notifyError(error)
                self.refreshEngineStatus()
                return
            }
            self.dictationManager.clearFallbackState()
            // Deleting the local engine while it is the chosen engine leaves dictation
            // with no working path — move to cloud, the default.
            if self.config.asrEngine == .local {
                self.config.asrEngine = .cloud
                self.persistConfig()
                self.dictationManager.reloadConfig(self.config)
                self.engineLocalItem?.state = .off
                self.engineCloudItem?.state = .on
                if CloudKeyStore.apiKey() == nil {
                    self.notifyInfo("本地引擎已删除，语音引擎已切到云端，但还没有 OpenRouter key——已打开设置。")
                    self.openSetup()
                } else {
                    self.notifyInfo("本地引擎已删除，语音引擎已切到云端。")
                }
            } else {
                self.notifyInfo("本地引擎已删除，约 4 GB 已释放。")
            }
            self.refreshEngineStatus()
            // The delete flow changed the app's config (possibly the engine); push it
            // back into the open Setup window so its engine dropdown and status refresh
            // against the new reality instead of the stale copy.
            self.setupWindow.config = self.config
            self.setupWindow.refresh()
        }
    }

    // MARK: - Local speech engine

    /// Engine menu: a status row plus Local/Cloud radio items. Cloud is cloud-first with
    /// automatic local fallback when unreachable; Local runs on-device only.
    private func configureEngineMenu() {
        guard let submenu = engineItem.submenu else { return }
        submenu.removeAllItems()

        engineStatusItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        engineStatusItem.isEnabled = false
        submenu.addItem(engineStatusItem)
        submenu.addItem(.separator())

        engineLocalItem = NSMenuItem(title: "Local (Qwen3-ASR, on this Mac)",
                                     action: #selector(selectEngine(_:)), keyEquivalent: "")
        engineLocalItem.target = self
        engineLocalItem.representedObject = ASREngine.local.rawValue
        engineLocalItem.state = config.asrEngine == .local ? .on : .off
        engineLocalItem.toolTip = "Runs on-device. Voice never leaves the machine, ~4 GB while in use."
        submenu.addItem(engineLocalItem)

        engineCloudItem = NSMenuItem(title: "Cloud (OpenRouter)",
                                     action: #selector(selectEngine(_:)), keyEquivalent: "")
        engineCloudItem.target = self
        engineCloudItem.representedObject = ASREngine.cloud.rawValue
        engineCloudItem.state = config.asrEngine == .cloud ? .on : .off
        engineCloudItem.toolTip = "Sends the recorded audio to OpenRouter (Qwen3-ASR-Flash). Setup… to add your key."
        submenu.addItem(engineCloudItem)

        refreshEngineStatus()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = ASREngine(rawValue: raw),
              engine != config.asrEngine
        else { return }

        config.asrEngine = engine
        persistConfig()
        dictationManager.reloadConfig(config)

        if engine == .cloud {
            // Free the ~4 GB resident model — the whole point of choosing cloud.
            sidecar.stop()
            healthTimer?.invalidate()
        } else {
            startSidecar()
        }

        engineLocalItem.state = engine == .local ? .on : .off
        engineCloudItem.state = engine == .cloud ? .on : .off
        refreshEngineStatus()
        notifyInfo(engine == .cloud
            ? "Speech engine: cloud (\(CloudDefaults.model)). Audio now leaves your Mac."
            : "Speech engine: local (Qwen3-ASR). Voice stays on this Mac.")
    }

    private func startSidecar() {
        guard config.asrEngine == .local else { return }
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

    private func refreshEngineStatus(completion: ((SidecarHealth?) -> Void)? = nil) {
        if config.asrEngine == .cloud {
            let configured = CloudKeyStore.apiKey() != nil
            if dictationManager?.effectiveEngine == .local {
                engineStatusItem?.title = "Local · fallback (cloud unavailable)"
                engineItem?.title = "Speech engine: local (cloud fallback)"
            } else {
                engineStatusItem?.title = "Cloud · OpenRouter · \(CloudDefaults.model)"
                engineItem?.title = configured
                    ? "Speech engine: cloud (\(CloudDefaults.model))"
                    : "Speech engine: cloud (no API key)"
            }
            completion?(nil)
            return
        }

        let probe = Transcriber(port: config.asrPort)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let health = probe.health()
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch health {
                case .ready(let model):
                    let short = model.split(separator: "/").last.map(String.init) ?? model
                    self.engineStatusItem?.title = "Local · ready (\(short))"
                    self.engineItem?.title = "Speech engine: ready (\(short))"
                case .loading:
                    self.engineStatusItem?.title = "Local · loading model…"
                    self.engineItem?.title = "Speech engine: loading model..."
                case .unreachable:
                    let problem = SidecarManager.installState().problem
                    self.engineStatusItem?.title = problem == nil
                        ? "Local · not running"
                        : "Local · not installed"
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
                persistConfig()
            } catch {
                notifyError("Failed to update launch-at-login: \(error.localizedDescription)")
            }
        } else {
            // Fallback: just save config
            launchItem.state = target ? .on : .off
            config.launchAtLogin = target
            persistConfig()
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
        if TextInserter.accessibilityGranted(prompt: false) {
            TextInserter.openAccessibilitySettings()
        } else {
            promptAccessibilityRepair()
        }
    }

    /// Shown when a paste has just failed, or from the menu when the grant is missing.
    ///
    /// Worth a modal rather than a notification: until this is fixed, every dictation ends
    /// with the user pressing ⌘V themselves, and the cause is invisible — System Settings
    /// keeps showing TalkType switched on.
    func promptAccessibilityRepair() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "TalkType cannot paste yet"
        alert.informativeText =
            "Your text is on the clipboard, but macOS has not given TalkType permission to "
            + "paste it for you.\n\n"
            + "TalkType is not signed with a paid Apple certificate, so each new version "
            + "arrives as a new app as far as macOS is concerned — even if System Settings "
            + "still shows TalkType switched on.\n\n"
            + "\"Fix This\" clears the stale entry and asks again. Then switch TalkType on "
            + "under Privacy & Security → Accessibility."
        alert.addButton(withTitle: "Fix This")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TextInserter.repairAccessibilityGrant()
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

// MARK: - NSMenuDelegate

extension TalkTypeApp: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === inputMenu { rebuildInputMenu() }
    }
}

// MARK: - TrayDelegate

extension TalkTypeApp: TrayDelegate {
    func setRecording(_ active: Bool) {
        DispatchQueue.main.async {
            self.setStatusSymbol(active ? .recording : .idle)
        }
    }

    func setProcessing(_ active: Bool) {
        DispatchQueue.main.async {
            self.setStatusSymbol(active ? .processing : .idle)
        }
    }

    func notifyError(_ message: String) {
        sendNotification(title: "TalkType", subtitle: "Error", body: message)
    }

    func notifyInfo(_ message: String) {
        sendNotification(title: "TalkType", subtitle: "", body: message)
    }

    func accessibilityMissing() {
        DispatchQueue.main.async { self.promptAccessibilityRepair() }
    }

    func engineStateDidChange(_ engine: ASREngine) {
        DispatchQueue.main.async {
            if engine == .local {
                self.startHealthPolling()
            } else {
                self.healthTimer?.invalidate()
                self.refreshEngineStatus()
            }
        }
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
