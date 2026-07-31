import Foundation

/// One live agent session as seen by the passive watcher, for the menu's
/// session list and the player-LED slots.
public struct AgentSessionSummary: Equatable, Sendable {
    /// Stable identity: the transcript path.
    public let id: String
    public let source: String
    public let displayName: String
    public let event: AgentActivityEvent
    public let isInferred: Bool
    /// The session's working directory, as recorded in its transcript; the
    /// window resolver matches its folder name against terminal titles.
    public let cwd: String?

    public init(
        id: String,
        source: String,
        displayName: String,
        event: AgentActivityEvent,
        isInferred: Bool,
        cwd: String? = nil
    ) {
        self.id = id
        self.source = source
        self.displayName = displayName
        self.event = event
        self.isInferred = isInferred
        self.cwd = cwd
    }
}

/// Pure layout math for the DualSense's five player LEDs. Later controller
/// revisions electrically mirror the outer pair and inner pair, so arbitrary
/// one-dot positions are not portable. Fleet uses Sony's symmetric player
/// patterns instead: one through five lit dots encode a position on a page.
public enum AgentSessionIndicators {
    public static let slotCount = 5

    /// Sony's standard player-number patterns. These remain visually correct
    /// on both the original five-independent-LED hardware and newer mirrored
    /// hardware: the number of illuminated dots is position + 1.
    private static let focusMasks: [UInt8] = [
        0b00100, // 1: ○○●○○
        0b01010, // 2: ○●○●○
        0b10101, // 3: ●○●○●
        0b11011, // 4: ●●○●●
        0b11111  // 5: ●●●●●
    ]

    public static func focusMask(forPosition position: Int) -> UInt8? {
        guard position >= 0, position < focusMasks.count else { return nil }
        return focusMasks[position]
    }

    public static func focusDiagram(forPosition position: Int) -> String? {
        guard let mask = focusMask(forPosition: position) else { return nil }
        return (0..<slotCount)
            .map { mask & (1 << UInt8($0)) == 0 ? "○" : "●" }
            .joined()
    }

    /// Pattern position for an unbounded, zero-based Fleet ordinal. Every
    /// five sessions begin a new logical page using the same five counts.
    public static func cursorSlot(forSessionOrdinal ordinal: Int) -> Int? {
        guard ordinal >= 0 else { return nil }
        return ordinal % slotCount
    }

    /// One-based logical page for display in the menu.
    public static func cursorPage(forSessionOrdinal ordinal: Int) -> Int? {
        guard ordinal >= 0 else { return nil }
        return ordinal / slotCount + 1
    }

    /// Short human name for a transcript. Claude project directories are
    /// slash-munged paths (`-Users-example-project`), so the last
    /// dash component is the project folder; Codex rollouts encode their
    /// start time in the filename.
    public static func displayName(
        transcriptPath: String,
        source: String
    ) -> String {
        let url = URL(fileURLWithPath: transcriptPath)
        let fileName = url.deletingPathExtension().lastPathComponent

        if source == "claude-code" {
            let project = url.deletingLastPathComponent().lastPathComponent
                .split(separator: "-")
                .last
                .map(String.init) ?? "claude"
            let shortSession = String(fileName.prefix(8))
            return "\(project) · \(shortSession)"
        }

        if source == "codex" {
            // rollout-2026-07-24T14-58-36-<uuid> → "codex · 14:58"
            let parts = fileName.split(separator: "-")
            if let timeIndex = parts.firstIndex(where: { $0.contains("T") }),
               timeIndex + 1 < parts.count,
               let hour = parts[timeIndex].split(separator: "T").last {
                return "codex · \(hour):\(parts[timeIndex + 1])"
            }
            return "codex · \(String(fileName.suffix(8)))"
        }

        return String(fileName.prefix(16))
    }
}
