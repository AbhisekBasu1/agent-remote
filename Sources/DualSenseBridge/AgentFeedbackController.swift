import CoreHaptics
import DualSenseBridgeCore
import Foundation
import GameController

/// Turns agent lifecycle events into controller feedback: the lightbar shows
/// the current agent state and the rumble motors deliver alert patterns.
/// Output is routed to whichever transport currently owns the controller —
/// the seized USB HID interface, the seized Bluetooth HID interface, or the
/// GameController framework fallback. All entry points run on the main queue.
final class AgentFeedbackController {
    /// Approximates the controller's own post-connect lightbar so disabling
    /// the feature (or quitting) does not leave an agent-state color latched.
    private static let releasedLightbar: (red: UInt8, green: UInt8, blue: UInt8) = (0x00, 0x00, 0x40)
    private static let doneHoldSeconds: TimeInterval = 6
    private static let errorHoldSeconds: TimeInterval = 10
    private static let transientFlashSeconds: TimeInterval = 2.5

    var onActivityChanged: ((String) -> Void)?

    private let settings: BridgeSettings
    private let bluetoothHID: DualSenseBluetoothEnhancedModeEnabler
    private let usbInputMonitor: DualSenseUSBInputMonitor
    private let audioInputManager: DualSenseAudioInputManager
    private let gameControllerProvider: () -> GCController?
    private let gameControllerHaptics = GameControllerHapticsPlayer()

    private var currentEvent: AgentActivityEvent = .idle
    private var currentSource: String?
    private var revertWorkItem: DispatchWorkItem?
    private var flashRevertWorkItem: DispatchWorkItem?
    private var microphoneRestoreWorkItem: DispatchWorkItem?
    private var reminderTimer: Timer?
    private var hapticWorkItems: [DispatchWorkItem] = []
    private var hapticPatternActiveUntil: TimeInterval = 0
    private var testWorkItems: [DispatchWorkItem] = []
    private var lastPlayedHapticEvent: AgentActivityEvent?
    private var lastPlayedHapticAt: TimeInterval = 0
    private var currentAttentionIsInferred = false
    private var currentEventFromPassiveWatching = false

    /// Hooks and passive watching can both report the same underlying moment
    /// within a couple of seconds of each other; identical events inside
    /// this window update state silently instead of buzzing twice. The
    /// window tracks haptics actually played — an inferred event whose buzz
    /// was suppressed must not swallow a confident one's.
    private static let duplicateHapticWindow: TimeInterval = 4

    init(
        settings: BridgeSettings,
        bluetoothHID: DualSenseBluetoothEnhancedModeEnabler,
        usbInputMonitor: DualSenseUSBInputMonitor,
        audioInputManager: DualSenseAudioInputManager,
        gameControllerProvider: @escaping () -> GCController?
    ) {
        self.settings = settings
        self.bluetoothHID = bluetoothHID
        self.usbInputMonitor = usbInputMonitor
        self.audioInputManager = audioInputManager
        self.gameControllerProvider = gameControllerProvider
    }

    var activitySummary: String {
        guard let currentSource else { return currentEvent.title }
        return "\(currentEvent.title) (\(currentSource))"
    }

