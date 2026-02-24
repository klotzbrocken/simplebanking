import AppKit
import Foundation

enum AppLogger {
    static let enabledKey = "appLoggingEnabled"
    private static let fileName = "simplebanking.log"
    private static let queue = DispatchQueue(label: "simplebanking.app.logger")

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var logFileURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("com.maik.simplebanking", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func setEnabled(_ enabled: Bool) {
        if !enabled {
            logForce("Logging disabled", category: "App")
            UserDefaults.standard.set(false, forKey: enabledKey)
            return
        }
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        logForce("Logging enabled", category: "App")
    }

    static func log(_ message: String, category: String = "App", level: String = "INFO") {
        guard isEnabled else { return }
        appendLine(message: message, category: category, level: level)
    }

    static func openInFinder() {
        queue.sync {
            do {
                try ensureParentDirectory()
                try ensureLogFileExists()
            } catch {
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }

    static func clear() throws {
        try queue.sync {
            try ensureParentDirectory()
            try Data().write(to: logFileURL, options: .atomic)
        }
    }

    private static func logForce(_ message: String, category: String = "App", level: String = "INFO") {
        appendLine(message: message, category: category, level: level)
    }

    private static func appendLine(message: String, category: String, level: String) {
        let timestamp = Self.timestampString()
        let line = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
        queue.async {
            do {
                try ensureParentDirectory()
                try ensureLogFileExists()
                let data = Data(line.utf8)
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try data.write(to: logFileURL, options: .atomic)
                }
            } catch {
                // Keep logger failure silent to avoid recursive logging issues.
            }
        }
    }

    private static func ensureParentDirectory() throws {
        let dir = logFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func ensureLogFileExists() throws {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            try Data().write(to: logFileURL, options: .atomic)
        }
    }

    private static func timestampString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
