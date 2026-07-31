import Foundation

/// Where a Codex rollout is hosted. Codex Desktop and the command-line
/// harness write into the same sessions tree, so the transcript directory
/// alone cannot tell the window resolver where to send focus.
public enum CodexSessionHost: String, Equatable, Sendable {
    case desktop
    case terminal
    case unknown
}

/// Routing evidence extracted from a Codex rollout's `session_meta` record.
public struct CodexSessionRoute: Equatable, Sendable {
    public let threadID: String?
    public let host: CodexSessionHost
    /// Internal child rollouts are implementation details, not independent
    /// user-visible tasks, and must not consume a Fleet slot.
    public let isSubagent: Bool
    public let parentThreadID: String?

    public init(
        threadID: String?,
        host: CodexSessionHost,
        isSubagent: Bool = false,
        parentThreadID: String? = nil
    ) {
        self.threadID = threadID
        self.host = host
        self.isSubagent = isSubagent
        self.parentThreadID = parentThreadID
    }
}

/// Pure transcript parsing used by the macOS window resolver. Keeping this
/// outside AppKit makes the routing decision independently testable.
public enum AgentSessionRouting {
    public static func codexRoute(
        transcriptPath: String,
        sessionMetadataLine: String?
    ) -> CodexSessionRoute {
        var threadID = codexThreadID(transcriptPath: transcriptPath)
        var host: CodexSessionHost = .unknown
        var isSubagent = false
        var parentThreadID: String?

        if let sessionMetadataLine,
           let data = sessionMetadataLine.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let record = object as? [String: Any],
           record["type"] as? String == "session_meta",
           let payload = record["payload"] as? [String: Any] {
            if let metadataID = validatedThreadID(payload["id"] as? String) {
                threadID = metadataID
            }

            if let originator = payload["originator"] as? String,
               !originator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Current desktop rollouts say "Codex Desktop". Treat a
                // future desktop-labelled originator the same way while all
                // explicit non-desktop originators remain terminal-hosted.
                host = originator.localizedCaseInsensitiveContains("desktop")
                    ? .desktop
                    : .terminal
            }

            parentThreadID = validatedThreadID(
                payload["parent_thread_id"] as? String
            )
            let threadSource = payload["thread_source"] as? String
            let sourceIsSubagent = (payload["source"] as? [String: Any])?["subagent"] != nil
            isSubagent = threadSource == "subagent"
                || sourceIsSubagent
                || parentThreadID != nil
        }

        return CodexSessionRoute(
            threadID: threadID,
            host: host,
            isSubagent: isSubagent,
            parentThreadID: parentThreadID
        )
    }

    /// Rollout filenames end in the thread UUID. This remains a useful
    /// fallback when the metadata record cannot be read, but is validated so
    /// an arbitrary filename can never become a deep link.
    public static func codexThreadID(transcriptPath: String) -> String? {
        let stem = URL(fileURLWithPath: transcriptPath)
            .deletingPathExtension()
            .lastPathComponent
        guard stem.count >= 36 else { return nil }
        return validatedThreadID(String(stem.suffix(36)))
    }

    private static func validatedThreadID(_ candidate: String?) -> String? {
        guard let candidate, UUID(uuidString: candidate) != nil else {
            return nil
        }
        return candidate.lowercased()
    }
}
