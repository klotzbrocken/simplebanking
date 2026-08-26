import Foundation
import CryptoKit

// MARK: - Wer darf was
//
// Der Server ist ausschließlich lesend — `prepare_transfer` wurde mit dieser Änderung
// entfernt. Die Bereiche schränken darüber hinaus ein, WAS ein einzelner Client lesen
// darf: Wer nur Summen auswerten soll, braucht keine Verwendungszwecke mit Klarnamen.
//
// **Der Zugang wird über Merkmale entschieden, die die App vergibt.** Sie legt eine
// Registrierung an, der Server liest sie. Der Token selbst steht dort NICHT — nur sein
// Hash. Wer die Datei liest, gewinnt damit nichts.
//
// Das Dateiformat ist der Vertrag zwischen zwei getrennten Zielen (App und Server). Wer
// es hier ändert, muss `MCPClientStore` in der App mitändern — es gibt keinen Compiler,
// der das erzwingt.
enum Zugang {

    /// Was ein Client darf. Bewusst grob: Vier Bereiche kann man in einem Dialog
    /// erklären, fünfzehn nicht.
    enum Bereich: String, CaseIterable {
        case konten        = "accounts"
        case umsaetze      = "transactions"
        case auswertung    = "analysis"
    }

    /// Welches Werkzeug welchen Bereich braucht.
    static func bereich(fuerWerkzeug name: String) -> Bereich? {
        switch name {
        case "get_accounts", "get_balance":                     return .konten
        case "get_transactions":                                return .umsaetze
        case "get_spending_summary", "get_monthly_overview":    return .auswertung
        default:                                                return nil
        }
    }

    struct Befund {
        let bereiche: Set<Bereich>
        /// Kein Token vorhanden — Altbestand.
        let altbestand: Bool
        let clientName: String?
    }

    // MARK: - Ermittlung

    /// Umgebungsvariable, über die der Client seinen Token mitgibt.
    static let tokenVariable = "SIMPLEBANKING_MCP_TOKEN"

    /// Was der aufrufende Client darf.
    ///
    /// **Ohne Token gibt es alle Bereiche.** Das ist vertretbar, seit der Server
    /// ausschließlich liest: Bestehende Einrichtungen sollen nach einem Update nicht
    /// wortlos aufhören zu funktionieren, und mehr als Lesen kann hier niemand.
    /// Die Bereiche sind dafür da, einem einzelnen Client *weniger* zu geben — nicht
    /// dafür, eine Schranke gegen den Rechner selbst zu bauen, der den Server startet.
    static func befund(umgebung: [String: String] = ProcessInfo.processInfo.environment,
                       jetzt: Date = Date()) -> Befund {
        guard let token = umgebung[tokenVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return Befund(bereiche: Set(Bereich.allCases), altbestand: true, clientName: nil)
        }
        guard let eintrag = eintrag(fuerToken: token) else {
            return Befund(bereiche: [], altbestand: false, clientName: nil)
        }
        if eintrag.widerrufen {
            return Befund(bereiche: [], altbestand: false, clientName: eintrag.name)
        }
        if let ablauf = eintrag.laeuftAbAm, ablauf < jetzt {
            return Befund(bereiche: [], altbestand: false, clientName: eintrag.name)
        }
        return Befund(bereiche: Set(eintrag.bereiche.compactMap(Bereich.init(rawValue:))),
                      altbestand: false, clientName: eintrag.name)
    }

    /// Vergleich über den Hash, nie über den Token im Klartext.
    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Registrierung lesen

    struct Eintrag {
        let name: String
        let bereiche: [String]
        let laeuftAbAm: Date?
        let widerrufen: Bool
    }

    static var registrierungURL: URL {
        let basis = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return basis.appendingPathComponent("simplebanking", isDirectory: true)
            .appendingPathComponent("mcp-clients.json")
    }

    private static func eintrag(fuerToken token: String) -> Eintrag? {
        guard let daten = try? Data(contentsOf: registrierungURL),
              let wurzel = try? JSONSerialization.jsonObject(with: daten) as? [String: Any],
              let liste = wurzel["clients"] as? [[String: Any]] else { return nil }

        let gesucht = hash(token)
        for c in liste {
            guard let h = c["tokenHash"] as? String, h == gesucht else { continue }
            let formatter = ISO8601DateFormatter()
            return Eintrag(
                name: c["name"] as? String ?? "unbenannt",
                bereiche: c["scopes"] as? [String] ?? [],
                laeuftAbAm: (c["expiresAt"] as? String).flatMap(formatter.date(from:)),
                widerrufen: c["revoked"] as? Bool ?? false
            )
        }
        return nil
    }
}
