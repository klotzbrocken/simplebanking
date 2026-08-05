import Foundation

/// Fasst den letzten Einrichtungsversuch zu einem Bericht zusammen.
///
/// **Warum im Nachhinein und nicht als Probe.** Eine Ersteinrichtung lässt sich nicht
/// nachspielen: Jeder Lauf ist eine echte Verbindung mit echten Freigaben — bei bunq drei
/// QR-Scans, bei einer Sparkasse eine Push-TAN. Ein Knopf „Einrichtung testen" würde den
/// Kunden also jedes Mal Geld an Zeit und Nerven kosten und ließe sich nicht wiederholen,
/// wenn beim ersten Mal etwas fehlt. Deshalb schreiben Einrichtung und Traces seit 2.0.3
/// **immer** mit, und dieser Typ liest hinterher zusammen, was dabei entstanden ist.
///
/// Zusammengetragen werden drei Quellen, die bisher getrennt lagen und deren Zeitstempel
/// man von Hand abgleichen musste:
///
/// - `setup/simplebanking-setup-*.txt` — die Schrittfolge samt Dauer und Fehlertext
/// - `trace/yaxi-trace-*.txt` — die HTTP-Roundtrips, sofern im Zeitfenster geschrieben
/// - der passende Ausschnitt aus `simplebanking.log`
enum SetupDiagnosticsReport {

    struct Bericht {
        /// Die Zusammenfassung, die oben im Mail-Anhang liegt.
        let summaryFile: URL
        /// Alles, was mitgeschickt wird — Zusammenfassung zuerst.
        let anhaenge: [URL]
        /// Wie viele Traces im Zeitfenster gefunden wurden. Null ist eine Aussage:
        /// dann war das Protokoll abgeschaltet oder die Einrichtung kam nie bis zu
        /// einem Bankaufruf.
        let traceAnzahl: Int
        /// Startzeit des ausgewerteten Versuchs.
        let begonnenAm: Date
    }

    enum Fehler: LocalizedError {
        case keinVersuchGefunden

        var errorDescription: String? {
            switch self {
            case .keinVersuchGefunden:
                return L10n.t("Es liegt keine Einrichtung zum Auswerten vor.",
                              "There is no setup attempt to evaluate.")
            }
        }
    }

    // MARK: - Öffentlich

