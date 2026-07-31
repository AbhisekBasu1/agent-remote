import AppKit
import DualSenseBridgeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let microphoneSelfTestRequested = ProcessInfo.processInfo.arguments.contains(
        "--microphone-self-test"
    )
    private lazy var settings = BridgeSettings()
    private let mouse = MouseEventEmitter()
    private let usbInputMonitor = DualSenseUSBInputMonitor()
    private let bluetoothEnhancedModeEnabler = DualSenseBluetoothEnhancedModeEnabler()
    private lazy var audioInputManager = DualSenseAudioInputManager(
        bluetoothHID: bluetoothEnhancedModeEnabler,
        usbHID: usbInputMonitor
    )
    private lazy var bridge = ControllerBridge(
        settings: settings,
        mouse: mouse,
        audioInputManager: audioInputManager,
        usbInputMonitor: usbInputMonitor
    )
    private lazy var agentFeedback = AgentFeedbackController(
        settings: settings,
        bluetoothHID: bluetoothEnhancedModeEnabler,
        usbInputMonitor: usbInputMonitor,
        audioInputManager: audioInputManager,
        gameControllerProvider: { [weak self] in
            self?.bridge.gameControllerForFeedback
        }
    )
    private let agentEventMonitor = AgentEventMonitor()
    private let agentSessionLogWatcher = AgentSessionLogWatcher()
    private lazy var sessionIndicators = SessionIndicatorController(
        settings: settings,
        bluetoothHID: bluetoothEnhancedModeEnabler,
        usbInputMonitor: usbInputMonitor,
        audioInputManager: audioInputManager
    )
    private lazy var fleetFocus = FleetFocusController(
        feedback: agentFeedback,
        slotProvider: { [weak self] id in
            self?.sessionIndicators.slot(forSessionID: id)
        }
    )
    private var lastSessionSummaries: [AgentSessionSummary] = []
    private lazy var statusMenu = StatusMenuController(
        settings: settings,
        mouse: mouse,
        bridge: bridge,
        audioInputManager: audioInputManager,
        agentFeedback: agentFeedback
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.beginSession()
        BridgeSettings.migrateLegacyDefaultsIfNeeded()

        // Install the raw-report callbacks and seize Bluetooth before doing
        // Core Audio enumeration or constructing the status UI. A DualSense
        // microphone stream is sticky; after an app update/restart, even a
        // short unowned startup window can let audio-tagged 0x31 reports reach
        // GameController and be mistaken for a system-button shortcut.
        _ = audioInputManager
        audioInputManager.setBluetoothMicrophoneVolume(
            settings.microphoneLevel.controllerGain
        )
        audioInputManager.setBluetoothMicrophoneSound(
            settings.bluetoothMicrophoneSound
        )
        bluetoothEnhancedModeEnabler.start()
        usbInputMonitor.start()

        DiagnosticLog.write("app launched; accessibilityTrusted=\(mouse.isAccessibilityTrusted)")
        audioInputManager.restoreDefaultInputIfStranded()
        audioInputManager.prewarmBluetoothAudioPath()
        _ = statusMenu
        statusMenu.startMonitoringAccessibility()
        _ = mouse.requestAccessibilityAccess(showPrompt: true)

        // Every callback must be installed before bridge.start(): with a
        // controller already attached, .connected is emitted synchronously
        // and a late-installed forwarding closure would miss it.
        audioInputManager.onMicrophoneSessionEnded = { [weak self] in
            self?.agentFeedback.microphoneSessionEnded()
            self?.sessionIndicators.microphoneSessionEnded()
        }
        agentEventMonitor.onEvent = { [weak self] envelope in
            self?.agentFeedback.handle(envelope)
        }
        agentSessionLogWatcher.onEvent = { [weak self] envelope in
            self?.agentFeedback.handle(envelope)
        }
        agentSessionLogWatcher.onSessionsChanged = { [weak self] sessions in
            guard let self else { return }
            self.lastSessionSummaries = sessions
            self.sessionIndicators.update(sessions: sessions)
            self.fleetFocus.update(sessions: sessions)
            self.renderSessionsList()
        }
        bridge.onFleetAction = { [weak self] action in
            self?.fleetFocus.perform(action)
        }
        fleetFocus.onFocusChanged = { [weak self] focused in
            guard let self else { return }
            self.renderSessionsList()
            if let focused,
               let slot = self.sessionIndicators.slot(forSessionID: focused.id) {
                self.sessionIndicators.identify(slot: slot)
            } else {
                self.sessionIndicators.finishIdentification()
            }
        }
        statusMenu.onSessionSelected = { [weak self] id in
            self?.fleetFocus.focusAndRaise(sessionID: id)
        }
        statusMenu.onPlayerLEDsChanged = { [weak self] in
            self?.sessionIndicators.refreshFromSettings()
        }
        statusMenu.onConnectionStatusChanged = { [weak self] status in
            self?.sessionIndicators.controllerStatusChanged(status)
        }
        statusMenu.onPassiveWatchingChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.agentSessionLogWatcher.start()
            } else {
                self.agentSessionLogWatcher.stop()
                self.agentFeedback.passiveWatchingDisabled()
                // The watcher's own empty-list publish is suppressed once
                // deliveries stop; clear the session list and LED slots
                // directly so nothing stays frozen at its last state.
                self.lastSessionSummaries = []
                self.sessionIndicators.update(sessions: [])
                self.fleetFocus.update(sessions: [])
                self.renderSessionsList()
            }
        }

        bridge.start()
        agentEventMonitor.start()
        if settings.agentPassiveWatchingEnabled {
            agentSessionLogWatcher.start()
        }
        if microphoneSelfTestRequested {
            scheduleMicrophoneSelfTest(attempt: 1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentSessionLogWatcher.stop()
        agentEventMonitor.stop()
        sessionIndicators.shutdown()
        agentFeedback.shutdown()
        statusMenu.stop()
        bridge.stop()
        usbInputMonitor.stop()
        bluetoothEnhancedModeEnabler.stop()
    }

    private func renderSessionsList() {
        statusMenu.updateSessionsList(
            lastSessionSummaries,
            focusedID: fleetFocus.focusedSessionID
        ) { [weak self] id in
            self?.sessionIndicators.slot(forSessionID: id)
        }
    }

    private func scheduleMicrophoneSelfTest(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self else { return }
            switch self.audioInputManager.activate() {
            case let .activated(name):
                DiagnosticLog.write(
                    "Bluetooth microphone self-test active for 20 seconds via \(name)"
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    self?.audioInputManager.deactivate()
                    DiagnosticLog.write("Bluetooth microphone self-test release requested")
                }
            case .unavailable where attempt < 12:
                DiagnosticLog.write(
                    "Bluetooth microphone self-test waiting for controller (attempt \(attempt))"
                )
                self.scheduleMicrophoneSelfTest(attempt: attempt + 1)
            case .unavailable:
                DiagnosticLog.write("Bluetooth microphone self-test could not find controller")
            case let .failed(message):
                DiagnosticLog.write("Bluetooth microphone self-test failed: \(message)")
            }
        }
    }

}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
