import Foundation

public enum AgentIntegrationConfigError: LocalizedError, Equatable {
    case malformedClaudeSettings

    public var errorDescription: String? {
        switch self {
        case .malformedClaudeSettings:
            return "~/.claude/settings.json exists but is not a JSON object, so it was left untouched."
        }
    }
}

/// Builds the Claude Code `settings.json` hook entries that forward agent
/// lifecycle events to the bundled `agent-remote-event` helper. Pure data
/// transforms live here so merging stays testable and file IO stays in the
/// app target.
public enum ClaudeHooksConfig {
    /// Hook events paired with the spool-event token the helper receives.
    /// `Notification` covers both permission requests and idle prompts, which
    /// are exactly the moments a controller in your hands should tap you.
    public static let hookEvents: [(hook: String, token: String)] = [
        ("UserPromptSubmit", "working"),
        ("Notification", "attention"),
        ("Stop", "done"),
        ("SessionEnd", "idle")
    ]

    public static func command(helperPath: String, token: String) -> String {
        "\(shellQuoted(helperPath)) \(token) claude-code"
    }

    /// Returns `settingsJSON` with any missing Agent Remote hooks appended.
    /// Existing user hooks are preserved untouched; an entry is recognized as
    /// ours by containing the helper path, so reinstalling after moving the
    /// app adds the new path rather than silently keeping a dead one.
    public static func addingAgentRemoteHooks(
        toSettingsJSON settingsJSON: Data?,
        helperPath: String
    ) throws -> (json: Data, changed: Bool) {
        var root: [String: Any] = [:]
        if let settingsJSON, !settingsJSON.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: settingsJSON),
                  let object = parsed as? [String: Any] else {
                throw AgentIntegrationConfigError.malformedClaudeSettings
            }
            root = object
        }

        var hooks: [String: Any] = [:]
        if let existing = root["hooks"] {
            guard let existingHooks = existing as? [String: Any] else {
                throw AgentIntegrationConfigError.malformedClaudeSettings
            }
            hooks = existingHooks
        }

        var changed = false
        for (hookName, token) in hookEvents {
            var entries: [[String: Any]] = []
            if let existing = hooks[hookName] {
                guard let existingEntries = existing as? [[String: Any]] else {
                    throw AgentIntegrationConfigError.malformedClaudeSettings
                }
                entries = existingEntries
            }

            guard !containsHelper(entries: entries, helperPath: helperPath) else {
                continue
            }
            entries.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": command(helperPath: helperPath, token: token)
                    ]
                ]
            ])
            hooks[hookName] = entries
            changed = true
        }

        root["hooks"] = hooks
        let json = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (json, changed)
    }

    /// Recognition matches on the shell-quoted form actually embedded in our
    /// commands: for a path containing an apostrophe the raw path never
    /// appears verbatim in the command string, and matching on it would make
    /// every reinstall append a duplicate hook.
    private static func containsHelper(
        entries: [[String: Any]],
        helperPath: String
    ) -> Bool {
        let marker = shellQuoted(helperPath)
        return entries.contains { entry in
            guard let commands = entry["hooks"] as? [[String: Any]] else {
                return false
            }
            return commands.contains { hook in
                (hook["command"] as? String)?.contains(marker) == true
            }
        }
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Edits the top-level `notify` entry of Codex CLI's `config.toml` without a
/// full TOML dependency. Only the prefix before the first real `[table]`
/// header is considered — a `notify` key after a header belongs to that
/// table — and "real" is decided by a line classifier that tracks strings,
/// comments, and bracket continuations, so a `[header]`-shaped line inside a
/// multiline string or a nested array can never derail the scan.
public enum CodexNotifyConfig {
    public static func notifyLine(helperPath: String) -> String {
        "notify = [\"\(tomlEscaped(helperPath))\", \"codex-notify\"]"
    }

    public static func settingNotify(
        inConfigTOML existing: String?,
        helperPath: String
    ) -> (toml: String, changed: Bool) {
        let desired = notifyLine(helperPath: helperPath)
        guard let existing, !existing.isEmpty else {
            return (desired + "\n", true)
        }

        var lines = existing.components(separatedBy: "\n")
        var classifier = TOMLLineClassifier()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let startsAtTopLevel = classifier.isAtTopLevel
            classifier.consume(line)
            guard startsAtTopLevel else {
                index += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                // First genuine table header: the top-level section is over.
                break
            }
            if isNotifyAssignment(trimmed) {
                // Only the exact canonical line counts as installed; a
                // different notifier whose comment merely mentions this app
                // must still be replaced.
                if trimmed == desired {
                    return (existing, false)
                }
                // The assignment may continue across lines (a multiline
                // array); replace the whole value or the file would keep a
                // dangling `]`.
                var endIndex = index
                while !classifier.isAtTopLevel, endIndex + 1 < lines.count {
                    endIndex += 1
                    classifier.consume(lines[endIndex])
                }
                lines.replaceSubrange(index...endIndex, with: [desired])
                return (lines.joined(separator: "\n"), true)
            }
            index += 1
        }

        lines.insert(desired, at: 0)
        return (lines.joined(separator: "\n"), true)
    }

    private static func isNotifyAssignment(_ trimmed: String) -> Bool {
        guard let (key, remainder) = leadingKey(of: trimmed) else { return false }
        return key == "notify"
            && remainder.trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    /// Extracts the first key token of a candidate `key = value` line.
    /// Quoted keys are decoded — TOML basic-string escapes included — so an
    /// escaped spelling like `"notify"` is still recognized as `notify`
    /// instead of provoking a duplicate-key insertion. Dotted keys never
    /// match: the remainder then starts with `.`, not `=`.
    private static func leadingKey(
        of trimmed: String
    ) -> (key: String, remainder: Substring)? {
        if trimmed.hasPrefix("\"") {
            var key = ""
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex {
                let character = trimmed[index]
                if character == "\"" {
                    return (key, trimmed[trimmed.index(after: index)...])
                }
                if character == "\\" {
                    let escapeStart = trimmed.index(after: index)
                    guard escapeStart < trimmed.endIndex,
                          let (decoded, next) = decodedEscape(trimmed, at: escapeStart) else {
                        return nil
                    }
                    key.append(decoded)
                    index = next
                } else {
                    key.append(character)
                    index = trimmed.index(after: index)
                }
            }
            return nil
        }
        if trimmed.hasPrefix("'") {
            let afterOpen = trimmed.index(after: trimmed.startIndex)
            guard let close = trimmed[afterOpen...].firstIndex(of: "'") else {
                return nil
            }
            return (
                String(trimmed[afterOpen..<close]),
                trimmed[trimmed.index(after: close)...]
            )
        }
        let keyEnd = trimmed.firstIndex {
            $0 == "=" || $0 == "." || $0 == " " || $0 == "\t"
        } ?? trimmed.endIndex
        return (String(trimmed[..<keyEnd]), trimmed[keyEnd...])
    }

    private static func decodedEscape(
        _ text: String,
        at index: String.Index
    ) -> (Character, String.Index)? {
        let next = text.index(after: index)
        switch text[index] {
        case "\"": return ("\"", next)
        case "\\": return ("\\", next)
        case "b": return ("\u{08}", next)
        case "t": return ("\t", next)
        case "n": return ("\n", next)
        case "f": return ("\u{0C}", next)
        case "r": return ("\r", next)
        case "u": return decodedUnicode(text, from: next, digits: 4)
        case "U": return decodedUnicode(text, from: next, digits: 8)
        default: return nil
        }
    }

    private static func decodedUnicode(
        _ text: String,
        from start: String.Index,
        digits: Int
    ) -> (Character, String.Index)? {
        guard let end = text.index(start, offsetBy: digits, limitedBy: text.endIndex),
              let value = UInt32(text[start..<end], radix: 16),
              let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return (Character(scalar), end)
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Tracks just enough TOML lexical state — multiline strings, single-line
/// strings, comments, and bracket depth — to decide whether a line begins in
/// a genuine top-level position. Deliberately not a parser: it only needs to
/// be correct for well-formed files, and on malformed input it degrades to
/// the pre-existing behavior of treating lines at face value.
struct TOMLLineClassifier {
    private enum MultilineString {
        case none
        case basic
        case literal
    }

    private var multiline = MultilineString.none
    private var bracketDepth = 0

    var isAtTopLevel: Bool {
        multiline == .none && bracketDepth == 0
    }

    mutating func consume(_ line: String) {
        let characters = Array(line)
        var index = 0
        var singleLineDelimiter: Character?

        while index < characters.count {
            switch multiline {
            case .basic:
                if characters[index] == "\\" {
                    index += 2
                } else if characters[index] == "\"" {
                    // TOML allows one or two content quotes adjacent to the
                    // closing delimiter (`""""x` is a quote then `"""`).
                    // Consume the whole quote run at once: matching the
                    // first three greedily would leave a phantom quote that
                    // opens a bogus single-line string and can hide a
                    // closing `]` on the same line.
                    let run = runLength(characters, from: index, of: "\"")
                    if run >= 3 { multiline = .none }
                    index += run
                } else {
                    index += 1
                }
            case .literal:
                if characters[index] == "'" {
                    let run = runLength(characters, from: index, of: "'")
                    if run >= 3 { multiline = .none }
                    index += run
                } else {
                    index += 1
                }
            case .none:
                if let delimiter = singleLineDelimiter {
                    if delimiter == "\"", characters[index] == "\\" {
                        index += 2
                    } else {
                        if characters[index] == delimiter {
                            singleLineDelimiter = nil
                        }
                        index += 1
                    }
                } else {
                    switch characters[index] {
                    case "#":
                        index = characters.count
                    case "\"":
                        if matches(characters, at: index, "\"\"\"") {
                            multiline = .basic
                            index += 3
                        } else {
                            singleLineDelimiter = "\""
                            index += 1
                        }
                    case "'":
                        if matches(characters, at: index, "'''") {
                            multiline = .literal
                            index += 3
                        } else {
                            singleLineDelimiter = "'"
                            index += 1
                        }
                    case "[":
                        bracketDepth += 1
                        index += 1
                    case "]":
                        bracketDepth = max(0, bracketDepth - 1)
                        index += 1
                    default:
                        index += 1
                    }
                }
            }
        }
    }

    private func matches(
        _ characters: [Character],
        at index: Int,
        _ delimiter: String
    ) -> Bool {
        let delimiterCharacters = Array(delimiter)
        guard index + delimiterCharacters.count <= characters.count else {
            return false
        }
        return Array(characters[index..<index + delimiterCharacters.count])
            == delimiterCharacters
    }

    private func runLength(
        _ characters: [Character],
        from index: Int,
        of character: Character
    ) -> Int {
        var end = index
        while end < characters.count, characters[end] == character {
            end += 1
        }
        return end - index
    }
}
