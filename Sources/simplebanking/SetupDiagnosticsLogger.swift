import Foundation

final class SetupDiagnosticsLogger: @unchecked Sendable {
    static let logDirectoryURL: URL = {
        let fm = FileManager.default
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        return desktop.appendingPathComponent("simplebanking-setup-logs", isDirectory: true)
    }()

    private static let maxRetainedLogs = 10

    let latestLogURL: URL

    private let ioQueue = DispatchQueue(label: "com.maik.simplebanking.setup-diagnostics")

    private init(fileURL: URL) {
        self.latestLogURL = fileURL
    }

    static func startAttempt() throws -> SetupDiagnosticsLogger {
        let fm = FileManager.default
        try fm.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let timestamp = filenameFormatter.string(from: Date())
        let fileURL = logDirectoryURL.appendingPathComponent("simplebanking-setup-\(timestamp).txt")

        guard fm.createFile(atPath: fileURL.path, contents: nil) else {
            throw NSError(domain: "SetupDiagnosticsLogger", code: 1, userInfo: [NSLocalizedDescriptionKey: "Log-Datei konnte nicht erstellt werden."])
        }

        let logger = SetupDiagnosticsLogger(fileURL: fileURL)
        logger.appendLine("simplebanking setup diagnostics")
        logger.appendLine("privacy: no personal data logged")
        logger.appendLine("created_at: \(timestampLineFormatter.string(from: Date()))")
        logger.appendLine("")

        try pruneOldLogs()
        return logger
    }

    func log(step: String, event: String, details: [String: String] = [:]) {
        var line = "[\(Self.timestampLineFormatter.string(from: Date()))] step=\(Self.sanitizeSingleToken(step)) event=\(Self.sanitizeSingleToken(event))"
        if !details.isEmpty {
            let serialized = details
                .sorted(by: { $0.key < $1.key })
                .map { key, value in
                    "\(Self.sanitizeSingleToken(key))=\(Self.sanitizeDetailValue(value))"
                }
                .joined(separator: " ")
            line += " \(serialized)"
        }
        appendLine(line)
    }

    func finish(success: Bool, error: String?) {
        var details: [String: String] = ["success": success ? "true" : "false"]
        if let error, !error.isEmpty {
            details["error"] = error
        }
        log(step: "setup", event: "finish", details: details)
    }

    private func appendLine(_ line: String) {
        ioQueue.sync {
            let sanitizedLine = Self.sanitizeLine(line)
            let payload = sanitizedLine + "\n"
            guard let data = payload.data(using: .utf8) else { return }

            do {
                let handle = try FileHandle(forWritingTo: latestLogURL)
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
            } catch {
                // Setup diagnostics should never break setup flow.
            }
        }
    }

    private static func pruneOldLogs() throws {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = urls.filter {
            $0.lastPathComponent.hasPrefix("simplebanking-setup-") && $0.pathExtension.lowercased() == "txt"
        }

        let sorted = candidates.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lDate > rDate
        }

        guard sorted.count > maxRetainedLogs else { return }
        for url in sorted.dropFirst(maxRetainedLogs) {
            try? fm.removeItem(at: url)
        }
    }

    private static func sanitizeSingleToken(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        return trimmed.replacingOccurrences(of: " ", with: "_")
    }

    private static func sanitizeDetailValue(_ text: String) -> String {
        sanitizeLine(text)
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeLine(_ input: String) -> String {
        var output = input
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")

        let patterns: [(String, String)] = [
            ("(?i)DE[0-9A-Z]{15,32}", "<redacted-iban>"),
            ("(?i)(user(id)?|leg\\.?-?id|login|anmeldename|pin|password|passwort|session|connectiondata)\\s*[:=]\\s*[^\\s,;]+", "<redacted-secret>"),
            ("(?i)[A-Za-z0-9_\\-+/=]{24,}", "<redacted-token>"),
        ]

        for (pattern, replacement) in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression]
            )
        }

        if output.count > 700 {
            let idx = output.index(output.startIndex, offsetBy: 700)
            output = String(output[..<idx]) + "…"
        }

        return output
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let timestampLineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()
}
