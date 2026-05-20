import AppKit
import Foundation

// MARK: - ErrorReportStore
//
// „Problem melden"-Flow für unerwartete Bank-Fehler (Routex `UnexpectedError`).
//
// Wenn ein Bank-Call mit einem nicht selbst-erklärenden Fehler abbricht, capturen
// wir Context + Trace und bieten dem User auf Knopfdruck einen Mail-Report an
// `support@simplebanking.de`. Trace ist YAXI-Provider-AGE-encrypted (Klartext-
// Bank-Daten landen nicht in dem File).
//
// Singleton + ObservableObject damit Setup-Sheet + andere UI reaktiv auf
// `pendingReport` reagieren können (z.B. „Problem melden"-Button einblenden).
//
// **Trigger-Scoping** (siehe `CallSource`):
// - `.normal` (default): Auto-Refresh, Manual Refresh, Slot-Switch
//   → capture + Auto-Prompt sofort wenn `NSApp.isActive`, sonst pending bis
//     Activation/Flyout-Öffnung
// - `.setupWarmup`: capture only, KEIN Auto-Alert (würde mit Setup-Error-Sheet
//   stacken). Setup-UI ruft `presentManually()` über eigenen Button.
// - `.diagnostic`: skip — `DiagnosticSession` hat eigenen Mail-Flow
// - `.silent`: skip — CLI/MCP/DeepSync-Importer haben keinen UI-Kontext

@MainActor
final class ErrorReportStore: ObservableObject {

    static let shared = ErrorReportStore()

    // MARK: - Trigger-Quelle

    enum CallSource: Equatable {
        /// Normaler User-Refresh-Pfad (Auto-Timer, Pull-to-Refresh, Slot-Switch).
        /// Auto-Prompt sofort wenn App aktiv, sonst auf nächste Activation warten.
        case normal
        /// Setup-Warmup (`performSetupConnection`). Capture-only — Setup-UI
        /// zeigt selbst ein Error-Sheet; der Report wird über einen dortigen
        /// Button manuell abgesetzt.
        case setupWarmup
        /// Bank-Diagnose hat eigenen Mail-Versand → kein Capture nötig.
        case diagnostic
        /// CLI, MCP, Background-Importer — kein UI-Kontext, kein Alert sinnvoll.
        case silent

        /// Soll dieser Call überhaupt einen Report registrieren?
        var capturesReports: Bool {
            switch self {
            case .normal, .setupWarmup: return true
            case .diagnostic, .silent:  return false
            }
        }

        /// Soll bei `register` automatisch ein Alert versucht werden? `.setupWarmup`
        /// ist auf manuelles Auslösen via Setup-UI angewiesen.
        var autoPrompts: Bool {
            switch self {
            case .normal:        return true
            case .setupWarmup:   return false
            case .diagnostic, .silent: return false
            }
        }
    }

    // MARK: - Pending-Report

    struct PendingErrorReport: Equatable {
        let id: UUID
        let createdAt: Date
        let callName: String          // „fetchBalances", „fetchAccounts", „fetchTransactions"
        let slotId: String
        let bankDisplayName: String?  // aus MultibankingStore, optional
        let connectionId: String?     // optional, kann nil sein wenn nie gesetzt
        let traceId: String?          // Hex; nil wenn SDK keinen liefert
        let ticketId: String?         // UUID-String aus JWT-Payload, nil wenn decode failt
        let userMessageFromBank: String?  // aus `RoutexClientError.UnexpectedError(userMessage:)`
        let attachmentURL: URL?       // Path zu `reports/...txt`, nil bei Fetch-Fail
        /// Lokalisierter Titel — wird im Alert + Mail-Subject genutzt.
        let alertTitle: String

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var pendingReport: PendingErrorReport?

    // MARK: - Throttle (in-memory)

