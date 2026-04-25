import AppKit
import Foundation

enum AppLogger {
    static let enabledKey = "appLoggingEnabled"
    private static let fileName = "simplebanking.log"
    private static let queue = DispatchQueue(label: "simplebanking.app.logger")

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Shared log directory for all log files: ~/Library/Logs/simplebanking/
    static var logDirectoryURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return lib.appendingPathComponent("Logs/simplebanking", isDirectory: true)
    }

    static var logFileURL: URL {
        logDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
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
        // PII-Schutz: alle Messages laufen durch LogSanitizer (IBAN, Credentials,
        // lange Tokens werden redacted). Wer raw logs braucht (z.B. Setup-Diagnostik
        // mit eigenem Sanitizer), nutzt SetupDiagnosticsLogger direkt.
        let safeMessage = LogSanitizer.redact(message)
        let line = "[\(timestamp)] [\(level)] [\(category)] \(safeMessage)\n"
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
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
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