    /// Wertet den jüngsten Einrichtungsversuch aus.
    static func ausLetztemVersuch() throws -> Bericht {
        guard let setupDatei = juengsteSetupDatei() else { throw Fehler.keinVersuchGefunden }

        let begonnen = (try? setupDatei.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate ?? Date()
        // Endezeitpunkt großzügig: Der Versuch kann nach der letzten Zeile noch
        // Traces nachgeschoben haben (der Trace-Abruf ist selbst eine Anfrage).
        let beendet = ((try? setupDatei.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()).addingTimeInterval(120)

        let traces = tracesImFenster(von: begonnen.addingTimeInterval(-60), bis: beendet)
        let summary = try schreibeZusammenfassung(setupDatei: setupDatei,
                                                  traces: traces,
                                                  begonnen: begonnen,
                                                  beendet: beendet)

        return Bericht(summaryFile: summary,
                       anhaenge: [summary, setupDatei] + traces,
                       traceAnzahl: traces.count,
                       begonnenAm: begonnen)
    }

    // MARK: - Quellen einsammeln

    static func juengsteSetupDatei() -> URL? {
        let dir = SetupDiagnosticsLogger.logDirectoryURL
        let dateien = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return dateien
            .filter { $0.pathExtension == "txt" }
            .max { datum($0) < datum($1) }
    }

    /// Traces, die im Zeitfenster des Versuchs geschrieben wurden.
    ///
    /// Über die Änderungszeit und nicht über den Dateinamen: Der Name trägt zwar einen
    /// Zeitstempel, aber in einem eigenen Format, und ein Fehlgriff beim Parsen würde
    /// stillschweigend zu leeren Berichten führen.
    static func tracesImFenster(von: Date, bis: Date) -> [URL] {
        let dir = AppLogger.logDirectoryURL.appendingPathComponent("trace", isDirectory: true)
        let dateien = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return dateien
            .filter { $0.pathExtension == "txt" }
            .filter { let d = datum($0); return d >= von && d <= bis }
            .sorted { datum($0) < datum($1) }
    }

    // MARK: - Prüfbare Kerne
    //
    // Die Auswahl arbeitet über feste Ordner; für den Test bekommt sie einen eigenen,
    // statt ins echte Protokollverzeichnis zu schreiben.

    static func tracesImFensterFuerTests(ordner: URL, von: Date, bis: Date) -> [URL] {
        let dateien = (try? FileManager.default.contentsOfDirectory(
            at: ordner, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return dateien
            .filter { $0.pathExtension == "txt" }
            .filter { let d = datum($0); return d >= von && d <= bis }
            .sorted { datum($0) < datum($1) }
    }

    static func juengsteDateiFuerTests(ordner: URL) -> URL? {
        let dateien = (try? FileManager.default.contentsOfDirectory(
            at: ordner, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return dateien.filter { $0.pathExtension == "txt" }.max { datum($0) < datum($1) }
    }

    private static func datum(_ url: URL) -> Date {
        let werte = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return werte?.creationDate ?? werte?.contentModificationDate ?? .distantPast
    }

    // MARK: - Zusammenfassung

    private static func schreibeZusammenfassung(setupDatei: URL,
                                                traces: [URL],
                                                begonnen: Date,
                                                beendet: Date) throws -> URL {
        let inhalt = (try? String(contentsOf: setupDatei, encoding: .utf8)) ?? ""
        let zeilen = inhalt.split(separator: "\n").map(String.init)

        var s = "simplebanking — Diagnose der Einrichtung\n"
        s += "════════════════════════════════════════\n\n"
        s += "Versuch begonnen: \(zeitFormat.string(from: begonnen))\n"
        s += "Protokolldatei:   \(setupDatei.lastPathComponent)\n"
        s += "YAXI-Traces:      \(traces.count)\n"
        if traces.isEmpty {
            s += "                  (keine — entweder war das Protokoll abgeschaltet\n"
            s += "                   oder es kam nie zu einem Bankaufruf)\n"
        }
        s += "\n"

        // Ergebnis zuerst: Wer den Bericht öffnet, will als Erstes wissen, woran es lag.
        if let finish = zeilen.last(where: { $0.contains("event=finish") }) {
            s += "── Ergebnis ─────────────────────────────\n\(finish)\n\n"
        } else {
            s += "── Ergebnis ─────────────────────────────\n"
            s += "Kein Abschluss protokolliert — der Versuch wurde abgebrochen oder\n"
            s += "die App wurde vorher beendet.\n\n"
        }

        let gescheiterte = zeilen.filter { $0.contains("event=failure") }
        if !gescheiterte.isEmpty {
            s += "── Gescheiterte Schritte (\(gescheiterte.count)) ────────────\n"
            s += gescheiterte.joined(separator: "\n") + "\n\n"
        }

        s += "── Verlauf ──────────────────────────────\n"
        s += inhalt.isEmpty ? "(leer)\n" : inhalt
        if !inhalt.hasSuffix("\n") { s += "\n" }
        s += "\n"

        if !traces.isEmpty {
            s += "── Beigelegte Traces ────────────────────\n"
            for t in traces { s += "\(t.lastPathComponent)\n" }
            s += "\n"
        }

        s += "── System ───────────────────────────────\n"
        s += "app:    \(ErrorReportStore.appVersionAndBuild())\n"
        s += "macOS:  \(ErrorReportStore.macOSVersion())\n"
        s += "routex: \(ErrorReportStore.routexSDKVersion())\n"

        let dir = AppLogger.logDirectoryURL.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ziel = dir.appendingPathComponent(
            "simplebanking-einrichtung-bericht-\(dateiFormat.string(from: begonnen)).txt")
        // Der Bericht enthält den Verlauf im Klartext — dieselbe Bereinigung wie die
        // Quelldatei, und dieselben Rechte wie das übrige Protokoll.
        try LogSanitizer.redact(s).write(to: ziel, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ziel.path)
        return ziel
    }

    private static let zeitFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateiFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
