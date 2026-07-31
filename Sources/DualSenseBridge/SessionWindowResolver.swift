import AppKit
import ApplicationServices
import DualSenseBridgeCore
import Foundation

/// Brings a session's host window to the front. Harnesses close their
/// transcripts between writes, so the writer process frequently does not
/// exist at the moment of a raise — the strategy therefore depends on the
/// session's source. Ghostty 1.3 exposes terminals and working directories
/// through its scripting dictionary, which can select an exact native tab or
/// split. Other terminals retain the Accessibility title-match fallback.
/// Codex Desktop rollouts identify themselves in `session_meta` and carry a
/// thread UUID, so those can use the app's registered deep link directly.
final class SessionWindowResolver {
    private struct GhosttyTerminalRecord {
        let candidate: GhosttyTerminalCandidate
        let cwd: String
    }

    private struct GhosttyCycleState {
        let transcriptPath: String
        let candidateIDs: [String]
        let selectedID: String
        let timestamp: TimeInterval
    }

    private static let codexDesktopBundleIDs: Set<String> = [
        "com.openai.codex", // Current rebranded ChatGPT/Codex desktop app.
        "com.openai.chat"   // Older ChatGPT builds.
    ]
    private static let ghosttyBundleID = "com.mitchellh.ghostty"
    private static let ghosttyBindingsDefaultsKey =
        "FleetGhosttyTerminalBindings.v1"
    private static let ghosttyCycleWindowSeconds: TimeInterval = 4
    private static let freshSessionObservationSeconds: TimeInterval = 8
    private static let maximumRememberedGhosttyBindings = 128
    private static let knownTerminalBundleIDs: Set<String> = [
        ghosttyBundleID,
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm"
    ]