    /// Throttle-State per (connectionId, callName). Verhindert dass bei einem
    /// persistenten Bank-Bug der Alert alle paar Sekunden hochkommt.
    /// In-memory — App-Restart resettet den Throttle. Bewusst akzeptiert
    /// (alternative wäre UserDefaults-backed, aber persistenter Bank-Bug
    /// rechtfertigt einen Re-Prompt nach Restart).
    private var lastReportedAt: [ThrottleKey: Date] = [:]
    nonisolated static let throttleWindow: TimeInterval = 30 * 60   // 30 min

    struct ThrottleKey: Hashable {
        let connectionId: String  // "" wenn nil — gruppiert dann zusammen
        let callName: String
    }

    // MARK: - Reports-Verzeichnis

    /// Nonisolated, weil von YaxiService non-Main-Actor-Context aus aufgerufen.
    /// Reine File-System-URL-Berechnung ohne `self`-Zugriff — safe.
    nonisolated static var reportsDirectoryURL: URL {
        AppLogger.logDirectoryURL.appendingPathComponent("reports")
    }
    nonisolated static let maxReportFiles = 10

    private init() {
        try? FileManager.default.createDirectory(at: Self.reportsDirectoryURL,
                                                 withIntermediateDirectories: true)
        installActivationObserver()
    }

    // MARK: - Public API

    /// Registriert einen neuen Pending-Report. Mit Throttle-Check + Routing nach
    /// `CallSource`. Bei `.normal`-Quelle: sofort presenten wenn App aktiv,
    /// sonst pending lassen.
    func register(_ report: PendingErrorReport, source: CallSource) {
        guard source.capturesReports else { return }

        // Throttle: drop wenn für (connectionId, callName) in den letzten 30 Min
        // schon ein Report registriert wurde.
        let key = ThrottleKey(connectionId: report.connectionId ?? "", callName: report.callName)
        if let last = lastReportedAt[key],
           Date().timeIntervalSince(last) < Self.throttleWindow {
            AppLogger.log("ErrorReport throttled (last=\(last) call=\(report.callName) connId=\(key.connectionId.prefix(8)))",
                          category: "ErrorReport")
            return
        }
        lastReportedAt[key] = Date()

        pendingReport = report
        AppLogger.log("ErrorReport registered: call=\(report.callName) slot=\(report.slotId.prefix(8)) source=\(source)",
                      category: "ErrorReport")

        if source.autoPrompts {
            flushIfPending()
        }
    }

    /// Wird vom Activation-Observer und Flyout-Open-Hook gerufen. Zeigt den
    /// pending Report wenn App aktiv ist, sonst no-op.
    func flushIfPending() {
        guard let report = pendingReport, NSApp.isActive else { return }
        present(report)
    }

    /// Manueller Trigger aus dem Setup-Error-Sheet. Idempotent — wenn nichts
    /// pending, no-op.
    func presentManually() {
        guard let report = pendingReport else { return }
        present(report)
    }

    /// Pending-Report verwerfen (z.B. User schließt Sheet, Setup wiederholt).
    func clearPending() {
        pendingReport = nil
    }

    // MARK: - Internals

    private func present(_ report: PendingErrorReport) {
        // Atomar konsumieren: nach Klick-egal weg.
        pendingReport = nil

        let alert = NSAlert()
        alert.messageText = report.alertTitle
        alert.informativeText = Self.composeAlertBody(report: report)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("Problem melden", "Report problem"))
        alert.addButton(withTitle: L10n.t("Nicht jetzt", "Not now"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            AppLogger.log("ErrorReport dismissed by user", category: "ErrorReport")
            return
        }

        sendReportByMail(report)
    }

    private func sendReportByMail(_ report: PendingErrorReport) {
        let subject = Self.composeMailSubject(report: report)
        let body    = Self.composeMailBody(report: report, locale: Locale.current)

        guard let service = NSSharingService(named: .composeEmail) else {
            AppLogger.log("ErrorReport: NSSharingService.composeEmail not available", category: "ErrorReport", level: "WARN")
            offerManualFallback(report: report, subject: subject, body: body)
            return
        }
        service.recipients = ["support@simplebanking.de"]
        service.subject = subject

        var items: [Any] = [body]
        if let url = report.attachmentURL, FileManager.default.fileExists(atPath: url.path) {
            items.append(url)
        }
        guard service.canPerform(withItems: items) else {
            AppLogger.log("ErrorReport: composeEmail cannot perform (no mail client?)", category: "ErrorReport", level: "WARN")
            offerManualFallback(report: report, subject: subject, body: body)
            return
        }
        service.perform(withItems: items)
    }

