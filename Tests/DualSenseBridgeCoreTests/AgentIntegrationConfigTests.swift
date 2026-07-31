import Foundation
import Testing
@testable import DualSenseBridgeCore

private let helperPath = "/Applications/Agent Remote.app/Contents/Resources/agent-remote-event"

private func hooksObject(from data: Data) throws -> [String: Any] {
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return root?["hooks"] as? [String: Any] ?? [:]
}

private func commands(in hooks: [String: Any], event: String) -> [String] {
    guard let entries = hooks[event] as? [[String: Any]] else { return [] }
    return entries.flatMap { entry -> [String] in
        guard let hookList = entry["hooks"] as? [[String: Any]] else { return [] }
        return hookList.compactMap { $0["command"] as? String }
    }
}

@Test func claudeHooksAreCreatedFromScratch() throws {
    let (json, changed) = try ClaudeHooksConfig.addingAgentRemoteHooks(
        toSettingsJSON: nil,
        helperPath: helperPath
    )
    #expect(changed)

    let hooks = try hooksObject(from: json)
    for (event, token) in ClaudeHooksConfig.hookEvents {
        let eventCommands = commands(in: hooks, event: event)
        #expect(eventCommands.count == 1)
        #expect(eventCommands.first?.contains(helperPath) == true)
        #expect(eventCommands.first?.hasSuffix(" \(token) claude-code") == true)
    }
}

@Test func claudeHooksInstallationIsIdempotent() throws {
    let (first, _) = try ClaudeHooksConfig.addingAgentRemoteHooks(
        toSettingsJSON: nil,
        helperPath: helperPath
    )
    let (second, changed) = try ClaudeHooksConfig.addingAgentRemoteHooks(
        toSettingsJSON: first,
        helperPath: helperPath
    )
    #expect(!changed)
    #expect(first == second)
}

@Test func claudeHooksPreserveExistingUserConfiguration() throws {
    let existing = """
    {
      "model": "opus",
      "hooks": {
        "Stop": [
          {"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}
        ]
      }
    }
    """.data(using: .utf8)

    let (json, changed) = try ClaudeHooksConfig.addingAgentRemoteHooks(
        toSettingsJSON: existing,
        helperPath: helperPath
    )
    #expect(changed)

    let root = try JSONSerialization.jsonObject(with: json) as? [String: Any]
    #expect(root?["model"] as? String == "opus")

    let hooks = try hooksObject(from: json)
    let stopCommands = commands(in: hooks, event: "Stop")
    #expect(stopCommands.count == 2)
    #expect(stopCommands.contains { $0.contains("afplay") })
    #expect(stopCommands.contains { $0.contains(helperPath) })
}

@Test func claudeHooksRejectNonObjectSettings() {
    let malformed = "[1, 2, 3]".data(using: .utf8)
    #expect(throws: AgentIntegrationConfigError.malformedClaudeSettings) {
        try ClaudeHooksConfig.addingAgentRemoteHooks(
            toSettingsJSON: malformed,
            helperPath: helperPath
        )
    }
}

@Test func claudeHookCommandQuotesThePath() {
    let command = ClaudeHooksConfig.command(helperPath: helperPath, token: "working")
    #expect(command == "'\(helperPath)' working claude-code")
}

@Test func codexNotifyIsCreatedWhenConfigIsMissing() {
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: nil,
        helperPath: helperPath
    )
    #expect(changed)
    #expect(toml == "notify = [\"\(helperPath)\", \"codex-notify\"]\n")
}

@Test func codexNotifyIsInsertedBeforeTheFirstTable() {
    let existing = """
    model = "gpt-5.6-codex"

    [profiles.full]
    model = "gpt-5.6-codex-max"
    """
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)

    let lines = toml.components(separatedBy: "\n")
    #expect(lines.first?.hasPrefix("notify = [") == true)
    // A key appended after a [table] header would silently become part of
    // that table, so insertion must happen at the top of the file.
    let notifyIndex = lines.firstIndex { $0.hasPrefix("notify") }
    let tableIndex = lines.firstIndex { $0.hasPrefix("[") }
    #expect(notifyIndex != nil && tableIndex != nil && notifyIndex! < tableIndex!)
    #expect(toml.contains("model = \"gpt-5.6-codex\""))
}

@Test func codexNotifyReplacesAnExistingTopLevelEntry() {
    let existing = """
    notify = ["/old/path/notifier"]
    model = "gpt-5.6-codex"
    """
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    #expect(!toml.contains("/old/path/notifier"))
    #expect(toml.contains(CodexNotifyConfig.notifyLine(helperPath: helperPath)))
    #expect(toml.contains("model = \"gpt-5.6-codex\""))
}

@Test func codexNotifyIsIdempotent() {
    let (first, _) = CodexNotifyConfig.settingNotify(
        inConfigTOML: nil,
        helperPath: helperPath
    )
    let (second, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: first,
        helperPath: helperPath
    )
    #expect(!changed)
    #expect(first == second)
}

@Test func codexNotifyLeavesTableScopedKeysAlone() {
    let existing = """
    model = "gpt-5.6-codex"

    [tui]
    notify = ["some-tui-notifier"]
    """
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    #expect(toml.contains("notify = [\"some-tui-notifier\"]"))
    #expect(toml.hasPrefix("notify = [\"\(helperPath)\""))
}

