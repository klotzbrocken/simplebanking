import Foundation

/// Parser for ISO 20022 camt.053 (Bank-to-Customer Statement).
///
/// Supports dialect variants 001.02 through 001.08+ by matching element *local names*
/// and ignoring XML namespace prefixes. Tested against DKB, Commerzbank, Sparkasse, ING,
/// and Comdirect exports.
///
/// Dedup: `<EndToEndId>` is mapped to `endToEndId` directly (primary dedup key).
/// Falls back to fingerprint (bookingDate + amount + party + memo) when not present.
enum Camt053Importer {

    @MainActor
    static func importFile(url: URL, slotId: String) throws -> ImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.parseFailed(error.localizedDescription)
        }
        let parsed = try parse(data: data)

        guard !parsed.transactions.isEmpty else {
            return ImportResult(
                inserted: 0, duplicates: 0,
                warnings: [localized(
                    "Keine Transaktionen in der CAMT-Datei gefunden.",
                    "No transactions found in the CAMT file.")]
                    + parsed.warnings)
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
            "CAMT: done total=\(parsed.transactions.count) inserted=\(inserted) duplicates=\(duplicates)",
            category: "Import")
        return ImportResult(inserted: inserted, duplicates: duplicates, warnings: parsed.warnings)
    }

    // MARK: - Parsing

    struct ParsedCAMT {
        let transactions: [TransactionsResponse.Transaction]
        let warnings: [String]
        let statementCurrency: String
    }

    static func parse(data: Data) throws -> ParsedCAMT {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        // XXE-Härtung: keine externen Entity-Definitionen (DTD-Refs, ENTITY-Tricks
        // wie billion-laughs). User-importierte Dateien sind low-risk, aber zero
        // ist besser als low — und der Performance-Cost ist null.
        parser.shouldResolveExternalEntities = false
        if !parser.parse() {
            if let err = parser.parserError {
                throw ImportError.parseFailed(err.localizedDescription)
            }
            throw ImportError.parseFailed(localized(
                "XML-Parsing fehlgeschlagen.", "XML parsing failed."))
        }
        return ParsedCAMT(
            transactions: delegate.transactions,
            warnings: delegate.warnings,
            statementCurrency: delegate.statementCurrency)
    }

    static func parse(xml: String) throws -> ParsedCAMT {
        guard let data = xml.data(using: .utf8) else {
            throw ImportError.parseFailed("UTF-8 encoding failed")
        }
        return try parse(data: data)
    }

    // MARK: - SAX Delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var transactions: [TransactionsResponse.Transaction] = []
        var warnings: [String] = []
        var statementCurrency: String = "EUR"

        private var pathStack: [String] = []
        private var textBuffer: String = ""
        private var currentNtry: NtryBuilder?
        private var currentAmtCcy: String?
        private var sawMultipleTxDtls: Bool = false

        struct NtryBuilder {
            var bookingDate: String?
            var valueDate: String?
            var amount: String?
            var amountCcy: String?
            var cdtDbtInd: String?
            var status: String?
            var endToEndId: String?
            var mandateId: String?
            var creditorName: String?
            var creditorIban: String?
            var debtorName: String?
            var debtorIban: String?
            var remittance: [String] = []
            var purposeCode: String?
            var additionalInfo: String?
            var acctSvcrRef: String?
            var txDtlsCount: Int = 0
        }

        // Local name = strip any `ns:` prefix
        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = local(elementName)
            pathStack.append(name)
            textBuffer = ""

            switch name {
            case "Ntry":
                currentNtry = NtryBuilder()
            case "Amt":
                currentAmtCcy = attributeDict["Ccy"] ?? attributeDict["ccy"]
                if currentNtry != nil && parentElement() == "Ntry" {
                    currentNtry?.amountCcy = currentAmtCcy
                }
            case "TxDtls":
                if var b = currentNtry {
                    b.txDtlsCount += 1
                    if b.txDtlsCount > 1 { sawMultipleTxDtls = true }
                    currentNtry = b
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = local(elementName)
            let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

            // Statement-level currency (Acct/Ccy, NOT inside Ntry)
            if name == "Ccy", !isInside("Ntry"), !text.isEmpty {
                statementCurrency = text
            }

            if var b = currentNtry {
                switch name {
                case "Amt" where parentElement() == "Ntry":
                    b.amount = text
                case "CdtDbtInd" where parentElement() == "Ntry":
                    b.cdtDbtInd = text
                case "Sts" where parentElement() == "Ntry":
                    b.status = text
                case "Dt":
                    if isInside("BookgDt") { b.bookingDate = text }
                    else if isInside("ValDt") { b.valueDate = text }
                case "EndToEndId" where b.txDtlsCount <= 1:
                    b.endToEndId = text
                case "MndtId" where b.txDtlsCount <= 1:
                    b.mandateId = text
                case "Nm":
                    // Only the first TxDtls counts (MVP); ignore counterparties of nested batches.
                    if b.txDtlsCount <= 1 {
                        if isInside("Cdtr"), !isInside("CdtrAcct"), !isInside("UltmtCdtr") {
                            b.creditorName = text
                        } else if isInside("Dbtr"), !isInside("DbtrAcct"), !isInside("UltmtDbtr") {
                            b.debtorName = text
                        }
                    }
                case "IBAN":
                    if b.txDtlsCount <= 1 {
                        if isInside("CdtrAcct") { b.creditorIban = text }
                        else if isInside("DbtrAcct") { b.debtorIban = text }
                    }
                case "Ustrd" where b.txDtlsCount <= 1:
                    if !text.isEmpty { b.remittance.append(text) }
                case "Cd" where isInside("Purp"):
                    if b.txDtlsCount <= 1 { b.purposeCode = text }
                case "AddtlNtryInf":
                    b.additionalInfo = text
                case "AcctSvcrRef" where parentElement() == "Ntry":
                    b.acctSvcrRef = text
                case "Ntry":
                    currentNtry = b
                    finalizeCurrentNtry()
                    pathStack.removeLast()
                    textBuffer = ""
                    return
                default: break
                }
                currentNtry = b
            }

            pathStack.removeLast()
            textBuffer = ""
        }

        // MARK: finalize

        private func finalizeCurrentNtry() {
            guard let b = currentNtry else { return }
            currentNtry = nil

            guard let bookingDate = b.bookingDate else {
                warnings.append("Ntry ohne BookgDt/Dt — übersprungen.")
                return
            }
            guard let amountRaw = b.amount, let amountValue = Double(amountRaw) else {
                warnings.append("Ntry ohne parseable Amt — übersprungen.")
                return
            }

            let ind = (b.cdtDbtInd ?? "").uppercased()
            let isDebit = (ind == "DBIT")
            let signedAmount = isDebit ? -abs(amountValue) : abs(amountValue)
            let amountStr = String(format: "%.2f", signedAmount)

            let currency = b.amountCcy ?? statementCurrency

            let creditor = TransactionsResponse.Party(
                name: b.creditorName, iban: b.creditorIban, bic: nil)
            let debtor = TransactionsResponse.Party(
                name: b.debtorName, iban: b.debtorIban, bic: nil)

            // DBIT: user paid → counterparty is creditor; CRDT: user received → counterparty is debtor
            let includeCreditor = isDebit && (b.creditorName != nil || b.creditorIban != nil)
            let includeDebtor = !isDebit && (b.debtorName != nil || b.debtorIban != nil)

            let status: String
            switch (b.status ?? "").uppercased() {
            case "BOOK": status = "Booked"
            case "PDNG": status = "Pending"
            case "INFO": status = "Information"
            default: status = "Booked"
            }

            let tx = TransactionsResponse.Transaction(
                bookingDate: bookingDate,
                valueDate: b.valueDate,
                status: status,
                endToEndId: b.endToEndId,
                amount: TransactionsResponse.Amount(currency: currency, amount: amountStr),
                creditor: includeCreditor ? creditor : nil,
                debtor: includeDebtor ? debtor : nil,
                remittanceInformation: b.remittance.isEmpty ? nil : b.remittance,
                additionalInformation: b.additionalInfo,
                purposeCode: b.purposeCode
            )
            transactions.append(tx)
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            if sawMultipleTxDtls {
                warnings.append(localized(
                    "Einige Einträge enthalten Batch-Buchungen. Nur die erste Teilbuchung wurde importiert.",
                    "Some entries contain batch bookings. Only the first sub-entry was imported."))
            }
        }

        // MARK: path helpers

        private func parentElement() -> String? {
            pathStack.count >= 2 ? pathStack[pathStack.count - 2] : nil
        }

        private func isInside(_ element: String) -> Bool {
            pathStack.contains(element)
        }
    }

    // MARK: - i18n

    private static func localized(_ de: String, _ en: String) -> String {
        (Locale.current.language.languageCode?.identifier == "de") ? de : en
    }
}
