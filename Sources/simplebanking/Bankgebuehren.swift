import Foundation

// MARK: - Was die Bank selbst abbucht
//
// Kontoführung, Buchungsposten, Rechnungsabschluss: Die Bank belastet das eigene Konto,
// und weil sie dabei ihr eigener Empfänger ist, steht in den Daten **kein Empfängername**.
// Am echten Bestand nachgesehen sieht so eine Buchung aus:
//
//     2026-07-31   -10,99   Empfänger: —   „Entgeltabrechnung siehe Anlage"
//
// Ein Abgleich gegen den Banknamen — der naheliegende Gedanke — hätte davon nichts
// gefunden. Der Verwendungszweck trägt das Signal, das leere Empfängerfeld bestätigt es.
//
// **Die Zahl landet unter dem Kontostand, also wird hier nicht geraten.** Ein
// Empfängername, der nichts mit der Bank zu tun hat, schließt die Buchung aus: „Mahngebühr
// Stadtwerke" ist eine Rechnung, keine Kontoführung.
enum Bankgebuehren {

    /// Anzeigename und zugleich Gruppenschlüssel in der Fixkosten-Auswertung.
    static let bezeichnung = "Bankgebühren"

    /// Wörter, mit denen deutsche Banken ihre eigenen Entgelte buchen.
    static let marker = [
        "entgeltabrechnung", "entgelt", "kontoführung", "kontofuehrung",
        "kontopreis", "grundpreis", "buchungsposten", "rechnungsabschluss",
        "kontogebühr", "kontogebuehr"
    ]

    /// Wörter, die eine Gebühr *einer anderen Stelle* bezeichnen — die gehört nicht hierher.
    static let fremdeGebuehren = ["mahngebühr", "mahngebuehr", "stornogebühr", "stornogebuehr",
                                  "versandkosten", "bearbeitungsgebühr", "bearbeitungsgebuehr"]

    /// Ist die Buchung ein Entgelt der kontoführenden Bank?
    ///
    /// - Parameter bankname: Anzeigename des Kontos. Steht ein Empfänger in der Buchung,
    ///   muss er dazu passen — sonst ist es die Rechnung eines Dritten.
    static func istGebuehr(_ tx: TransactionsResponse.Transaction, bankname: String? = nil) -> Bool {
        guard let betrag = Double(tx.amount?.amount ?? ""), betrag < 0 else { return false }

        let text = ((tx.remittanceInformation ?? []).joined(separator: " ") + " "
                    + (tx.additionalInformation ?? "")).lowercased()
        guard !text.isEmpty else { return false }
        guard !fremdeGebuehren.contains(where: { text.contains($0) }) else { return false }
        guard marker.contains(where: { text.contains($0) }) else { return false }

        // Kein Empfänger: Die Bank bucht bei sich selbst — das ist der Normalfall.
        let empfaenger = (tx.creditor?.name ?? "").trimmingCharacters(in: .whitespaces)
        if empfaenger.isEmpty { return true }

        // Steht doch einer da, muss er zur Bank gehören.
        guard let bankname, !bankname.isEmpty else { return false }
        return passtZurBank(empfaenger, bankname: bankname)
    }

    /// Grober Namensabgleich: „Sparkasse Siegen" gegen „SPARKASSE SIEGEN AG" o. ä.
    static func passtZurBank(_ empfaenger: String, bankname: String) -> Bool {
        let a = Set(zerlegen(empfaenger)), b = Set(zerlegen(bankname))
        guard !a.isEmpty, !b.isEmpty else { return false }
        return !a.intersection(b).isEmpty
    }

    private static func zerlegen(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 4 && !["bank", "gmbh", "aktiengesellschaft"].contains($0) }
    }

    /// Wie viele gleichartige Belastungen es mindestens braucht.
    ///
    /// Drei, nicht zwei: Zwei Buchungen können ein Zufall sein, und eine erfundene
    /// Monatsgebühr unter dem Saldo wäre schlimmer als gar keine Angabe.
    static let mindestens = 3
}