    /// Fallback wenn kein Mail-Client konfiguriert: Trace-Datei im Finder
    /// anzeigen + Empfänger-Adresse + Subject in Pasteboard kopieren.
    private func offerManualFallback(report: PendingErrorReport, subject: String, body: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t("Keine Mail-App eingerichtet", "No mail app configured")
        alert.informativeText = L10n.t(
            "Bitte sende eine Mail mit der Diagnose-Datei an support@simplebanking.de. Empfänger und Betreff wurden in die Zwischenablage kopiert.",
            "Please send an email with the diagnostic file to support@simplebanking.de. Recipient and subject have been copied to the clipboard."
        )
        alert.addButton(withTitle: L10n.t("Datei im Finder zeigen", "Reveal file in Finder"))
        alert.addButton(withTitle: L10n.t("OK", "OK"))
        let combined = "To: support@simplebanking.de\nSubject: \(subject)\n\n\(body)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let url = report.attachmentURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func installActivationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushIfPending()
            }
        }
    }

    // MARK: - Pure helpers (testbar)

    /// Body für den NSAlert. Bank-userMessage zuerst (wenn vorhanden), dann
    /// Privacy-Hinweis. Beides via `L10n` für i18n.
    nonisolated static func composeAlertBody(report: PendingErrorReport) -> String {
        var parts: [String] = []
        if let msg = report.userMessageFromBank?.trimmingCharacters(in: .whitespacesAndNewlines),
           !msg.isEmpty {
            parts.append(msg)
        }
        parts.append(privacyNotice())
        return parts.joined(separator: "\n\n")
    }

    nonisolated static func privacyNotice() -> String {
        L10n.t(
            "Wenn du das Problem meldest, hängen wir automatisch eine verschlüsselte Diagnosedatei an. Sie hilft uns, den Fehler nachzuvollziehen. Deine Online-Banking-Zugangsdaten (Anmeldename, PIN, Passwort) sind darin nicht enthalten. Die Datei kann aber andere persönliche Angaben enthalten (z. B. Kontoname oder Umsätze), ist verschlüsselt und wird ausschließlich zur Behebung dieses Fehlers verwendet.",
            "If you report the problem, we automatically attach an encrypted diagnostic file. It helps us trace the error. Your online-banking credentials (username, PIN, password) are NOT included. The file may contain other personal data (e.g. account name or transactions), is encrypted and used solely to resolve this error."
        )
    }

    nonisolated static func composeMailSubject(report: PendingErrorReport) -> String {
        let dateStr = ISO8601DateFormatter().string(from: report.createdAt)
        let bank = report.bankDisplayName ?? "Bank"
        return L10n.t(
            "simplebanking — Unerwarteter Fehler (\(bank), \(dateStr))",
            "simplebanking — Unexpected error (\(bank), \(dateStr))"
        )
    }

    /// Mail-Body. Erst Intro + Privacy, dann Context-Block. Free-Text wird
    /// durch `LogSanitizer.redact` gefiltert.
    nonisolated static func composeMailBody(report: PendingErrorReport, locale: Locale) -> String {
        let intro = L10n.t(
            "Beim Bank-Abruf ist ein unerwarteter Fehler aufgetreten. Bitte beschreibe kurz, was du gemacht hast, als der Fehler auftrat:",
            "An unexpected error occurred during a bank call. Please describe briefly what you were doing when the error happened:"
        )
        let userBlock = "\n\n[ … ]\n\n---\n"  // Platz für User-Text + Trennung
        let ctx = composeContextBlock(report: report)
        return "\(intro)\n\(userBlock)\(ctx)"
    }

    /// Strukturierter Context-Block. Deterministisch — sortierte Keys,
    /// stabile Reihenfolge.
    nonisolated static func composeContextBlock(report: PendingErrorReport) -> String {
        var lines: [String] = ["=== simplebanking Diagnose-Kontext ==="]
        lines.append("Zeitstempel:     \(ISO8601DateFormatter().string(from: report.createdAt))")
        lines.append("App:             \(appVersionAndBuild())")
        lines.append("macOS:           \(macOSVersion())")
        lines.append("Routex SDK:      \(routexSDKVersion())")
        lines.append("Bank:            \(report.bankDisplayName ?? "-")")
        lines.append("Bank-Call:       \(report.callName)")
        lines.append("connectionId:    \(report.connectionId ?? "-")")
        lines.append("ticketId:        \(report.ticketId ?? "-")")
        lines.append("traceId:         \(report.traceId ?? "-")")
        lines.append("Slot:            \(report.slotId)")
        let bankMsg = (report.userMessageFromBank ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBankMsg = bankMsg.isEmpty ? "-" : LogSanitizer.redact(bankMsg)
        lines.append("Bank-Meldung:    \(safeBankMsg)")
        lines.append("=== Ende Kontext ===")
        return lines.joined(separator: "\n")
    }

    // MARK: - Throttle-Pure-Helper (für Tests)

    /// Pure entscheidung: gegeben den letzten Report-Zeitpunkt für diese Key
    /// (oder nil wenn nie), den jetzt-Zeitpunkt und das Window — soll registriert
    /// werden? Test-friendly ohne Date()-Sideeffect.
    nonisolated static func shouldRegister(
        lastReportedAt: Date?,
        now: Date,
        window: TimeInterval = throttleWindow
    ) -> Bool {
        guard let last = lastReportedAt else { return true }
        return now.timeIntervalSince(last) >= window
    }

    // MARK: - Reports-Datei prune

    /// Behält die letzten N Files im reports-Dir; ältere werden gelöscht. Pure-
    /// von-Side-Effekten: pure helper `filesToDelete(from:keepCount:)` ist
    /// testbar; dieser Wrapper macht Filesystem-IO.
    /// Nonisolated weil File-System-only, kein Store-State angefasst.
    nonisolated static func pruneOldReports(keepCount: Int = maxReportFiles) {
        let dir = reportsDirectoryURL
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return
        }
        let toDelete = filesToDelete(from: files, keepCount: keepCount)
        for url in toDelete {
            try? fm.removeItem(at: url)
        }
    }

    /// Pure: aus einer URL-Liste die ältesten herausfiltern, sodass nur
    /// `keepCount` jüngste bleiben. Test-friendly.
    nonisolated static func filesToDelete(from files: [URL], keepCount: Int) -> [URL] {
        guard files.count > keepCount else { return [] }
        let sorted = files.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate  // newest first
        }
        return Array(sorted.dropFirst(keepCount))
    }

    // MARK: - System-Info-Helper (shared mit DiagnosticSession)

    nonisolated static func appVersionAndBuild() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    nonisolated static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    nonisolated static func routexSDKVersion() -> String {
        // Routex liefert keine Version-API; wir tragen die SPM-Pin-Version manuell.
        // Wenn Du das SDK upgradest, hier mitziehen.
        "0.4.1"
    }
}

// MARK: - JWT Ticket-ID-Decoder

/// Extrahiert die `data.id` aus dem JWT-Payload eines YAXI-Tickets.
/// Pure function — testbar ohne JWT-Library.
enum JWTTicketDecoder {
    static func extractTicketId(from jwt: String) -> String? {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3 else { return nil }
        let payloadSegment = String(segments[1])
        guard let payloadData = base64URLDecode(payloadSegment),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let id = data["id"] as? String
        else { return nil }
        return id
    }

    static func base64URLDecode(_ input: String) -> Data? {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Padding auffüllen auf %4 == 0
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
