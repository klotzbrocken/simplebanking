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

    /// Buchungscode der Bank für Entgelte. `SWIFT:CHG` steht für *Charges* — die Bank
    /// sagt damit selbst, dass es eine Gebühr ist. Das ist die belastbarste Auskunft, die
    /// es hier gibt; im echten Bestand steht `SWIFT:CHG;GVC:809`.
    static let swiftGebuehr = "CHG"
    static let germanGebuehrenGVCs: Set<String> = ["808", "809", "810", "888"]

    static func istGebuehrLautCode(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        for teil in code.uppercased().split(separator: ";") {
            if teil.hasPrefix("SWIFT:"), String(teil.dropFirst(6)) == swiftGebuehr { return true }
            if teil.hasPrefix("GVC:"), germanGebuehrenGVCs.contains(String(teil.dropFirst(4))) { return true }
        }
        return false
    }

    /// Ist die Buchung ein Entgelt der kontoführenden Bank?
    ///
    /// - Parameter bankname: Anzeigename des Kontos. Steht ein Empfänger in der Buchung,
    ///   muss er dazu passen — sonst ist es die Rechnung eines Dritten.
    static func istGebuehr(_ tx: TransactionsResponse.Transaction, bankname: String? = nil) -> Bool {
        // `AmountParser`, nicht `Double(...)`: Die Bank liefert „-10,99" mit Komma, und
        // `Double` gibt darauf nil zurück. Daran fiel die erste Fassung durch — an jeder
        // einzelnen echten Buchung, während die Tests mit Punkt geschrieben grün blieben.
        guard tx.parsedAmount < 0 else { return false }

        let text = ((tx.remittanceInformation ?? []).joined(separator: " ") + " "
                    + (tx.additionalInformation ?? "")).lowercased()
        guard !text.isEmpty else { return false }
        guard !fremdeGebuehren.contains(where: { text.contains($0) }) else { return false }
        // Code der Bank zuerst — er ist eindeutig. Der Text ist der Rückfall für Banken,
        // die keinen liefern.
        guard istGebuehrLautCode(tx.bankTransactionCode)
                || marker.contains(where: { text.contains($0) }) else { return false }

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
    /// **Zwei, nicht drei.** Drei war der erste Entwurf und in der Praxis unerreichbar:
    /// Die Listen zeigen 60 Tage, und darin liegen von einer Monatsgebühr höchstens zwei
    /// Buchungen. Die Sicherung steckt stattdessen in `giltAlsWiederkehrend` — gleicher
    /// Betrag und regelmäßiger Abstand sind ein stärkerer Beleg als drei beliebige Treffer.
    static let mindestens = 2

    /// Trägt die Gruppe genug Beleg, um als laufende Gebühr zu gelten?
    ///
    /// Verlangt wird: mindestens zwei Belastungen, **derselbe Betrag** auf den Cent, und
    /// ein Abstand, der zu einem Rhythmus passt (monatlich bis quartalsweise). Zwei
    /// zufällig gleich benannte Buchungen aus derselben Woche fallen damit heraus.
    static func giltAlsWiederkehrend(_ buchungen: [TransactionsResponse.Transaction]) -> Bool {
        guard buchungen.count >= mindestens else { return false }

        let betraege = buchungen.map { abs($0.parsedAmount) }
        guard let erster = betraege.first,
              betraege.allSatisfy({ abs($0 - erster) < 0.01 }) else { return false }

        let tage = buchungen
            .compactMap { $0.bookingDate ?? $0.valueDate }
            .compactMap { parser.date(from: String($0.prefix(10))) }
            .sorted()
        guard tage.count == buchungen.count else { return false }

        let kalender = Calendar(identifier: .gregorian)
        for (frueher, spaeter) in zip(tage, tage.dropFirst()) {
            let abstand = kalender.dateComponents([.day], from: frueher, to: spaeter).day ?? 0
            guard (20...100).contains(abstand) else { return false }
        }
        return true
    }

    /// Der wiederkehrende Betrag der Bankgebühr — oder `nil`.
    ///
    /// `nil` heißt: **Zeile weglassen.** Es gibt Konten ohne Gebühren, und „Bankgebühren
    /// 0,00 €" wäre dort keine Information, sondern eine Behauptung.
    static func betrag(aus buchungen: [TransactionsResponse.Transaction],
                       bankname: String? = nil) -> Double? {
        let gebuehren = buchungen.filter { istGebuehr($0, bankname: bankname) }
        guard giltAlsWiederkehrend(gebuehren) else { return nil }
        let summe = gebuehren.map { abs($0.parsedAmount) }.reduce(0, +)
        return summe / Double(gebuehren.count)
    }

    nonisolated(unsafe) private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
