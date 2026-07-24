import Foundation

// MARK: - TransferDraft
//
// Vom MCP-Server (oder anderen externen Quellen) vorbereiteter Transfer.
// Wird als JSON unter ~/Library/Application Support/simplebanking/transfer-drafts/
// abgelegt; die App watcht das Verzeichnis und öffnet bei neuem Draft das
// TransferSheet vorausgefüllt. SCA + Send-Delay + Lizenz-Gate bleiben unverändert
// — der LLM bereitet nur vor, der User bestätigt selbst.
//
// JSON-Schema ist SOURCE-OF-TRUTH für externe Schreiber (MCP-Tool prepare_transfer).
// Felder bewusst flach + Decimal-as-String, damit sich auch ohne Decimal-Encoder
// (z.B. Manuelles JSON-Schreiben aus dem MCP-Target) saubere Werte schreiben lassen.

struct TransferDraft: Codable, Sendable, Equatable {
    /// UUID-String, zugleich Dateiname (`<id>.json`).
    let id: String
    /// ISO-8601-String, wann der Draft erstellt wurde.
    let createdAt: String
    /// ISO-8601-String, ab wann der Draft als abgelaufen gilt (TTL meist 5 min).
    let expiresAt: String
    /// Quelle, z.B. "mcp". Erlaubt zukünftig andere Schreiber (CLI, Shortcuts).
    let source: String
    let creditorName: String
    let creditorIban: String
    /// Decimal als String — `Decimal`-Codable rundet bei Float-Roundtrip.
    let amountEUR: String
    let remittance: String?
    let endToEndId: String?
}

// MARK: - TransferDraftStore

enum TransferDraftStore {

    static let directoryName = "transfer-drafts"
    /// Drafts älter als 5 Minuten werden ignoriert + beim Scan gelöscht.
    static let ttlSeconds: TimeInterval = 5 * 60
    /// Toleranz für Uhrzeit-Drift zwischen Schreiber (z.B. MCP) und App.
    static let clockSkew: TimeInterval = 60
    /// Erlaubte `source`-Werte. Ein extern geschriebener Draft mit unbekannter
    /// Quelle wird verworfen (Härtung gegen manipulierte/fremde Dateien).
    static let allowedSources: Set<String> = ["mcp", "app", "cli"]

    /// Frischer Formatter pro Aufruf — ISO8601DateFormatter ist nicht Sendable,
    /// die Instanz ist billig genug für jedes Read/Write.
    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func directoryURL() throws -> URL {
        let appDir = try CredentialsStore.appSupportURL()
        let dir = appDir.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func draftURL(id: String) throws -> URL {
        try directoryURL().appendingPathComponent("\(id).json")
    }

    /// Prüft einen Draft rein (ohne Filesystem) gegen Dateinamen + Zeitfenster.
    /// SICHERHEIT: `id` muss ein UUID sein UND exakt dem Dateinamen-Stamm entsprechen
    /// — so kann eine manipulierte `id` (z.B. mit `../`) nie als Pfadbestandteil
    /// wiederverwendet werden, und ein Draft muss zu genau seiner Datei gehören.
    /// Zusätzlich: bekannte Quelle, parsebare Zeitstempel, `createdAt <= now+skew`,
    /// `expiresAt > createdAt`, TTL-Obergrenze, und noch nicht abgelaufen.
    static func isValid(_ draft: TransferDraft, filenameStem: String, now: Date = Date()) -> Bool {
        guard UUID(uuidString: draft.id) != nil, draft.id == filenameStem else { return false }
        guard allowedSources.contains(draft.source) else { return false }
        let iso = makeISOFormatter()
        guard let created = iso.date(from: draft.createdAt),
              let expires = iso.date(from: draft.expiresAt) else { return false }
        guard created <= now.addingTimeInterval(clockSkew) else { return false }
        guard expires > created else { return false }
        guard expires.timeIntervalSince(created) <= ttlSeconds + clockSkew else { return false }
        guard expires > now else { return false }  // nicht abgelaufen
        return true
    }

    /// Liest, parst und **validiert** alle Drafts und gibt sie mit ihrer echten
    /// Datei-URL zurück (jüngster zuerst). Defekte/ungültige/abgelaufene Dateien
    /// werden über ihre **aufgelistete** URL gelöscht — nie über einen aus JSON
    /// neu berechneten Pfad.
    static func loadAllWithURLs(now: Date = Date()) -> [(draft: TransferDraft, url: URL)] {
        guard let dir = try? directoryURL() else { return [] }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        var result: [(draft: TransferDraft, url: URL)] = []
        for url in files where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let draft = try? decoder.decode(TransferDraft.self, from: data),
                  isValid(draft, filenameStem: stem, now: now) else {
                // Defekt / ungültig / abgelaufen → aufgelistete Datei wegräumen.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            result.append((draft, url))
        }
        return result.sorted { lhs, rhs in
            (makeISOFormatter().date(from: lhs.draft.createdAt) ?? .distantPast) >
            (makeISOFormatter().date(from: rhs.draft.createdAt) ?? .distantPast)
        }
    }

    /// Convenience: nur die validierten Drafts (ohne URLs).
    static func loadAll() -> [TransferDraft] {
        loadAllWithURLs().map { $0.draft }
    }

    /// Konsumiert (= löscht) einen Draft über seine **aufgelistete** URL. One-shot —
    /// verhindert, dass derselbe Draft beim nächsten App-Start nochmal aufpoppt.
    /// Nimmt bewusst die URL (nicht die JSON-`id`), um Pfadmanipulation auszuschließen.
    static func consume(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Wandelt einen Draft in ein validiertes TransferRequest. Wirft, wenn die
    /// MCP-Seite Müll geschrieben hat (Amount nicht parsebar, IBAN-Check fail, …).
    static func makeRequest(from draft: TransferDraft) throws -> TransferRequest {
        let trimmed = draft.amountEUR.replacingOccurrences(of: ",", with: ".")
        guard let amount = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            throw TransferRequestError.nonPositiveAmount
        }
        return try TransferRequest(
            creditorName: draft.creditorName,
            creditorIban: draft.creditorIban,
            amountEUR: amount,
            remittance: draft.remittance,
            endToEndId: draft.endToEndId
        )
    }

    // MARK: Schreiber (auch von Tests + zukünftigen App-internen Drafts genutzt)

    static func write(_ draft: TransferDraft) throws {
        let url = try draftURL(id: draft.id)
        let data = try JSONEncoder.prettyOrdered.encode(draft)
        try data.write(to: url, options: .atomic)
    }

    /// Convenience für Tests + App-internes Anlegen ohne Datei.
    static func makeDraft(
        from request: TransferRequest,
        source: String = "app",
        ttl: TimeInterval = ttlSeconds,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) -> TransferDraft {
        TransferDraft(
            id: id,
            createdAt: makeISOFormatter().string(from: now),
            expiresAt: makeISOFormatter().string(from: now.addingTimeInterval(ttl)),
            source: source,
            creditorName: request.creditorName,
            creditorIban: request.creditorIban,
            amountEUR: NSDecimalNumber(decimal: request.amountEUR).stringValue,
            remittance: request.remittance,
            endToEndId: request.endToEndId
        )
    }
}

private extension JSONEncoder {
    /// Stabile Encoder-Konfiguration mit Pretty-Print und sortierten Keys, damit
    /// JSON-Files diff-freundlich bleiben.
    static let prettyOrdered: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
