import CoreServices
import DualSenseBridgeCore
import Foundation

/// Passive session watching: observes the JSONL transcripts Claude Code and
/// Codex already write (read-only, via FSEvents) and infers agent activity
/// from appended lines. No harness configuration is touched and nothing runs
/// in the harness's execution path, so this mode cannot affect a session by
/// construction — the harness never knows it exists.
final class AgentSessionLogWatcher {
    /// Delivered on the main queue.
    var onEvent: ((AgentEventEnvelope) -> Void)?
    /// Delivered on the main queue whenever the set of live sessions or any
    /// session's state changes; feeds the menu's session list and the
    /// player-LED slots.
    var onSessionsChanged: (([AgentSessionSummary]) -> Void)?

    private enum SessionKind {
        case claude
        case codex

        var source: String {
            switch self {
            case .claude: return "claude-code"
            case .codex: return "codex"
            }
        }
    }

    private final class FileTail {
        let kind: SessionKind
        var offset: UInt64
        var partialLine = Data()
        var discardingOversizedLine = false
        var claudeReducer = ClaudeTranscriptStateReducer()
        var codexReducer = CodexSessionLogStateReducer()
        var lastTouched = Date()
        /// Whether this tail's current event came from a timing heuristic.
        /// Part of the aggregate's identity: a confident attention arriving
        /// while an inferred one holds the same enum value must still emit,
        /// or it would never buzz.
        var currentEventIsInferred = false
        /// The session's working directory, captured from the first
        /// transcript line that carries one.
        var cwd: String?
        /// Codex Desktop creates internal child rollouts (for example its
        /// guardian). They are not user-visible tasks and must not take a
        /// Fleet slot or drive aggregate feedback.
        var isHiddenSubagent = false
        var codexMetadataClassified = false

        init(kind: SessionKind, offset: UInt64) {
            self.kind = kind
            self.offset = offset
        }

        var currentEvent: AgentActivityEvent {
            switch kind {
            case .claude: return claudeReducer.currentEvent
            case .codex: return codexReducer.currentEvent
            }
        }
    }

    /// A record split across reads is buffered until its newline arrives; a
    /// runaway record without one must not grow that buffer forever.
    private static let maximumPartialLineBytes = 1_048_576
    /// A file first seen at creation is read from byte zero so a fast turn's
    /// opening records are not skipped — but only when it is small, so a
    /// large pre-existing file moved into the tree cannot replay history.
    private static let freshFileReplayLimit: UInt64 = 524_288

    private static var claudeProjectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private static var codexSessionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private let queue = DispatchQueue(
        label: "local.controllerproject.DualSenseBridge.session-logs"
    )
    private var eventStream: FSEventStreamRef?
    private var watchedRoots: [String] = []
    private var tails: [String: FileTail] = [:]
    private var quietTimer: DispatchSourceTimer?
    private var timerTickCount = 0
    private var lastAggregateEvent: AgentActivityEvent = .idle
    private var lastAggregateWasInferred = false
    private var lastSessionSummaries: [AgentSessionSummary] = []
    private var emittedEventCount = 0
    /// Main-thread confined, checked by the main-queue delivery hop: an
    /// envelope already in flight when the user toggles the feature off must
    /// not reapply state after the disable.
    private var deliveriesSuspended = true

    func start() {
        deliveriesSuspended = false
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        deliveriesSuspended = true
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private static func availableRoots() -> [String] {
        [claudeProjectsURL, codexSessionsURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
    }

    private func startOnQueue() {
        // The timer is the "started" marker, not the stream: with no
        // transcript directories yet, the stream is legitimately nil while
        // the timer waits to discover one, and a second start must not
        // create a duplicate timer.
        guard quietTimer == nil else { return }
        startStream(roots: Self.availableRoots())

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.timerTick()
        }
        quietTimer = timer
        timer.resume()
    }

    private func startStream(roots: [String]) {
        // Record the watched set only when the stream actually starts, so a
        // creation failure is retried at the next rediscovery tick instead
        // of being mistaken for a running stream.
        watchedRoots = []
        guard !roots.isEmpty else {
            DiagnosticLog.write("passive session watching found no transcript directories yet")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            agentSessionLogFSEventsCallback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
            )
        ) else {
            DiagnosticLog.write("passive session watching could not create its FSEvents stream")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            DiagnosticLog.write("passive session watching could not start its FSEvents stream")
            return
        }
        eventStream = stream
        watchedRoots = roots
        DiagnosticLog.write(
            "passive session watching started for \(roots.count) transcript root(s)"
        )
        // The stream reports from "now", so anything written before it
        // started — a first agent run that created its root and finished
        // inside the discovery interval, or events pending during a rebuild
        // — would otherwise be invisible. One scan closes the gap.
        scanRecentTranscripts()
    }