@Test func codexNotifyDoesNotMatchKeysThatMerelyStartWithNotify() {
    let existing = "notify_command = \"something\""
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    #expect(toml.contains("notify_command = \"something\""))
    #expect(toml.hasPrefix("notify = ["))
}

@Test func codexNotifyEscapesQuotesAndBackslashes() {
    let trickyPath = "/tmp/we\"ird\\path/agent-remote-event"
    let line = CodexNotifyConfig.notifyLine(helperPath: trickyPath)
    #expect(line == "notify = [\"/tmp/we\\\"ird\\\\path/agent-remote-event\", \"codex-notify\"]")
}

@Test func codexNotifyIgnoresHeadersAndKeysInsideMultilineStrings() {
    let existing = """
    model = "gpt-5.6-codex"
    instructions = \"\"\"
    [not-a-table]
    notify = ["fake"]
    \"\"\"
    notify = ["/old/notifier"]
    """
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    // The string contents must survive untouched, the real top-level entry
    // must be replaced, and no duplicate may be inserted at the top.
    #expect(toml.contains("[not-a-table]"))
    #expect(toml.contains("notify = [\"fake\"]"))
    #expect(!toml.contains("/old/notifier"))
    let notifyLines = toml.components(separatedBy: "\n").filter {
        $0.hasPrefix("notify = [\"\(helperPath)\"")
    }
    #expect(notifyLines.count == 1)
}

@Test func codexNotifyTreatsNestedArrayLinesAsContinuations() {
    let existing = """
    matrix = [
      [1, 2],
      [3, 4],
    ]
    notify = ["/old/notifier"]
    """
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    // `[1, 2],` must not read as a table header, or the scan would stop
    // before the real notify entry and insert a duplicate key.
    #expect(!toml.contains("/old/notifier"))
    #expect(toml.contains("  [1, 2],"))
    #expect(toml.contains(CodexNotifyConfig.notifyLine(helperPath: helperPath)))
}

@Test func codexNotifyReplacesMultilineArraysCompletely() {
    let existing = """
    notify = [
      "/old/notifier",
    ]
    model = "gpt-5.6-codex"
    """
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    #expect(!toml.contains("/old/notifier"))
    #expect(toml.contains("model = \"gpt-5.6-codex\""))
    // Replacing only the first line of a multiline value would leave a
    // dangling `]` behind and the file would no longer parse.
    let dangling = toml.components(separatedBy: "\n").filter {
        $0.trimmingCharacters(in: .whitespaces) == "]"
    }
    #expect(dangling.isEmpty)
}

@Test func codexNotifyRecognizesQuotedKeysAndIgnoresComments() {
    let existing = """
    # notify = ["/commented-out"]
    # [commented-table]
    "notify" = ["/old/notifier"]
    """
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    #expect(toml.contains("# notify = [\"/commented-out\"]"))
    #expect(!toml.contains("\"notify\" = [\"/old/notifier\"]"))
    #expect(toml.contains(CodexNotifyConfig.notifyLine(helperPath: helperPath)))
}

@Test func codexNotifyReplacesEntriesWhoseCommentMentionsThisApp() {
    let existing = "notify = [\"/other/notifier\"] # migrated from \(helperPath)"
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    // A different notifier stays a different notifier no matter what its
    // comment says; only the exact canonical line counts as installed.
    #expect(changed)
    #expect(!toml.contains("/other/notifier"))
}

@Test func codexNotifyHandlesQuoteRunsAtMultilineDelimiters() {
    // TOML permits content quotes directly against multiline delimiters:
    // `""""quoted""""` is the string `"quoted"`. A greedy first-three-quotes
    // close once left a phantom quote open, hid the closing `]`, and made the
    // replacement walk consume every following line.
    let existing = """
    notify = [
      \"\"\"\"quoted\"\"\"\", ]
    model = "keep"
    """
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    #expect(toml.contains("model = \"keep\""))
    #expect(!toml.contains("quoted"))
    #expect(toml.contains(CodexNotifyConfig.notifyLine(helperPath: helperPath)))
}

@Test func codexNotifyDecodesEscapedQuotedKeys() {
    // "\u006eotify" is semantically the key `notify`; failing to decode it
    // would insert a second bare notify and the file would stop parsing as
    // TOML (duplicate key).
    let existing = "\"\\u006eotify\" = [\"/old/notifier\"]"
    let (toml, changed) = CodexNotifyConfig.settingNotify(
        inConfigTOML: existing,
        helperPath: helperPath
    )
    #expect(changed)
    #expect(!toml.contains("/old/notifier"))
    let notifyAssignments = toml.components(separatedBy: "\n").filter {
        $0.contains("notify") && $0.contains("=")
    }
    #expect(notifyAssignments.count == 1)
}

@Test func claudeHooksStayIdempotentForPathsWithApostrophes() throws {
    let apostrophePath = "/Users/example/Developer's Tools/Agent Remote.app/Contents/Resources/agent-remote-event"
    let (first, firstChanged) = try ClaudeHooksConfig.addingAgentRemoteHooks(
        toSettingsJSON: nil,
        helperPath: apostrophePath
    )
    let (second, secondChanged) = try ClaudeHooksConfig.addingAgentRemoteHooks(
        toSettingsJSON: first,
        helperPath: apostrophePath
    )
    #expect(firstChanged)
    #expect(!secondChanged)
    #expect(first == second)
}
