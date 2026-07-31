import DualSenseBridgeCore
import Foundation

/// Wires coding agents to the event spool by editing their user-level config
/// files. The pure merge logic lives in DualSenseBridgeCore; this type owns
/// the file IO, backups, and helper-script location.
final class AgentIntegrationInstaller {
    enum InstallOutcome: Equatable {
        case installed(detail: String)
        case alreadyInstalled(detail: String)
        case failed(message: String)
    }

    private let fileManager = FileManager.default

    /// The helper only exists inside the packaged bundle; `swift run` builds
    /// have no Resources directory, and hooks must never point at a path that
    /// disappears with a build directory.
    var helperURL: URL? {
        Bundle.main.url(forResource: "agent-remote-event", withExtension: nil)
    }

    private var claudeSettingsURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    private var codexConfigURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    func installClaudeHooks() -> InstallOutcome {
        guard let helper = helperURL else {
            return .failed(message: Self.missingHelperMessage)
        }
        ensureSpoolDirectory()

        // A file that exists but cannot be read must abort the install: the
        // merge would otherwise treat live configuration as absent and
        // replace it with a fresh file.
        let existing: Data?
        if fileManager.fileExists(atPath: claudeSettingsURL.path) {
            do {
                existing = try Data(contentsOf: claudeSettingsURL)
            } catch {
                return .failed(
                    message: "~/.claude/settings.json exists but could not be read: \(error.localizedDescription)"
                )
            }
        } else {
            existing = nil
        }
        do {
            let (json, changed) = try ClaudeHooksConfig.addingAgentRemoteHooks(
                toSettingsJSON: existing,
                helperPath: helper.path
            )
            guard changed else {
                return .alreadyInstalled(
                    detail: "Claude Code hooks already point at this app."
                )
            }
            try backUpAndWrite(data: json, to: claudeSettingsURL)
            return .installed(
                detail: "Hooks were added to ~/.claude/settings.json. Restart any running Claude Code session to pick them up."
            )
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    func installCodexNotify() -> InstallOutcome {
        guard let helper = helperURL else {
            return .failed(message: Self.missingHelperMessage)
        }
        ensureSpoolDirectory()

        let existing: String?
        if fileManager.fileExists(atPath: codexConfigURL.path) {
            do {
                existing = try String(contentsOf: codexConfigURL, encoding: .utf8)
            } catch {
                return .failed(
                    message: "~/.codex/config.toml exists but could not be read as UTF-8: \(error.localizedDescription)"
                )
            }
        } else {
            existing = nil
        }
        let (toml, changed) = CodexNotifyConfig.settingNotify(
            inConfigTOML: existing,
            helperPath: helper.path
        )
        guard changed else {
            return .alreadyInstalled(
                detail: "Codex notifications already point at this app."
            )
        }
        guard let data = toml.data(using: .utf8) else {
            return .failed(message: "The Codex config could not be encoded.")
        }
        do {
            try backUpAndWrite(data: data, to: codexConfigURL)
            return .installed(
                detail: "notify was set in ~/.codex/config.toml. Codex reports turn completion; new notification types are mapped automatically."
            )
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Creating the spool up front keeps the helper's own `mkdir -p` from
    /// being the first writer, so the watcher can already be attached by the
    /// time an agent fires its first hook.
    func ensureSpoolDirectory() {
        try? fileManager.createDirectory(
            at: AgentEventMonitor.spoolDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func backUpAndWrite(data: Data, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            let backup = destination.appendingPathExtension("agent-remote-backup")
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            try fileManager.copyItem(at: destination, to: backup)
        }
        try data.write(to: destination, options: .atomic)
    }

    private static let missingHelperMessage =
        "The agent-remote-event helper is missing from this build. Package the app with scripts/package-app.sh and run it from dist."
}