    private func scanRecentTranscripts() {
        let cutoff = Date().addingTimeInterval(-60)
        for root in watchedRoots {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else {
                continue
            }
            for case let relative as String in enumerator where relative.hasSuffix(".jsonl") {
                let path = (root as NSString).appendingPathComponent(relative)
                guard let kind = kind(forPath: path),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let modified = attributes[.modificationDate] as? Date,
                      modified > cutoff else {
                    continue
                }
                // A recently touched file with no tail is presented as
                // freshly created so the small-file replay rule recovers its
                // opening records; one with an existing tail is read from
                // its stored offset, catching up appends that fell into a
                // stream-rebuild gap.
                processFile(
                    at: path,
                    kind: kind,
                    eventFlags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
                )
            }
        }
    }

    /// Lightweight `"cwd":"…"` extraction without a full JSON parse; both
    /// harnesses record it (Claude on every entry, Codex in session/turn
    /// context lines), and only the first hit per session is needed.
    private static func extractCWD(from line: String) -> String? {
        guard let markerRange = line.range(of: "\"cwd\":\"") else { return nil }
        var value = ""
        var previousWasEscape = false
        for character in line[markerRange.upperBound...] {
            if previousWasEscape {
                value.append(character)
                previousWasEscape = false
                continue
            }
            if character == "\\" {
                previousWasEscape = true
                continue
            }
            if character == "\"" {
                return value.isEmpty ? nil : value
            }
            value.append(character)
        }
        return nil
    }

    private func kind(forPath path: String) -> SessionKind? {
        if path.hasPrefix(Self.claudeProjectsURL.path) { return .claude }
        if path.hasPrefix(Self.codexSessionsURL.path) { return .codex }
        return nil
    }

    private func stopStreamOnly() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    private func stopOnQueue() {
        stopStreamOnly()
        quietTimer?.cancel()
        quietTimer = nil
        tails.removeAll()
        watchedRoots = []
        lastAggregateEvent = .idle
        // Both halves of the aggregate identity reset together, or a
        // restart could emit a false idle purely from a stale inferred flag.
        lastAggregateWasInferred = false
        publishSessionsIfChanged()
        DiagnosticLog.write("passive session watching stopped")
    }

    private func timerTick() {
        timerTickCount += 1

        // A transcript directory can appear after launch (first Claude or
        // Codex run); rediscover roots so watching does not require an app
        // restart. The stream's path set is fixed at creation, so a change
        // means rebuilding it — tails carry over untouched.
        let roots = Self.availableRoots()
        if roots != watchedRoots, quietTimer != nil {
            stopStreamOnly()
            startStream(roots: roots)
        }

        let now = Date()
        var anyQuietTransition = false
        for tail in tails.values {
            let event: AgentActivityEvent?
            switch tail.kind {
            case .claude:
                event = tail.claudeReducer.quietCheck(at: now)
            case .codex:
                event = tail.codexReducer.quietCheck(at: now)
            }
            if event != nil {
                // Quiet-derived transitions are heuristics for Claude; the
                // Codex quiet path only expires to idle, which is inferred
                // by nature as well.
                tail.currentEventIsInferred = tail.kind == .claude || event == .idle
                anyQuietTransition = true
                emitAggregateIfChanged()
            }
        }
        if anyQuietTransition {
            publishSessionsIfChanged()
        }

        if timerTickCount.isMultiple(of: 120) {
            pruneStaleTails()
        }
    }

    fileprivate func handleChangedPaths(
        _ paths: [String],
        flags: [FSEventStreamEventFlags]
    ) {
        for (index, path) in paths.enumerated() where path.hasSuffix(".jsonl") {
            guard let kind = kind(forPath: path) else { continue }
            let eventFlags = index < flags.count ? flags[index] : 0
            processFile(at: path, kind: kind, eventFlags: eventFlags)
        }
    }

    private func processFile(
        at path: String,
        kind: SessionKind,
        eventFlags: FSEventStreamEventFlags
    ) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64 else {
            // A deleted transcript takes its state with it; the aggregate
            // must be recomputed or a removed session's attention would
            // hold the controller amber with no reducer left to expire it.
            if tails.removeValue(forKey: path) != nil {
                emitAggregateIfChanged()
                publishSessionsIfChanged()
            }
            return
        }

