import DualSenseBridgeCore
import Foundation

/// The focus model: which session the controller is pointing at. Cycling is
/// manual; attention snaps focus automatically unless the user cycled
/// recently, because the session that needs you is almost always the one
/// you want to act on. All entry points run on the main queue.
final class FleetFocusController {
    /// Fired whenever focus moves; carries the focused session (or nil).
    var onFocusChanged: ((AgentSessionSummary?) -> Void)?

    private(set) var focusedSessionID: String?

    private let feedback: AgentFeedbackController
    private let resolver = SessionWindowResolver()
    private let slotProvider: (String) -> Int?
    private var sessions: [AgentSessionSummary] = []
    private var manualFocusHoldUntil: TimeInterval = 0
    private var holdExpiryGeneration: UInt64 = 0

    /// How long a manual cycle pins focus against attention auto-snapping.
    private static let manualFocusHoldSeconds: TimeInterval = 30

    init(
        feedback: AgentFeedbackController,
        slotProvider: @escaping (String) -> Int?
    ) {
        self.feedback = feedback
        self.slotProvider = slotProvider
    }

    var focusedSession: AgentSessionSummary? {
        sessions.first { $0.id == focusedSessionID }
    }

    func update(sessions newSessions: [AgentSessionSummary]) {
        resolver.observe(sessions: newSessions)
        sessions = orderedBySlot(newSessions)

        let focusedStillLive = sessions.contains { $0.id == focusedSessionID }
        if !focusedStillLive {
            // Initial focus must be published too: player LEDs now have one
            // stable meaning and should show the focused session immediately.
            setFocus(bestAutomaticChoice()?.id, notify: true)
            return
        }
        reevaluateAutoFocus()
    }

    /// Attention pulls focus unless the user pinned it by cycling recently —
    /// and never away from a session that also needs them. Runs on session
    /// updates AND at hold expiry: attention that arrived mid-hold must snap
    /// when the hold lapses even if no summary changes again.
    private func reevaluateAutoFocus() {
        guard ProcessInfo.processInfo.systemUptime >= manualFocusHoldUntil else {
            return
        }
        if focusedSession?.event != .attention,
           let waiting = sessions.first(where: { $0.event == .attention }),
           waiting.id != focusedSessionID {
            setFocus(waiting.id, notify: true)
        }
    }

    private func beginManualHold() {
        manualFocusHoldUntil = ProcessInfo.processInfo.systemUptime
            + Self.manualFocusHoldSeconds
        holdExpiryGeneration &+= 1
        let generation = holdExpiryGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.manualFocusHoldSeconds + 0.1
        ) { [weak self] in
            guard let self, self.holdExpiryGeneration == generation else { return }
            self.reevaluateAutoFocus()
        }
    }

    func perform(_ action: FleetAction) {
        switch action {
        case .focusNext:
            cycle(by: 1)
        case .focusPrevious:
            cycle(by: -1)
        case .raiseFocused:
            raiseFocused()
        }
    }

    /// Menu clicks focus and raise in one gesture. A click on a session
    /// that left the fleet between render and click refuses audibly rather
    /// than doing nothing.
    func focusAndRaise(sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else {
            feedback.playActionRefused()
            return
        }
        beginManualHold()
        setFocus(sessionID, notify: true)
        raiseFocused()
    }

    private func cycle(by offset: Int) {
        guard !sessions.isEmpty else {
            feedback.playActionRefused()
            return
        }
        beginManualHold()

        let currentIndex = sessions.firstIndex { $0.id == focusedSessionID }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + offset + sessions.count) % sessions.count
        } else {
            nextIndex = offset >= 0 ? 0 : sessions.count - 1
        }
        let nextID = sessions[nextIndex].id
        if nextID == focusedSessionID {
            // With one live session, cycling wraps to the same ID. It is
            // still a real user action and must enter LED selection mode.
            onFocusChanged?(focusedSession)
        } else {
            setFocus(nextID, notify: true)
        }
        feedback.playFocusTick()
    }

    private func raiseFocused() {
        guard let session = focusedSession else {
            feedback.playActionRefused()
            return
        }
        resolver.raise(
            transcriptPath: session.id,
            cwd: session.cwd,
            source: session.source
        ) { [weak self] raised in
            if raised {
                self?.feedback.playFocusTick()
            } else {
                self?.feedback.playActionRefused()
                DiagnosticLog.write(
                    "could not resolve a window for the focused session"
                )
            }
        }
    }

    private func setFocus(_ id: String?, notify: Bool) {
        guard id != focusedSessionID else { return }
        focusedSessionID = id
        if notify {
            onFocusChanged?(focusedSession)
        }
    }

    /// Automatic focus prefers whoever needs the user, then the busiest.
    private func bestAutomaticChoice() -> AgentSessionSummary? {
        sessions.first { $0.event == .attention }
            ?? sessions.first { $0.event == .error }
            ?? sessions.first { $0.event == .working }
            ?? sessions.first
    }

    private func orderedBySlot(
        _ list: [AgentSessionSummary]
    ) -> [AgentSessionSummary] {
        list.sorted { left, right in
            let leftSlot = slotProvider(left.id) ?? Int.max
            let rightSlot = slotProvider(right.id) ?? Int.max
            if leftSlot != rightSlot { return leftSlot < rightSlot }
            return left.id < right.id
        }
    }
}
