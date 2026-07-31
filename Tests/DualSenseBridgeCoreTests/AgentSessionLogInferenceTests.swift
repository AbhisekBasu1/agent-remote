import Foundation
import Testing
@testable import DualSenseBridgeCore

private let start = Date(timeIntervalSince1970: 1_753_300_000)

@Test func claudeReducerTracksAWholeTurn() {
    var reducer = ClaudeTranscriptStateReducer()

    let prompt = #"{"type":"user","message":{"role":"user","content":"fix the bug"}}"#
    #expect(reducer.consume(line: prompt, at: start) == .working)

    let toolCall = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash"}]}}"#
    // Already working, so no duplicate transition — but the pending call is
    // now tracked for the quiet heuristic.
    #expect(reducer.consume(line: toolCall, at: start.addingTimeInterval(2)) == nil)
    #expect(reducer.pendingToolUseSince != nil)

    let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#
    #expect(reducer.consume(line: toolResult, at: start.addingTimeInterval(5)) == nil)
    #expect(reducer.pendingToolUseSince == nil)

    let reply = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed."}]}}"#
    #expect(reducer.consume(line: reply, at: start.addingTimeInterval(8)) == .done)
}

@Test func claudeReducerInfersAttentionFromAQuietPendingToolCall() {
    var reducer = ClaudeTranscriptStateReducer()
    _ = reducer.consume(
        line: #"{"type":"user","message":{"content":"go"}}"#,
        at: start
    )
    _ = reducer.consume(
        line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash"}]}}"#,
        at: start.addingTimeInterval(1)
    )

    // Below threshold: still just a running tool.
    #expect(reducer.quietCheck(at: start.addingTimeInterval(10)) == nil)
    // Past threshold: probably waiting on the user.
    #expect(reducer.quietCheck(at: start.addingTimeInterval(30)) == .attention)
    // Only once per episode.
    #expect(reducer.quietCheck(at: start.addingTimeInterval(40)) == nil)

    // The user answered; activity resumes and clears the pending call.
    let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#
    #expect(reducer.consume(line: result, at: start.addingTimeInterval(45)) == .working)
    #expect(reducer.quietCheck(at: start.addingTimeInterval(70)) == nil)
}

@Test func claudeReducerDoesNotMistakePreambleTextForCompletion() {
    var reducer = ClaudeTranscriptStateReducer()
    _ = reducer.consume(
        line: #"{"type":"user","message":{"content":"build it"}}"#,
        at: start
    )

    // Real transcripts split one assistant message into per-block entries,
    // all stamped with the message's stop_reason. A text preamble ("I'll
    // now run the build") arrives as a text-only entry with
    // stop_reason=tool_use — 232 of these appeared in three measured
    // sessions, and each must NOT read as the turn finishing.
    let preamble = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"I'll run the build."}]}}"#
    #expect(reducer.consume(line: preamble, at: start.addingTimeInterval(1)) == nil)
    #expect(reducer.currentEvent == .working)

    let toolCall = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash"}]}}"#
    #expect(reducer.consume(line: toolCall, at: start.addingTimeInterval(2)) == nil)
    #expect(reducer.pendingToolUseSince != nil)

    // Thinking entries carry the final message's end_turn too; either the
    // thinking or the text entry may deliver the completion.
    let finalThinking = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"…"}]}}"#
    #expect(reducer.consume(line: finalThinking, at: start.addingTimeInterval(3)) == .done)
    #expect(reducer.pendingToolUseSince == nil)

    let finalText = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Built."}]}}"#
    #expect(reducer.consume(line: finalText, at: start.addingTimeInterval(4)) == nil)
    #expect(reducer.currentEvent == .done)
}

@Test func claudeReducerExpiresAbandonedSessions() {
    var reducer = ClaudeTranscriptStateReducer()
    _ = reducer.consume(
        line: #"{"type":"user","message":{"content":"go"}}"#,
        at: start
    )
    _ = reducer.consume(
        line: #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash"}]}}"#,
        at: start.addingTimeInterval(1)
    )
    #expect(reducer.quietCheck(at: start.addingTimeInterval(30)) == .attention)

    // The agent process was killed at the prompt; without expiry the
    // controller would hold amber forever.
    #expect(reducer.quietCheck(at: start.addingTimeInterval(950)) == .idle)
    #expect(reducer.pendingToolUseSince == nil)
    #expect(reducer.quietCheck(at: start.addingTimeInterval(1_000)) == nil)
}

