import Testing
@testable import DualSenseBridgeCore

private let shellTab = GhosttyTerminalCandidate(
    id: "shell",
    name: "drift — zsh",
    order: 0
)
private let agentTab = GhosttyTerminalCandidate(
    id: "agent",
    name: "✳ Claude Code",
    order: 1
)

@Test func ghosttySelectionPrefersTheAgentTitleOverTheFirstShellTab() {
    let choice = GhosttyTerminalSelector.choose(
        candidates: [shellTab, agentTab],
        source: "claude-code",
        routingHint: nil,
        rememberedID: nil,
        cycleAfterID: nil
    )

    #expect(choice?.candidate.id == "agent")
    #expect(choice?.reason == .titleHint)
}

@Test func ghosttySelectionUsesTheClaudeSessionSlugWhenAvailable() {
    let firstAgent = GhosttyTerminalCandidate(
        id: "other-agent",
        name: "Claude Code — other-session",
        order: 0
    )
    let matchingAgent = GhosttyTerminalCandidate(
        id: "matching-agent",
        name: "Claude Code — rosy-drifting-cherny",
        order: 1
    )
    let choice = GhosttyTerminalSelector.choose(
        candidates: [firstAgent, matchingAgent],
        source: "claude-code",
        routingHint: "rosy-drifting-cherny",
        rememberedID: nil,
        cycleAfterID: nil
    )

    #expect(choice?.candidate.id == "matching-agent")
}

@Test func ghosttySelectionMatchesATaskSummaryToTheFirstPrompt() {
    let unrelated = GhosttyTerminalCandidate(
        id: "year-ahead",
        name: "Fix year ahead showing 2025 instead of correct year",
        order: 0
    )
    let matching = GhosttyTerminalCandidate(
        id: "date-continuity",
        name: "Fix date inconsistency and integrate user data across platform",
        order: 2
    )
    let genericAgent = GhosttyTerminalCandidate(
        id: "generic-agent",
        name: "Claude Code",
        order: 1
    )
    let prompt = """
    A user feedback bug report came in that we should fix. Their date is a
    day behind in one place, and entered user information should be connected
    across the entire platform.
    """
    let choice = GhosttyTerminalSelector.choose(
        candidates: [unrelated, genericAgent, matching],
        source: "claude-code",
        routingHint: prompt,
        rememberedID: nil,
        cycleAfterID: nil
    )

    #expect(choice?.candidate.id == "date-continuity")
    #expect(choice?.reason == .titleHint)
}

@Test func oneGenericPromptWordDoesNotCreateAFalseTitleMatch() {
    let first = GhosttyTerminalCandidate(
        id: "first",
        name: "Fix authentication",
        order: 0
    )
    let second = GhosttyTerminalCandidate(
        id: "second",
        name: "Build reporting dashboard",
        order: 1
    )
    let choice = GhosttyTerminalSelector.choose(
        candidates: [first, second],
        source: "claude-code",
        routingHint: "Please fix the unrelated animation issue",
        rememberedID: nil,
        cycleAfterID: nil
    )

    #expect(choice?.candidate.id == "second")
    #expect(choice?.reason == .deterministicFallback)
}

@Test func ghosttySelectionRemembersAConfirmedSurface() {
    let choice = GhosttyTerminalSelector.choose(
        candidates: [shellTab, agentTab],
        source: "claude-code",
        routingHint: nil,
        rememberedID: "shell",
        cycleAfterID: nil
    )

    #expect(choice?.candidate.id == "shell")
    #expect(choice?.reason == .remembered)
}

@Test func rapidSecondRaiseCyclesAndOverridesTheRememberedSurface() {
    let third = GhosttyTerminalCandidate(
        id: "third",
        name: "Claude Code",
        order: 2
    )
    let choice = GhosttyTerminalSelector.choose(
        candidates: [shellTab, agentTab, third],
        source: "claude-code",
        routingHint: nil,
        rememberedID: "agent",
        cycleAfterID: "agent"
    )

    #expect(choice?.candidate.id == "third")
    #expect(choice?.reason == .cycled)
}

@Test func ambiguousTitlesFallBackToTheLastSurfaceNotTabOne() {
    let secondShell = GhosttyTerminalCandidate(
        id: "second",
        name: "drift — zsh",
        order: 1
    )
    let choice = GhosttyTerminalSelector.choose(
        candidates: [shellTab, secondShell],
        source: "claude-code",
        routingHint: nil,
        rememberedID: nil,
        cycleAfterID: nil
    )

    #expect(choice?.candidate.id == "second")
    #expect(choice?.reason == .deterministicFallback)
}
