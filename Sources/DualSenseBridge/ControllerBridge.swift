import AppKit
import DualSenseBridgeCore
import Foundation
import GameController

enum ControllerConnectionTransport: Equatable {
    case usb
    case bluetooth

    var title: String {
        switch self {
        case .usb:
            return "USB (Plugged In)"
        case .bluetooth:
            return "Bluetooth"
        }
    }
}

enum ControllerBridgeStatus: Equatable {
    case searching
    case connected(
        name: String,
        transport: ControllerConnectionTransport,
        capabilities: String
    )
    case disconnected

    var summary: String {
        switch self {
        case .searching:
            return "Looking for a DualSense…"
        case let .connected(name, transport, _):
            return "Connected via \(transport.title): \(name)"
        case .disconnected:
            return "DualSense disconnected"
        }
    }
}

final class ControllerBridge {
    var onStatusChanged: ((ControllerBridgeStatus) -> Void)?

    /// Fired on the main thread when a button bound to a fleet action is
    /// pressed. Such buttons never emit their keystroke mapping.
    var onFleetAction: ((FleetAction) -> Void)?

    /// Present only while the GameController fallback path is attached; the
    /// raw HID paths seize the device away from the framework, so agent
    /// feedback must route through raw output reports instead.
    var gameControllerForFeedback: GCController? {
        activeController
    }

    private let settings: BridgeSettings
    private let mouse: MouseEventEmitter
    private let audioInputManager: DualSenseAudioInputManager
    private let usbInputMonitor: DualSenseUSBInputMonitor
    private let workspaceSwitcher = MacOSWorkspaceSwitcher()
    private var gestureEngine = GestureEngine()
    private var tapRecognizer = TouchpadTapRecognizer()
    private var workspaceSwipeRecognizer = TouchpadWorkspaceSwipeRecognizer()
    private var observers: [NSObjectProtocol] = []
    private weak var activeController: GCController?
    private var activeButton: BridgeMouseButton?
    private var activeButtonShortcuts: [ControllerShortcutButton: KeyboardShortcut] = [:]
    private var activeMicrophoneButtons: Set<ControllerShortcutButton> = []
    private var shortcutRepeatStartWorkItems: [ControllerShortcutButton: DispatchWorkItem] = [:]
    private var shortcutRepeatTimers: [ControllerShortcutButton: Timer] = [:]
    private var shortcutRepeatGenerations: [ControllerShortcutButton: UInt64] = [:]
    private var shortcutRepeatGenerationCounter: UInt64 = 0
    private var leftRawTrigger = AnalogTriggerLatch()
    private var rightRawTrigger = AnalogTriggerLatch()
    private var leftStickHorizontal = AnalogAxisDirectionLatch()
    private var leftStickVertical = AnalogAxisDirectionLatch()
    private var rightStickHorizontal = AnalogAxisDirectionLatch()
    private var rightStickVertical = AnalogAxisDirectionLatch()
    private var primaryEventCount = 0
    private var lastBluetoothGamepadState: DualSenseBluetoothGamepadState?
    private var lastUSBGamepadState: DualSenseBluetoothGamepadState?
    private var isBluetoothRawControllerActive = false
    private var isUSBRawControllerActive = false
    private var gameControllerMonitoringStarted = false
    private var activeTransport: ControllerConnectionTransport?
    private var transportReconciliationTimer: Timer?
    private var lastObservedUSBConnection = false
    private var consecutiveUSBMissingObservations = 0

    init(
        settings: BridgeSettings,
        mouse: MouseEventEmitter,
        audioInputManager: DualSenseAudioInputManager,
        usbInputMonitor: DualSenseUSBInputMonitor
    ) {
        self.settings = settings
        self.mouse = mouse
        self.audioInputManager = audioInputManager
        self.usbInputMonitor = usbInputMonitor
    }

