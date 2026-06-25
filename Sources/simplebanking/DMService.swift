import Foundation

extension Notification.Name {
    /// Gepostet nach erfolgreichem dm-Sync → offene Panels laden die Bons neu.
    static let dmReceiptsChanged = Notification.Name("dmReceiptsChanged")
}

// MARK: - Result / Errors

struct DMSyncResult: Equatable {
    var listed: Int      // Einkäufe aus der purchasehistory-Liste
    var detailed: Int    // eBons mit nachgeladenen Einzelposten (DANs)
    var stored: Int      // persistierte Bons
}

enum DMServiceError: Error, Equatable {
    case noToken
    case tokenExpired
    case listFailed(Int)
    case detailFailed(Int)
}

// MARK: - Wire-Modelle (nur fürs Parsen, dm-spezifisch)

/// Ein dm-Produkt-Tile (Auflösung DAN → Name/Marke/Preis), public Endpoint.
private struct DMProduct {
    var name: String
    var priceCents: Int?   // AKTUELLER Shop-Preis (nicht der historisch gezahlte)
}

// MARK: - Service

/// Holt dm-eBons und persistiert sie (in dieselbe `rewe_receipts`-Tabelle wie
/// REWE, slot-skopiert über `ReweReceiptStore`). Drei Stufen — alles JSON, kein
/// PDF:
///   1. Liste:   purchasehistory-prod…/v1/purchasehistory?size=N   (Bearer)
///   2. Detail:  ebon-prod…/api/customer/ebons/{id}                 (Bearer)
///   3. Produkt: products.dm.de/product/products/tiles/DE/dans/…    (kein Auth)
///
/// Auth ist ein KURZLEBIGER Bearer-JWT (~2,5 min) aus Curity (signin.dm.de),
/// kein Cookie wie bei REWE — er wird live aus der Login-WebView geerntet
/// (`DMAuthWebView`). dm liefert pro Posten nur die Artikelnummer (DAN) und den
/// aktuellen Shop-Preis, NICHT den historisch gezahlten Einzelpreis — die
/// `totalAmount` des Bons bleibt die maßgebliche Summe.
@MainActor
enum DMService {
    private static let listURLString = "https://purchasehistory-prod.services.dmtech.com/v1/purchasehistory"
    private static let ebonBase = "https://ebon-prod.services.dmtech.com/api/customer/ebons/"
    private static let productBase = "https://products.dm.de/product/products/tiles/DE/dans/"

    /// Voller Sync. Lädt die Liste, dann für jeden noch nicht geparsten Einkauf
    /// den eBon-Detail (DANs), löst die DANs in einem Batch zu Produktnamen auf
    /// und persistiert. Bereits geparste Bons werden NICHT erneut detailliert.
    static func sync(token: String, size: Int = 20,
                     slotId: String, bankId: String = "primary") async throws -> DMSyncResult {
        guard !token.isEmpty else { throw DMServiceError.noToken }
        if isExpired(token) { throw DMServiceError.tokenExpired }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let list = try await fetchList(token: token, size: size)
        let alreadyParsed = (try? ReweReceiptStore.parsedIds(slotId: slotId, bankId: bankId)) ?? []

        // Detail nur für noch nicht geparste Bons (Dedup über Sync-Läufe). Mit
        // begrenzter Parallelität laden — sonst summieren sich die Latenzen bei vielen
        // neuen Bons. 401 bricht ab (Token tot); andere Einzelfehler werden geschluckt.
        let toFetch = list.filter { !alreadyParsed.contains($0.id) }.map(\.id)
        let fetched = try await boundedConcurrentMap(toFetch, maxConcurrent: 5) { id -> (String, DMEbonDetail?) in
            do {
                return (id, try await fetchDetail(id: id, token: token))
            } catch DMServiceError.detailFailed(401) {
                throw DMServiceError.tokenExpired
            } catch {
                return (id, nil)   // einzelner Bon-Fehler: überspringen, Rest läuft weiter
            }
        }
        var details: [String: DMEbonDetail] = [:]
        var allDans: Set<String> = []
        for (id, d) in fetched {
            if let d { details[id] = d; allDans.formUnion(d.dans) }
        }

        let products = await resolveProducts(dans: Array(allDans))

        let receipts: [ReweReceipt] = list.map { item in
            let detail = details[item.id]
            let rawItems: [ReweLineItem] = (detail?.dans ?? []).map { dan in
                let p = products[dan]
                return ReweLineItem(name: p?.name ?? "Artikel \(dan)", quantity: nil,
                                    totalCents: p?.priceCents ?? 0, taxCategory: nil)
            }
            // dm liefert nur AKTUELLE Shop-Preise (nicht den gezahlten Preis) → auf die
            // maßgebliche Bon-Summe skalieren, damit Euro-Auswertungen korrekt aufsummieren.
            let items = Self.scaleItemsToTotal(rawItems, total: item.totalCents)
            return ReweReceipt(
                slotId: slotId, receiptId: item.id, timestamp: item.timestamp,
                totalCents: item.totalCents,
                marketName: detail?.marketName ?? "dm-drogerie markt",
                marketCity: detail?.marketCity,
                cancelled: false, items: items,
                parsed: detail != nil, fetchedAt: stamp)
        }

        try ReweReceiptStore.upsert(receipts, bankId: bankId)
        return DMSyncResult(listed: list.count, detailed: details.count, stored: receipts.count)
    }

