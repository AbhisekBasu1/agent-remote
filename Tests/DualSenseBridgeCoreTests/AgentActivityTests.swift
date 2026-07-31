import Foundation
import Testing
@testable import DualSenseBridgeCore

@Test func agentEnvelopeParsesAllFields() {
    let envelope = AgentEventEnvelope.parse(fileContents: """
    event=attention
    source=claude-code
    ts=1753270000
    """)

    #expect(envelope?.event == .attention)
    #expect(envelope?.source == "claude-code")
    #expect(envelope?.timestamp == Date(timeIntervalSince1970: 1_753_270_000))
}

@Test func agentEnvelopeFirstKeyWinsSoPayloadCannotOverrideHeader() {
    let envelope = AgentEventEnvelope.parse(fileContents: """
    event=done
    source=codex
    payload={"note":"contains event=error and source=spoofed"}
    event=error
    """)

    #expect(envelope?.event == .done)
    #expect(envelope?.source == "codex")
}

@Test func agentEnvelopeRejectsUnknownEventTokens() {
    #expect(AgentEventEnvelope.parse(fileContents: "event=reticulating\n") == nil)
    #expect(AgentEventEnvelope.parse(fileContents: "source=claude-code\n") == nil)
    #expect(AgentEventEnvelope.parse(fileContents: "") == nil)
}

@Test func agentEnvelopeMapsCodexNotifications() {
    let done = AgentEventEnvelope.parse(fileContents: """
    event=codex-notify
    source=codex
    payload={"type":"agent-turn-complete","turn-id":"1"}
    """)
    #expect(done?.event == .done)

    let approval = AgentEventEnvelope.parse(fileContents: """
    event=codex-notify
    source=codex
    payload={"type":"approval-requested"}
    """)
    #expect(approval?.event == .attention)

    let unknown = AgentEventEnvelope.parse(fileContents: """
    event=codex-notify
    source=codex
    payload={"type":"something-new"}
    """)
    #expect(unknown == nil)
}

@Test func agentEnvelopeFreshnessDropsOldEventsAndKeepsUntimestampedOnes() {
    let now = Date()
    let recent = AgentEventEnvelope(
        event: .done,
        source: "hook",
        timestamp: now.addingTimeInterval(-5)
    )
    let stale = AgentEventEnvelope(
        event: .done,
        source: "hook",
        timestamp: now.addingTimeInterval(-3_600)
    )
    let untimestamped = AgentEventEnvelope(event: .done, source: "hook", timestamp: nil)

    #expect(recent.isFresh(at: now))
    #expect(!stale.isFresh(at: now))
    #expect(untimestamped.isFresh(at: now))
}

@Test func hapticPatternsStartImmediatelyAndEndSilent() {
    for kind in AgentHapticPatternKind.allCases where kind != .none {
        let steps = AgentHapticPatterns.steps(
            for: kind,
            lowFrequencyPeak: 140,
            highFrequencyPeak: 70
        )
        #expect(steps.first?.offset == 0)
        #expect(steps.first?.isSilent == false)
        #expect(steps.last?.isSilent == true)
        // Rumble is sticky between reports; offsets must strictly advance or
        // a later edge could be applied before an earlier one.
        for index in 1..<steps.count {
            #expect(steps[index].offset > steps[index - 1].offset)
        }
    }
    #expect(AgentHapticPatterns.steps(
        for: .none,
        lowFrequencyPeak: 140,
        highFrequencyPeak: 70
    ).isEmpty)
}
