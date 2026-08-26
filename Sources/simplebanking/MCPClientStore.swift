import Foundation
import CryptoKit

// MARK: - Wer den MCP-Server benutzen darf
//
// Gegenstück zu `Zugang` im Server-Ziel. **Das Dateiformat ist der Vertrag zwischen
// beiden**, und es gibt keinen Compiler, der ihn erzwingt — wer hier etwas ändert, muss
// dort mitändern.
//
// Der Token wird genau einmal angezeigt, danach nie wieder: Abgelegt ist nur sein Hash.
// Das ist kein Selbstzweck. Die Datei liegt unverschlüsselt neben der Datenbank; würde
// der Token darin stehen, wäre die Datei selbst der Zugang.
enum MCPClientStore {

    struct Client: Identifiable, Equatable {
        let id: String
        var name: String
        var bereiche: Set<Zugangsbereich>
        var angelegtAm: Date
        var laeuftAbAm: Date?
        var widerrufen: Bool

        var abgelaufen: Bool {
            guard let laeuftAbAm else { return false }
            return laeuftAbAm < Date()
        }

        var aktiv: Bool { !widerrufen && !abgelaufen }
    }

    /// Spiegelt `Zugang.Bereich` im Server-Ziel. Die Rohwerte müssen übereinstimmen.
    enum Zugangsbereich: String, CaseIterable, Identifiable {
        case konten       = "accounts"
        case umsaetze     = "transactions"
        case auswertung   = "analysis"

        var id: String { rawValue }

        var titel: String {
            switch self {
            case .konten:       return L10n.t("Konten und Salden", "Accounts and balances")
            case .umsaetze:     return L10n.t("Umsätze", "Transactions")
            case .auswertung:   return L10n.t("Auswertungen", "Analysis")
            }
        }

        var hinweis: String {
            switch self {
            case .konten:
                return L10n.t("Kontonamen, IBAN und Kontostand.", "Account names, IBAN and balance.")
            case .umsaetze:
                return L10n.t("Einzelne Buchungen mit Empfänger und Verwendungszweck.",
                              "Individual bookings with recipient and reference.")
            case .auswertung:
                return L10n.t("Summen je Kategorie und Monat.", "Totals per category and month.")
            }
        }

        /// Voreinstellung für einen neuen Client. Alle Bereiche sind lesend; wer
        /// einzelne abwählt, gibt einem Client bewusst weniger.
        var standardmaessigAn: Bool { true }
    }

    // MARK: - Ablage

    static var dateiURL: URL {
        let basis = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return basis.appendingPathComponent("simplebanking", isDirectory: true)
            .appendingPathComponent("mcp-clients.json")
    }

    static func laden() -> [Client] {
        guard let daten = try? Data(contentsOf: dateiURL),
              let wurzel = try? JSONSerialization.jsonObject(with: daten) as? [String: Any],
              let liste = wurzel["clients"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return liste.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            return Client(
                id: id,
                name: c["name"] as? String ?? "unbenannt",
                bereiche: Set((c["scopes"] as? [String] ?? []).compactMap(Zugangsbereich.init(rawValue:))),
                angelegtAm: (c["createdAt"] as? String).flatMap(iso.date(from:)) ?? Date(),
                laeuftAbAm: (c["expiresAt"] as? String).flatMap(iso.date(from:)),
                widerrufen: c["revoked"] as? Bool ?? false
            )
        }
    }

    /// Legt einen Client an und gibt den Token zurück — **das einzige Mal**, dass er
    /// existiert. Wer ihn verliert, legt einen neuen an; wiederherstellen kann ihn
    /// niemand, auch die App nicht.
    @discardableResult
    static func anlegen(name: String,
                        bereiche: Set<Zugangsbereich>,
                        gueltigTage: Int?) throws -> (client: Client, token: String) {
        var zufall = Data(count: 32)
        let ok = zufall.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard ok == errSecSuccess else {
            throw NSError(domain: "MCPClientStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.t("Zufallsquelle nicht verfügbar.",
                                                  "Random source unavailable.")
            ])
        }
        let token = zufall.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let client = Client(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "MCP-Client",
            bereiche: bereiche,
            angelegtAm: Date(),
            laeuftAbAm: gueltigTage.map { Date().addingTimeInterval(TimeInterval($0) * 86_400) },
            widerrufen: false
        )
        var alle = laden()
        alle.append(client)
        try schreiben(alle, neuerHash: [client.id: hash(token)])
        return (client, token)
    }

    static func widerrufen(id: String) throws {
        var alle = laden()
        guard let i = alle.firstIndex(where: { $0.id == id }) else { return }
        alle[i].widerrufen = true
        try schreiben(alle, neuerHash: [:])
    }

    static func loeschen(id: String) throws {
        try schreiben(laden().filter { $0.id != id }, neuerHash: [:])
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Schreibt die Registrierung. Vorhandene Hashes werden aus der Datei übernommen —
    /// sie stehen nirgends sonst, und ein Schreibvorgang darf sie nicht verlieren.
    private static func schreiben(_ clients: [Client], neuerHash: [String: String]) throws {
        var bestehendeHashes: [String: String] = [:]
        if let daten = try? Data(contentsOf: dateiURL),
           let wurzel = try? JSONSerialization.jsonObject(with: daten) as? [String: Any],
           let liste = wurzel["clients"] as? [[String: Any]] {
            for c in liste {
                if let id = c["id"] as? String, let h = c["tokenHash"] as? String {
                    bestehendeHashes[id] = h
                }
            }
        }
        let iso = ISO8601DateFormatter()
        let eintraege: [[String: Any]] = clients.map { c in
            var d: [String: Any] = [
                "id": c.id,
                "name": c.name,
                "scopes": c.bereiche.map(\.rawValue).sorted(),
                "createdAt": iso.string(from: c.angelegtAm),
                "revoked": c.widerrufen
            ]
            if let h = neuerHash[c.id] ?? bestehendeHashes[c.id] { d["tokenHash"] = h }
            if let ablauf = c.laeuftAbAm { d["expiresAt"] = iso.string(from: ablauf) }
            return d
        }
        let wurzel: [String: Any] = ["version": 1, "clients": eintraege]
        let daten = try JSONSerialization.data(withJSONObject: wurzel,
                                               options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: dateiURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try daten.write(to: dateiURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: dateiURL.path)
    }
}
