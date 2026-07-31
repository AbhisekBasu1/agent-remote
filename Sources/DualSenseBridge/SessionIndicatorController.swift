import DualSenseBridgeCore
import Foundation

/// Gives every live session a sticky Fleet ordinal and displays focus with
/// Sony's symmetric one-through-five-dot player patterns. Five positions are
/// paged: F1...F5 use page one, F6...F10 repeat the counts on page two, and
/// so on. All entry points run on the main queue.
final class SessionIndicatorController {
    /// Sony's normal center indicator, restored when the feature is off or
    /// the app quits.
    private static let defaultMask: UInt8 = 0x04

    private let settings: BridgeSettings
    private let bluetoothHID: DualSenseBluetoothEnhancedModeEnabler
    private let usbInputMonitor: DualSenseUSBInputMonitor
    private let audioInputManager: DualSenseAudioInputManager

    /// Ordinals are sticky for a session's lifetime. Unlike the old status
    /// slots, they are not capped at five; overflow sessions get another
    /// five-position page instead of silently falling back to a status mask.
    private var slotAssignments: [String: Int] = [:]
    private var selectedOrdinal: Int?
    private var lastSentMask: UInt8?

    func slot(forSessionID id: String) -> Int? {
        slotAssignments[id]
    }

    init(
        settings: BridgeSettings,
        bluetoothHID: DualSenseBluetoothEnhancedModeEnabler,
        usbInputMonitor: DualSenseUSBInputMonitor,
        audioInputManager: DualSenseAudioInputManager
    ) {
        self.settings = settings
        self.bluetoothHID = bluetoothHID
        self.usbInputMonitor = usbInputMonitor
        self.audioInputManager = audioInputManager
    }

    func update(sessions: [AgentSessionSummary]) {
        let liveIDs = Set(sessions.map(\.id))
        slotAssignments = slotAssignments.filter { liveIDs.contains($0.key) }

        for session in sessions where slotAssignments[session.id] == nil {
            let taken = Set(slotAssignments.values)
            var freeOrdinal = 0
            while taken.contains(freeOrdinal) {
                freeOrdinal += 1
            }
            slotAssignments[session.id] = freeOrdinal
        }
    }

    /// Shows the focused Fleet ordinal as a steady, countable player pattern.
    /// The immediate bit prevents old and new patterns from blending.
    func identify(slot ordinal: Int) {
        guard let position = AgentSessionIndicators.cursorSlot(
            forSessionOrdinal: ordinal
        ), let mask = AgentSessionIndicators.focusMask(
            forPosition: position
        ) else {
            return
        }

        selectedOrdinal = ordinal
        guard settings.agentPlayerLEDsEnabled else { return }
        let page = AgentSessionIndicators.cursorPage(
            forSessionOrdinal: ordinal
        ) ?? 1
        DiagnosticLog.write(
            "session indicators: focus F\(ordinal + 1), page=\(page), count=\(position + 1), mask=0x\(String(format: "%02x", mask))"
        )
        send(mask: mask)
    }

    /// Clears focus only when the fleet has no focused session. Raising a
    /// session deliberately does not call this: focus remains visible.
    func finishIdentification() {
        selectedOrdinal = nil
        guard settings.agentPlayerLEDsEnabled else { return }
        lastSentMask = nil
        send(mask: 0)
    }

    /// A freshly connected controller starts with Sony's own indicator;
    /// reassert the focus cursor once the connection settles.
    func controllerStatusChanged(_ status: ControllerBridgeStatus) {
        guard case .connected = status else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.reassertIndicators()
        }
    }

    /// Player-LED reports are suppressed during microphone capture; restore
    /// the same focus cursor after the microphone session fully ends.
    func microphoneSessionEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  !self.audioInputManager.isMicrophoneSessionActive else {
                return
            }
            self.reassertIndicators()
        }
    }

    func refreshFromSettings() {
        reassertIndicators()
    }

    func shutdown() {
        guard !audioInputManager.isMicrophoneSessionActive else { return }
        lastSentMask = nil
        send(mask: Self.defaultMask)
    }

    private func reassertIndicators() {
        lastSentMask = nil
        guard settings.agentPlayerLEDsEnabled else {
            send(mask: Self.defaultMask)
            return
        }
        guard let selectedOrdinal,
              let position = AgentSessionIndicators.cursorSlot(
                  forSessionOrdinal: selectedOrdinal
              ),
              let mask = AgentSessionIndicators.focusMask(
                  forPosition: position
              ) else {
            send(mask: 0)
            return
        }
        send(mask: mask)
    }

    private func send(mask: UInt8) {
        guard !audioInputManager.isMicrophoneSessionActive,
              mask != lastSentMask else {
            return
        }
        lastSentMask = mask
        if usbInputMonitor.hasExclusiveAccess {
            usbInputMonitor.setPlayerLEDs(mask: mask, immediate: true)
        } else if bluetoothHID.isBluetoothConnected {
            bluetoothHID.setPlayerLEDs(mask: mask, immediate: true)
        }
        // GameController exposes the lightbar, but not player indicators.
    }
}