    func handle(_ envelope: AgentEventEnvelope) {
        if envelope.isTransient {
            handleTransient(envelope)
            return
        }
        // A sustained event supersedes any flash still showing; its color is
        // the truth from here on.
        flashRevertWorkItem?.cancel()
        flashRevertWorkItem = nil
        // A real event supersedes any menu-triggered demo still in flight;
        // otherwise the demo's scheduled "done" would overwrite newer state.
        if envelope.source != "test" {
            for item in testWorkItems { item.cancel() }
            testWorkItems.removeAll()
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isDuplicate = envelope.event == lastPlayedHapticEvent
            && now - lastPlayedHapticAt < Self.duplicateHapticWindow
        let isStateChange = envelope.event != currentEvent

        // A confident attention upgrades an inferred one. An inferred event
        // downgrades confidence only when both the current state and the
        // envelope come from passive watching — its aggregate then really
        // means the confident attention is over — never when a hook
        // established the confidence.
        if envelope.event == .attention {
            let downgradeBlocked = currentEvent == .attention
                && !currentAttentionIsInferred
                && envelope.isInferred
                && !(envelope.isFromPassiveWatching && currentEventFromPassiveWatching)
            if !downgradeBlocked {
                currentAttentionIsInferred = envelope.isInferred
            }
        } else {
            currentAttentionIsInferred = false
        }
        currentEvent = envelope.event
        currentSource = envelope.source
        // A passive duplicate of a hook-established state must not steal its
        // provenance, or toggling passive watching off would clear state
        // that hooks still own. Genuine state changes always carry their
        // origin's provenance.
        if isStateChange
            || !envelope.isFromPassiveWatching
            || currentEventFromPassiveWatching {
            currentEventFromPassiveWatching = envelope.isFromPassiveWatching
        }
        revertWorkItem?.cancel()
        revertWorkItem = nil

        applyLightbarForCurrentState()
        // Inferred attention stays visual-only: a heuristic that cannot tell
        // a permission prompt from a slow build must not buzz for it. The
        // duplicate window advances only when a haptic was genuinely
        // dispatched, so a suppressed or bailed-out attempt cannot swallow
        // the next confident event's buzz.
        let suppressHaptic = isDuplicate
            || (envelope.isInferred && envelope.event == .attention)
        if !suppressHaptic,
           playHaptic(settings.agentHapticPattern(for: envelope.event)) {
            lastPlayedHapticEvent = envelope.event
            lastPlayedHapticAt = now
        }

        if envelope.event == .attention {
            if currentAttentionIsInferred {
                stopAttentionReminder()
            } else {
                startAttentionReminder()
            }
        } else {
            stopAttentionReminder()
        }

        switch envelope.event {
        case .done:
            scheduleRevertToIdle(after: Self.doneHoldSeconds)
        case .error:
            scheduleRevertToIdle(after: Self.errorHoldSeconds)
        case .working, .attention, .idle:
            break
        }
        onActivityChanged?(activitySummary)
    }

    /// A momentary notification: one session finished or raised another
    /// approval while a different session owns the sustained state. Plays
    /// the event's haptic and flashes its color, then hands the lightbar
    /// back to the sustained state — currentEvent, reminders, and revert
    /// timers are deliberately untouched.
    private func handleTransient(_ envelope: AgentEventEnvelope) {
        let now = ProcessInfo.processInfo.systemUptime
        let isDuplicate = envelope.event == lastPlayedHapticEvent
            && now - lastPlayedHapticAt < Self.duplicateHapticWindow
        if !isDuplicate,
           playHaptic(settings.agentHapticPattern(for: envelope.event)) {
            lastPlayedHapticEvent = envelope.event
            lastPlayedHapticAt = now
        }

        guard settings.agentLightbarEnabled,
              !audioInputManager.isMicrophoneSessionActive else { return }
        let color = settings.agentLightbarColor(for: envelope.event).rgb
        sendLightbar(red: color.red, green: color.green, blue: color.blue)

        flashRevertWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flashRevertWorkItem = nil
            self.applyLightbarForCurrentState()
        }
        flashRevertWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.transientFlashSeconds,
            execute: work
        )
    }

    /// A freshly connected controller starts with Sony's own lightbar state,
    /// so reassert the agent state once the connection settles.
    func controllerStatusChanged(_ status: ControllerBridgeStatus) {
        guard case .connected = status else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyLightbarForCurrentState()
        }
    }

    /// A microphone session — Bluetooth stream or USB dictation hold — owns
    /// the lightbar while active (blue capture, amber finished). Reassert
    /// the agent state after the amber indicator has had a moment to be seen.
    func microphoneSessionEnded() {
        // A flash scheduled before capture began must not fire its revert
        // into the post-session amber hold and repaint the sustained color
        // early.
        flashRevertWorkItem?.cancel()
        flashRevertWorkItem = nil
        // The restoration is a tracked lightbar owner: while it is pending,
        // a done/error hold expiring must not paint idle over the amber, and
        // when it fires it defers to any flash that began during the hold.
        microphoneRestoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.microphoneRestoreWorkItem = nil
            guard !self.audioInputManager.isMicrophoneSessionActive else { return }
            // Backstop for the one unlikely path to stranded rumble: a
            // pattern whose zero step was suppressed by the capture interlock
            // while the session-start zero write also failed. Skipped while a
            // pattern scheduled after capture is still mid-flight — that
            // pattern runs unsuppressed and ends with its own zero, and
            // zeroing here would truncate it.
            if ProcessInfo.processInfo.systemUptime >= self.hapticPatternActiveUntil {
                if self.usbInputMonitor.hasExclusiveAccess {
                    self.usbInputMonitor.setRumble(lowFrequencyMotor: 0, highFrequencyMotor: 0)
                }
                if self.bluetoothHID.isBluetoothConnected {
                    self.bluetoothHID.setAgentRumble(lowFrequencyMotor: 0, highFrequencyMotor: 0)
                }
            }
            if self.flashRevertWorkItem == nil {
                self.applyLightbarForCurrentState()
            }
        }
        microphoneRestoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Called by the menu after any agent setting changes so choices take
    /// effect immediately instead of at the next agent event.
    func refreshFromSettings() {
        if settings.agentLightbarEnabled {
            applyLightbarForCurrentState()
        } else if !audioInputManager.isMicrophoneSessionActive {
            sendLightbar(
                red: Self.releasedLightbar.red,
                green: Self.releasedLightbar.green,
                blue: Self.releasedLightbar.blue
            )
        }

        if !settings.agentHapticsEnabled {
            cancelHapticSchedule()
        }

        if currentEvent == .attention, !currentAttentionIsInferred {
            startAttentionReminder()
        } else {
            stopAttentionReminder()
        }
    }

    /// A single light confirmation pulse for fleet focus cycling and
    /// successful raises; respects the haptics toggle and mic interlock.
    func playFocusTick() {
        _ = playHaptic(.tap)
    }

    /// The refusal signal: a fleet action had nothing to act on.
    func playActionRefused() {
        _ = playHaptic(.buzz)
    }

    /// Toggling passive watching off must withdraw any state it established
    /// — an inferred amber, a Codex approval's reminder — without touching
    /// state that came from hooks. The synthetic idle is deliberately NOT
    /// marked passive: it is a cleanup command, and marking it passive
    /// would re-poison the provenance it exists to clear.
    func passiveWatchingDisabled() {
        guard currentEventFromPassiveWatching else { return }
        handle(AgentEventEnvelope(
            event: .idle,
            source: "passive watching off",
            timestamp: nil
        ))
    }

    /// Walks the real event path with synthetic events so the user can feel
    /// and see the configured feedback without waiting on an actual agent.
    func runFeedbackTest() {
        for item in testWorkItems { item.cancel() }
        testWorkItems.removeAll()

        let sequence: [(delay: TimeInterval, event: AgentActivityEvent)] = [
            (0, .working),
            (1.2, .attention),
            (2.8, .done)
        ]
        for (delay, event) in sequence {
            let work = DispatchWorkItem { [weak self] in
                self?.handle(AgentEventEnvelope(
                    event: event,
                    source: "test",
                    timestamp: nil
                ))
            }
            testWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func shutdown() {
        for item in testWorkItems { item.cancel() }
        testWorkItems.removeAll()
        revertWorkItem?.cancel()
        revertWorkItem = nil
        flashRevertWorkItem?.cancel()
        flashRevertWorkItem = nil
        microphoneRestoreWorkItem?.cancel()
        microphoneRestoreWorkItem = nil
        stopAttentionReminder()
        cancelHapticSchedule()
        sendLightbar(
            red: Self.releasedLightbar.red,
            green: Self.releasedLightbar.green,
            blue: Self.releasedLightbar.blue
        )
        gameControllerHaptics.stop()
    }

    // MARK: - Lightbar

    private func applyLightbarForCurrentState() {
        guard settings.agentLightbarEnabled else { return }
        // The microphone session's own blue/amber indicators own the lightbar
        // until the session fully stops; see microphoneSessionEnded.
        guard !audioInputManager.isMicrophoneSessionActive else { return }
        let color = settings.agentLightbarColor(for: currentEvent).rgb
        sendLightbar(red: color.red, green: color.green, blue: color.blue)
    }

    private func sendLightbar(red: UInt8, green: UInt8, blue: UInt8) {
        if usbInputMonitor.hasExclusiveAccess {
            usbInputMonitor.setLightbar(red: red, green: green, blue: blue)
        } else if bluetoothHID.isBluetoothConnected {
            bluetoothHID.setAgentLightbar(red: red, green: green, blue: blue)
        } else if let controller = gameControllerProvider(),
                  let light = controller.light {
            light.color = GCColor(
                red: Float(red) / 255,
                green: Float(green) / 255,
                blue: Float(blue) / 255
            )
        }
    }

    // MARK: - Haptics

    /// Returns whether a pattern was genuinely dispatched, so the duplicate
    /// window only advances for haptics that could actually be felt.
    @discardableResult
    private func playHaptic(_ pattern: AgentHapticPatternKind) -> Bool {
        guard settings.agentHapticsEnabled, pattern != .none else { return false }
        // The microphone interlock is enforced here for every route, not
        // just inside the Bluetooth sender. Over Bluetooth a rumble report
        // would switch the controller's haptics mode mid-capture; over USB
        // the motors would buzz straight into the dictation audio.
        guard !audioInputManager.isMicrophoneSessionActive else {
            DiagnosticLog.write("agent haptic skipped during microphone capture")
            return false
        }
        let strength = settings.agentHapticStrength
        let steps = AgentHapticPatterns.steps(
            for: pattern,
            lowFrequencyPeak: strength.lowFrequencyPeak,
            highFrequencyPeak: strength.highFrequencyPeak
        )
        guard !steps.isEmpty else { return false }

        if usbInputMonitor.hasExclusiveAccess {
            scheduleRawPattern(steps) { [weak self] low, high in
                self?.usbInputMonitor.setRumble(
                    lowFrequencyMotor: low,
                    highFrequencyMotor: high
                )
            }
            return true
        }
        if bluetoothHID.isBluetoothConnected {
            scheduleRawPattern(steps) { [weak self] low, high in
                self?.bluetoothHID.setAgentRumble(
                    lowFrequencyMotor: low,
                    highFrequencyMotor: high
                )
            }
            return true
        }
        if let controller = gameControllerProvider() {
            return gameControllerHaptics.play(steps: steps, on: controller)
        }
        return false
    }

    private func scheduleRawPattern(
        _ steps: [AgentHapticStep],
        send: @escaping (UInt8, UInt8) -> Void
    ) {
        cancelHapticSchedule()
        hapticPatternActiveUntil = ProcessInfo.processInfo.systemUptime
            + (steps.last?.offset ?? 0)
        for step in steps {
            // Recheck the microphone at fire time: a capture can begin
            // between scheduling and a step. Both session-start paths zero
            // the motors themselves, so skipping a trailing zero step is
            // safe.
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.audioInputManager.isMicrophoneSessionActive else {
                    return
                }
                send(step.lowFrequencyMotor, step.highFrequencyMotor)
            }
            hapticWorkItems.append(work)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + step.offset,
                execute: work
            )
        }
    }

    /// Cancels pending motor edges and forces the motors off. Rumble is
    /// sticky until the next report, so cancelling a pattern between its "on"
    /// and "off" steps must not strand the motors running. The zero goes to
    /// every connected raw transport, not just the currently preferred one,
    /// so a transport switch mid-pattern cannot leave the motors on.
    private func cancelHapticSchedule() {
        guard !hapticWorkItems.isEmpty else { return }
        for item in hapticWorkItems { item.cancel() }
        hapticWorkItems.removeAll()
        hapticPatternActiveUntil = 0
        guard !audioInputManager.isMicrophoneSessionActive else { return }
        if usbInputMonitor.hasExclusiveAccess {
            usbInputMonitor.setRumble(lowFrequencyMotor: 0, highFrequencyMotor: 0)
        }
        if bluetoothHID.isBluetoothConnected {
            bluetoothHID.setAgentRumble(lowFrequencyMotor: 0, highFrequencyMotor: 0)
        }
    }

    // MARK: - Timers

    private func startAttentionReminder() {
        stopAttentionReminder()
        guard settings.agentHapticsEnabled,
              let interval = settings.agentAttentionReminder.interval else {
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.currentEvent == .attention else { return }
            self.playHaptic(self.settings.agentHapticPattern(for: .attention))
        }
        reminderTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAttentionReminder() {
        reminderTimer?.invalidate()
        reminderTimer = nil
    }

    private func scheduleRevertToIdle(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.currentEvent = .idle
            // A flash still showing — or the pending post-microphone amber
            // hold — owns the lightbar for its remaining moment; whichever
            // owner fires last paints the (now idle) state.
            if self.flashRevertWorkItem == nil,
               self.microphoneRestoreWorkItem == nil {
                self.applyLightbarForCurrentState()
            }
            self.onActivityChanged?(self.activitySummary)
        }
        revertWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// CoreHaptics playback for the GameController fallback path, used when
/// neither raw HID interface is seized. Continuous events are synthesized
/// between a pattern's motor edges; the DualSense's two motors collapse to
/// one intensity because GCDeviceHaptics exposes a single default locality.
private final class GameControllerHapticsPlayer {
    private var engine: CHHapticEngine?
    private weak var engineController: GCController?

    /// Returns whether playback genuinely started, so callers tracking
    /// played haptics are not misled by a missing engine or a throw.
    func play(steps: [AgentHapticStep], on controller: GCController) -> Bool {
        guard let haptics = controller.haptics else { return false }
        if engine == nil || engineController !== controller {
            engine = haptics.createEngine(withLocality: .default)
            engineController = controller
        }
        guard let engine else { return false }

        var events: [CHHapticEvent] = []
        for (index, step) in steps.enumerated() where !step.isSilent {
            let nextOffset = index + 1 < steps.count
                ? steps[index + 1].offset
                : step.offset + 0.2
            let level = Float(max(step.lowFrequencyMotor, step.highFrequencyMotor)) / 255
            events.append(CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(
                        parameterID: .hapticIntensity,
                        value: level
                    )
                ],
                relativeTime: step.offset,
                duration: max(nextOffset - step.offset, 0.02)
            ))
        }
        guard !events.isEmpty else { return false }

        do {
            // Starting an already-running engine throws; that is fine as long
            // as the player itself starts.
            try? engine.start()
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            DiagnosticLog.write(
                "GameController haptic playback failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    func stop() {
        engine?.stop(completionHandler: nil)
        engine = nil
        engineController = nil
    }
}
