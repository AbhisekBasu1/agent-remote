import AppKit
import DualSenseBridgeCore
import ServiceManagement

final class StatusMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let settings: BridgeSettings
    private let mouse: MouseEventEmitter
    private let bridge: ControllerBridge
    private let audioInputManager: DualSenseAudioInputManager
    private let agentFeedback: AgentFeedbackController
    private let agentInstaller = AgentIntegrationInstaller()
    private let microphoneDriverManager = BundledMicrophoneDriverManager()
    private var loadedButtonMappingWindowController: ButtonMappingWindowController?
    private var buttonMappingWindowController: ButtonMappingWindowController {
        if let loadedButtonMappingWindowController {
            return loadedButtonMappingWindowController
        }
        let controller = ButtonMappingWindowController(
            settings: settings,
            audioInputManager: audioInputManager
        )
        controller.onMappingsChanged = { [weak self] in
            self?.refreshSettingsState()
        }
        loadedButtonMappingWindowController = controller
        return controller
    }

    private let connectionItem = NSMenuItem(title: "Looking for a DualSense…", action: nil, keyEquivalent: "")
    private let capabilitiesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Agent Remote Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let naturalScrollItem = NSMenuItem(title: "Natural Scrolling", action: #selector(toggleNaturalScrolling), keyEquivalent: "")
    private let rightClickItem = NSMenuItem(title: "Right Side Press = Right Click", action: #selector(toggleRightSideClick), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let microphoneDriverItem = NSMenuItem(
        title: "Install Open-Source Bluetooth Mic Driver…",
        action: #selector(installMicrophoneDriver),
        keyEquivalent: ""
    )
    private let microphoneDriverUninstallItem = NSMenuItem(
        title: "Uninstall Bluetooth Mic Driver…",
        action: #selector(uninstallMicrophoneDriver),
        keyEquivalent: ""
    )
    private let agentStatusItem = NSMenuItem(title: "Agent: Idle", action: nil, keyEquivalent: "")
    private let sessionsItem = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
    private let sessionsMenu = NSMenu(title: "Sessions")
    private let agentPassiveWatchingItem = NSMenuItem(
        title: "Watch Sessions Automatically",
        action: #selector(toggleAgentPassiveWatching),
        keyEquivalent: ""
    )
    private let agentPlayerLEDsItem = NSMenuItem(
        title: "Player LEDs Show Focus",
        action: #selector(toggleAgentPlayerLEDs),
        keyEquivalent: ""
    )
    private let agentLightbarItem = NSMenuItem(
        title: "Lightbar Shows Agent State",
        action: #selector(toggleAgentLightbar),
        keyEquivalent: ""
    )
    private let agentHapticsItem = NSMenuItem(
        title: "Haptic Alerts",
        action: #selector(toggleAgentHaptics),
        keyEquivalent: ""
    )
    private var speedItems: [NSMenuItem] = []
    private var microphoneLevelItems: [NSMenuItem] = []
    private var bluetoothMicrophoneSoundItems: [NSMenuItem] = []
    private var agentColorItems: [NSMenuItem] = []
    private var agentPatternItems: [NSMenuItem] = []
    private var agentStrengthItems: [NSMenuItem] = []
    private var agentReminderItems: [NSMenuItem] = []
    private var fleetButtonItems: [NSMenuItem] = []
    private var accessibilityTimer: Timer?

    init(
        settings: BridgeSettings,
        mouse: MouseEventEmitter,
        bridge: ControllerBridge,
        audioInputManager: DualSenseAudioInputManager,
        agentFeedback: AgentFeedbackController
    ) {
        self.settings = settings
        self.mouse = mouse
        self.bridge = bridge
        self.audioInputManager = audioInputManager
        self.agentFeedback = agentFeedback
        super.init()

        configureStatusItem()
        configureMenu()
        refreshSettingsState()
        refreshAccessibilityState()
        refreshMicrophoneDriverState()

        bridge.onStatusChanged = { [weak self] status in
            self?.apply(status: status)
            self?.agentFeedback.controllerStatusChanged(status)
            self?.onConnectionStatusChanged?(status)
        }
        agentFeedback.onActivityChanged = { [weak self] summary in
            self?.agentStatusItem.title = "Agent: \(summary)"
        }
    }

    func startMonitoringAccessibility() {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshAccessibilityState()
        }
    }

    func stop() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        bridge.onStatusChanged = nil
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = makeStatusItemImage()
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel("Agent Remote")
        button.toolTip = "Agent Remote"
        statusItem.menu = menu
    }

    private func makeStatusItemImage() -> NSImage? {
        if let url = Bundle.main.url(
            forResource: "AgentRemoteMenuBarIcon",
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            // The Agent Remote mark is intentionally white in every
            // appearance; template images would be recolored by AppKit.
            image.isTemplate = false
            return image
        }

        // Keep development builds usable if they are run without the app
        // packaging step that installs the custom resource.
        return NSImage(
            systemSymbolName: "sparkle",
            accessibilityDescription: "Agent Remote"
        )
    }

    private func configureMenu() {
        let title = NSMenuItem(title: "Agent Remote", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        connectionItem.isEnabled = false
        menu.addItem(connectionItem)

        capabilitiesItem.isEnabled = false
        capabilitiesItem.isHidden = true
        menu.addItem(capabilitiesItem)

        accessibilityItem.isEnabled = false
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())

        enabledItem.target = self
        menu.addItem(enabledItem)

        let speedItem = NSMenuItem(title: "Pointer Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu(title: "Pointer Speed")
        for speed in BridgeSettings.PointerSpeed.allCases {
            let item = NSMenuItem(title: speed.title, action: #selector(setPointerSpeed(_:)), keyEquivalent: "")
            item.tag = speed.rawValue
            item.target = self
            speedMenu.addItem(item)
            speedItems.append(item)
        }
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)

        naturalScrollItem.target = self
        menu.addItem(naturalScrollItem)

        rightClickItem.target = self
        menu.addItem(rightClickItem)

        let microphoneLevelItem = NSMenuItem(
            title: "Microphone Level",
            action: nil,
            keyEquivalent: ""
        )
        let microphoneLevelMenu = NSMenu(title: "Microphone Level")
        for level in BridgeSettings.MicrophoneLevel.allCases {
            let item = NSMenuItem(
                title: level.title,
                action: #selector(setMicrophoneLevel(_:)),
                keyEquivalent: ""
            )
            item.tag = level.rawValue
            item.target = self
            microphoneLevelMenu.addItem(item)
            microphoneLevelItems.append(item)
        }
        microphoneLevelItem.submenu = microphoneLevelMenu
        menu.addItem(microphoneLevelItem)

        let bluetoothMicrophoneSoundItem = NSMenuItem(
            title: "Bluetooth Mic Sound",
            action: nil,
            keyEquivalent: ""
        )
        let bluetoothMicrophoneSoundMenu = NSMenu(title: "Bluetooth Mic Sound")
        for sound in BridgeSettings.BluetoothMicrophoneSound.allCases {
            let item = NSMenuItem(
                title: sound.title,
                action: #selector(setBluetoothMicrophoneSound(_:)),
                keyEquivalent: ""
            )
            item.tag = sound.rawValue
            item.target = self
            bluetoothMicrophoneSoundMenu.addItem(item)
            bluetoothMicrophoneSoundItems.append(item)
        }
        bluetoothMicrophoneSoundItem.submenu = bluetoothMicrophoneSoundMenu
        menu.addItem(bluetoothMicrophoneSoundItem)

        menu.addItem(.separator())
        menu.addItem(makeAgentFeedbackItem())

        menu.addItem(.separator())
        let buttonMappingItem = NSMenuItem(title: "Button Mapping…", action: #selector(openButtonMapping), keyEquivalent: "")
        buttonMappingItem.target = self
        menu.addItem(buttonMappingItem)

        menu.addItem(.separator())
        let movementHelp = NSMenuItem(title: "One finger: move/tap • Two fingers: scroll/right tap", action: nil, keyEquivalent: "")
        movementHelp.isEnabled = false
        menu.addItem(movementHelp)
        let clickHelp = NSMenuItem(title: "Press touchpad: click/drag • Face buttons: configurable", action: nil, keyEquivalent: "")
        clickHelp.isEnabled = false
        menu.addItem(clickHelp)
        let spacesHelp = NSMenuItem(title: "Hold touchpad + two-finger swipe: switch Spaces", action: nil, keyEquivalent: "")
        spacesHelp.isEnabled = false
        menu.addItem(spacesHelp)

        menu.addItem(.separator())
        let requestAccessItem = NSMenuItem(title: "Request Accessibility Access…", action: #selector(requestAccessibility), keyEquivalent: "")
        requestAccessItem.target = self
        menu.addItem(requestAccessItem)

        let openSettingsItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        openSettingsItem.target = self
        menu.addItem(openSettingsItem)

        microphoneDriverItem.target = self
        menu.addItem(microphoneDriverItem)
        microphoneDriverUninstallItem.target = self
        menu.addItem(microphoneDriverUninstallItem)

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Agent Remote", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// The five agent states are tracked per-color and the alert events
    /// per-pattern; the (event, choice) pair rides in the menu item tag as
    /// `eventIndex * 100 + choiceRawValue` so one selector serves every row.
    private static let agentEventOrder = AgentActivityEvent.allCases
    private static let agentAlertEvents: [AgentActivityEvent] = [.attention, .done, .error]

    private func makeAgentFeedbackItem() -> NSMenuItem {
        let container = NSMenuItem(title: "Agent Feedback", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Agent Feedback")

        agentStatusItem.isEnabled = false
        submenu.addItem(agentStatusItem)
        sessionsItem.submenu = sessionsMenu
        submenu.addItem(sessionsItem)
        updateSessionsList([], slotFor: { _ in nil })
        submenu.addItem(.separator())

        // Passive watching reads the transcripts the harnesses already
        // write; it needs no hook installation, so it leads the submenu as
        // the zero-setup integration.
        agentPassiveWatchingItem.target = self
        submenu.addItem(agentPassiveWatchingItem)
        agentPlayerLEDsItem.target = self
        submenu.addItem(agentPlayerLEDsItem)

        // Fleet controls are semantic actions, remappable to any button; a
        // bound button never emits its keystroke mapping. Tag encodes
        // (action, choice) as actionRaw * 1000 + buttonRaw + 1, with 0 = Off.
        let fleetItem = NSMenuItem(title: "Fleet Controls", action: nil, keyEquivalent: "")
        let fleetMenu = NSMenu(title: "Fleet Controls")
        for action in FleetAction.allCases {
            let actionItem = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            let actionMenu = NSMenu(title: action.title)
            let offItem = NSMenuItem(
                title: "Off",
                action: #selector(setFleetButton(_:)),
                keyEquivalent: ""
            )
            offItem.tag = action.rawValue * 1000
            offItem.target = self
            actionMenu.addItem(offItem)
            fleetButtonItems.append(offItem)
            for button in ControllerShortcutButton.allCases {
                let buttonItem = NSMenuItem(
                    title: button.title,
                    action: #selector(setFleetButton(_:)),
                    keyEquivalent: ""
                )
                buttonItem.tag = action.rawValue * 1000 + button.rawValue + 1
                buttonItem.target = self
                actionMenu.addItem(buttonItem)
                fleetButtonItems.append(buttonItem)
            }
            actionItem.submenu = actionMenu
            fleetMenu.addItem(actionItem)
        }
        fleetItem.submenu = fleetMenu
        submenu.addItem(fleetItem)
        submenu.addItem(.separator())

        agentLightbarItem.target = self
        submenu.addItem(agentLightbarItem)

        let colorsItem = NSMenuItem(title: "Lightbar Colors", action: nil, keyEquivalent: "")
        let colorsMenu = NSMenu(title: "Lightbar Colors")
        for (eventIndex, event) in Self.agentEventOrder.enumerated() {
            let stateItem = NSMenuItem(title: event.title, action: nil, keyEquivalent: "")
            let stateMenu = NSMenu(title: event.title)
            for color in BridgeSettings.AgentLightbarColor.allCases {
                let item = NSMenuItem(
                    title: color.title,
                    action: #selector(setAgentColor(_:)),
                    keyEquivalent: ""
                )
                item.tag = eventIndex * 100 + color.rawValue
                item.target = self
                stateMenu.addItem(item)
                agentColorItems.append(item)
            }
            stateItem.submenu = stateMenu
            colorsMenu.addItem(stateItem)
        }
        colorsItem.submenu = colorsMenu
        submenu.addItem(colorsItem)

        submenu.addItem(.separator())
        agentHapticsItem.target = self
        submenu.addItem(agentHapticsItem)

        let strengthItem = NSMenuItem(title: "Haptic Strength", action: nil, keyEquivalent: "")
        let strengthMenu = NSMenu(title: "Haptic Strength")
        for strength in BridgeSettings.AgentHapticStrength.allCases {
            let item = NSMenuItem(
                title: strength.title,
                action: #selector(setAgentStrength(_:)),
                keyEquivalent: ""
            )
            item.tag = strength.rawValue
            item.target = self
            strengthMenu.addItem(item)
            agentStrengthItems.append(item)
        }
        strengthItem.submenu = strengthMenu
        submenu.addItem(strengthItem)

        let patternsItem = NSMenuItem(title: "Haptic Patterns", action: nil, keyEquivalent: "")
        let patternsMenu = NSMenu(title: "Haptic Patterns")
        for event in Self.agentAlertEvents {
            guard let eventIndex = Self.agentEventOrder.firstIndex(of: event) else { continue }
            let eventItem = NSMenuItem(title: event.title, action: nil, keyEquivalent: "")
            let eventMenu = NSMenu(title: event.title)
            for pattern in AgentHapticPatternKind.allCases {
                let item = NSMenuItem(
                    title: Self.title(for: pattern),
                    action: #selector(setAgentPattern(_:)),
                    keyEquivalent: ""
                )
                item.tag = eventIndex * 100 + pattern.rawValue
                item.target = self
                eventMenu.addItem(item)
                agentPatternItems.append(item)
            }
            eventItem.submenu = eventMenu
            patternsMenu.addItem(eventItem)
        }
        patternsItem.submenu = patternsMenu
        submenu.addItem(patternsItem)

        let reminderItem = NSMenuItem(title: "Attention Reminder", action: nil, keyEquivalent: "")
        let reminderMenu = NSMenu(title: "Attention Reminder")
        for reminder in BridgeSettings.AgentAttentionReminder.allCases {
            let item = NSMenuItem(
                title: reminder.title,
                action: #selector(setAgentReminder(_:)),
                keyEquivalent: ""
            )
            item.tag = reminder.rawValue
            item.target = self
            reminderMenu.addItem(item)
            agentReminderItems.append(item)
        }
        reminderItem.submenu = reminderMenu
        submenu.addItem(reminderItem)

        submenu.addItem(.separator())
        let testItem = NSMenuItem(
            title: "Test Agent Feedback",
            action: #selector(testAgentFeedback),
            keyEquivalent: ""
        )
        testItem.target = self
        submenu.addItem(testItem)

        submenu.addItem(.separator())
        let claudeItem = NSMenuItem(
            title: "Install Claude Code Hooks…",
            action: #selector(installClaudeHooks),
            keyEquivalent: ""
        )
        claudeItem.target = self
        submenu.addItem(claudeItem)
        let codexItem = NSMenuItem(
            title: "Connect Codex Notifications…",
            action: #selector(installCodexNotify),
            keyEquivalent: ""
        )
        codexItem.target = self
        submenu.addItem(codexItem)

        container.submenu = submenu
        return container
    }

    private static func title(for pattern: AgentHapticPatternKind) -> String {
        switch pattern {
        case .none: return "Off"
        case .tap: return "Tap"
        case .doubleTap: return "Double Tap"
        case .buzz: return "Buzz"
        }
    }

    private func apply(status: ControllerBridgeStatus) {
        connectionItem.title = status.summary

        switch status {
        case let .connected(_, transport, capabilities):
            capabilitiesItem.title = capabilities
            capabilitiesItem.isHidden = false
            connectionItem.image = NSImage(
                systemSymbolName: transport == .usb
                    ? "cable.connector"
                    : "antenna.radiowaves.left.and.right",
                accessibilityDescription: transport.title
            )
            statusItem.button?.toolTip = "Agent Remote — \(transport.title)"
            statusItem.button?.contentTintColor = settings.isEnabled ? .systemGreen : .secondaryLabelColor
        case .searching:
            capabilitiesItem.isHidden = true
            connectionItem.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: "Searching"
            )
            statusItem.button?.toolTip = "Agent Remote — Searching"
            statusItem.button?.contentTintColor = .secondaryLabelColor
        case .disconnected:
            capabilitiesItem.isHidden = true
            connectionItem.image = NSImage(
                systemSymbolName: "exclamationmark.circle",
                accessibilityDescription: "Disconnected"
            )
            statusItem.button?.toolTip = "Agent Remote — Disconnected"
            statusItem.button?.contentTintColor = .secondaryLabelColor
        }
    }

    private func refreshSettingsState() {
        enabledItem.state = settings.isEnabled ? .on : .off
        naturalScrollItem.state = settings.naturalScrolling ? .on : .off
        rightClickItem.state = settings.rightSideClickEnabled ? .on : .off
        for item in speedItems {
            item.state = item.tag == settings.pointerSpeed.rawValue ? .on : .off
        }
        for item in microphoneLevelItems {
            item.state = item.tag == settings.microphoneLevel.rawValue ? .on : .off
        }
        for item in bluetoothMicrophoneSoundItems {
            item.state = item.tag == settings.bluetoothMicrophoneSound.rawValue ? .on : .off
        }

        agentPassiveWatchingItem.state = settings.agentPassiveWatchingEnabled ? .on : .off
        agentPlayerLEDsItem.state = settings.agentPlayerLEDsEnabled ? .on : .off
        agentLightbarItem.state = settings.agentLightbarEnabled ? .on : .off
        agentHapticsItem.state = settings.agentHapticsEnabled ? .on : .off
        for item in agentStrengthItems {
            item.state = item.tag == settings.agentHapticStrength.rawValue ? .on : .off
        }
        for item in agentReminderItems {
            item.state = item.tag == settings.agentAttentionReminder.rawValue ? .on : .off
        }
        for item in agentColorItems {
            let event = Self.agentEventOrder[item.tag / 100]
            let isSelected = item.tag % 100 == settings.agentLightbarColor(for: event).rawValue
            item.state = isSelected ? .on : .off
        }
        for item in agentPatternItems {
            let event = Self.agentEventOrder[item.tag / 100]
            let isSelected = item.tag % 100 == settings.agentHapticPattern(for: event).rawValue
            item.state = isSelected ? .on : .off
        }
        for item in fleetButtonItems {
            guard let action = FleetAction(rawValue: item.tag / 1000) else { continue }
            let choice = item.tag % 1000
            let bound = settings.fleetButton(for: action)
            let isSelected = choice == 0
                ? bound == nil
                : bound?.rawValue == choice - 1
            item.state = isSelected ? .on : .off
        }

        if #available(macOS 13.0, *) {
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    private func refreshAccessibilityState() {
        if mouse.isAccessibilityTrusted {
            accessibilityItem.title = "Accessibility: Allowed"
            accessibilityItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        } else {
            accessibilityItem.title = "Accessibility: Approval Required"
            accessibilityItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        }
    }

    private func refreshMicrophoneDriverState() {
        switch microphoneDriverManager.state {
        case .missing:
            microphoneDriverItem.title = "Install Open-Source Bluetooth Mic Driver…"
            microphoneDriverItem.isEnabled = true
            microphoneDriverItem.state = .off
            microphoneDriverUninstallItem.isHidden = true
        case .updateAvailable:
            microphoneDriverItem.title = "Update Open-Source Bluetooth Mic Driver…"
            microphoneDriverItem.isEnabled = true
            microphoneDriverItem.state = .off
            microphoneDriverUninstallItem.isHidden = false
        case .installed:
            microphoneDriverItem.title = "Bluetooth Mic Driver: Installed"
            microphoneDriverItem.isEnabled = false
            microphoneDriverItem.state = .on
            microphoneDriverUninstallItem.isHidden = false
        }
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        if !settings.isEnabled {
            bridge.resetGestureState()
        }
        refreshSettingsState()
        statusItem.button?.contentTintColor = settings.isEnabled ? .systemGreen : .secondaryLabelColor
    }

    @objc private func setPointerSpeed(_ sender: NSMenuItem) {
        guard let speed = BridgeSettings.PointerSpeed(rawValue: sender.tag) else { return }
        settings.pointerSpeed = speed
        refreshSettingsState()
    }

    @objc private func toggleNaturalScrolling() {
        settings.naturalScrolling.toggle()
        refreshSettingsState()
    }

    @objc private func toggleRightSideClick() {
        settings.rightSideClickEnabled.toggle()
        refreshSettingsState()
    }

    @objc private func setMicrophoneLevel(_ sender: NSMenuItem) {
        guard let level = BridgeSettings.MicrophoneLevel(rawValue: sender.tag) else {
            return
        }
        settings.microphoneLevel = level
        audioInputManager.setBluetoothMicrophoneVolume(level.controllerGain)
        DiagnosticLog.write(
            "Bluetooth microphone level set to \(level.title) (\(level.controllerGain))"
        )
        refreshSettingsState()
    }

    @objc private func setBluetoothMicrophoneSound(_ sender: NSMenuItem) {
        guard let sound = BridgeSettings.BluetoothMicrophoneSound(
            rawValue: sender.tag
        ) else {
            return
        }
        settings.bluetoothMicrophoneSound = sound
        audioInputManager.setBluetoothMicrophoneSound(sound)
        DiagnosticLog.write("Bluetooth microphone sound set to \(sound.title)")
        refreshSettingsState()
    }

    /// Set by the app delegate; receives the new enabled state so the
    /// session-log watcher can start or stop immediately.
    var onPassiveWatchingChanged: ((Bool) -> Void)?
    /// Set by the app delegate; notifies the session-indicator controller.
    var onPlayerLEDsChanged: (() -> Void)?
    /// Set by the app delegate; forwards connection changes to listeners
    /// beyond the feedback controller (currently the LED slots).
    var onConnectionStatusChanged: ((ControllerBridgeStatus) -> Void)?

    /// Set by the app delegate; a clicked session focuses and raises it.
    var onSessionSelected: ((String) -> Void)?

    /// Rebuilds the menu's session list. Fleet ordinals are sticky, and each
    /// five-session page reuses the five physical cursor positions. "▶"
    /// marks the session currently represented on the controller.
    func updateSessionsList(
        _ sessions: [AgentSessionSummary],
        focusedID: String? = nil,
        slotFor: (String) -> Int?
    ) {
        sessionsMenu.removeAllItems()
        if sessions.isEmpty {
            sessionsItem.title = "Sessions: none"
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sessionsMenu.addItem(empty)
            return
        }

        let waiting = sessions.filter { $0.event == .attention || $0.event == .error }.count
        let working = sessions.filter { $0.event == .working }.count
        var headline = "Sessions: \(sessions.count)"
        if waiting > 0 {
            headline += " (\(waiting) waiting)"
        } else if working > 0 {
            headline += " (\(working) working)"
        }
        sessionsItem.title = headline

        let ordered = sessions.sorted { left, right in
            let leftSlot = slotFor(left.id) ?? Int.max
            let rightSlot = slotFor(right.id) ?? Int.max
            if leftSlot != rightSlot { return leftSlot < rightSlot }
            return left.id < right.id
        }
        for session in ordered {
            let slot: String
            if let ordinal = slotFor(session.id),
               let physicalSlot = AgentSessionIndicators.cursorSlot(
                   forSessionOrdinal: ordinal
               ),
               let page = AgentSessionIndicators.cursorPage(
                   forSessionOrdinal: ordinal
               ) {
                let diagram = AgentSessionIndicators.focusDiagram(
                    forPosition: physicalSlot
                ) ?? ""
                slot = sessions.count > AgentSessionIndicators.slotCount
                    ? "F\(ordinal + 1) · page \(page) \(diagram)"
                    : "F\(ordinal + 1) \(diagram)"
            } else {
                slot = "— ○○○○○"
            }
            let stateTitle = session.isInferred && session.event == .attention
                ? "Waiting?"
                : session.event.title
            let focusMarker = session.id == focusedID ? "▶ " : ""
            let item = NSMenuItem(
                title: "\(focusMarker)\(slot)  \(stateTitle) — \(session.displayName)",
                action: #selector(selectSession(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = session.id as NSString
            sessionsMenu.addItem(item)
        }
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSessionSelected?(id)
    }

    @objc private func toggleAgentPassiveWatching() {
        settings.agentPassiveWatchingEnabled.toggle()
        onPassiveWatchingChanged?(settings.agentPassiveWatchingEnabled)
        refreshSettingsState()
    }

    @objc private func toggleAgentPlayerLEDs() {
        settings.agentPlayerLEDsEnabled.toggle()
        onPlayerLEDsChanged?()
        refreshSettingsState()
    }

    @objc private func setFleetButton(_ sender: NSMenuItem) {
        guard let action = FleetAction(rawValue: sender.tag / 1000) else { return }
        let choice = sender.tag % 1000
        let button = choice == 0
            ? nil
            : ControllerShortcutButton(rawValue: choice - 1)
        if let button {
            settings.assignFleetAction(action, to: button)
        } else {
            settings.setFleetButton(nil, for: action)
        }
        loadedButtonMappingWindowController?.refreshControls()
        refreshSettingsState()
    }

    @objc private func toggleAgentLightbar() {
        settings.agentLightbarEnabled.toggle()
        agentFeedback.refreshFromSettings()
        refreshSettingsState()
    }

    @objc private func toggleAgentHaptics() {
        settings.agentHapticsEnabled.toggle()
        agentFeedback.refreshFromSettings()
        refreshSettingsState()
    }

    @objc private func setAgentColor(_ sender: NSMenuItem) {
        let event = Self.agentEventOrder[sender.tag / 100]
        guard let color = BridgeSettings.AgentLightbarColor(rawValue: sender.tag % 100) else {
            return
        }
        settings.setAgentLightbarColor(color, for: event)
        agentFeedback.refreshFromSettings()
        refreshSettingsState()
    }

    @objc private func setAgentPattern(_ sender: NSMenuItem) {
        let event = Self.agentEventOrder[sender.tag / 100]
        guard let pattern = AgentHapticPatternKind(rawValue: sender.tag % 100) else {
            return
        }
        settings.setAgentHapticPattern(pattern, for: event)
        refreshSettingsState()
    }

    @objc private func setAgentStrength(_ sender: NSMenuItem) {
        guard let strength = BridgeSettings.AgentHapticStrength(rawValue: sender.tag) else {
            return
        }
        settings.agentHapticStrength = strength
        refreshSettingsState()
    }

    @objc private func setAgentReminder(_ sender: NSMenuItem) {
        guard let reminder = BridgeSettings.AgentAttentionReminder(rawValue: sender.tag) else {
            return
        }
        settings.agentAttentionReminder = reminder
        agentFeedback.refreshFromSettings()
        refreshSettingsState()
    }

    @objc private func testAgentFeedback() {
        agentFeedback.runFeedbackTest()
    }

    @objc private func installClaudeHooks() {
        let confirm = NSAlert()
        confirm.messageText = "Install Claude Code Hooks?"
        confirm.informativeText = "This adds Agent Remote hook commands to ~/.claude/settings.json so Claude Code reports working, attention, done, and idle states to your controller. A backup of the current file is kept alongside it."
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "Install")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        present(outcome: agentInstaller.installClaudeHooks(), integration: "Claude Code")
    }

    @objc private func installCodexNotify() {
        let confirm = NSAlert()
        confirm.messageText = "Connect Codex Notifications?"
        confirm.informativeText = "This sets the top-level notify entry in ~/.codex/config.toml so Codex CLI reports turn completion to your controller. Codex supports a single notify program, so an existing entry is replaced; a backup of the current file is kept alongside it."
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "Connect")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        present(outcome: agentInstaller.installCodexNotify(), integration: "Codex")
    }

    private func present(
        outcome: AgentIntegrationInstaller.InstallOutcome,
        integration: String
    ) {
        let alert = NSAlert()
        switch outcome {
        case let .installed(detail):
            alert.messageText = "\(integration) Connected"
            alert.informativeText = detail
            alert.alertStyle = .informational
        case let .alreadyInstalled(detail):
            alert.messageText = "\(integration) Already Connected"
            alert.informativeText = detail
            alert.alertStyle = .informational
        case let .failed(message):
            alert.messageText = "Couldn’t Connect \(integration)"
            alert.informativeText = message
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    @objc private func requestAccessibility() {
        _ = mouse.requestAccessibilityAccess(showPrompt: true)
        refreshAccessibilityState()
    }

    @objc private func openButtonMapping() {
        buttonMappingWindowController.showWindow(nil)
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func installMicrophoneDriver() {
        let alert = NSAlert()
        alert.messageText = microphoneDriverManager.state == .updateAvailable
            ? "Update DualSense Bridge Mic?"
            : "Install DualSense Bridge Mic?"
        alert.informativeText = "This installs the open-source virtual microphone shipped inside Agent Remote. The replacement is staged and verified before the live driver changes. macOS will request an administrator password and briefly restart system audio."
        alert.alertStyle = .informational
        alert.addButton(withTitle: microphoneDriverManager.state == .updateAvailable ? "Update" : "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try microphoneDriverManager.install()
            refreshMicrophoneDriverState()
            let success = NSAlert()
            success.messageText = "DualSense Bridge Mic Installed"
            success.informativeText = "The project-owned virtual microphone is ready. Reopen Button Mapping to see its status."
            success.alertStyle = .informational
            success.runModal()
        } catch {
            presentError(
                title: "Couldn’t install DualSense Bridge Mic",
                message: error.localizedDescription
            )
        }
    }

    @objc private func uninstallMicrophoneDriver() {
        let alert = NSAlert()
        alert.messageText = "Uninstall DualSense Bridge Mic?"
        alert.informativeText = "This removes only Agent Remote’s virtual microphone from /Library/Audio/Plug-Ins/HAL. macOS will request an administrator password and briefly restart system audio."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try microphoneDriverManager.uninstall()
            refreshMicrophoneDriverState()
            let success = NSAlert()
            success.messageText = "DualSense Bridge Mic Uninstalled"
            success.informativeText = "The virtual microphone was removed."
            success.alertStyle = .informational
            success.runModal()
        } catch {
            presentError(
                title: "Couldn’t uninstall DualSense Bridge Mic",
                message: error.localizedDescription
            )
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentError(title: "Couldn’t change Launch at Login", message: error.localizedDescription)
        }
        refreshSettingsState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
