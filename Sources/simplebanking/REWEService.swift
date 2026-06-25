import Foundation
import PDFKit

extension Notification.Name {
    /// Gepostet nach erfolgreichem REWE-Sync → offene Panels laden die Bons neu.
    static let reweReceiptsChanged = Notification.Name("reweReceiptsChanged")
}

// MARK: - Result / Errors

struct REWESyncResult: Equatable {
    var listed: Int     // Bons aus der Liste
    var parsed: Int     // PDFs erfolgreich geparst
    var matched: Int    // Listen-Bons mit zugeordneten Einzelposten
    var stored: Int     // persistierte Bons
}

enum REWEServiceError: Error, Equatable {
    case notLoggedIn
    case listFailed(Int)
    case zipFailed(Int)
    case badZip
}

// MARK: - Merger (pure, testbar)

/// Ordnet geparste PDFs den Listen-Bons zu. Schlüssel: Datum (yyyy-MM-dd) +
/// Summe (Cent) — die receiptId steckt nicht im PDF-Text. Listen-Bons ohne
/// PDF-Match bleiben `parsed=false` (Einzelposten kommen beim nächsten Sync).
enum ReweReceiptMerger {
    static func merge(list: [ReweReceipt], parsed: [ReweParsedReceipt], fetchedAt: String) -> [ReweReceipt] {
        var byKey: [String: [ReweParsedReceipt]] = [:]
        for p in parsed {
            guard let total = p.totalCents, let date = p.date else { continue }
            byKey[key(date: date, total: total), default: []].append(p)
        }
        return list.map { receipt in
            var r = receipt
            r.fetchedAt = fetchedAt
            let k = key(date: String(r.timestamp.prefix(10)), total: r.totalCents)
            if var bucket = byKey[k], !bucket.isEmpty {
                let match = bucket.removeFirst()
                byKey[k] = bucket
                r.items = match.items
                r.parsed = true
            }
            return r
        }
    }

    private static func key(date: String, total: Int) -> String { "\(date)|\(total)" }
}

// MARK: - ZIP-Extraktion

enum ReweZip {
    /// Entpackt die eBon-ZIP via /usr/bin/unzip (App ist nicht sandboxed) und
    /// liefert alle enthaltenen PDFs. Läuft off-main.
    static func extractPDFs(_ data: Data) async -> [Data] {
        await Task.detached { () -> [Data] in
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rewe-zip-\(UUID().uuidString)")
            let zipURL = dir.appendingPathExtension("zip")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.removeItem(at: zipURL)
            }
            do { try data.write(to: zipURL) } catch { return [] }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-o", "-q", zipURL.path, "-d", dir.path]
            do { try p.run(); p.waitUntilExit() } catch { return [] }
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { return [] }
            return files.filter { $0.pathExtension.lowercased() == "pdf" }
                .compactMap { try? Data(contentsOf: $0) }
        }.value
    }
}

// MARK: - Service

/// Holt REWE-eBons und persistiert sie. Auth = Cookie-Header + User-Agent, die
/// aus der eingeloggten Login-WebView geerntet werden (Phase 3). Datenpfad ist
/// rein `URLSession` (Phase-2-verifiziert: die ZIP geht ohne curl/Gesten-Gate).
@MainActor
enum REWEService {
    private static let referer = "https://www.rewe.de/shop/mydata/meine-einkaeufe/im-markt"
    private static let listURLString = "https://www.rewe.de/shop/api/receipts/"
    private static let zipURLString = "https://www.rewe.de/api/receipts/zip"

    /// Voller Sync: Liste + ZIP → parsen → mergen → persistieren.
    static func sync(cookieHeader: String, userAgent: String,
                     slotId: String, bankId: String = "primary") async throws -> REWESyncResult {
        guard cookieHeader.contains("rstp=") else { throw REWEServiceError.notLoggedIn }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let list = try await fetchList(cookieHeader: cookieHeader, userAgent: userAgent, slotId: slotId, stamp: stamp)
        let zipData = try await fetchZip(cookieHeader: cookieHeader, userAgent: userAgent)
        let pdfs = await ReweZip.extractPDFs(zipData)

        // PDFDocument-Textextraktion + Parsing sind CPU-lastig → off-main, damit die
        // UI bei vielen Bons nicht ruckelt (REWEService ist @MainActor).
        let parsed: [ReweParsedReceipt] = await Task.detached(priority: .userInitiated) {
            pdfs.compactMap { data -> ReweParsedReceipt? in
                guard let doc = PDFDocument(data: data), let text = doc.string, !text.isEmpty else { return nil }
                return ReweReceiptParser.parse(text)
            }
        }.value

        let merged = ReweReceiptMerger.merge(list: list, parsed: parsed, fetchedAt: stamp)
        try ReweReceiptStore.upsert(merged, bankId: bankId)

        return REWESyncResult(listed: list.count, parsed: parsed.count,
                              matched: merged.filter(\.parsed).count, stored: merged.count)
    }

    // MARK: - Network

    private static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }

    private static func fetchList(cookieHeader: String, userAgent: String,
                                  slotId: String, stamp: String) async throws -> [ReweReceipt] {
        var req = URLRequest(url: URL(string: listURLString)!)
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, resp) = try await session().data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw REWEServiceError.listFailed(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { throw REWEServiceError.listFailed(-1) }
        return items.compactMap { it in
            guard let rid = it["receiptId"] as? String,
                  let ts = it["receiptTimestamp"] as? String,
                  let total = it["receiptTotalPrice"] as? Int else { return nil }
            let market = it["market"] as? [String: Any]
            return ReweReceipt(slotId: slotId, receiptId: rid, timestamp: ts, totalCents: total,
                               marketName: market?["name"] as? String,
                               marketCity: market?["city"] as? String,
                               cancelled: (it["cancelled"] as? Bool) ?? false,
                               items: [], parsed: false, fetchedAt: stamp)
        }
    }

    private static func fetchZip(cookieHeader: String, userAgent: String) async throws -> Data {
        var req = URLRequest(url: URL(string: zipURLString)!)
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        let (data, resp) = try await session().data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw REWEServiceError.zipFailed(code) }
        guard data.prefix(2).elementsEqual(Array("PK".utf8)) else { throw REWEServiceError.badZip }
        return data
    }
}
