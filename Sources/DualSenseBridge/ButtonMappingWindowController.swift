import AppKit
import DualSenseBridgeCore

final class ButtonMappingWindowController: NSWindowController {
    var onMappingsChanged: (() -> Void)?

    private let settings: BridgeSettings
    private let audioInputManager: DualSenseAudioInputManager
    private var assignmentPopups: [ControllerShortcutButton: NSPopUpButton] = [:]
    private var recorders: [ControllerShortcutButton: ShortcutRecorderButton] = [:]
    private var chooseButtons: [ControllerShortcutButton: NSButton] = [:]
    private var microphoneToggles: [ControllerShortcutButton: NSButton] = [:]
    private let microphoneStatusLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: BridgeSettings, audioInputManager: DualSenseAudioInputManager) {
        self.settings = settings
        self.audioInputManager = audioInputManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 670),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Button Mapping"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.setFrameAutosaveName("DualSenseBridgeButtonMapping")

        super.init(window: window)
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        refreshControls()
        refreshMicrophoneStatus()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let window else { return }

        let titleLabel = NSTextField(labelWithString: "DualSense Button Mapping")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let descriptionLabel = NSTextField(wrappingLabelWithString:
            "Map every pressable DualSense control plus all four directions on both sticks. The Assignment menu shows whether a button emits a keyboard shortcut or performs a Fleet action. Fleet actions take priority and never type into the focused app."
        )
        descriptionLabel.textColor = .secondaryLabelColor

        let columnHeader: (String) -> NSTextField = { title in
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .semibold
            )
            label.textColor = .secondaryLabelColor
            return label
        }
        var rows: [[NSView]] = [[
            columnHeader("Button"),
            columnHeader("Assignment"),
            columnHeader("Shortcut"),
            NSView(),
            columnHeader("Microphone"),
            NSView()
        ]]
        for button in ControllerShortcutButton.allCases {
            let label = NSTextField(labelWithString: button.title)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            label.alignment = .right

            let assignmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            assignmentPopup.addItem(withTitle: "Keyboard / Built-in")
            assignmentPopup.lastItem?.tag = 0
            for action in FleetAction.allCases {
                assignmentPopup.addItem(withTitle: "Fleet: \(action.title)")
                assignmentPopup.lastItem?.tag = action.rawValue + 1
            }
            assignmentPopup.tag = button.rawValue
            assignmentPopup.target = self
            assignmentPopup.action = #selector(changeAssignment(_:))
            assignmentPopup.toolTip = "Choose the effective action for \(button.title)"
            assignmentPopup.setAccessibilityLabel("\(button.title) assignment")
            assignmentPopup.widthAnchor.constraint(equalToConstant: 225).isActive = true
            assignmentPopups[button] = assignmentPopup

            let recorder = ShortcutRecorderButton(
                shortcut: settings.shortcut(for: button),
                emptyTitle: button == .touchpadClick
                    ? "Mouse Click (Built-in)"
                    : "Not Set"
            )
            recorder.onShortcutChanged = { [weak self] shortcut in
                self?.settings.setShortcut(shortcut, for: button)
                self?.onMappingsChanged?()
                DiagnosticLog.write("mapping changed: \(button.title) → \(shortcut?.displayText ?? "Not Set")")
            }
            recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
            recorders[button] = recorder

            let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseMapping(_:)))
            chooseButton.tag = button.rawValue
            chooseButton.bezelStyle = .rounded
            chooseButton.toolTip = "Pick a key and modifiers without pressing the shortcut"
            chooseButtons[button] = chooseButton

            let microphoneToggle = NSButton(
                checkboxWithTitle: "Use PS5 Mic",
                target: self,
                action: #selector(toggleMicrophone(_:))
            )
            microphoneToggle.tag = button.rawValue
            microphoneToggle.state = settings.usesDualSenseMicrophone(for: button) ? .on : .off
            microphoneToggle.toolTip = "Use the DualSense microphone while this button's shortcut is held"
            microphoneToggles[button] = microphoneToggle

            let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearMapping(_:)))
            clearButton.tag = button.rawValue
            clearButton.bezelStyle = .rounded

            rows.append([
                label,
                assignmentPopup,
                recorder,
                chooseButton,
                microphoneToggle,
                clearButton
            ])
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .leading
        grid.column(at: 3).xPlacement = .leading
        grid.column(at: 4).xPlacement = .leading
        grid.column(at: 5).xPlacement = .leading

        let mappingDocument = NSView()
        mappingDocument.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        mappingDocument.addSubview(grid)

        let mappingScrollView = NSScrollView()
        mappingScrollView.hasVerticalScroller = true
        mappingScrollView.autohidesScrollers = true
        mappingScrollView.borderType = .bezelBorder
        mappingScrollView.drawsBackground = false
        mappingScrollView.documentView = mappingDocument
        mappingScrollView.heightAnchor.constraint(equalToConstant: 390).isActive = true

        NSLayoutConstraint.activate([
            mappingDocument.leadingAnchor.constraint(equalTo: mappingScrollView.contentView.leadingAnchor),
            mappingDocument.topAnchor.constraint(equalTo: mappingScrollView.contentView.topAnchor),
            mappingDocument.widthAnchor.constraint(equalTo: mappingScrollView.contentView.widthAnchor),
            grid.leadingAnchor.constraint(equalTo: mappingDocument.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: mappingDocument.trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: mappingDocument.topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: mappingDocument.bottomAnchor, constant: -8)
        ])

        let escapeHelp = NSTextField(wrappingLabelWithString:
            "Choose Keyboard / Built-in to record a shortcut, or select a Fleet action directly. A stored shortcut is preserved but inactive while Fleet owns its button. Clear removes both kinds of mapping. “Use PS5 Mic” routes the controller mic while its shortcut is held. “Mouse Click (Built-in)” retains the touchpad's normal click and Spaces gestures."
        )
        escapeHelp.textColor = .tertiaryLabelColor
        escapeHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        microphoneStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

        let resetButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        resetButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [resetButton, spacer, doneButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [titleLabel, descriptionLabel, mappingScrollView, microphoneStatusLabel, escapeHelp, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(8, after: titleLabel)
        stack.setCustomSpacing(20, after: descriptionLabel)
        stack.setCustomSpacing(20, after: mappingScrollView)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            mappingScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            microphoneStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            escapeHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func refreshControls() {
        for button in ControllerShortcutButton.allCases {
            let fleetAction = settings.fleetAction(boundTo: button)
            assignmentPopups[button]?.selectItem(
                withTag: fleetAction.map { $0.rawValue + 1 } ?? 0
            )
            recorders[button]?.shortcut = settings.shortcut(for: button)
            microphoneToggles[button]?.state = settings.usesDualSenseMicrophone(for: button) ? .on : .off
            let acceptsShortcut = fleetAction == nil
            recorders[button]?.isEnabled = acceptsShortcut
            chooseButtons[button]?.isEnabled = acceptsShortcut
            microphoneToggles[button]?.isEnabled = acceptsShortcut
            recorders[button]?.toolTip = acceptsShortcut
                ? "Click, then press a key or modifier combination. Click elsewhere to cancel."
                : "Inactive while this button performs a Fleet action."
        }
    }

    private func refreshMicrophoneStatus() {
        guard let name = audioInputManager.availableInputName else {
            microphoneStatusLabel.stringValue = "PS5 mic unavailable. For Bluetooth, install the bundled open-source DualSense Bridge Mic driver from the menu-bar app."
            microphoneStatusLabel.textColor = .systemOrange
            return
        }

        if audioInputManager.isDualSenseDefaultInput {
            microphoneStatusLabel.stringValue = "PS5 mic ready: \(name) is the current input."
            microphoneStatusLabel.textColor = .systemGreen
        } else {
            microphoneStatusLabel.stringValue = "PS5 mic available: \(name). It activates when an enabled button is held."
            microphoneStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func clearMapping(_ sender: NSButton) {
        guard let button = ControllerShortcutButton(rawValue: sender.tag) else { return }
        settings.assignFleetAction(nil, to: button)
        settings.setShortcut(nil, for: button)
        settings.setUsesDualSenseMicrophone(false, for: button)
        refreshControls()
        onMappingsChanged?()
        let clearedAction = button == .touchpadClick
            ? "Mouse Click (Built-in)"
            : "Not Set"
        DiagnosticLog.write("mapping changed: \(button.title) → \(clearedAction)")
    }

    @objc private func changeAssignment(_ sender: NSPopUpButton) {
        guard let button = ControllerShortcutButton(rawValue: sender.tag),
              let selectedTag = sender.selectedItem?.tag else {
            return
        }
        let action = selectedTag == 0
            ? nil
            : FleetAction(rawValue: selectedTag - 1)
        settings.assignFleetAction(action, to: button)
        refreshControls()
        onMappingsChanged?()
        let assignment = action.map { "Fleet: \($0.title)" }
            ?? settings.shortcut(for: button)?.displayText
            ?? (button == .touchpadClick ? "Mouse Click (Built-in)" : "Not Set")
        DiagnosticLog.write("mapping changed: \(button.title) → \(assignment)")
    }

    @objc private func chooseMapping(_ sender: NSButton) {
        guard let button = ControllerShortcutButton(rawValue: sender.tag),
              let window else {
            return
        }

        ManualShortcutEditor.present(
            for: button,
            currentShortcut: settings.shortcut(for: button),
            parentWindow: window
        ) { [weak self] shortcut in
            self?.settings.setShortcut(shortcut, for: button)
            self?.refreshControls()
            self?.onMappingsChanged?()
            DiagnosticLog.write("mapping manually changed: \(button.title) → \(shortcut.displayText)")
        }
    }

    @objc private func toggleMicrophone(_ sender: NSButton) {
        guard let button = ControllerShortcutButton(rawValue: sender.tag) else { return }
        let enabled = sender.state == .on
        settings.setUsesDualSenseMicrophone(enabled, for: button)
        onMappingsChanged?()

        guard enabled else {
            DiagnosticLog.write("PS5 mic disabled for \(button.title)")
            refreshMicrophoneStatus()
            return
        }
        DiagnosticLog.write("PS5 mic enabled for \(button.title); it will activate on button hold")
        refreshMicrophoneStatus()
    }

    @objc private func restoreDefaults() {
        settings.resetButtonMappings()
        refreshControls()
        refreshMicrophoneStatus()
        onMappingsChanged?()
        DiagnosticLog.write("button mappings restored to defaults")
    }

    @objc private func closeWindow() {
        close()
    }
}
