import Foundation

// MARK: - API models

struct DiscoveredBank: Codable, Hashable, Sendable {
    let id: String?
    let displayName: String
    let logoId: String?
    let credentials: DiscoveredBankCredentials?
    let userIdLabel: String?
    let advice: String?
}

struct DiscoveredBankCredentials: Codable, Hashable, Sendable {
    let full: Bool
    let userId: Bool
    let none: Bool
}

struct BalancesResponse: Codable, Sendable {
    struct Balance: Codable, Sendable {
        let amount: String
        let currency: String
        let balanceType: String?
        let creditLimitIncluded: Bool?
    }

    let ok: Bool
    let booked: Balance?
    let expected: Balance?
    let session: String?
    let connectionData: String?
    let error: String?
    let userMessage: String?
    let scaRequired: Bool?
    /// Die Bank kennt das am Slot hinterlegte Konto nicht — die erteilte Zustimmung
    /// deckt ein anderes ab.
    ///
    /// Bis 05.09.2026 lieferte die App in diesem Fall den Saldo des erstbesten
    /// angebotenen Kontos, ohne die gespeicherte IBAN zu ändern. Ein Betrag unter dem
    /// falschen Kontonamen ist schlimmer als kein Betrag: Der Slot behauptete etwas
    /// über ein Konto, das die Bank gar nicht geliefert hatte.
    var kontoNichtInZustimmung: Bool? = nil
    /// Die Bank verlangt eine Freigabe, und der Abruf lief im Hintergrund — es wurde
    /// nichts geöffnet.
    ///
    /// Gemeldet am 01.10.2026: Bis dahin ging in diesem Fall ungefragt die Anmeldeseite
    /// der Bank auf, mehrmals täglich. Jetzt bleibt der Abruf stehen und sagt es hiermit;
    /// der Aufrufer merkt sich das Konto und hört auf, es von selbst zu versuchen.
    var freigabeNoetig: Bool? = nil
}

struct TransactionsResponse: Codable, Sendable {
    struct Amount: Codable, Hashable, Sendable {
        let currency: String
        let amount: String
    }

    struct Party: Codable, Hashable, Sendable {
        /// Auf zwei Wörter gekürzt — **Gruppierungsschlüssel**. Daran hängen Fixkosten,
        /// Abo-Erkennung, Zuordnungsregeln und die Ausschlüsse des Nutzers; ändert er
        /// sich, zerfallen bestehende Gruppen.
        let name: String?
        /// Wie die Bank ihn geliefert hat, ungekürzt — **nur zur Anzeige**.
        /// `nil` bei Buchungen, die vor der Einführung gespeichert wurden; dort bleibt
        /// nur der gekürzte Name, denn der volle war nie gespeichert.
        var fullName: String? = nil
        let iban: String?
        let bic: String?
    }

    struct Transaction: Codable, Hashable, Sendable {
        let bookingDate: String?
        let valueDate: String?
        let status: String?
        let endToEndId: String?
        let amount: Amount?
        let creditor: Party?
        let debtor: Party?
        let remittanceInformation: [String]?
        let additionalInformation: String?  // Buchungstext (z.B. "DAUERAUFTRAG")
        let purposeCode: String?            // Kategorie (z.B. "RINP")
        /// Buchungstyp der Bank in kompakter Schreibweise, z.B. `ISO:PMNT/ICDT/STDO`
        /// (Dauerauftrag) oder `GVC:52`. Kommt aus `bankTransactionCodes` der API und
        /// ist die einzige *belastbare* Auskunft darüber, ob eine Zahlung wiederkehrend
        /// ist — alles andere muss aus Beträgen und Abständen geraten werden.
        /// `nil` bei Buchungen, die vor Einführung des Feldes gespeichert wurden.
        var bankTransactionCode: String? = nil
        /// Bankseitige Referenzen aus dem SDK (`accountServicerReference`, `entryReference`,
        /// `transactionID`). Bis 2.0.3 wurden sie beim Mapping verworfen. Sie liegen jetzt
        /// in `raw_json`, gehen aber bewusst NICHT in den Fingerprint: Bei HBCI-Banken
        /// sind sie nicht durchgängig vorhanden und nicht stabil über pending→booked,
        /// und jede Änderung der Fingerprint-Formel verwaist Notizen, Anhänge und Flags.
        var accountServicerReference: String? = nil
        var entryReference: String? = nil
        var transactionId: String? = nil
        var category: String? = nil         // Local category label (e.g. "Essen & Alltag")
        var slotId: String? = nil           // Unified inbox: which bank slot this transaction belongs to

        /// Der Schlüssel, unter dem die Datenbank **diese** Zeile führt.
        ///
        /// Zwei gleiche Buchungen aus einem Abruf bekommen beim Speichern verschiedene
        /// Schlüssel (`fp` und `fp#2`, s. `TransactionsDatabase.upsert`). Berechnet man
        /// die Identität beim Anzeigen neu, kommt für beide derselbe Wert heraus — und
        /// die Anreicherungsspalten der zweiten Zeile sind unerreichbar: nicht schreibbar,
        /// nicht lesbar. Aus einem Audit, 29.09.2026.
        ///
        /// Bewusst **nicht** in `CodingKeys`: Der Wert gehört zur Zeile, nicht zur
        /// Buchung, und hat in `raw_json` nichts verloren. Gesetzt wird er an genau einer
        /// Stelle, `TransactionRecord.toTransaction()`.
        var dbTxId: String? = nil

        /// Alle Felder außer `dbTxId`. Ohne diese Liste würde der Schlüssel der Zeile in
        /// das gespeicherte JSON wandern.
        private enum CodingKeys: String, CodingKey {
            case bookingDate, valueDate, status, endToEndId, amount, creditor, debtor
            case remittanceInformation, additionalInformation, purposeCode
            case bankTransactionCode, accountServicerReference, entryReference, transactionId
            case category, slotId
        }
    }

    let ok: Bool?
    let transactions: [Transaction]?
    let session: String?
    let connectionData: String?
    let error: String?
    let userMessage: String?
    let scaRequired: Bool?
    /// Die Bank verlangt eine Freigabe, und der Abruf lief im Hintergrund — es wurde
    /// nichts geöffnet.
    ///
    /// Gemeldet am 01.10.2026: Bis dahin ging in diesem Fall ungefragt die Anmeldeseite
    /// der Bank auf, mehrmals täglich. Jetzt bleibt der Abruf stehen und sagt es hiermit;
    /// der Aufrufer merkt sich das Konto und hört auf, es von selbst zu versuchen.
    var freigabeNoetig: Bool? = nil
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
