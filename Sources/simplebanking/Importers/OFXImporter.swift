import Foundation

/// Parser for Open Financial Exchange files (OFX 1.x SGML and OFX 2.x XML).
///
/// Extracts `<STMTTRN>` entries and maps them to `TransactionsResponse.Transaction`.
/// Upsert dedupes naturally via `TransactionRecord.fingerprint` — we deliberately
/// do NOT put `<FITID>` into `endToEndId`, because banks often generate different
/// endToEndIds for the same booking across OFX / PSD2 APIs.
enum OFXImporter {

    /// Parse + upsert an OFX file for the given slot.
    @MainActor
    static func importFile(url: URL, slotId: String) throws -> ImportResult {
        let content = try readFileRobust(url: url)
        let parsed = try parse(ofx: content)

        guard !parsed.transactions.isEmpty else {
            return ImportResult(inserted: 0, duplicates: 0,
                                warnings: [localized(
                                    "Keine Transaktionen in der Datei gefunden.",
                                    "No transactions found in file.")])
        }

        let prevDbSlot = TransactionsDatabase.activeSlotId
        TransactionsDatabase.activeSlotId = slotId
        defer { TransactionsDatabase.activeSlotId = prevDbSlot }

        let countBefore = (try? TransactionsDatabase.loadTransactions(days: 3650).count) ?? 0
        do {
            try TransactionsDatabase.upsert(transactions: parsed.transactions)
        } catch {
            throw ImportError.databaseFailed(error.localizedDescription)
        }
        let countAfter = (try? TransactionsDatabase.loadTransactions(days: 3650).count) ?? countBefore
        let inserted = max(0, countAfter - countBefore)
        let duplicates = max(0, parsed.transactions.count - inserted)

        AppLogger.log(
            "OFX: done total=\(parsed.transactions.count) inserted=\(inserted) duplicates=\(duplicates)",
            category: "Import")
        return ImportResult(inserted: inserted, duplicates: duplicates, warnings: parsed.warnings)
    }

    // MARK: - Parsing (exposed internal for tests)

    struct ParsedOFX {
        let transactions: [TransactionsResponse.Transaction]
        let warnings: [String]
        let currency: String
    }

    static func parse(ofx content: String) throws -> ParsedOFX {
        let currency = extractValue(tag: "CURDEF", in: content) ?? "EUR"
        let blocks = extractTransactionBlocks(in: content)

        var transactions: [TransactionsResponse.Transaction] = []
        var warnings: [String] = []

        for (index, block) in blocks.enumerated() {
            guard let tx = parseTransaction(from: block, currency: currency) else {
                warnings.append(localized(
                    "Block #\(index + 1) konnte nicht gelesen werden.",
                    "Block #\(index + 1) could not be parsed."))
                continue
            }
            transactions.append(tx)
        }

        return ParsedOFX(transactions: transactions, warnings: warnings, currency: currency)
    }

    // MARK: - Block extraction

    /// Find all `<STMTTRN>` blocks. Handles both SGML (unclosed) and XML (`</STMTTRN>`) variants.
    private static func extractTransactionBlocks(in content: String) -> [String] {
        let marker = "<STMTTRN>"
        let closer = "</STMTTRN>"
        var blocks: [String] = []
        var cursor = content.startIndex

        while let start = content.range(of: marker, range: cursor..<content.endIndex) {
            let blockStart = start.upperBound
            let blockEnd: String.Index
            if let close = content.range(of: closer, range: blockStart..<content.endIndex) {
                // Next STMTTRN could come before the close tag in malformed files — take min.
                if let nextStart = content.range(of: marker, range: blockStart..<content.endIndex),
                   nextStart.lowerBound < close.lowerBound {
                    blockEnd = nextStart.lowerBound
                } else {
                    blockEnd = close.lowerBound
                }
            } else if let nextStart = content.range(of: marker, range: blockStart..<content.endIndex) {
                blockEnd = nextStart.lowerBound
            } else {
                blockEnd = content.endIndex
            }
            blocks.append(String(content[blockStart..<blockEnd]))
            cursor = blockEnd
        }
        return blocks
    }

    // MARK: - Field extraction

    private static func parseTransaction(from block: String, currency: String) -> TransactionsResponse.Transaction? {
        let trnType = extractValue(tag: "TRNTYPE", in: block)
        guard let dtPostedRaw = extractValue(tag: "DTPOSTED", in: block),
              let bookingDate = parseDate(dtPostedRaw) else {
            return nil
        }
        let valueDate = extractValue(tag: "DTUSER", in: block).flatMap(parseDate)

        guard let trnAmtRaw = extractValue(tag: "TRNAMT", in: block) else { return nil }
        let amountString = normalizeAmount(trnAmtRaw)
        guard let amountValue = Double(amountString) else { return nil }

        let name = extractValue(tag: "NAME", in: block)
        let memo = extractValue(tag: "MEMO", in: block)
        let bankAcctIban = extractValue(tag: "ACCTID", in: findNestedBlock(tag: "BANKACCTTO", in: block) ?? "")

        // Sign convention: TRNAMT is already signed for German banks; TRNTYPE=DEBIT
        // with positive amount still means money out. Normalize both.
        let isDebit: Bool
        if amountValue < 0 {
            isDebit = true
        } else if let t = trnType?.uppercased(), t == "DEBIT" || t == "POS" || t == "CHECK" || t == "PAYMENT" {
            isDebit = true
        } else {
            isDebit = false
        }
        let signedAmount = isDebit ? -abs(amountValue) : abs(amountValue)
        let amountStr = formatAmount(signedAmount)

        let party = TransactionsResponse.Party(name: name, iban: bankAcctIban, bic: nil)
        let remittance: [String]? = memo.map { [$0] }

        return TransactionsResponse.Transaction(
            bookingDate: bookingDate,
            valueDate: valueDate,
            status: "Booked",
            endToEndId: nil, // intentionally nil — see header comment
            amount: TransactionsResponse.Amount(currency: currency, amount: amountStr),
            creditor: isDebit ? party : nil,
            debtor: isDebit ? nil : party,
            remittanceInformation: remittance,
            additionalInformation: trnType,
            purposeCode: nil
        )
    }

