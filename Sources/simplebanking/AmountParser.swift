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

}

extension TransactionsResponse.Transaction {
    var parsedAmount: Double {
        AmountParser.parse(amount?.amount)
    }

    /// Identität einer Buchung für Anzeige und Export.
    ///
    /// Zuerst der Schlüssel der Datenbankzeile: Er ist der einzige Wert, der zwei gleiche
    /// Buchungen auseinanderhält (`fp` und `fp#2`). Die End-to-End-ID der Bank kann das
    /// nicht — sie ist oft leer, und Sentinels wie `NOTPROVIDED` wären für alle Zeilen
    /// gleich. Aus einem Audit, 29.09.2026: Kollisionen trafen die Zeilenidentität in der
    /// Liste, die `FITID` im OFX-Export und — am schwersten — den Speicherschlüssel der
    /// Sparmarken.
    ///
    /// Der Rückfall darunter bleibt unverändert, für Buchungen, die noch nicht aus der
    /// Datenbank kommen (frischer Abruf, Vorschau, Tests).
    var stableIdentifier: String {
        if let dbTxId, !dbTxId.isEmpty {
            return dbTxId
        }
        return stableIdentifierAusBankdaten
    }

    /// Die Identität, wie sie bis 2.0.7 galt — allein aus dem, was die Bank liefert.
    ///
    /// Sie bleibt erreichbar, weil unter ihr etwas gespeichert ist: Sparmarken hängen an
    /// diesem Wert. Ohne einen Lese-Rückfall wären alle Marken mit dem Umstieg verloren
    /// gewesen — kein Datenverlust im engeren Sinn, aber genau die Art stiller
    /// Verschlechterung, die niemand meldet und jeder merkt.
    var stableIdentifierAusBankdaten: String {
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