    /// Verteilt die maßgebliche Bon-Summe proportional zu den (aktuellen) Posten-
    /// Preisen → geschätzte Einzelbeträge, die exakt auf `total` aufsummieren. Sind
    /// alle Preise 0 → gleichmäßig. Rundungsrest landet auf dem größten Posten.
    nonisolated static func scaleItemsToTotal(_ items: [ReweLineItem], total: Int) -> [ReweLineItem] {
        guard !items.isEmpty, total > 0 else { return items }
        let sum = items.reduce(0) { $0 + $1.totalCents }
        var scaled: [ReweLineItem]
        if sum > 0 {
            scaled = items.map { it in
                var c = it
                c.totalCents = Int((Double(it.totalCents) / Double(sum) * Double(total)).rounded())
                return c
            }
        } else {
            let each = total / items.count
            scaled = items.map { it in var c = it; c.totalCents = each; return c }
        }
        let remainder = total - scaled.reduce(0) { $0 + $1.totalCents }
        if remainder != 0,
           let maxIdx = scaled.indices.max(by: { scaled[$0].totalCents < scaled[$1].totalCents }) {
            scaled[maxIdx].totalCents += remainder
        }
        return scaled
    }

    // MARK: - JWT

    /// Liest `exp` aus dem JWT-Payload und prüft, ob er (mit 5 s Puffer) abgelaufen
    /// ist. Bei nicht-parsebarem Token → false (Server entscheidet dann via 401).
    nonisolated static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let exp = claims(token)?["exp"] as? Double else { return false }
        return now.timeIntervalSince1970 >= (exp - 5)
    }

    /// Decodiert den JWT-Payload (Diagnose). Loggt NIE den ganzen Token.
    nonisolated static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                   .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// `aud`-Claim (für 400-Diagnose: richtiger Dienst-Token?).
    nonisolated static func tokenAudience(_ token: String) -> String {
        let aud = claims(token)?["aud"]
        if let s = aud as? String { return s }
        if let a = aud as? [String] { return a.joined(separator: ",") }
        return "?"
    }

    // MARK: - Network

    private static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }

    private static func authedRequest(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("https://account.dm.de", forHTTPHeaderField: "Origin")
        req.setValue("https://account.dm.de/", forHTTPHeaderField: "Referer")
        req.setValue("web", forHTTPHeaderField: "src")
        // Browser-UA: der CFNetwork-Default-UA von URLSession wird vom dm-Gateway
        // mit leerem 400 abgewiesen.
        req.setValue(macUserAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// purchasehistory → id / Zeitstempel / Summe. Nur MARKET-Einkäufe (echte
    /// Kassenbons; Online-Bestellungen tragen keinen eBon).
    private static func fetchList(token: String, size: Int) async throws -> [DMListItem] {
        var comps = URLComponents(string: listURLString)!
        comps.queryItems = [URLQueryItem(name: "size", value: String(size))]
        let (data, resp) = try await session().data(for: authedRequest(comps.url!, token: token))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw DMServiceError.tokenExpired }
        guard code == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
            AppLogger.log("dm list \(code) url=\(comps.url?.absoluteString ?? "?") tokenAud=\(tokenAudience(token)) body=\(body)", category: "DM", level: "WARN")
            throw DMServiceError.listFailed(code)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["purchaseHistoryItems"] as? [[String: Any]] else {
            throw DMServiceError.listFailed(-1)
        }
        return items.compactMap { it -> DMListItem? in
            guard let id = it["id"] as? String,
                  (it["purchaseType"] as? String) == "MARKET",
                  let placed = it["dateTimePlaced"] as? String else { return nil }
            let amount = (it["totalAmount"] as? Double) ?? 0
            return DMListItem(id: id, timestamp: placed, totalCents: Int((amount * 100).rounded()))
        }
    }

    /// eBon-Detail → Markt-Adresse + bonItems (nur DAN-Nummern).
    private static func fetchDetail(id: String, token: String) async throws -> DMEbonDetail {
        let url = URL(string: ebonBase + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id))!
        let (data, resp) = try await session().data(for: authedRequest(url, token: token))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DMServiceError.detailFailed(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DMServiceError.detailFailed(-1)
        }
        let addr = obj["address"] as? [String: Any]
        let bonItems = obj["bonItems"] as? [[String: Any]] ?? []
        let dans: [String] = bonItems.compactMap { item in
            if let s = item["dan"] as? String { return s }
            if let n = item["dan"] as? Int { return String(n) }
            return nil
        }
        return DMEbonDetail(dans: dans,
                            marketName: addr?["name"] as? String,
                            marketCity: addr?["city"] as? String)
    }

    /// DAN → Produktname + aktueller Preis (public, kein Auth). Chunked, damit die
    /// URL nicht zu lang wird. Fehlende DANs bleiben einfach aus der Map.
    private static func resolveProducts(dans: [String]) async -> [String: DMProduct] {
        guard !dans.isEmpty else { return [:] }
        var map: [String: DMProduct] = [:]
        for chunk in dans.chunked(into: 40) {
            let csv = chunk.joined(separator: ",")
            guard let url = URL(string: productBase + csv) else { continue }
            var req = URLRequest(url: url)
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            req.setValue("https://account.dm.de/", forHTTPHeaderField: "Referer")
            req.setValue(macUserAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session().data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let products = obj["products"] as? [String: Any] else { continue }
            for (dan, raw) in products {
                guard let p = raw as? [String: Any] else { continue }
                let title = (p["title"] as? [String: Any])?["tileHeadline"] as? String
                let brand = (p["brand"] as? [String: Any])?["name"] as? String
                let name = [brand, title].compactMap { $0 }.joined(separator: " ")
                let priceStr = (((p["price"] as? [String: Any])?["price"] as? [String: Any])?["current"] as? [String: Any])?["value"] as? String
                map[dan] = DMProduct(name: name.isEmpty ? "Artikel \(dan)" : name,
                                     priceCents: priceStr.flatMap(parsePriceCents))
            }
        }
        return map
    }

    private static let macUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"

    /// "1,25 €" / "1,25\u{00a0}€" → 125. Public + static für Tests.
    nonisolated static func parsePriceCents(_ s: String) -> Int? {
        let cleaned = s.filter { $0.isNumber || $0 == "," || $0 == "." }
        let norm = cleaned.replacingOccurrences(of: ".", with: "")
                          .replacingOccurrences(of: ",", with: ".")
        guard let d = Double(norm) else { return nil }
        return Int((d * 100).rounded())
    }
}

// MARK: - Detail-Modelle (file-private)

private struct DMListItem {
    var id: String
    var timestamp: String   // ISO-8601 (dateTimePlaced)
    var totalCents: Int
}

private struct DMEbonDetail {
    var dans: [String]
    var marketName: String?
    var marketCity: String?
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
