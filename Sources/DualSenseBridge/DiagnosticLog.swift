import Foundation

enum DiagnosticLog {
    private static let directoryURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Agent Remote", isDirectory: true)
    private static let fileURL = directoryURL
        .appendingPathComponent("Agent Remote.log", isDirectory: false)
    private static let previousFileURL = directoryURL
        .appendingPathComponent("Agent Remote.previous.log", isDirectory: false)
    private static let maximumBytes: UInt64 = 1_048_576
    private static let lock = NSLock()

    static var path: String { fileURL.path }

    static func beginSession() {
        lock.lock()
        defer { lock.unlock() }

        let header = "=== DualSense Bridge session \(ISO8601DateFormatter().string(from: Date())) ===\n"
        guard let data = header.data(using: .utf8), prepareDirectory() else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
        createPrivateLog(contents: data)
    }

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        guard prepareDirectory() else { return }
        rotateIfNeeded(adding: UInt64(data.count))
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            createPrivateLog(contents: data)
            return
        }

        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics must never affect controller input.
        }
    }

    private static func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            return true
        } catch {
            return false
        }
    }

    private static func createPrivateLog(contents: Data) {
        _ = FileManager.default.createFile(
            atPath: fileURL.path,
            contents: contents,
            attributes: [.posixPermissions: 0o600]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func rotateIfNeeded(adding byteCount: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        ), let existingSize = attributes[.size] as? NSNumber,
        existingSize.uint64Value + byteCount > maximumBytes else {
            return
        }

        try? FileManager.default.removeItem(at: previousFileURL)
        do {
            try FileManager.default.moveItem(at: fileURL, to: previousFileURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: previousFileURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
