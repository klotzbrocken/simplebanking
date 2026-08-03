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
                rotateIfNeeded()
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
        // Nur der Nutzer selbst. Ohne das erbt die Datei die Umask (0644) und ist für
        // jeden anderen Prozess lesbar — bei einer Datei, die IBAN-Präfixe und
        // Bankdialoge enthält, kein guter Standard.
        //
        // Bewusst bei JEDEM Aufruf und nicht nur beim Anlegen: Bestehende Installationen
        // haben ihre Datei längst mit 0644 — bei ihnen bliebe die Härtung sonst
        // wirkungslos, bis jemand das Log von Hand löscht. `setAttributes` auf eine
        // Datei, die schon 0600 hat, ist ein billiger No-op.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: logFileURL.path)
    }

    /// Obergrenze für die Logdatei. Vorher wuchs sie unbegrenzt: Ein Jahr aktiviertes
    /// Logging hinterließ eine lückenlose Historie, die niemand je gelesen hat.
    static let maxLogBytes = 5 * 1024 * 1024

    /// Halbiert die Datei, wenn sie zu groß wird — die ältere Hälfte fliegt raus.
    ///
    /// Bewusst kein zweites `.1`-Archiv: Das verdoppelte nur die Datenmenge, die am Ende
    /// auf der Platte liegt. Wer ein Problem meldet, braucht die jüngsten Zeilen.
    /// Der Schnitt läuft auf Zeilengrenze, damit keine halbe Zeile stehen bleibt.
    private static func rotateIfNeeded() {
        guard let groesse = try? FileManager.default
                .attributesOfItem(atPath: logFileURL.path)[.size] as? Int,
              groesse > maxLogBytes else { return }
        guard let inhalt = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            // Unlesbar (z.B. abgeschnittenes UTF-8) → lieber neu anfangen als wachsen lassen.
            try? Data().write(to: logFileURL, options: .atomic)
            return
        }
        let zeilen = inhalt.split(separator: "\n", omittingEmptySubsequences: false)
        let behalten = zeilen.suffix(zeilen.count / 2)
        let neu = "[gekürzt: ältere Hälfte entfernt, Grenze \(maxLogBytes / 1024 / 1024) MB]\n"
            + behalten.joined(separator: "\n")
        try? neu.write(to: logFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: logFileURL.path)
    }

    private static func timestampString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