        let tail: FileTail
        if let existing = tails[path] {
            tail = existing
        } else {
            // FSEvents latency coalesces a file's creation with its first
            // records (a real rollout wrote session_meta and task_started
            // three milliseconds apart), so a freshly created file must be
            // read from byte zero or fast turns are missed entirely.
            // Pre-existing files start at EOF: history is not replayed.
            let created = eventFlags & FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
            ) != 0
            let initialOffset = (created && size <= Self.freshFileReplayLimit) ? 0 : size
            tail = FileTail(kind: kind, offset: initialOffset)
            tails[path] = tail
            tail.lastTouched = Date()
            hydrateTranscriptMetadata(at: path, tail: tail)
            if initialOffset == size {
                return
            }
        }
        tail.lastTouched = Date()

        // A creation event can arrive before its first complete line. Retry
        // the bounded metadata read until the session has been classified.
        hydrateTranscriptMetadata(at: path, tail: tail)
        if tail.isHiddenSubagent {
            return
        }

        if size < tail.offset {
            // The file shrank (compaction/rewrite). Skip to the new end
            // rather than re-reading: replaying an entire rewritten
            // transcript would resurrect stale transitions.
            tail.offset = size
            tail.partialLine.removeAll()
            tail.discardingOversizedLine = false
            return
        }
        guard size > tail.offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: tail.offset)
        } catch {
            return
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        tail.offset += UInt64(data.count)

        var buffer = tail.partialLine + data
        if tail.discardingOversizedLine {
            // Resynchronize at the next record boundary after an overflow.
            if let newline = buffer.firstIndex(of: 0x0a) {
                buffer = Data(buffer[buffer.index(after: newline)...])
                tail.discardingOversizedLine = false
            } else {
                tail.partialLine.removeAll()
                return
            }
        }

        // Appends are usually line-atomic, but never assume: hold trailing
        // partial bytes for the next read instead of feeding half a JSON
        // object (or a split UTF-8 scalar) to the reducer.
        if let lastNewline = buffer.lastIndex(of: 0x0a) {
            let complete = buffer[..<lastNewline]
            tail.partialLine = Data(buffer[buffer.index(after: lastNewline)...])
            consumeLines(in: complete, tail: tail)
        } else {
            tail.partialLine = buffer
        }

        if tail.partialLine.count > Self.maximumPartialLineBytes {
            tail.partialLine.removeAll()
            tail.discardingOversizedLine = true
        }
    }

    private func consumeLines(in data: Data, tail: FileTail) {
        let now = Date()
        for lineData in data.split(separator: 0x0a) where !lineData.isEmpty {
            let line = String(decoding: lineData, as: UTF8.self)
            if tail.kind == .codex, !tail.codexMetadataClassified,
               line.contains("\"type\":\"session_meta\"") {
                let route = AgentSessionRouting.codexRoute(
                    transcriptPath: "",
                    sessionMetadataLine: line
                )
                tail.codexMetadataClassified = true
                tail.isHiddenSubagent = route.isSubagent
                if route.isSubagent {
                    DiagnosticLog.write(
                        "passive session watching hid an internal Codex subagent"
                    )
                    emitAggregateIfChanged()
                    publishSessionsIfChanged()
                    continue
                }
            }
            if tail.isHiddenSubagent { continue }
            if tail.cwd == nil {
                tail.cwd = Self.extractCWD(from: line)
            }
            let event: AgentActivityEvent?
            switch tail.kind {
            case .claude:
                event = tail.claudeReducer.consume(line: line, at: now)
            case .codex:
                event = tail.codexReducer.consume(line: line, at: now)
            }
            guard let event else { continue }
            tail.currentEventIsInferred = false
            publishSessionsIfChanged()
            let aggregateAnnouncedIt = emitAggregateIfChanged()
                && lastAggregateEvent == event

            // A session finishing (or raising another approval) while a
            // different session owns the sustained aggregate would otherwise
            // vanish entirely; surface it as a momentary notification.
            if !aggregateAnnouncedIt {
                switch event {
                case .done, .error, .attention:
                    emitTransient(event, from: tail.kind)
                case .working, .idle:
                    break
                }
            }
        }
    }

    private func emitTransient(
        _ event: AgentActivityEvent,
        from kind: SessionKind
    ) {
        emittedEventCount += 1
        DiagnosticLog.write(
            "passive session event #\(emittedEventCount): transient \(event.rawValue) from \(kind.source)"
        )
        let envelope = AgentEventEnvelope(
            event: event,
            source: kind.source,
            timestamp: nil,
            isFromPassiveWatching: true,
            isTransient: true
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.deliveriesSuspended else { return }
            self.onEvent?(envelope)
        }
    }

    /// One controller shows one state, so several live sessions collapse to
    /// the most demanding one: a session finishing must not paint the bar
    /// green while another still works. Severity: attention > error >
    /// working > done > idle, with a confident event outranking an inferred
    /// one at equal severity. The aggregate's identity includes confidence —
    /// a confident attention arriving while an inferred one already shows
    /// amber must still emit, or it would never buzz — and the source label
    /// comes from the tail that supplies the maximum, not whichever tail
    /// happened to change last.
    @discardableResult
    private func emitAggregateIfChanged() -> Bool {
        let maximumTail = tails.values
            .filter { !$0.isHiddenSubagent }
            .max { left, right in
                score(left) < score(right)
            }
        let aggregate = maximumTail?.currentEvent ?? .idle
        let aggregateInferred = maximumTail?.currentEventIsInferred ?? false
        guard aggregate != lastAggregateEvent
            || aggregateInferred != lastAggregateWasInferred else {
            return false
        }
        lastAggregateEvent = aggregate
        lastAggregateWasInferred = aggregateInferred

        let source = maximumTail?.kind.source ?? "sessions"
        emittedEventCount += 1
        DiagnosticLog.write(
            "passive session event #\(emittedEventCount): \(aggregate.rawValue) from \(source)\(aggregateInferred ? " (inferred)" : "")"
        )
        let envelope = AgentEventEnvelope(
            event: aggregate,
            source: source,
            timestamp: nil,
            isInferred: aggregateInferred,
            isFromPassiveWatching: true
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.deliveriesSuspended else { return }
            self.onEvent?(envelope)
        }
        return true
    }

    /// Every tracked session, stable-ordered by identity — including idle
    /// ones. A session that finished and went quiet is still attached in
    /// its terminal and is exactly the thing a user raises to hand new
    /// work; dropping it from the fleet made sessions "vanish" while their
    /// processes lived on. Idle sessions show unlit LEDs and leave for good
    /// only when their tails prune.
    private func publishSessionsIfChanged() {
        let summaries = tails
            .filter { !$0.value.isHiddenSubagent }
            .map { path, tail in
                AgentSessionSummary(
                    id: path,
                    source: tail.kind.source,
                    displayName: AgentSessionIndicators.displayName(
                        transcriptPath: path,
                        source: tail.kind.source
                    ),
                    event: tail.currentEvent,
                    isInferred: tail.currentEventIsInferred,
                    cwd: tail.cwd
                )
            }
            .sorted { $0.id < $1.id }
        guard summaries != lastSessionSummaries else { return }
        lastSessionSummaries = summaries

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.deliveriesSuspended else { return }
            self.onSessionsChanged?(summaries)
        }
    }

    private func score(_ tail: FileTail) -> Int {
        let severity: Int
        switch tail.currentEvent {
        case .attention: severity = 4
        case .error: severity = 3
        case .working: severity = 2
        case .done: severity = 1
        case .idle: severity = 0
        }
        return severity * 2 + (tail.currentEventIsInferred ? 0 : 1)
    }

    /// Metadata is safe to hydrate even when a large pre-existing transcript
    /// deliberately starts tailing at EOF. Without this bounded first-line
    /// read, such a session has no cwd until its next write and cannot be
    /// routed to its terminal in the meantime.
    private func hydrateTranscriptMetadata(at path: String, tail: FileTail) {
        let needsCodexClassification = tail.kind == .codex
            && !tail.codexMetadataClassified
        guard tail.cwd == nil || needsCodexClassification,
              let handle = FileHandle(forReadingAtPath: path) else {
            return
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 131_072) else {
            return
        }
        let lines = prefix.split(separator: 0x0a)
        guard let firstLine = lines.first else { return }
        if tail.cwd == nil {
            for lineData in lines {
                let line = String(decoding: lineData, as: UTF8.self)
                if let cwd = Self.extractCWD(from: line) {
                    tail.cwd = cwd
                    break
                }
            }
        }
        let line = String(decoding: firstLine, as: UTF8.self)
        guard needsCodexClassification,
              line.contains("\"type\":\"session_meta\"") else {
            return
        }
        let route = AgentSessionRouting.codexRoute(
            transcriptPath: path,
            sessionMetadataLine: line
        )
        tail.codexMetadataClassified = true
        tail.isHiddenSubagent = route.isSubagent
        if route.isSubagent {
            DiagnosticLog.write(
                "passive session watching hid an internal Codex subagent"
            )
            emitAggregateIfChanged()
            publishSessionsIfChanged()
        }
    }

    /// Sessions end silently, so bounded memory needs a sweep. The
    /// reducers' own abandonment expiry has already idled anything this old,
    /// but recompute the aggregate afterwards regardless so removal can
    /// never strand a state.
    private func pruneStaleTails() {
        let cutoff = Date().addingTimeInterval(-7_200)
        let before = tails.count
        tails = tails.filter { $0.value.lastTouched > cutoff }
        if tails.count != before {
            emitAggregateIfChanged()
            publishSessionsIfChanged()
        }
    }
}

private func agentSessionLogFSEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo,
          let paths = unsafeBitCast(
            eventPaths,
            to: CFArray.self
          ) as? [String] else {
        return
    }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
    Unmanaged<AgentSessionLogWatcher>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
        .handleChangedPaths(paths, flags: flags)
}