    private let workQueue = DispatchQueue(
        label: "local.controllerproject.DualSenseBridge.window-resolver",
        qos: .userInitiated
    )
    private let defaults: UserDefaults
    private var ghosttyBindings: [String: String]
    private var lastGhosttyChoice: GhosttyCycleState?
    private var observedSessionEvents: [String: AgentActivityEvent] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ghosttyBindings = defaults.dictionary(
            forKey: Self.ghosttyBindingsDefaultsKey
        ) as? [String: String] ?? [:]
    }

    /// Learns the strongest association available without touching terminal
    /// input. A brand-new session first becomes Working while Ghostty and its
    /// exact terminal are normally still focused. Capturing the scripting
    /// API's stable terminal ID at that moment makes later raises exact even
    /// when several tabs share the same directory. Existing sessions are not
    /// relearned from background activity, which could otherwise poison a
    /// correct binding while the user views a different same-project tab.
    func observe(sessions: [AgentSessionSummary]) {
        let now = Date()
        var freshWorkingSessions: [(AgentSessionSummary, Date)] = []
        let liveIDs = Set(sessions.map(\.id))

        for session in sessions {
            let previousEvent = observedSessionEvents[session.id]
            observedSessionEvents[session.id] = session.event
            guard session.event == .working,
                  previousEvent == nil,
                  let cwd = session.cwd,
                  !cwd.isEmpty,
                  session.source == "claude-code" || session.source == "codex"
            else {
                continue
            }

            if session.source == "codex" {
                let route = AgentSessionRouting.codexRoute(
                    transcriptPath: session.id,
                    sessionMetadataLine: Self.firstLine(of: session.id)
                )
                guard route.host != .desktop else { continue }
            }

            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: session.id
            ),
            let created = attributes[.creationDate] as? Date,
            let modified = attributes[.modificationDate] as? Date,
            now.timeIntervalSince(created) >= -1,
            now.timeIntervalSince(created)
                <= Self.freshSessionObservationSeconds else {
                continue
            }
            freshWorkingSessions.append((session, modified))
        }
        observedSessionEvents = observedSessionEvents.filter {
            liveIDs.contains($0.key)
        }

        // One focused terminal can only establish one identity. If several
        // summaries changed in a single publication, the newest transcript
        // write is the one most likely caused by the foreground prompt.
        guard let session = freshWorkingSessions.max(by: {
            $0.1 < $1.1
        })?.0,
        let cwd = session.cwd,
        let ghostty = Self.runningApplication(bundleID: Self.ghosttyBundleID),
        ghostty.isActive,
        let record = Self.focusedGhosttyTerminal(
            bundlePath: ghostty.bundleURL?.path
        ),
        Self.normalizedPath(record.cwd) == Self.normalizedPath(cwd) else {
            return
        }

        rememberGhosttyTerminal(
            record.candidate.id,
            forTranscript: session.id
        )
        DiagnosticLog.write(
            "window resolver: learned a Ghostty terminal binding for a new active session"
        )
    }

    /// Completion runs on the main queue with whether anything was raised.
    func raise(
        transcriptPath: String,
        cwd: String?,
        source: String,
        completion: @escaping (Bool) -> Void
    ) {
        workQueue.async {
            let codexRoute: CodexSessionRoute?
            if source == "codex" {
                codexRoute = AgentSessionRouting.codexRoute(
                    transcriptPath: transcriptPath,
                    sessionMetadataLine: Self.firstLine(of: transcriptPath)
                )
                if let codexRoute {
                    DiagnosticLog.write(
                        "window resolver: Codex host=\(codexRoute.host.rawValue)"
                    )
                }
            } else {
                codexRoute = nil
            }
            let routingHint = source == "claude-code"
                ? Self.claudeRoutingHint(in: transcriptPath)
                : nil

            // A positively identified desktop rollout needs no process
            // search: its deep link is both faster and more precise. Other
            // routes retain ancestry as useful fallback evidence.
            let owners = codexRoute?.host == .desktop
                ? []
                : Self.owningApplications(ofFileWriters: transcriptPath)
            DispatchQueue.main.async {
                completion(self.raiseOnMain(
                    transcriptPath: transcriptPath,
                    owners: owners,
                    cwd: cwd,
                    source: source,
                    routingHint: routingHint,
                    codexRoute: codexRoute
                ))
            }
        }
    }

    // MARK: - Process discovery (background queue)

    /// All applications reachable by walking up from any process that
    /// currently holds the transcript open. Usually zero or one; indexers
    /// and helpers resolve to nil and drop out.
    private static func owningApplications(
        ofFileWriters path: String
    ) -> [NSRunningApplication] {
        guard let output = run("/usr/sbin/lsof", ["-t", "--", path]) else {
            return []
        }
        let pids = output.split(separator: "\n").compactMap {
            pid_t($0.trimmingCharacters(in: .whitespaces))
        }
        DiagnosticLog.write(
            "window resolver: found \(pids.count) transcript writer process(es)"
        )
        var apps: [NSRunningApplication] = []
        for pid in pids {
            if let app = owningApplication(of: pid),
               !apps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                DiagnosticLog.write(
                    "window resolver: pid \(pid) belongs to \(app.bundleIdentifier ?? "?")"
                )
                apps.append(app)
            }
        }
        return apps
    }

    private static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<15 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.bundleIdentifier != nil {
                return app
            }
            guard let parent = parentPID(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        guard let output = run("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"]) else {
            return nil
        }
        return pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `session_meta` is the first JSONL record and is small. Read only a
    /// bounded prefix so opening a long-lived multi-megabyte task remains
    /// effectively constant time.
    private static func firstLine(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 131_072),
              !data.isEmpty else {
            return nil
        }
        let lineData: Data
        if let newline = data.firstIndex(of: 0x0a) {
            lineData = Data(data[..<newline])
        } else {
            lineData = data
        }
        return String(data: lineData, encoding: .utf8)
    }

    /// Claude's short session slug and first real prompt are written near the
    /// start of its transcript. Ghostty commonly turns that prompt into the
    /// tab's task-summary title, so both are useful first-use hints. They are
    /// never identities: a stable learned terminal ID still wins.
    private static func claudeRoutingHint(in path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 524_288),
              !data.isEmpty else {
            return nil
        }
        var slug: String?
        var firstHumanPrompt: String?
        for line in data.split(separator: 0x0a) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dictionary = object as? [String: Any] else {
                continue
            }
            if slug == nil,
               let candidate = dictionary["slug"] as? String,
               !candidate.isEmpty {
                slug = candidate
            }
            if firstHumanPrompt == nil,
               dictionary["type"] as? String == "user",
               dictionary["isMeta"] as? Bool != true,
               let message = dictionary["message"] as? [String: Any],
               let content = message["content"] as? String,
               isHumanClaudePrompt(dictionary, content: content) {
                firstHumanPrompt = content
            }
            if slug != nil, firstHumanPrompt != nil { break }
        }
        let pieces = [slug, firstHumanPrompt].compactMap { $0 }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    private static func isHumanClaudePrompt(
        _ record: [String: Any],
        content: String
    ) -> Bool {
        if let origin = record["origin"] as? [String: Any],
           origin["kind"] as? String == "human" {
            return true
        }
        if record["promptSource"] as? String == "typed" {
            return true
        }
        // Older Claude transcripts may lack the explicit origin fields.
        // Exclude the harness's synthetic command/meta strings while still
        // allowing an ordinary typed prompt from those versions.
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.hasPrefix("<command-")
            && !trimmed.hasPrefix("<local-command-")
    }

    // MARK: - Raising (main queue)

    private func raiseOnMain(
        transcriptPath: String,
        owners: [NSRunningApplication],
        cwd: String?,
        source: String,
        routingHint: String?,
        codexRoute: CodexSessionRoute?
    ) -> Bool {
        let folder = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let codexDesktopOwner = owners.first {
            Self.codexDesktopBundleIDs.contains($0.bundleIdentifier ?? "")
        }
        let terminalOwner = owners.first {
            Self.knownTerminalBundleIDs.contains($0.bundleIdentifier ?? "")
        }

        if source == "claude-code" {
            // Always terminal-hosted. Ghostty's API selects the native tab
            // (and split, when applicable) instead of merely raising the
            // outer window.
            if focusGhosttyTerminal(
                transcriptPath: transcriptPath,
                cwd: cwd,
                source: source,
                routingHint: routingHint
            ) {
                return true
            }
            if Self.raiseTerminalWindow(preferring: terminalOwner, folder: folder) {
                return true
            }
            if let terminalOwner { return Self.activate(terminalOwner) }
            return Self.activateSoleRunningTerminal()
        }

        // Codex Desktop records its host and thread UUID in session_meta.
        // Open the exact task rather than just foregrounding the app.
        if codexRoute?.host == .desktop {
            if let threadID = codexRoute?.threadID,
               Self.openCodexThread(threadID) {
                return true
            }
            if let app = Self.runningCodexDesktopApplication() {
                return Self.activate(app)
            }
            return false
        }

        // An explicit CLI/exec originator must never fall through to Codex
        // Desktop merely because the desktop app happens to be running.
        if codexRoute?.host == .terminal {
            if focusGhosttyTerminal(
                transcriptPath: transcriptPath,
                cwd: cwd,
                source: source,
                routingHint: routingHint
            ) {
                return true
            }
            if Self.raiseTerminalWindow(preferring: terminalOwner, folder: folder) {
                return true
            }
            if let terminalOwner { return Self.activate(terminalOwner) }
            return Self.activateSoleRunningTerminal()
        }

        // Old or incomplete rollouts may lack metadata; retain process
        // ancestry and conservative fallbacks for those.
        if let codexDesktopOwner {
            if let threadID = codexRoute?.threadID,
               Self.openCodexThread(threadID) {
                return true
            }
            return Self.activate(codexDesktopOwner)
        }
        if focusGhosttyTerminal(
            transcriptPath: transcriptPath,
            cwd: cwd,
            source: source,
            routingHint: routingHint
        ) {
            return true
        }
        if Self.raiseTerminalWindow(preferring: terminalOwner, folder: folder) {
            return true
        }
        if let terminalOwner { return Self.activate(terminalOwner) }
        if let app = Self.runningCodexDesktopApplication() {
            if let threadID = codexRoute?.threadID,
               Self.openCodexThread(threadID) {
                return true
            }
            return Self.activate(app)
        }
        return Self.activateSoleRunningTerminal()
    }

    /// Ghostty 1.3's official scripting API exposes stable terminal IDs,
    /// names, working directories, and a focus command. It still exposes no
    /// PID/TTY, so duplicate directories are resolved from a learned stable
    /// ID, title hints, and user-correctable cycling rather than tab order.
    private func focusGhosttyTerminal(
        transcriptPath: String,
        cwd: String?,
        source: String,
        routingHint: String?
    ) -> Bool {
        guard let ghostty = Self.runningApplication(
            bundleID: Self.ghosttyBundleID
        ),
              let ghosttyBundlePath = ghostty.bundleURL?.path,
              let cwd,
              !cwd.isEmpty else {
            return false
        }
        let normalized = Self.normalizedPath(cwd)
        guard let allRecords = Self.ghosttyTerminals(
            bundlePath: ghosttyBundlePath
        ) else {
            return false
        }

        let exact = allRecords.filter {
            Self.normalizedPath($0.cwd) == normalized
        }
        let matchKind: String
        let matchingRecords: [GhosttyTerminalRecord]
        if exact.isEmpty {
            let nestedPrefix = normalized == "/" ? "/" : normalized + "/"
            matchingRecords = allRecords.filter {
                Self.normalizedPath($0.cwd).hasPrefix(nestedPrefix)
            }
            matchKind = "nested"
        } else {
            matchingRecords = exact
            matchKind = "exact"
        }
        guard !matchingRecords.isEmpty else {
            DiagnosticLog.write(
                "window resolver: Ghostty has no terminal with the requested working directory"
            )
            return false
        }

        let candidates = matchingRecords.map(\.candidate)
        let candidateIDs = candidates.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }.map(\.id)
        let now = ProcessInfo.processInfo.systemUptime
        let cycleAfterID: String?
        if let previous = lastGhosttyChoice,
           previous.transcriptPath == transcriptPath,
           previous.candidateIDs == candidateIDs,
           now - previous.timestamp <= Self.ghosttyCycleWindowSeconds {
            cycleAfterID = previous.selectedID
        } else {
            cycleAfterID = nil
        }

        var rememberedID = ghosttyBindings[transcriptPath]
        if let staleID = rememberedID, !candidateIDs.contains(staleID) {
            ghosttyBindings.removeValue(forKey: transcriptPath)
            persistGhosttyBindings()
            DiagnosticLog.write(
                "window resolver: forgot a missing Ghostty terminal binding"
            )
            rememberedID = nil
        }

        guard let choice = GhosttyTerminalSelector.choose(
            candidates: candidates,
            source: source,
            routingHint: routingHint,
            rememberedID: rememberedID,
            cycleAfterID: cycleAfterID
        ) else {
            return false
        }

        if candidates.count > 1 {
            DiagnosticLog.write(
                "window resolver: chose among \(candidates.count) Ghostty \(matchKind)-cwd candidates by \(choice.reason.rawValue)"
            )
        }

        guard Self.focusGhosttyTerminal(
            id: choice.candidate.id,
            bundlePath: ghosttyBundlePath
        ) else {
            return false
        }

        rememberGhosttyTerminal(
            choice.candidate.id,
            forTranscript: transcriptPath
        )
        lastGhosttyChoice = GhosttyCycleState(
            transcriptPath: transcriptPath,
            candidateIDs: candidateIDs,
            selectedID: choice.candidate.id,
            timestamp: now
        )
        DiagnosticLog.write(
            "window resolver: focused a Ghostty terminal by \(matchKind) cwd match (\(choice.reason.rawValue))"
        )
        return true
    }

    private func rememberGhosttyTerminal(
        _ terminalID: String,
        forTranscript transcriptPath: String
    ) {
        guard ghosttyBindings[transcriptPath] != terminalID else { return }
        if ghosttyBindings[transcriptPath] == nil,
           ghosttyBindings.count >= Self.maximumRememberedGhosttyBindings {
            let removable = ghosttyBindings.keys
                .filter { $0 != transcriptPath }
                .sorted()
            if let missingTranscript = removable.first(where: {
                !FileManager.default.fileExists(atPath: $0)
            }) ?? removable.first {
                ghosttyBindings.removeValue(forKey: missingTranscript)
            }
        }
        ghosttyBindings[transcriptPath] = terminalID
        persistGhosttyBindings()
    }

    private func persistGhosttyBindings() {
        defaults.set(
            ghosttyBindings,
            forKey: Self.ghosttyBindingsDefaultsKey
        )
    }

    /// Enumerates Ghostty's terminal surfaces without reading terminal text
    /// or sending input. The list order is retained only as a deterministic
    /// fallback and for cycling.
    private static func ghosttyTerminals(
        bundlePath: String
    ) -> [GhosttyTerminalRecord]? {
        let escapedBundlePath = appleScriptString(bundlePath)
        let source = """
        tell application "\(escapedBundlePath)"
            set terminalRows to {}
            set terminalOrder to 0
            repeat with candidateTerminal in terminals
                set terminalOrder to terminalOrder + 1
                set end of terminalRows to {((id of candidateTerminal) as text), ((name of candidateTerminal) as text), ((working directory of candidateTerminal) as text), terminalOrder}
            end repeat
            return terminalRows
        end tell
        """
        guard let result = executeGhosttyScript(
            source,
            operation: "enumeration"
        ) else {
            return nil
        }

        var records: [GhosttyTerminalRecord] = []
        guard result.numberOfItems > 0 else { return records }
        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index),
                  let id = row.atIndex(1)?.stringValue,
                  !id.isEmpty,
                  let cwd = row.atIndex(3)?.stringValue else {
                continue
            }
            let name = row.atIndex(2)?.stringValue ?? ""
            let order = Int(row.atIndex(4)?.int32Value ?? Int32(index))
            records.append(GhosttyTerminalRecord(
                candidate: GhosttyTerminalCandidate(
                    id: id,
                    name: name,
                    order: order
                ),
                cwd: cwd
            ))
        }
        return records
    }

    /// Returns the currently selected split of Ghostty's selected front tab.
    /// Called only while Ghostty is active, immediately after a fresh prompt
    /// transition, to learn that transcript's stable surface ID.
    private static func focusedGhosttyTerminal(
        bundlePath: String?
    ) -> GhosttyTerminalRecord? {
        guard let bundlePath else { return nil }
        let escapedBundlePath = appleScriptString(bundlePath)
        let source = """
        tell application "\(escapedBundlePath)"
            set activeWindow to front window
            if activeWindow is missing value then return {}
            set activeTab to selected tab of activeWindow
            if activeTab is missing value then return {}
            set activeTerminal to focused terminal of activeTab
            if activeTerminal is missing value then return {}
            return {((id of activeTerminal) as text), ((name of activeTerminal) as text), ((working directory of activeTerminal) as text)}
        end tell
        """
        guard let result = executeGhosttyScript(
            source,
            operation: "focused-terminal observation"
        ),
        let id = result.atIndex(1)?.stringValue,
        !id.isEmpty,
        let cwd = result.atIndex(3)?.stringValue else {
            return nil
        }
        return GhosttyTerminalRecord(
            candidate: GhosttyTerminalCandidate(
                id: id,
                name: result.atIndex(2)?.stringValue ?? "",
                order: 0
            ),
            cwd: cwd
        )
    }

    private static func focusGhosttyTerminal(
        id: String,
        bundlePath: String
    ) -> Bool {
        let escapedBundlePath = appleScriptString(bundlePath)
        let escapedID = appleScriptString(id)
        let source = """
        tell application "\(escapedBundlePath)"
            set wantedID to "\(escapedID)"
            repeat with candidateTerminal in terminals
                if ((id of candidateTerminal) as text) is wantedID then
                    focus candidateTerminal
                    return true
                end if
            end repeat
            return false
        end tell
        """
        return executeGhosttyScript(
            source,
            operation: "focus"
        )?.booleanValue ?? false
    }

    private static func executeGhosttyScript(
        _ source: String,
        operation: String
    ) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else {
            DiagnosticLog.write(
                "window resolver: could not create Ghostty \(operation) script"
            )
            return nil
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo["NSAppleScriptErrorNumber"] ?? "?"
            DiagnosticLog.write(
                "window resolver: Ghostty \(operation) failed with AppleScript error \(number)"
            )
            return nil
        }
        return result
    }

    private static func normalizedPath(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func openCodexThread(_ threadID: String) -> Bool {
        guard let url = URL(string: "codex://threads/\(threadID)") else {
            return false
        }
        let opened = NSWorkspace.shared.open(url)
        DiagnosticLog.write(
            "window resolver: \(opened ? "opened" : "could not open") the selected Codex task"
        )
        return opened
    }

    private static func runningCodexDesktopApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            codexDesktopBundleIDs.contains($0.bundleIdentifier ?? "")
        }
    }

    private static func raiseTerminalWindow(
        preferring preferred: NSRunningApplication?,
        folder: String?
    ) -> Bool {
        guard let folder else { return false }
        if let preferred, raiseWindow(of: preferred, titleContaining: folder) {
            return true
        }
        for app in runningKnownTerminals()
        where app.processIdentifier != preferred?.processIdentifier {
            if raiseWindow(of: app, titleContaining: folder) {
                return true
            }
        }
        return false
    }

    private static func runningKnownTerminals() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            knownTerminalBundleIDs.contains($0.bundleIdentifier ?? "")
        }
    }

    private static func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID
        }
    }

    /// With exactly one known terminal running, activating it beats a
    /// refusal buzz — the session is in there somewhere even when no title
    /// matched.
    private static func activateSoleRunningTerminal() -> Bool {
        let terminals = runningKnownTerminals()
        guard terminals.count == 1, let only = terminals.first else {
            DiagnosticLog.write(
                "window resolver: no title match and \(terminals.count) terminals running; giving up"
            )
            return false
        }
        DiagnosticLog.write(
            "window resolver: falling back to sole running terminal \(only.bundleIdentifier ?? "?")"
        )
        return activate(only)
    }

    private static func raiseWindow(
        of app: NSRunningApplication,
        titleContaining fragment: String
    ) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement] else {
            DiagnosticLog.write(
                "window resolver: no AX windows from \(app.bundleIdentifier ?? "?")"
            )
            return false
        }

        var seenTitles: [String] = []
        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXTitleAttribute as CFString,
                &titleValue
            ) == .success,
            let title = titleValue as? String else {
                continue
            }
            seenTitles.append(title)
            guard title.localizedCaseInsensitiveContains(fragment) else {
                continue
            }
            // Success must be genuine end to end: a tick for a raise that
            // silently failed teaches the user to distrust the tick.
            let raised = AXUIElementPerformAction(
                window,
                kAXRaiseAction as CFString
            ) == .success
            let activated = activate(app)
            guard raised, activated else { continue }
            DiagnosticLog.write(
                "window resolver: raised a matching window of \(app.bundleIdentifier ?? "?")"
            )
            return true
        }
        DiagnosticLog.write(
            "window resolver: none of \(seenTitles.count) window title(s) from \(app.bundleIdentifier ?? "?") matched the session folder"
        )
        return false
    }

    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            return app.activate()
        } else {
            return app.activate(options: [])
        }
    }
}
