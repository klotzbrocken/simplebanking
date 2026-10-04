import Foundation

/// Obergrenze für eine eingehende Nachricht.
///
/// Der Server läuft lokal über `stdio`, der Client ist der eigene Elternprozess — ein
/// Angreifer ist hier nicht die naheliegende Sorge. Ein fehlerhafter Client aber schon:
/// Ohne Grenze wächst eine Zeile Byte für Byte weiter, und ein `Content-Length` von
/// einigen Gigabyte fordert den Lesepuffer in einem Stück an. Eingehende Nachrichten
/// sind Aufrufe, keine Nutzdaten; acht Mebibyte sind großzügig.
public let maxNachrichtenGroesse = 8 * 1024 * 1024

/// Obergrenze für eine einzelne Headerzeile.
///
/// Deutlich enger als die Nachricht selbst, denn ein Header ist nie lang. Die **erste**
/// Zeile behält bewusst die große Grenze: Im NDJSON-Modus ist sie die vollständige
/// Nachricht und kein Header.
public let maxHeaderZeile = 8 * 1024

/// Prüfung des LSP-Rahmens („Content-Length"-Header vor dem Körper).
public enum MCPRahmen {

    public enum Fehler: Error, Equatable, CustomStringConvertible {
        case fehlenderHeader
        case doppelterHeader
        case ungueltigerWert(String)
        case zuGross(Int)

        public var description: String {
            switch self {
            case .fehlenderHeader: return "kein Content-Length-Header"
            case .doppelterHeader: return "mehr als ein Content-Length-Header"
            case .ungueltigerWert(let v): return "ungültige Content-Length \(v)"
            case .zuGross(let n): return "Content-Length \(n) über der Grenze von \(maxNachrichtenGroesse)"
            }
        }
    }

    /// Liefert die Länge des Nachrichtenkörpers aus den gesammelten Headerzeilen.
    ///
    /// Alle Zeilen werden **gemeinsam** geprüft, nicht nacheinander. Genau daran
    /// scheiterte die frühere Fassung: Sie prüfte die Grenze direkt nach der ersten Zeile
    /// und ließ jede weitere den bereits geprüften Wert überschreiben, ohne erneut zu
    /// prüfen. `Content-Length: 10` gefolgt von `Content-Length: 2000000000` kam so
    /// ungehindert durch.
    public static func koerperLaenge(headerZeilen: [String]) -> Result<Int, Fehler> {
        let werte = headerZeilen.compactMap { zeile -> String? in
            let z = zeile.lowercased()
            guard z.hasPrefix("content-length:") else { return nil }
            return String(zeile.dropFirst("content-length:".count))
                .trimmingCharacters(in: .whitespaces)
        }

        guard !werte.isEmpty else { return .failure(.fehlenderHeader) }
        // Doppelte Header sind ein Protokollfehler, kein „der letzte gewinnt".
        guard werte.count == 1 else { return .failure(.doppelterHeader) }
        guard let laenge = Int(werte[0]), laenge > 0 else {
            return .failure(Fehler.ungueltigerWert(werte[0]))
        }
        guard laenge <= maxNachrichtenGroesse else {
            return .failure(Fehler.zuGross(laenge))
        }
        return .success(laenge)
    }
}

/// Ob die simplesend-Lizenz als aktiv gilt — die reine Rechnung.
///
/// Liegt hier und nicht im Server-Ziel, weil ein Executable mit `main.swift` sich aus
/// einem Testziel nicht importieren lässt. `Lizenz` im MCP-Ziel ruft das hier auf und
/// besorgt nur die Eingabe.
///
/// Maßstab ist derselbe wie in der App ohne Netz: Die letzte Server-Bestätigung liegt im
/// Gnadenfenster. Den Schlüssel selbst liest der Server bewusst **nicht** — er steht im
/// Schlüsselbund, und ein zweites Binary, das ihn anfasst, löst eine Freigabe-Abfrage
/// aus. Nötig ist er auch nicht: Den Zeitstempel setzt die App nur nach einer
/// erfolgreichen Bestätigung und löscht ihn mit dem Schlüssel zusammen.
public enum LizenzFenster {
    /// 14 Tage, wie `LicenseConfig.offlineGracePeriod`.
    public static let gnadenfenster: TimeInterval = 14 * 24 * 60 * 60

    public static func istAktiv(bestaetigtAm: Date?,
                                jetzt: Date = Date(),
                                fenster: TimeInterval = gnadenfenster) -> Bool {
        guard let bestaetigtAm else { return false }
        let alter = jetzt.timeIntervalSince(bestaetigtAm)
        // Negatives Alter heißt: der Zeitstempel liegt in der Zukunft. Uhr verstellt
        // oder Datum zurückgedreht — das zählt als abgelaufen, nicht als frisch.
        return alter >= 0 && alter < fenster
    }
}
