import Foundation

/// State inference for passive session watching: the app reads the JSONL
/// transcripts that Claude Code and Codex already write, touching no harness
/// configuration, and derives agent activity from what appears there. These
/// reducers are deliberately tolerant — a malformed or unrecognized line is
/// generic activity, never an error — because transcript formats are another
/// project's internals and can shift between releases.
///
/// Events returned by `consume` come from explicit transcript structure and
/// are treated as confident. Events returned by `quietCheck` are timing
/// heuristics — a pending tool call with a silent file could be a permission
/// prompt or just a slow build — and callers should mark them inferred so
/// feedback can stay visual-only.
public struct ClaudeTranscriptStateReducer {
    public private(set) var currentEvent: AgentActivityEvent = .idle
    public private(set) var lastActivity: Date?
    public private(set) var pendingToolUseSince: Date?

    /// How long a pending tool call must sit in a silent transcript before
    /// it is read as "probably waiting on the user."
    public static let attentionQuietThreshold: TimeInterval = 20
    /// How long a finished session sits silent before it reads as idle.
    public static let idleQuietThreshold: TimeInterval = 300
    /// Sessions end silently when their process dies. Without an expiry, a
    /// session killed at an approval prompt would hold attention forever.
    public static let abandonedQuietThreshold: TimeInterval = 900

    public init() {}

    public mutating func consume(line: String, at now: Date) -> AgentActivityEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let entry = object as? [String: Any] else {
            // Unparseable bytes refresh the liveness clock but must not
            // drive state.
            lastActivity = now
            return nil
        }

        let type = entry["type"] as? String
        // Summaries are rewritten at unpredictable times and say nothing
        // about the live turn.
        if type == "summary" { return nil }

        lastActivity = now

        // Subagent traffic keeps the session busy but must not drive the
        // main turn's done/pending state.
        if entry["isSidechain"] as? Bool == true {
            return transition(to: .working)
        }

        let message = entry["message"] as? [String: Any]
        let content = message?["content"]

        switch type {
        case "user":
            if contentContainsBlock(content, ofType: "tool_result") {
                pendingToolUseSince = nil
                return transition(to: .working)
            }
            // A genuine user prompt supersedes any pending approval.
            pendingToolUseSince = nil
            return transition(to: .working)
        case "assistant":
            // Transcripts split one assistant message across several entries
            // (thinking, text preamble, tool_use — one block each), all
            // stamped with the message-level stop_reason. Judging by block
            // shape alone misread every "I'll now run X" preamble as the
            // final reply: 232 false completions in three measured real
            // sessions. stop_reason is the reliable discriminator.
            let stopReason = message?["stop_reason"] as? String
            if contentContainsBlock(content, ofType: "tool_use") {
                pendingToolUseSince = now
                return transition(to: .working)
            }
            switch stopReason {
            case "tool_use":
                return transition(to: .working)
            case "end_turn", "stop_sequence", "max_tokens":
                pendingToolUseSince = nil
                return transition(to: .done)
            case nil:
                // Legacy entries without stop_reason: fall back to the
                // block-shape heuristic.
                if content is String || contentContainsBlock(content, ofType: "text") {
                    pendingToolUseSince = nil
                    return transition(to: .done)
                }
                return nil
            default:
                return nil
            }
        default:
            // Real transcripts carry many bookkeeping entry types (mode,
            // last-prompt, file-history-snapshot, ai-title, …) — and
            // ai-title in particular lands AFTER a turn completes, so any
            // "unknown means working" rule would flip a finished session
            // back to working and strand it there. Only user/assistant
            // entries carry turn state; the rest are liveness.
            return nil
        }
    }

    /// Timing heuristics, evaluated periodically by the watcher. Attention
    /// from here is a guess: a permission prompt and a three-minute build
    /// look identical in the transcript (a tool call with no result and a
    /// quiet file), so callers must flag the result as inferred.
    public mutating func quietCheck(at now: Date) -> AgentActivityEvent? {
        guard let lastActivity else { return nil }
        let quiet = now.timeIntervalSince(lastActivity)

        if quiet >= Self.abandonedQuietThreshold,
           currentEvent == .working || currentEvent == .attention {
            pendingToolUseSince = nil
            return transition(to: .idle)
        }
        if pendingToolUseSince != nil,
           currentEvent == .working,
           quiet >= Self.attentionQuietThreshold {
            return transition(to: .attention)
        }
        if currentEvent == .done, quiet >= Self.idleQuietThreshold {
            return transition(to: .idle)
        }
        return nil
    }

    private mutating func transition(to event: AgentActivityEvent) -> AgentActivityEvent? {
        guard event != currentEvent else { return nil }
        currentEvent = event
        return event
    }

    private func contentContainsBlock(_ content: Any?, ofType blockType: String) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) == blockType }
    }
}

/// Codex rollout files carry explicit protocol events, so this reducer
/// matches serialized markers instead of guessing from timing. The markers
/// include their JSON punctuation (`"type":"task_complete"`) so a tool's
/// plain-text output that merely mentions the words cannot trigger a
/// transition.
public struct CodexSessionLogStateReducer {
    public private(set) var currentEvent: AgentActivityEvent = .idle
    public private(set) var lastActivity: Date?

    public init() {}

    public mutating func consume(line: String, at now: Date) -> AgentActivityEvent? {
        lastActivity = now
        let compact = line.replacingOccurrences(of: " ", with: "")

        if compact.contains("_approval_request\"") || compact.contains("\"type\":\"elicitation") {
            return transition(to: .attention)
        }
        if compact.contains("\"type\":\"task_complete\"")
            || compact.contains("\"type\":\"turn_complete\"") {
            return transition(to: .done)
        }
        if compact.contains("\"type\":\"task_started\"")
            || compact.contains("\"type\":\"turn_started\"") {
            return transition(to: .working)
        }
        // Generic appends only clear an answered approval back to working.
        // They must not pull a finished session out of done: every real turn
        // emits its own task_started marker (verified against live
        // rollouts), so a trailing bookkeeping write after task_complete
        // would otherwise strand the session on the working color.
        if currentEvent == .attention {
            return transition(to: .working)
        }
        return nil
    }

    /// Rollouts also end silently; expire live states the same way the
    /// Claude reducer does so a killed session cannot hold attention.
    public mutating func quietCheck(at now: Date) -> AgentActivityEvent? {
        guard let lastActivity,
              currentEvent == .working || currentEvent == .attention,
              now.timeIntervalSince(lastActivity)
                >= ClaudeTranscriptStateReducer.abandonedQuietThreshold else {
            return nil
        }
        return transition(to: .idle)
    }

    private mutating func transition(to event: AgentActivityEvent) -> AgentActivityEvent? {
        guard event != currentEvent else { return nil }
        currentEvent = event
        return event
    }
}