@Test func codexReducerExpiresAbandonedSessions() {
    var reducer = CodexSessionLogStateReducer()
    _ = reducer.consume(
        line: #"{"type":"event_msg","payload":{"type":"exec_approval_request"}}"#,
        at: start
    )
    #expect(reducer.currentEvent == .attention)
    #expect(reducer.quietCheck(at: start.addingTimeInterval(100)) == nil)
    #expect(reducer.quietCheck(at: start.addingTimeInterval(950)) == .idle)
}

@Test func claudeReducerReachesIdleAfterALongQuietDone() {
    var reducer = ClaudeTranscriptStateReducer()
    _ = reducer.consume(
        line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#,
        at: start
    )
    #expect(reducer.currentEvent == .done)
    #expect(reducer.quietCheck(at: start.addingTimeInterval(60)) == nil)
    #expect(reducer.quietCheck(at: start.addingTimeInterval(400)) == .idle)
}

@Test func claudeReducerTreatsSidechainsAndUnknownsAsActivityOnly() {
    var reducer = ClaudeTranscriptStateReducer()

    let sidechain = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}"#
    // A subagent's final text must not read as the main turn finishing.
    #expect(reducer.consume(line: sidechain, at: start) == .working)
    #expect(reducer.currentEvent == .working)

    #expect(reducer.consume(line: "not json at all", at: start.addingTimeInterval(1)) == nil)
    #expect(reducer.currentEvent == .working)

    // Summaries are rewritten out of band and say nothing about the turn.
    let before = reducer.lastActivity
    #expect(reducer.consume(line: #"{"type":"summary","summary":"..."}"#, at: start.addingTimeInterval(2)) == nil)
    #expect(reducer.lastActivity == before)
}

@Test func claudeReducerIgnoresBookkeepingEntriesAfterDone() {
    var reducer = ClaudeTranscriptStateReducer()
    _ = reducer.consume(
        line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#,
        at: start
    )
    #expect(reducer.currentEvent == .done)

    // Observed in real transcripts: ai-title (and friends) append AFTER the
    // final assistant message. They must not flip done back to working, or
    // the lightbar would strand on the working color after every first turn.
    for line in [
        #"{"type":"ai-title","title":"Fixing the bug"}"#,
        #"{"type":"file-history-snapshot","snapshot":{}}"#,
        #"{"type":"queue-operation","operation":"drain"}"#
    ] {
        #expect(reducer.consume(line: line, at: start.addingTimeInterval(3)) == nil)
        #expect(reducer.currentEvent == .done)
    }
}

@Test func codexReducerMatchesProtocolMarkersNotProse() {
    var reducer = CodexSessionLogStateReducer()

    #expect(reducer.consume(
        line: #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_started"}}"#,
        at: start
    ) == .working)

    // A tool's plain-text output mentioning the words must not transition;
    // it still counts as activity, which is already the current state.
    #expect(reducer.consume(
        line: #"{"type":"response_item","payload":{"output":"echo task_complete done"}}"#,
        at: start.addingTimeInterval(1)
    ) == nil)
    #expect(reducer.currentEvent == .working)

    #expect(reducer.consume(
        line: #"{"type":"event_msg","payload":{"type":"exec_approval_request","command":"rm -rf"}}"#,
        at: start.addingTimeInterval(2)
    ) == .attention)

    // Answering the approval produces ordinary appends, which clear it.
    #expect(reducer.consume(
        line: #"{"type":"response_item","payload":{"type":"function_call_output"}}"#,
        at: start.addingTimeInterval(3)
    ) == .working)

    #expect(reducer.consume(
        line: #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}"#,
        at: start.addingTimeInterval(4)
    ) == .done)

    // Trailing bookkeeping after completion must not resurrect working;
    // only an explicit task_started marker starts the next turn.
    #expect(reducer.consume(
        line: #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        at: start.addingTimeInterval(5)
    ) == nil)
    #expect(reducer.currentEvent == .done)
}

@Test func codexReducerSurvivesSpacingVariations() {
    var reducer = CodexSessionLogStateReducer()
    #expect(reducer.consume(
        line: #"{ "type" : "event_msg", "payload" : { "type" : "task_complete" } }"#,
        at: start
    ) == .done)
}

@Test func inferredEnvelopesDefaultToReported() {
    let parsed = AgentEventEnvelope.parse(fileContents: "event=attention\n")
    #expect(parsed?.isInferred == false)

    let inferred = AgentEventEnvelope(
        event: .attention,
        source: "claude-code",
        timestamp: nil,
        isInferred: true
    )
    #expect(inferred.isInferred)
}