    // MARK: - Helpers

    /// Regex-extract `<TAG>value` up to next `<` or newline.
    /// Handles both SGML (unclosed tags) and XML (`</TAG>`) variants.
    static func extractValue(tag: String, in content: String) -> String? {
        let pattern = "<\(tag)>([^<\\r\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges >= 2 else { return nil }
        let captured = ns.substring(with: match.range(at: 1))
        return captured.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Find the inner content of `<TAG>…</TAG>` or `<TAG>…<next-sibling>`.
    private static func findNestedBlock(tag: String, in content: String) -> String? {
        let openMarker = "<\(tag)>"
        let closeMarker = "</\(tag)>"
        guard let start = content.range(of: openMarker) else { return nil }
        let blockStart = start.upperBound
        if let close = content.range(of: closeMarker, range: blockStart..<content.endIndex) {
            return String(content[blockStart..<close.lowerBound])
        }
        return String(content[blockStart..<content.endIndex])
    }

    /// Parse OFX date: `YYYYMMDD[HHMMSS[.FFF][TZ]]` → `YYYY-MM-DD`.
    static func parseDate(_ raw: String) -> String? {
        let digits = raw.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let y = String(digits.prefix(4))
        let m = String(digits.dropFirst(4).prefix(2))
        let d = String(digits.dropFirst(6).prefix(2))
        return "\(y)-\(m)-\(d)"
    }

    /// Normalize "1.234,56" (EU) → "1234.56" (decimal). Trim trailing spaces.
    private static func normalizeAmount(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // If comma present and dot is thousand-separator: DKB-OFX uses "." as decimal, but
        // some tools emit "1.234,56" — swap if we detect that pattern (comma after dot).
        if let lastComma = s.lastIndex(of: ","),
           let lastDot = s.lastIndex(of: "."),
           lastComma > lastDot {
            s = s.replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
        } else {
            s = s.replacingOccurrences(of: ",", with: ".")
        }
        return s
    }

    /// Format a signed `Double` as `-1234.56` (two decimals).
    private static func formatAmount(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - File reading

    /// Read an OFX file. OFX 1.x SGML deklariert die Encoding im plain-text-Header
    /// (z.B. `CHARSET:1252`) — wenn vorhanden, nutzen wir die. Sonst Fallback auf
    /// UTF-8 → ISO-8859-1.
    ///
    /// Hintergrund: Sparkasse exportiert oft Windows-1252 (CP1252). Ohne Header-
    /// Erkennung wäre der UTF-8-Try fail (gut), aber der Latin-1-Fallback würde
    /// das €-Zeichen (0x80 in CP1252, control char in Latin-1) falsch dekodieren.
    private static func readFileRobust(url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.parseFailed(error.localizedDescription)
        }

        // 1. Header-deklarierte Encoding bevorzugen
        if let declared = detectOFXHeaderEncoding(in: data),
           let s = String(data: data, encoding: declared) {
            return s
        }

        // 2. Fallback: UTF-8 → ISO-8859-1
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw ImportError.parseFailed(localized(
            "Datei-Kodierung wird nicht unterstützt (UTF-8, ISO-8859-1 oder Windows-1252 erwartet).",
            "Unsupported file encoding (UTF-8, ISO-8859-1, or Windows-1252 expected)."))
    }

    /// Liest die ersten ~1 KB der Datei als ASCII und sucht nach `CHARSET:`-Zeile
    /// im OFX-1.x-SGML-Header. Pure function — getestet in OFXImporterTests.
    /// Internal für Tests.
    static func detectOFXHeaderEncoding(in data: Data) -> String.Encoding? {
        let probe = data.prefix(1024)
        guard let header = String(data: probe, encoding: .ascii) else { return nil }
        // Header-Zeilen sind ASCII-only — typisch erste 9-15 Zeilen vor `<OFX>`.
        for line in header.split(separator: "\n").prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard trimmed.hasPrefix("CHARSET:") else { continue }
            let value = String(trimmed.dropFirst("CHARSET:".count))
                .trimmingCharacters(in: .whitespaces)
            switch value {
            case "1252", "WINDOWS-1252", "CP1252":
                return .windowsCP1252
            case "ISO-8859-1", "ISO8859-1", "LATIN1", "LATIN-1":
                return .isoLatin1
            case "UTF-8", "UTF8":
                return .utf8
            case "NONE", "USASCII", "US-ASCII", "ASCII":
                return .ascii
            default:
                return nil  // unbekannter Wert → Fallback-Logik nutzen
            }
        }
        return nil
    }

    // MARK: - i18n

    private static func localized(_ de: String, _ en: String) -> String {
        (Locale.current.language.languageCode?.identifier == "de") ? de : en
    }
}
