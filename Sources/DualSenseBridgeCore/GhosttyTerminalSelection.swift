import Foundation

/// The stable, non-content metadata Ghostty exposes for one terminal surface.
/// `order` is the position returned by Ghostty's scripting API and is used
/// only as a deterministic last-resort tie breaker.
public struct GhosttyTerminalCandidate: Equatable, Sendable {
    public let id: String
    public let name: String
    public let order: Int

    public init(id: String, name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
    }
}

public enum GhosttyTerminalChoiceReason: String, Equatable, Sendable {
    case onlyCandidate
    case cycled
    case remembered
    case titleHint
    case deterministicFallback
}

public struct GhosttyTerminalChoice: Equatable, Sendable {
    public let candidate: GhosttyTerminalCandidate
    public let reason: GhosttyTerminalChoiceReason

    public init(
        candidate: GhosttyTerminalCandidate,
        reason: GhosttyTerminalChoiceReason
    ) {
        self.candidate = candidate
        self.reason = reason
    }
}

/// Resolves ambiguity after the caller has narrowed Ghostty terminals to the
/// best working-directory match. A stable learned binding wins. Pressing the
/// action again quickly asks for the next candidate, which lets the user
/// correct an inherently ambiguous same-directory match without a settings
/// detour. Before a binding exists, agent-specific titles and Claude's unique
/// session slug are stronger evidence than tab order.
public enum GhosttyTerminalSelector {
    public static func choose(
        candidates: [GhosttyTerminalCandidate],
        source: String,
        routingHint: String?,
        rememberedID: String?,
        cycleAfterID: String?
    ) -> GhosttyTerminalChoice? {
        let ordered = candidates.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
        guard let first = ordered.first else { return nil }
        if ordered.count == 1 {
            return GhosttyTerminalChoice(
                candidate: first,
                reason: .onlyCandidate
            )
        }

        if let cycleAfterID,
           let index = ordered.firstIndex(where: { $0.id == cycleAfterID }) {
            let next = ordered[(index + 1) % ordered.count]
            return GhosttyTerminalChoice(candidate: next, reason: .cycled)
        }

        if let rememberedID,
           let remembered = ordered.first(where: { $0.id == rememberedID }) {
            return GhosttyTerminalChoice(
                candidate: remembered,
                reason: .remembered
            )
        }

        let scored = ordered.map { candidate in
            (candidate: candidate, score: titleScore(
                candidate.name,
                source: source,
                routingHint: routingHint
            ))
        }
        let bestScore = scored.map(\.score).max() ?? 0
        if bestScore > 0,
           let best = scored.last(where: { $0.score == bestScore })?.candidate {
            return GhosttyTerminalChoice(candidate: best, reason: .titleHint)
        }

        // Ghostty returns terminals in stable order. Choosing the last one
        // avoids the old pathological behavior of always selecting tab 1;
        // a quick second press cycles when order alone is insufficient.
        return GhosttyTerminalChoice(
            candidate: ordered.last ?? first,
            reason: .deterministicFallback
        )
    }

    private static func titleScore(
        _ name: String,
        source: String,
        routingHint: String?
    ) -> Int {
        let foldedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        var score = 0
        if let routingHint, !routingHint.isEmpty {
            let foldedHint = routingHint.folding(
               options: [.caseInsensitive, .diacriticInsensitive],
               locale: .current
            )
            if foldedName.contains(foldedHint) {
                score += 1_000
            }

            // Claude's Ghostty title is commonly a short generated summary
            // of the first prompt, not a verbatim substring. Reward multiple
            // meaningful shared words (or one unusually distinctive word)
            // so "Fix date inconsistency … across platform" can route back
            // to the prompt it summarizes without fuzzy-matching generic
            // titles on a single word such as "fix".
            let titleWords = meaningfulWords(in: foldedName)
            let hintWords = meaningfulWords(in: foldedHint)
            let shared = titleWords.intersection(hintWords)
            if shared.count >= 2
                || shared.contains(where: { $0.count >= 9 }) {
                score += 600 + shared.reduce(0) {
                    $0 + min($1.count, 12) * 10
                }
            }
        }
        if source == "claude-code", foldedName.contains("claude") {
            score += 500
        }
        if source == "codex", foldedName.contains("codex") {
            score += 500
        }
        return score
    }

    private static func meaningfulWords(in value: String) -> Set<String> {
        let stopWords: Set<String> = [
            "about", "after", "again", "also", "been", "before", "being",
            "can", "could", "does", "from", "have", "into", "just", "like",
            "more", "other", "should", "that", "the", "their", "then", "there",
            "these", "they", "this", "through", "want", "was", "were", "what",
            "when", "where", "which", "while", "with", "would", "you", "your"
        ]
        return Set(value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count >= 3 && !stopWords.contains($0) })
    }
}
