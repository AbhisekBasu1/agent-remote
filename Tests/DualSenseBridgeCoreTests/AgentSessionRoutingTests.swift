import Testing
@testable import DualSenseBridgeCore

@Test func codexDesktopMetadataRoutesToItsExactThread() {
    let line = #"{"timestamp":"2026-07-17T00:00:00Z","type":"session_meta","payload":{"id":"019F7026-AF7C-7073-B811-8830DCE6CC28","cwd":"/tmp/project","originator":"Codex Desktop","source":"vscode"}}"#
    let route = AgentSessionRouting.codexRoute(
        transcriptPath: "/tmp/rollout-without-an-id.jsonl",
        sessionMetadataLine: line
    )

    #expect(route.host == .desktop)
    #expect(route.threadID == "019f7026-af7c-7073-b811-8830dce6cc28")
    #expect(!route.isSubagent)
}

@Test func codexCLIRecordStaysTerminalHosted() {
    let line = #"{"type":"session_meta","payload":{"id":"019f9595-2780-7173-9f2b-6bf509b5c555","originator":"codex_exec","source":"exec"}}"#
    let route = AgentSessionRouting.codexRoute(
        transcriptPath: "/tmp/rollout.jsonl",
        sessionMetadataLine: line
    )

    #expect(route.host == .terminal)
    #expect(route.threadID == "019f9595-2780-7173-9f2b-6bf509b5c555")
    #expect(!route.isSubagent)
}

@Test func rolloutFilenameSuppliesAValidatedThreadFallback() {
    let route = AgentSessionRouting.codexRoute(
        transcriptPath: "/Users/me/.codex/sessions/2026/07/17/rollout-2026-07-17T18-26-51-019f7026-af7c-7073-b811-8830dce6cc28.jsonl",
        sessionMetadataLine: "not json"
    )

    #expect(route.host == .unknown)
    #expect(route.threadID == "019f7026-af7c-7073-b811-8830dce6cc28")
    #expect(AgentSessionRouting.codexThreadID(
        transcriptPath: "/tmp/not-a-rollout.jsonl"
    ) == nil)
}

@Test func internalCodexSubagentPointsBackToItsVisibleParent() {
    let line = #"{"type":"session_meta","payload":{"id":"019f9791-fea1-71c3-ab9b-5a44dcd13801","originator":"Codex Desktop","parent_thread_id":"019f7026-af7c-7073-b811-8830dce6cc28","session_id":"019f7026-af7c-7073-b811-8830dce6cc28","thread_source":"subagent","source":{"subagent":{"other":"guardian"}}}}"#
    let route = AgentSessionRouting.codexRoute(
        transcriptPath: "/tmp/rollout.jsonl",
        sessionMetadataLine: line
    )

    #expect(route.host == .desktop)
    #expect(route.isSubagent)
    #expect(route.parentThreadID == "019f7026-af7c-7073-b811-8830dce6cc28")
}