    func start() {
        let usbConnected = isUSBConnectionAvailable
        DiagnosticLog.write(
            "bridge start; USB=\(usbConnected), USB exclusive=\(usbInputMonitor.hasExclusiveAccess), Bluetooth exclusive=\(audioInputManager.hasExclusiveBluetoothAccess)"
        )

        usbInputMonitor.onGamepadState = { [weak self] state in
            DispatchQueue.main.async {
                self?.usbGamepadStateChanged(state)
            }
        }
        usbInputMonitor.onConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                self?.usbConnectionChanged(connected)
            }
        }

        audioInputManager.onBluetoothGamepadState = { [weak self] state in
            DispatchQueue.main.async {
                self?.bluetoothGamepadStateChanged(state)
            }
        }
        audioInputManager.onBluetoothConnectionChanged = { [weak self] connected in
            DispatchQueue.main.async {
                self?.bluetoothConnectionChanged(connected)
            }
        }

        onStatusChanged?(.searching)
        lastObservedUSBConnection = usbConnected
        startTransportReconciliation()
        if usbInputMonitor.hasExclusiveAccess {
            activateUSBRawController()
        } else if usbConnected {
            startGameControllerMonitoring()
        } else if audioInputManager.hasExclusiveBluetoothAccess {
            activateBluetoothRawController()
        } else {
            startGameControllerMonitoring()
        }
    }

    private func installGameControllerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            DiagnosticLog.write("GCControllerDidConnect: \(controller.vendorName ?? "unknown")")
            guard let self else { return }
            if isUSBRawControllerActive {
                return
            }
            if isBluetoothRawControllerActive {
                if isUSBConnectionAvailable {
                    switchToUSBControllerPath(
                        reason: "USB GameController appeared while Bluetooth was active"
                    )
                }
                return
            }
            consider(controller)
        })

        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.controllerDisconnected(controller)
        })
    }

    private func startGameControllerMonitoring() {
        guard !gameControllerMonitoringStarted,
              !isBluetoothRawControllerActive,
              !isUSBRawControllerActive else { return }
        installGameControllerObservers()
        gameControllerMonitoringStarted = true
        GCController.shouldMonitorBackgroundEvents = true
        DiagnosticLog.write(
            "starting GameController monitoring for USB/fallback; candidates=\(GCController.controllers().count)"
        )
        attachFirstAvailableController()

        GCController.startWirelessControllerDiscovery { [weak self] in
            DispatchQueue.main.async {
                self?.attachFirstAvailableController()
            }
        }

        // Initial controller discovery is asynchronous, including for USB devices.
        for delay in [0.4, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                DiagnosticLog.write("discovery retry at \(delay)s; controller count=\(GCController.controllers().count)")
                self?.attachFirstAvailableController()
            }
        }
    }

    func stop() {
        transportReconciliationTimer?.invalidate()
        transportReconciliationTimer = nil
        if gameControllerMonitoringStarted {
            GCController.stopWirelessControllerDiscovery()
        }
        gameControllerMonitoringStarted = false
        audioInputManager.onBluetoothFaceButtonMaskChanged = nil
        audioInputManager.onBluetoothGamepadState = nil
        audioInputManager.onBluetoothConnectionChanged = nil
        usbInputMonitor.onGamepadState = nil
        usbInputMonitor.onConnectionChanged = nil
        removeGameControllerObservers()
        isBluetoothRawControllerActive = false
        isUSBRawControllerActive = false
        lastBluetoothGamepadState = nil
        lastUSBGamepadState = nil
        detachCurrentController()
        activeTransport = nil
    }

    func resetGestureState() {
        gestureEngine.reset()
        tapRecognizer.reset()
        workspaceSwipeRecognizer.reset()
        releaseActiveButtonShortcuts()
        leftRawTrigger.reset()
        rightRawTrigger.reset()
        leftStickHorizontal.reset()
        leftStickVertical.reset()
        rightStickHorizontal.reset()
        rightStickVertical.reset()
        mouse.releaseAnyHeldInputs()
        activeButton = nil
    }

    private func attachFirstAvailableController() {
        guard !isBluetoothRawControllerActive,
              !isUSBRawControllerActive,
              activeController == nil else { return }
        DiagnosticLog.write("attach scan; candidates=\(GCController.controllers().count)")
        for controller in GCController.controllers() {
            if consider(controller) { return }
        }
    }

    @discardableResult
    private func consider(_ controller: GCController) -> Bool {
        guard !isBluetoothRawControllerActive,
              !isUSBRawControllerActive else { return false }
        guard activeController == nil || activeController === controller else {
            return false
        }

        let profile = controller.physicalInputProfile
        let dualSense = controller.extendedGamepad as? GCDualSenseGamepad
        let primary = dualSense?.touchpadPrimary
            ?? profile.dpads[GCInputDualShockTouchpadOne]
        let secondary = dualSense?.touchpadSecondary
            ?? profile.dpads[GCInputDualShockTouchpadTwo]
        let button = dualSense?.touchpadButton
            ?? profile.buttons[GCInputDualShockTouchpadButton]
        let extendedGamepad = controller.extendedGamepad
        let dpad = extendedGamepad?.dpad
            ?? profile.dpads[GCInputDirectionPad]
        let leftThumbstick = extendedGamepad?.leftThumbstick
            ?? profile.dpads[GCInputLeftThumbstick]
        let rightThumbstick = extendedGamepad?.rightThumbstick
            ?? profile.dpads[GCInputRightThumbstick]
        var shortcutButtons: [ControllerShortcutButton: GCControllerButtonInput] = [:]
        shortcutButtons[.cross] = extendedGamepad?.buttonA
            ?? profile.buttons[GCInputButtonA]
        shortcutButtons[.circle] = extendedGamepad?.buttonB
            ?? profile.buttons[GCInputButtonB]
        shortcutButtons[.square] = extendedGamepad?.buttonX
            ?? profile.buttons[GCInputButtonX]
        shortcutButtons[.triangle] = extendedGamepad?.buttonY
            ?? profile.buttons[GCInputButtonY]
        shortcutButtons[.l1] = extendedGamepad?.leftShoulder
            ?? profile.buttons[GCInputLeftShoulder]
        shortcutButtons[.l2] = extendedGamepad?.leftTrigger
            ?? profile.buttons[GCInputLeftTrigger]
        shortcutButtons[.r1] = extendedGamepad?.rightShoulder
            ?? profile.buttons[GCInputRightShoulder]
        shortcutButtons[.r2] = extendedGamepad?.rightTrigger
            ?? profile.buttons[GCInputRightTrigger]
        shortcutButtons[.dpadUp] = dpad?.up
        shortcutButtons[.dpadRight] = dpad?.right
        shortcutButtons[.dpadDown] = dpad?.down
        shortcutButtons[.dpadLeft] = dpad?.left
        shortcutButtons[.l3] = extendedGamepad?.leftThumbstickButton
            ?? profile.buttons[GCInputLeftThumbstickButton]
        shortcutButtons[.r3] = extendedGamepad?.rightThumbstickButton
            ?? profile.buttons[GCInputRightThumbstickButton]
        shortcutButtons[.create] = extendedGamepad?.buttonOptions
            ?? profile.buttons[GCInputButtonShare]
            ?? profile.buttons[GCInputButtonOptions]
        shortcutButtons[.options] = extendedGamepad?.buttonMenu
            ?? profile.buttons[GCInputButtonMenu]
        shortcutButtons[.playStation] = extendedGamepad?.buttonHome
            ?? profile.buttons[GCInputButtonHome]
        shortcutButtons[.leftStickUp] = leftThumbstick?.up
        shortcutButtons[.leftStickRight] = leftThumbstick?.right
        shortcutButtons[.leftStickDown] = leftThumbstick?.down
        shortcutButtons[.leftStickLeft] = leftThumbstick?.left
        shortcutButtons[.rightStickUp] = rightThumbstick?.up
        shortcutButtons[.rightStickRight] = rightThumbstick?.right
        shortcutButtons[.rightStickDown] = rightThumbstick?.down
        shortcutButtons[.rightStickLeft] = rightThumbstick?.left

        let vendor = controller.vendorName ?? "Game Controller"
        let categoryMatches = controller.productCategory == GCProductCategoryDualSense
        let nameMatches = vendor.localizedCaseInsensitiveContains("dualsense")
            || vendor.localizedCaseInsensitiveContains("wireless controller")

        let mappedButtonNames = shortcutButtons.keys
            .map(\.title)
            .sorted()
            .joined(separator: ", ")
        DiagnosticLog.write(
            "candidate vendor=\(vendor) category=\(controller.productCategory) dualSenseProfile=\(dualSense != nil) primary=\(primary != nil) secondary=\(secondary != nil) touchpadButton=\(button != nil) mappedButtons=[\(mappedButtonNames)]"
        )

        guard (dualSense != nil || categoryMatches || nameMatches),
              let primary,
              let button else {
            return false
        }

        activeController = controller
        primaryEventCount = 0
        gestureEngine.reset()
        tapRecognizer.reset()
        configure(
            primary: primary,
            secondary: secondary,
            button: button,
            shortcutButtons: shortcutButtons
        )
        DiagnosticLog.write("attached and handlers configured for \(vendor)")

        var capabilities = ["Touchpad taps", "Button shortcuts"]
        if audioInputManager.availableInputName != nil { capabilities.append("PS5 mic") }
        if controller.motion != nil { capabilities.append("Motion") }
        if controller.haptics != nil { capabilities.append("Haptics") }
        if controller.light != nil { capabilities.append("Light bar") }
        if dualSense != nil { capabilities.append("Adaptive triggers") }

        let batteryText: String
        if let battery = controller.battery {
            batteryText = " • Battery \(Int((battery.batteryLevel * 100).rounded()))%"
        } else {
            batteryText = ""
        }

        // Raw Bluetooth is normally owned by the dedicated HID path above.
        // A DualSense reaching us through GameController with no live
        // Bluetooth HID match is therefore USB, even if Core Audio is still
        // enumerating the controller microphone.
        let transport: ControllerConnectionTransport
        if audioInputManager.isUSBConnected {
            transport = .usb
        } else if audioInputManager.isBluetoothConnected {
            transport = .bluetooth
        } else {
            transport = .usb
        }
        DiagnosticLog.write("active controller transport: \(transport.title)")
        activeTransport = transport
        onStatusChanged?(.connected(
            name: vendor,
            transport: transport,
            capabilities: capabilities.joined(separator: " • ") + batteryText
        ))
        return true
    }

    private func configure(
        primary: GCControllerDirectionPad,
        secondary: GCControllerDirectionPad?,
        button: GCControllerButtonInput,
        shortcutButtons: [ControllerShortcutButton: GCControllerButtonInput]
    ) {
        primary.valueChangedHandler = { [weak self] _, x, y in
            DispatchQueue.main.async {
                self?.primaryChanged(x: Double(x), y: Double(y))
            }
        }

        secondary?.valueChangedHandler = { [weak self] _, x, y in
            DispatchQueue.main.async {
                self?.secondaryChanged(x: Double(x), y: Double(y))
            }
        }

        button.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async {
                self?.touchpadButtonChanged(pressed: pressed)
            }
        }

        for (shortcutButton, input) in shortcutButtons {
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                DispatchQueue.main.async {
                    self?.shortcutButtonChanged(shortcutButton, pressed: pressed)
                }
            }
        }
    }

    private func primaryChanged(
        x: Double,
        y: Double,
        fromRawReport: Bool = false,
        contactIsActive: Bool? = nil
    ) {
        guard !audioInputManager.isBluetoothMicrophoneActive
                || fromRawReport else {
            gestureEngine.reset()
            tapRecognizer.reset()
            workspaceSwipeRecognizer.reset()
            return
        }
        primaryEventCount += 1
        if primaryEventCount <= 20 || primaryEventCount.isMultiple(of: 100) {
            DiagnosticLog.write("primary input #\(primaryEventCount) x=\(x) y=\(y) enabled=\(settings.isEnabled)")
        }
        guard settings.isEnabled else {
            gestureEngine.reset()
            workspaceSwipeRecognizer.reset()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let swipeDirection = workspaceSwipeRecognizer.primaryChanged(
            x: x,
            y: y,
            isActive: contactIsActive ?? (x != 0 || y != 0),
            at: now
        )
        if let swipeDirection {
            performWorkspaceSwipe(swipeDirection)
        }
        guard !workspaceSwipeRecognizer.isTracking else { return }

        scheduleTap(tapRecognizer.primaryChanged(x: x, y: y, at: now))

        guard case let .move(deltaX, deltaY) = gestureEngine.primaryChanged(
            x: x,
            y: y,
            at: now
        ) else {
            if primaryEventCount <= 20 {
                DiagnosticLog.write("primary input #\(primaryEventCount) established/reset baseline")
            }
            return
        }

        if primaryEventCount <= 20 {
            DiagnosticLog.write("primary action deltaX=\(deltaX) deltaY=\(deltaY)")
        }

        mouse.move(
            normalizedDeltaX: deltaX,
            normalizedDeltaY: deltaY,
            baseGain: settings.pointerSpeed.baseGain
        )
    }

    private func secondaryChanged(
        x: Double,
        y: Double,
        fromRawReport: Bool = false,
        contactIsActive: Bool? = nil
    ) {
        guard !audioInputManager.isBluetoothMicrophoneActive
                || fromRawReport else {
            gestureEngine.reset()
            tapRecognizer.reset()
            workspaceSwipeRecognizer.reset()
            return
        }
        guard settings.isEnabled else {
            gestureEngine.reset()
            workspaceSwipeRecognizer.reset()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let swipeDirection = workspaceSwipeRecognizer.secondaryChanged(
            x: x,
            y: y,
            isActive: contactIsActive ?? (x != 0 || y != 0),
            at: now
        )
        if let swipeDirection {
            performWorkspaceSwipe(swipeDirection)
        }
        guard !workspaceSwipeRecognizer.isTracking else { return }

        scheduleTap(tapRecognizer.secondaryChanged(x: x, y: y, at: now))

        guard case let .scroll(deltaX, deltaY) = gestureEngine.secondaryChanged(
            x: x,
            y: y,
            at: now
        ) else { return }

        mouse.scroll(
            normalizedDeltaX: deltaX,
            normalizedDeltaY: deltaY,
            natural: settings.naturalScrolling
        )
    }

    private func touchpadButtonChanged(
        pressed: Bool,
        fromRawReport: Bool = false
    ) {
        guard !audioInputManager.isBluetoothMicrophoneActive
                || fromRawReport else {
            if !pressed, let activeButton {
                mouse.setButton(activeButton, pressed: false)
                self.activeButton = nil
            }
            tapRecognizer.reset()
            workspaceSwipeRecognizer.reset()
            return
        }

        if settings.shortcut(for: .touchpadClick) != nil
            || activeButtonShortcuts[.touchpadClick] != nil
            || settings.fleetAction(boundTo: .touchpadClick) != nil {
            tapRecognizer.reset()
            workspaceSwipeRecognizer.reset()
            if let activeButton {
                mouse.setButton(activeButton, pressed: false)
                self.activeButton = nil
            }
            shortcutButtonChanged(
                .touchpadClick,
                pressed: pressed,
                fromRawReport: fromRawReport
            )
            return
        }

        guard settings.isEnabled else {
            if !pressed { resetGestureState() }
            return
        }

        tapRecognizer.touchpadButtonChanged(pressed: pressed)

        let swipeTransition = workspaceSwipeRecognizer.touchpadButtonChanged(
            pressed: pressed,
            at: ProcessInfo.processInfo.systemUptime
        )
        switch swipeTransition {
        case .began:
            if let activeButton {
                mouse.setButton(activeButton, pressed: false)
                self.activeButton = nil
            }
            gestureEngine.reset()
            DiagnosticLog.write("touchpad held with two fingers; workspace swipe armed")
            return
        case .endedAsRightClick:
            gestureEngine.reset()
            tapRecognizer.reset()
            DiagnosticLog.write("touchpad two-finger press without swipe → right click")
            mouse.click(.right)
            return
        case .endedAfterSwipe:
            gestureEngine.reset()
            tapRecognizer.reset()
            DiagnosticLog.write("touchpad workspace swipe completed; physical click suppressed")
            return
        case .endedCancelled:
            gestureEngine.reset()
            tapRecognizer.reset()
            DiagnosticLog.write("touchpad held gesture cancelled; no click or Space change")
            return
        case .ignored:
            break
        }

        if pressed {
            let button = gestureEngine.mouseButton(
                at: ProcessInfo.processInfo.systemUptime,
                rightSideClickEnabled: settings.rightSideClickEnabled
            )
            DiagnosticLog.write(
                "touchpad physical press → \(button == .left ? "left" : "right") click; right-side mode=\(settings.rightSideClickEnabled)"
            )
            activeButton = button
            mouse.setButton(button, pressed: true)
        } else if let activeButton {
            mouse.setButton(activeButton, pressed: false)
            self.activeButton = nil
        }
    }

    private func shortcutButtonChanged(
        _ button: ControllerShortcutButton,
        pressed: Bool,
        fromRawReport: Bool = false
    ) {
        // Audio feedback frames share report ID 0x31 with gamepad input. The
        // GameController framework can interpret encoded audio bytes as input,
        // so raw, marker-filtered button states are authoritative while the
        // Bluetooth microphone is active.
        if audioInputManager.isBluetoothMicrophoneActive,
           !fromRawReport {
            return
        }

        // Fleet actions intercept the button entirely: no keystroke down, no
        // repeat, nothing on release. Semantic controls must never type.
        if let action = settings.fleetAction(boundTo: button) {
            // A binding created while the button's previous shortcut was
            // still held must deliver that shortcut's release, or the key
            // sticks down and repeats forever.
            if activeButtonShortcuts[button] != nil {
                cancelShortcutRepeat(for: button)
                if let shortcut = activeButtonShortcuts.removeValue(forKey: button) {
                    mouse.setKeyboardShortcut(shortcut, pressed: false)
                }
                if activeMicrophoneButtons.remove(button) != nil {
                    audioInputManager.deactivate()
                }
            }
            if pressed, settings.isEnabled {
                onFleetAction?(action)
            }
            return
        }

        if pressed {
            guard settings.isEnabled,
                  activeButtonShortcuts[button] == nil,
                  let shortcut = settings.shortcut(for: button) else {
                return
            }

            if settings.usesDualSenseMicrophone(for: button) {
                switch audioInputManager.activate() {
                case let .activated(name):
                    DiagnosticLog.write("\(button.title) selected PS5 mic: \(name)")
                    activeMicrophoneButtons.insert(button)
                case .unavailable:
                    DiagnosticLog.write("\(button.title) requested PS5 mic, but no DualSense audio input is available")
                case let .failed(message):
                    DiagnosticLog.write("\(button.title) could not select PS5 mic: \(message)")
                }
            }

            activeButtonShortcuts[button] = shortcut
            DiagnosticLog.write("\(button.title) → \(shortcut.displayText) down")
            mouse.setKeyboardShortcut(shortcut, pressed: true)
            scheduleShortcutRepeat(
                for: button,
                shortcut: shortcut
            )
        } else {
            cancelShortcutRepeat(for: button)
            guard let shortcut = activeButtonShortcuts.removeValue(forKey: button) else {
                return
            }
            DiagnosticLog.write("\(button.title) → \(shortcut.displayText) up")
            mouse.setKeyboardShortcut(shortcut, pressed: false)
            if activeMicrophoneButtons.remove(button) != nil {
                audioInputManager.deactivate()
            }
        }
    }

    private func bluetoothGamepadStateChanged(
        _ state: DualSenseBluetoothGamepadState
    ) {
        guard isBluetoothRawControllerActive else { return }
        let previous = lastBluetoothGamepadState
        lastBluetoothGamepadState = state
        processRawGamepadState(state, previous: previous, source: "Bluetooth")
    }

    private func usbGamepadStateChanged(
        _ state: DualSenseBluetoothGamepadState
    ) {
        guard isUSBRawControllerActive else { return }
        let previous = lastUSBGamepadState
        lastUSBGamepadState = state
        processRawGamepadState(state, previous: previous, source: "USB")
    }

    private func processRawGamepadState(
        _ state: DualSenseBluetoothGamepadState,
        previous: DualSenseBluetoothGamepadState?,
        source: String
    ) {

        updateRawTouch(
            state.primaryTouch,
            previous: previous?.primaryTouch,
            isPrimary: true
        )
        updateRawTouch(
            state.secondaryTouch,
            previous: previous?.secondaryTouch,
            isPrimary: false
        )

        if previous?.touchpadButtonPressed != state.touchpadButtonPressed {
            touchpadButtonChanged(
                pressed: state.touchpadButtonPressed,
                fromRawReport: true
            )
        }

        updateRawShortcutButtons(state, previous: previous, source: source)
    }

    private func updateRawTouch(
        _ point: DualSenseBluetoothTouchPoint,
        previous: DualSenseBluetoothTouchPoint?,
        isPrimary: Bool
    ) {
        guard point != previous else { return }
        if point.isActive {
            if isPrimary {
                primaryChanged(
                    x: point.normalizedX,
                    y: point.normalizedY,
                    fromRawReport: true,
                    contactIsActive: true
                )
            } else {
                secondaryChanged(
                    x: point.normalizedX,
                    y: point.normalizedY,
                    fromRawReport: true,
                    contactIsActive: true
                )
            }
        } else if previous?.isActive == true {
            if isPrimary {
                primaryChanged(
                    x: 0,
                    y: 0,
                    fromRawReport: true,
                    contactIsActive: false
                )
            } else {
                secondaryChanged(
                    x: 0,
                    y: 0,
                    fromRawReport: true,
                    contactIsActive: false
                )
            }
        }
    }

    private func updateRawShortcutButtons(
        _ state: DualSenseBluetoothGamepadState,
        previous: DualSenseBluetoothGamepadState?,
        source: String
    ) {
        let faceBits: [(ControllerShortcutButton, UInt8)] = [
            (.square, 0x10),
            (.cross, 0x20),
            (.circle, 0x40),
            (.triangle, 0x80)
        ]
        updateRawDigitalButtons(
            faceBits,
            mask: state.faceButtonMask,
            previousMask: previous?.faceButtonMask ?? 0,
            source: source
        )

        let dpadBits: [(ControllerShortcutButton, UInt8)] = [
            (.dpadUp, 0x01),
            (.dpadRight, 0x02),
            (.dpadDown, 0x04),
            (.dpadLeft, 0x08)
        ]
        updateRawDigitalButtons(
            dpadBits,
            mask: state.dpadDirectionMask,
            previousMask: previous?.dpadDirectionMask ?? 0,
            source: source
        )

        let shoulderBits: [(ControllerShortcutButton, UInt8)] = [
            (.l1, 0x01),
            (.r1, 0x02)
        ]
        updateRawDigitalButtons(
            shoulderBits,
            mask: state.shoulderButtonMask,
            previousMask: previous?.shoulderButtonMask ?? 0,
            source: source
        )

        let auxiliaryBits: [(ControllerShortcutButton, UInt8)] = [
            (.create, 0x10),
            (.options, 0x20),
            (.l3, 0x40),
            (.r3, 0x80)
        ]
        updateRawDigitalButtons(
            auxiliaryBits,
            mask: state.auxiliaryButtonMask,
            previousMask: previous?.auxiliaryButtonMask ?? 0,
            source: source
        )

        updateRawBooleanButton(
            .playStation,
            pressed: state.playStationButtonPressed,
            wasPressed: previous?.playStationButtonPressed ?? false,
            source: source
        )
        updateRawBooleanButton(
            .mute,
            pressed: state.microphoneButtonPressed,
            wasPressed: previous?.microphoneButtonPressed ?? false,
            source: source
        )

        let leftHorizontalUpdate = leftStickHorizontal.update(
            value: state.leftStickX
        )
        emitRawAxisUpdate(
            leftHorizontalUpdate,
            negativeButton: .leftStickLeft,
            positiveButton: .leftStickRight,
            source: source
        )
        let leftVerticalUpdate = leftStickVertical.update(
            value: state.leftStickY
        )
        emitRawAxisUpdate(
            leftVerticalUpdate,
            negativeButton: .leftStickUp,
            positiveButton: .leftStickDown,
            source: source
        )
        let rightHorizontalUpdate = rightStickHorizontal.update(
            value: state.rightStickX
        )
        emitRawAxisUpdate(
            rightHorizontalUpdate,
            negativeButton: .rightStickLeft,
            positiveButton: .rightStickRight,
            source: source
        )
        let rightVerticalUpdate = rightStickVertical.update(
            value: state.rightStickY
        )
        emitRawAxisUpdate(
            rightVerticalUpdate,
            negativeButton: .rightStickUp,
            positiveButton: .rightStickDown,
            source: source
        )

        if let pressed = leftRawTrigger.update(value: state.leftTriggerValue) {
            emitRawButtonEdge(.l2, pressed: pressed, source: source)
        }
        if let pressed = rightRawTrigger.update(value: state.rightTriggerValue) {
            emitRawButtonEdge(.r2, pressed: pressed, source: source)
        }
    }

    private func updateRawDigitalButtons(
        _ bits: [(ControllerShortcutButton, UInt8)],
        mask: UInt8,
        previousMask: UInt8,
        source: String
    ) {
        for (button, bit) in bits {
            let pressed = mask & bit != 0
            let wasPressed = previousMask & bit != 0
            if pressed != wasPressed {
                emitRawButtonEdge(button, pressed: pressed, source: source)
            }
        }
    }

    private func updateRawBooleanButton(
        _ button: ControllerShortcutButton,
        pressed: Bool,
        wasPressed: Bool,
        source: String
    ) {
        guard pressed != wasPressed else { return }
        emitRawButtonEdge(button, pressed: pressed, source: source)
    }

    private func emitRawAxisUpdate(
        _ update: AnalogAxisDirectionUpdate,
        negativeButton: ControllerShortcutButton,
        positiveButton: ControllerShortcutButton,
        source: String
    ) {
        if let pressed = update.negativePressed {
            emitRawButtonEdge(negativeButton, pressed: pressed, source: source)
        }
        if let pressed = update.positivePressed {
            emitRawButtonEdge(positiveButton, pressed: pressed, source: source)
        }
    }

    private func emitRawButtonEdge(
        _ button: ControllerShortcutButton,
        pressed: Bool,
        source: String
    ) {
        DiagnosticLog.write(
            "raw \(source) \(button.title) \(pressed ? "down" : "up")"
        )
        shortcutButtonChanged(
            button,
            pressed: pressed,
            fromRawReport: true
        )
    }

    private var isUSBConnectionAvailable: Bool {
        usbInputMonitor.isConnected || audioInputManager.isUSBConnected
    }

    private func usbConnectionChanged(_ connected: Bool) {
        if connected, usbInputMonitor.hasExclusiveAccess {
            activateUSBRawController()
            return
        }

        guard !connected, isUSBRawControllerActive else { return }
        DiagnosticLog.write("raw USB DualSense disconnected")
        isUSBRawControllerActive = false
        lastUSBGamepadState = nil
        activeTransport = nil
        resetGestureState()
        onStatusChanged?(.disconnected)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reconcilePreferredTransport()
        }
    }

    private func activateUSBRawController() {
        guard usbInputMonitor.hasExclusiveAccess else { return }
        guard !isUSBRawControllerActive else { return }

        if gameControllerMonitoringStarted {
            GCController.stopWirelessControllerDiscovery()
            gameControllerMonitoringStarted = false
        }
        if activeController != nil {
            detachCurrentController()
        }
        removeGameControllerObservers()

        if isBluetoothRawControllerActive {
            isBluetoothRawControllerActive = false
            lastBluetoothGamepadState = nil
            resetGestureState()
        }

        isUSBRawControllerActive = true
        activeTransport = .usb
        lastUSBGamepadState = nil
        gestureEngine.reset()
        tapRecognizer.reset()
        leftRawTrigger.reset()
        rightRawTrigger.reset()
        leftStickHorizontal.reset()
        leftStickVertical.reset()
        rightStickHorizontal.reset()
        rightStickVertical.reset()
        primaryEventCount = 0
        DiagnosticLog.write(
            "raw USB DualSense attached under HID isolation; 19 physical buttons and 8 virtual stick directions available"
        )
        onStatusChanged?(.connected(
            name: "DualSense Wireless Controller",
            transport: .usb,
            capabilities: "Touchpad taps • 27 button/direction shortcuts • Native PS5 mic"
        ))
    }

    private func bluetoothConnectionChanged(_ connected: Bool) {
        if connected, isUSBConnectionAvailable {
            DiagnosticLog.write(
                "Bluetooth DualSense connected while USB is available; keeping USB authoritative"
            )
            switchToUSBControllerPath(
                reason: "late Bluetooth connection must not replace USB"
            )
            return
        }

        if connected, audioInputManager.hasExclusiveBluetoothAccess {
            activateBluetoothRawController()
            return
        }

        guard !connected, isBluetoothRawControllerActive else { return }
        DiagnosticLog.write("raw Bluetooth DualSense disconnected")
        isBluetoothRawControllerActive = false
        lastBluetoothGamepadState = nil
        activeTransport = nil
        resetGestureState()
        onStatusChanged?(.disconnected)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.onStatusChanged?(.searching)
            self.startGameControllerMonitoring()
        }
    }

    private func activateBluetoothRawController() {
        guard !isUSBConnectionAvailable else {
            switchToUSBControllerPath(
                reason: "Bluetooth activation was rejected because USB is available"
            )
            return
        }
        guard !isBluetoothRawControllerActive else { return }
        if gameControllerMonitoringStarted {
            GCController.stopWirelessControllerDiscovery()
            gameControllerMonitoringStarted = false
        }
        if activeController != nil {
            detachCurrentController()
        }
        removeGameControllerObservers()
        isUSBRawControllerActive = false
        lastUSBGamepadState = nil
        isBluetoothRawControllerActive = true
        activeTransport = .bluetooth
        lastBluetoothGamepadState = nil
        resetGestureState()
        primaryEventCount = 0
        DiagnosticLog.write("raw Bluetooth DualSense attached under continuous HID isolation")
        onStatusChanged?(.connected(
            name: "DualSense Wireless Controller",
            transport: .bluetooth,
            capabilities: "Touchpad taps • 27 button/direction shortcuts • Bluetooth PS5 mic"
        ))
    }

    /// Keeps the data-bearing USB connection authoritative whenever it is
    /// available. The Bluetooth HID monitor remains isolated in the
    /// background so a simultaneous radio connection cannot inject duplicate
    /// controller events, but its reports are ignored until USB is removed.
    private func switchToUSBControllerPath(reason: String) {
        guard isUSBConnectionAvailable else { return }
        DiagnosticLog.write("selecting USB controller path: \(reason)")

        if usbInputMonitor.hasExclusiveAccess {
            activateUSBRawController()
            return
        }

        if isBluetoothRawControllerActive {
            isBluetoothRawControllerActive = false
            lastBluetoothGamepadState = nil
            activeTransport = nil
            resetGestureState()
        } else if activeTransport == .bluetooth, activeController != nil {
            detachCurrentController()
        }

        guard activeTransport != .usb || activeController == nil else { return }
        onStatusChanged?(.searching)
        startGameControllerMonitoring()
        attachFirstAvailableController()
    }

    private func startTransportReconciliation() {
        guard transportReconciliationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reconcilePreferredTransport()
        }
        transportReconciliationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Handles cable changes even while the raw Bluetooth path owns the HID
    /// device and GameController therefore cannot always deliver a USB event.
    private func reconcilePreferredTransport() {
        let usbConnected = isUSBConnectionAvailable
        if usbConnected {
            let newlyDetected = !lastObservedUSBConnection
            consecutiveUSBMissingObservations = 0
            if newlyDetected {
                DiagnosticLog.write("USB DualSense data connection detected")
            }
            lastObservedUSBConnection = true
            if usbInputMonitor.hasExclusiveAccess {
                activateUSBRawController()
                return
            }
            if isBluetoothRawControllerActive
                || activeTransport == .bluetooth
                || (newlyDetected && activeController == nil) {
                switchToUSBControllerPath(reason: "periodic transport reconciliation")
            }
            return
        }

        consecutiveUSBMissingObservations += 1
        var usbWasRemoved = false
        if lastObservedUSBConnection {
            // Core Audio can briefly re-enumerate a USB device. Requiring two
            // misses prevents a momentary dropout from switching transports.
            guard consecutiveUSBMissingObservations >= 2 else { return }
            lastObservedUSBConnection = false
            usbWasRemoved = true
            DiagnosticLog.write("USB DualSense data connection no longer available")

            if activeTransport == .usb {
                if isUSBRawControllerActive {
                    isUSBRawControllerActive = false
                    lastUSBGamepadState = nil
                    activeTransport = nil
                    resetGestureState()
                } else if activeController != nil {
                    detachCurrentController()
                }
                onStatusChanged?(.disconnected)
            }
        }

        guard !isBluetoothRawControllerActive,
              !isUSBRawControllerActive,
              activeController == nil else { return }
        if audioInputManager.hasExclusiveBluetoothAccess {
            activateBluetoothRawController()
        } else if !gameControllerMonitoringStarted {
            onStatusChanged?(.searching)
            startGameControllerMonitoring()
        } else if usbWasRemoved {
            onStatusChanged?(.searching)
            attachFirstAvailableController()
        }
    }

    private func removeGameControllerObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func scheduleShortcutRepeat(
        for button: ControllerShortcutButton,
        shortcut: KeyboardShortcut
    ) {
        guard button.repeatsWhileHeld else { return }
        cancelShortcutRepeat(for: button)
        shortcutRepeatGenerationCounter &+= 1
        let generation = shortcutRepeatGenerationCounter
        shortcutRepeatGenerations[button] = generation

        let startWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shortcutRepeatGenerations[button] == generation,
                  self.activeButtonShortcuts[button] == shortcut else {
                return
            }
            self.shortcutRepeatStartWorkItems.removeValue(forKey: button)
            self.mouse.repeatKeyboardShortcut(shortcut)

            let interval = max(NSEvent.keyRepeatInterval, 0.01)
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
                guard let self,
                      self.shortcutRepeatGenerations[button] == generation,
                      self.activeButtonShortcuts[button] == shortcut else {
                    timer.invalidate()
                    return
                }
                self.mouse.repeatKeyboardShortcut(shortcut)
            }
            self.shortcutRepeatTimers[button] = timer
            RunLoop.main.add(timer, forMode: .common)
            DiagnosticLog.write(
                String(
                    format: "%@ keyboard repeat started; delay=%.3fs interval=%.3fs",
                    button.title,
                    NSEvent.keyRepeatDelay,
                    interval
                )
            )
        }
        shortcutRepeatStartWorkItems[button] = startWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(NSEvent.keyRepeatDelay, 0),
            execute: startWorkItem
        )
    }

    private func cancelShortcutRepeat(for button: ControllerShortcutButton) {
        shortcutRepeatGenerationCounter &+= 1
        shortcutRepeatGenerations.removeValue(forKey: button)
        shortcutRepeatStartWorkItems.removeValue(forKey: button)?.cancel()
        shortcutRepeatTimers.removeValue(forKey: button)?.invalidate()
    }

    private func cancelAllShortcutRepeats() {
        shortcutRepeatGenerationCounter &+= 1
        shortcutRepeatGenerations.removeAll()
        shortcutRepeatStartWorkItems.values.forEach { $0.cancel() }
        shortcutRepeatStartWorkItems.removeAll()
        shortcutRepeatTimers.values.forEach { $0.invalidate() }
        shortcutRepeatTimers.removeAll()
    }

    private func releaseActiveButtonShortcuts() {
        cancelAllShortcutRepeats()
        for (button, shortcut) in activeButtonShortcuts {
            DiagnosticLog.write("\(button.title) → \(shortcut.displayText) released during reset")
            mouse.setKeyboardShortcut(shortcut, pressed: false)
        }
        activeButtonShortcuts.removeAll()
        let microphoneButtonCount = activeMicrophoneButtons.count
        activeMicrophoneButtons.removeAll()
        for _ in 0..<microphoneButtonCount {
            audioInputManager.deactivate()
        }
    }

    private func performWorkspaceSwipe(_ direction: WorkspaceSwipeDirection) {
        let shortcut = direction.macOSSpaceShortcut
        let fingerDirection = direction == .left ? "left" : "right"
        let spaceDirection = direction == .left ? "right" : "left"
        if workspaceSwitcher.switchSpace(for: direction) {
            DiagnosticLog.write(
                "touchpad held two-finger swipe \(fingerDirection) → native Space \(spaceDirection) gesture"
            )
        } else {
            DiagnosticLog.write(
                "native Space gesture unavailable; falling back to \(shortcut.displayText)"
            )
            mouse.pressKeyboardShortcut(shortcut)
        }
    }

    private func scheduleTap(_ candidate: TapCandidate?) {
        guard let candidate else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + candidate.delay) { [weak self] in
            guard let self,
                  settings.isEnabled,
                  let button = tapRecognizer.consumePendingTap(id: candidate.id) else {
                return
            }

            DiagnosticLog.write("touchpad tap → \(button == .left ? "left" : "right") click")
            mouse.click(button)
        }
    }

    private func controllerDisconnected(_ controller: GCController) {
        guard !isBluetoothRawControllerActive,
              !isUSBRawControllerActive else { return }
        guard activeController === controller else { return }
        if audioInputManager.isBluetoothMicrophoneActive {
            // Expected while the raw HID device is seized so macOS cannot
            // interpret proprietary microphone packets as system controls.
            DiagnosticLog.write("GCController detached during isolated Bluetooth microphone session")
            activeController = nil
            activeTransport = nil
            return
        }
        DiagnosticLog.write("active controller disconnected")
        detachCurrentController()
        onStatusChanged?(.disconnected)

        if !isUSBConnectionAvailable,
           audioInputManager.hasExclusiveBluetoothAccess {
            activateBluetoothRawController()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.onStatusChanged?(.searching)
            self?.attachFirstAvailableController()
        }
    }

    private func detachCurrentController() {
        if let dualSense = activeController?.extendedGamepad as? GCDualSenseGamepad {
            dualSense.touchpadPrimary.valueChangedHandler = nil
            dualSense.touchpadSecondary.valueChangedHandler = nil
            dualSense.touchpadButton.pressedChangedHandler = nil
        } else if let profile = activeController?.physicalInputProfile {
            profile.dpads[GCInputDualShockTouchpadOne]?.valueChangedHandler = nil
            profile.dpads[GCInputDualShockTouchpadTwo]?.valueChangedHandler = nil
            profile.buttons[GCInputDualShockTouchpadButton]?.pressedChangedHandler = nil
        }
        if let gamepad = activeController?.extendedGamepad {
            gamepad.buttonA.pressedChangedHandler = nil
            gamepad.buttonB.pressedChangedHandler = nil
            gamepad.buttonX.pressedChangedHandler = nil
            gamepad.buttonY.pressedChangedHandler = nil
            gamepad.leftShoulder.pressedChangedHandler = nil
            gamepad.leftTrigger.pressedChangedHandler = nil
            gamepad.rightShoulder.pressedChangedHandler = nil
            gamepad.rightTrigger.pressedChangedHandler = nil
            gamepad.dpad.up.pressedChangedHandler = nil
            gamepad.dpad.right.pressedChangedHandler = nil
            gamepad.dpad.down.pressedChangedHandler = nil
            gamepad.dpad.left.pressedChangedHandler = nil
            gamepad.leftThumbstickButton?.pressedChangedHandler = nil
            gamepad.rightThumbstickButton?.pressedChangedHandler = nil
            gamepad.buttonMenu.pressedChangedHandler = nil
            gamepad.buttonOptions?.pressedChangedHandler = nil
            gamepad.buttonHome?.pressedChangedHandler = nil
            gamepad.leftThumbstick.up.pressedChangedHandler = nil
            gamepad.leftThumbstick.right.pressedChangedHandler = nil
            gamepad.leftThumbstick.down.pressedChangedHandler = nil
            gamepad.leftThumbstick.left.pressedChangedHandler = nil
            gamepad.rightThumbstick.up.pressedChangedHandler = nil
            gamepad.rightThumbstick.right.pressedChangedHandler = nil
            gamepad.rightThumbstick.down.pressedChangedHandler = nil
            gamepad.rightThumbstick.left.pressedChangedHandler = nil
        }
        if let profile = activeController?.physicalInputProfile {
            profile.buttons[GCInputButtonA]?.pressedChangedHandler = nil
            profile.buttons[GCInputButtonB]?.pressedChangedHandler = nil
            profile.buttons[GCInputButtonX]?.pressedChangedHandler = nil
            profile.buttons[GCInputButtonY]?.pressedChangedHandler = nil
            profile.buttons[GCInputLeftShoulder]?.pressedChangedHandler = nil
            profile.buttons[GCInputLeftTrigger]?.pressedChangedHandler = nil
            profile.buttons[GCInputRightShoulder]?.pressedChangedHandler = nil
            profile.buttons[GCInputRightTrigger]?.pressedChangedHandler = nil
            profile.dpads[GCInputDirectionPad]?.up.pressedChangedHandler = nil
            profile.dpads[GCInputDirectionPad]?.right.pressedChangedHandler = nil
            profile.dpads[GCInputDirectionPad]?.down.pressedChangedHandler = nil
            profile.dpads[GCInputDirectionPad]?.left.pressedChangedHandler = nil
            profile.buttons[GCInputLeftThumbstickButton]?.pressedChangedHandler = nil
            profile.buttons[GCInputRightThumbstickButton]?.pressedChangedHandler = nil
            profile.buttons[GCInputButtonShare]?.pressedChangedHandler = nil
            profile.buttons[GCInputButtonOptions]?.pressedChangedHandler = nil
            profile.buttons[GCInputButtonMenu]?.pressedChangedHandler = nil
            profile.buttons[GCInputButtonHome]?.pressedChangedHandler = nil
            profile.dpads[GCInputLeftThumbstick]?.up.pressedChangedHandler = nil
            profile.dpads[GCInputLeftThumbstick]?.right.pressedChangedHandler = nil
            profile.dpads[GCInputLeftThumbstick]?.down.pressedChangedHandler = nil
            profile.dpads[GCInputLeftThumbstick]?.left.pressedChangedHandler = nil
            profile.dpads[GCInputRightThumbstick]?.up.pressedChangedHandler = nil
            profile.dpads[GCInputRightThumbstick]?.right.pressedChangedHandler = nil
            profile.dpads[GCInputRightThumbstick]?.down.pressedChangedHandler = nil
            profile.dpads[GCInputRightThumbstick]?.left.pressedChangedHandler = nil
        }

        resetGestureState()
        activeController = nil
        activeTransport = nil
    }
}
