import Foundation

enum AmountParser {
    /// Parses amounts in German ("1.200,50"), English ("1200.50"), or plain integer format.
    static func parse(_ raw: String?) -> Double {
        guard let raw, !raw.isEmpty else { return 0 }

        if raw.contains(",") {
            let clean = raw
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
            return Double(clean) ?? 0
        }

        return Double(raw) ?? 0
    }

    /// Parses formatted display values like "1.234,56 €", "-120,00 €", "--,-- €".
    /// Returns nil when value is unavailable or not parseable.
    static func parseCurrencyDisplayOrNil(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Common placeholders for "no value".
        if trimmed.contains("--") {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "0123456789,.-")
        let filtered = trimmed.components(separatedBy: allowed.inverted).joined()
        guard !filtered.isEmpty else { return nil }

        if filtered.contains(",") {
            let normalized = filtered
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
            return Double(normalized)
        }

        return Double(filtered)
    }

    /// Same as parseCurrencyDisplayOrNil but falls back to 0.
    static func parseCurrencyDisplay(_ raw: String?) -> Double {
        parseCurrencyDisplayOrNil(raw) ?? 0
    }
}

extension TransactionsResponse.Transaction {
    var parsedAmount: Double {
        AmountParser.parse(amount?.amount)
    }

    var stableIdentifier: String {
        let trimmedID = endToEndId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedID.isEmpty {
            return trimmedID
        }

        let booking = bookingDate ?? valueDate ?? ""
        let amountValue = amount?.amount ?? ""
        let creditorName = creditor?.name ?? ""
        let debtorName = debtor?.name ?? ""
        let remittance = (remittanceInformation ?? []).joined(separator: "|")
        return "\(booking)|\(amountValue)|\(creditorName)|\(debtorName)|\(remittance)"
    }
}
