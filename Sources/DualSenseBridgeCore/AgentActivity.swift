import Foundation

/// One coding-agent lifecycle state, as reported by Claude Code hooks, Codex
/// notifications, or any script that writes to the agent-event spool.
public enum AgentActivityEvent: String, CaseIterable, Sendable {
    case working
    case attention
    case done
    case error
    case idle

    public var title: String {
        switch self {
        case .working: return "Working"
        case .attention: return "Needs Attention"
        case .done: return "Done"
        case .error: return "Error"
        case .idle: return "Idle"
        }
    }
}

/// One parsed agent-event spool file. The wire format is deliberately
/// line-oriented `key=value` text rather than JSON: the writer is a POSIX
/// shell one-liner running inside an agent hook, and it must never fail on
/// quoting no matter what payload an agent framework passes through.
public struct AgentEventEnvelope: Equatable, Sendable {
    public let event: AgentActivityEvent
    public let source: String
    public let timestamp: Date?
    /// True when the event came from a timing heuristic (passive transcript
    /// watching) rather than an explicit report. Inferred attention keeps
    /// its lightbar color but stays silent on haptics: a permission prompt
    /// and a long-running build are indistinguishable in a transcript, and
    /// a wrong buzz costs more trust than a wrong color.
    public let isInferred: Bool
    /// True for events produced by the passive session watcher (inferred or
    /// not), so state it established can be withdrawn when the feature is
    /// switched off without touching hook-reported state.
    public let isFromPassiveWatching: Bool
    /// A momentary notification rather than a state: one session finished
    /// (or raised a second approval) while another still owns the sustained
    /// aggregate. Transients play their haptic and flash their color, then
    /// the lightbar returns to the sustained state.
    public let isTransient: Bool

    public init(
        event: AgentActivityEvent,
        source: String,
        timestamp: Date?,
        isInferred: Bool = false,
        isFromPassiveWatching: Bool = false,
        isTransient: Bool = false
    ) {
        self.event = event
        self.source = source
        self.timestamp = timestamp
        self.isInferred = isInferred
        self.isFromPassiveWatching = isFromPassiveWatching
        self.isTransient = isTransient
    }

    /// Spool files written while the app was not running describe history,
    /// not the present. Files older than the freshness window are dropped so
    /// a queued "done" from hours ago cannot buzz the controller at launch.
    public static let maximumAge: TimeInterval = 60

    public static func parse(fileContents: String) -> AgentEventEnvelope? {
        var fields: [String: String] = [:]
        for line in fileContents.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            // First occurrence wins so a payload that happens to contain a
            // `key=value` looking line can never override the real header.
            if fields[key] == nil {
                fields[key] = value
            }
        }

        guard let eventToken = fields["event"] else { return nil }
        let event: AgentActivityEvent?
        if let direct = AgentActivityEvent(rawValue: eventToken) {
            event = direct
        } else if eventToken == "codex-notify" {
            event = eventForCodexNotification(fields["payload"] ?? "")
        } else {
            event = nil
        }
        guard let event else { return nil }

        let timestamp = fields["ts"]
            .flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        return AgentEventEnvelope(
            event: event,
            source: fields["source"] ?? "hook",
            timestamp: timestamp
        )
    }

    /// Codex's `notify` program receives one JSON argument. Match on stable
    /// type substrings instead of parsing the schema: Codex has already
    /// renamed notification fields between releases, and an unrecognized
    /// payload should be ignored, not misclassified.
    public static func eventForCodexNotification(
        _ payload: String
    ) -> AgentActivityEvent? {
        let lowered = payload.lowercased()
        if lowered.contains("agent-turn-complete") { return .done }
        if lowered.contains("approval") { return .attention }
        return nil
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        guard let timestamp else { return true }
        return now.timeIntervalSince(timestamp) <= Self.maximumAge
    }
}

/// One motor state change inside a haptic pattern, offset from pattern start.
/// Sparse edges rather than a sample stream: classic DualSense rumble is
/// sticky until the next report, so a pattern only needs its transitions and
/// must always end on a zero step.
public struct AgentHapticStep: Equatable, Sendable {
    public let offset: TimeInterval
    public let lowFrequencyMotor: UInt8
    public let highFrequencyMotor: UInt8

    public init(
        offset: TimeInterval,
        lowFrequencyMotor: UInt8,
        highFrequencyMotor: UInt8
    ) {
        self.offset = offset
        self.lowFrequencyMotor = lowFrequencyMotor
        self.highFrequencyMotor = highFrequencyMotor
    }

    public var isSilent: Bool {
        lowFrequencyMotor == 0 && highFrequencyMotor == 0
    }
}

public enum AgentHapticPatternKind: Int, CaseIterable, Sendable {
    case none = 0
    case tap = 1
    case doubleTap = 2
    case buzz = 3
}

public enum AgentHapticPatterns {
    public static func steps(
        for kind: AgentHapticPatternKind,
        lowFrequencyPeak: UInt8,
        highFrequencyPeak: UInt8
    ) -> [AgentHapticStep] {
        let low = lowFrequencyPeak
        let high = highFrequencyPeak
        switch kind {
        case .none:
            return []
        case .tap:
            return [
                AgentHapticStep(offset: 0, lowFrequencyMotor: low, highFrequencyMotor: high),
                AgentHapticStep(offset: 0.15, lowFrequencyMotor: 0, highFrequencyMotor: 0)
            ]
        case .doubleTap:
            return [
                AgentHapticStep(offset: 0, lowFrequencyMotor: low, highFrequencyMotor: high),
                AgentHapticStep(offset: 0.12, lowFrequencyMotor: 0, highFrequencyMotor: 0),
                AgentHapticStep(offset: 0.26, lowFrequencyMotor: low, highFrequencyMotor: high),
                AgentHapticStep(offset: 0.38, lowFrequencyMotor: 0, highFrequencyMotor: 0)
            ]
        case .buzz:
            return [
                AgentHapticStep(offset: 0, lowFrequencyMotor: low, highFrequencyMotor: high),
                AgentHapticStep(offset: 0.6, lowFrequencyMotor: 0, highFrequencyMotor: 0)
            ]
        }
    }
}
