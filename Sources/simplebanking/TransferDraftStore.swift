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

    /// Liest und parst alle Drafts. Abgelaufene werden verworfen (und gelöscht).
    /// Sortierung: jüngster zuerst.
    static func loadAll() -> [TransferDraft] {
        guard let dir = try? directoryURL() else { return [] }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let now = Date()
        let decoder = JSONDecoder()
        var drafts: [TransferDraft] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let draft = try? decoder.decode(TransferDraft.self, from: data) else {
                // Defekte Datei wegräumen, damit der Watcher nicht ewig daran nagt.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if let expires = makeISOFormatter().date(from: draft.expiresAt), expires < now {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            drafts.append(draft)
        }
        return drafts.sorted { lhs, rhs in
            (makeISOFormatter().date(from: lhs.createdAt) ?? .distantPast) >
            (makeISOFormatter().date(from: rhs.createdAt) ?? .distantPast)
        }
    }

    /// Konsumiert (= löscht) den Draft. One-shot — verhindert, dass derselbe
    /// Draft beim nächsten App-Start nochmal aufpoppt.
    static func consume(id: String) {
        if let url = try? draftURL(id: id) {
            try? FileManager.default.removeItem(at: url)
        }
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
