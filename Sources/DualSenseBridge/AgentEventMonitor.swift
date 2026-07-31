import DualSenseBridgeCore
import Foundation

/// Watches the drop directory that the bundled `agent-remote-event` helper
/// writes into from Claude Code hooks, Codex notify, or any script. A spool
/// of atomically-renamed files needs no socket server and keeps the hook
/// side one `mv`, so a hook can never block or crash an agent turn on IPC
/// state — and events survive the app briefly restarting.
final class AgentEventMonitor {
    static var spoolDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/DualSenseBridge/agent-events",
            isDirectory: true
        )
    }

    /// Delivered on the main queue.
    var onEvent: ((AgentEventEnvelope) -> Void)?

    private let queue = DispatchQueue(
        label: "local.controllerproject.DualSenseBridge.agent-events"
    )
    private var source: DispatchSourceFileSystemObject?
    private var directoryDescriptor: CInt = -1
    private var receivedEventCount = 0

    func start() {
        let directory = Self.spoolDirectoryURL
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            DiagnosticLog.write("agent event spool could not be created")
            return
        }

        directoryDescriptor = open(directory.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            DiagnosticLog.write("agent event spool could not be opened for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: .write,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.drainSpool(emitEvents: true)
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.directoryDescriptor >= 0 else { return }
            close(self.directoryDescriptor)
            self.directoryDescriptor = -1
        }
        self.source = source

        // Anything queued before this launch describes sessions the app was
        // not watching; deleting without emitting keeps a stale "done" from
        // buzzing the controller the moment the app starts. The purge must
        // finish before watching begins, or it could swallow a live event
        // written moments after the watcher attaches; the emitting drain
        // afterwards covers files that land during this handoff.
        queue.sync { [weak self] in
            self?.drainSpool(emitEvents: false)
        }
        source.resume()
        queue.async { [weak self] in
            self?.drainSpool(emitEvents: true)
        }
        DiagnosticLog.write("agent event spool watcher started")
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func drainSpool(emitEvents: Bool) {
        let directory = Self.spoolDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let ordered = entries.sorted { left, right in
            let leftDate = (try? left.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            let rightDate = (try? right.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            return leftDate < rightDate
        }

        for file in ordered {
            let contents = try? String(contentsOf: file, encoding: .utf8)
            // Consume unconditionally: a file that cannot be parsed would
            // otherwise re-trigger this handler forever.
            try? FileManager.default.removeItem(at: file)

            guard emitEvents,
                  let contents,
                  let envelope = AgentEventEnvelope.parse(fileContents: contents) else {
                continue
            }
            guard envelope.isFresh() else {
                DiagnosticLog.write(
                    "agent event \(envelope.event.rawValue) dropped as stale"
                )
                continue
            }

            receivedEventCount += 1
            DiagnosticLog.write(
                "agent event #\(receivedEventCount): \(envelope.event.rawValue)"
            )
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(envelope)
            }
        }
    }
}
