import Foundation

/// Buchungstyp-Signale, die die **Bank** mitliefert — im Gegensatz zu allem, was
/// die App aus Beträgen und Datumsabständen erraten muss.
///
/// Ein Dauerauftrag ist per Definition wiederkehrend. Wenn die Bank das sagt, ist
/// das eine ungleich bessere Auskunft als jede Heuristik: Miete, Sparrate oder
/// Vereinsbeitrag brauchen dann keine zwei Beobachtungen mehr, um als
/// wiederkehrend zu gelten.
enum BookingType {

    /// Marker deutscher und internationaler Banken im Buchungstext.
    /// `DAUERAUFTR` deckt „DAUERAUFTRAG", „DAUERAUFTR." und
    /// „DAUERAUFTRAGSGUTSCHRIFT" mit ab (Treffer am Wortanfang).
    static let standingOrderMarkers = ["DAUERAUFTR", "STANDING ORDER", "DAUERBUCHUNG"]

    /// Erkennt einen Dauerauftrag am **Buchungstext der Bank**.
    ///
    /// Bewusst NUR `additionalInformation` (das von der Bank erzeugte
    /// `bankTransactionCode`-Klartextfeld), **nicht** `remittanceInformation`:
    /// der Verwendungszweck wird vom Zahler frei getippt, und „Kündigung
    /// Dauerauftrag" als Zweck einer einmaligen Überweisung würde sonst als
    /// Dauerauftrag zählen.
    static func isStandingOrder(text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let upper = text.uppercased()
        return standingOrderMarkers.contains { WordMatch.atWordStart(upper, $0) }
    }

    /// ISO-20022-SubFamily für Dauerauftrag — gilt für ausgehende (`ICDT`) wie
    /// eingehende (`RCDT`) Zahlungen.
    static let isoStandingOrderSubFamily = "STDO"
    /// Deutsche Geschäftsvorfallcodes für Daueraufträge: 52 (Belastung),
    /// 152 (Gutschrift).
    static let germanStandingOrderGVCs: Set<String> = ["52", "052", "152"]

    /// Wertet den **Buchungstyp-Code** der Bank aus (`bankTransactionCodes`).
    ///
    /// Das ist die belastbarste Auskunft überhaupt: sie kommt aus dem
    /// Buchungssystem der Bank und ist im Gegensatz zum Buchungstext nicht
    /// sprach- oder institutsabhängig formuliert.
    static func isStandingOrder(code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        for part in code.uppercased().split(separator: ";") {
            if part.hasPrefix("ISO:"),
               part.split(separator: "/").last.map(String.init) == isoStandingOrderSubFamily {
                return true
            }
            if part.hasPrefix("GVC:"),
               germanStandingOrderGVCs.contains(String(part.dropFirst(4))) {
                return true
            }
        }
        return false
    }

    /// Code zuerst (eindeutig), Buchungstext als Rückfall für Banken, die keine
    /// Codes liefern.
    static func isStandingOrder(_ transaction: TransactionsResponse.Transaction) -> Bool {
        isStandingOrder(code: transaction.bankTransactionCode)
            || isStandingOrder(text: transaction.additionalInformation)
    }

    /// `true`, wenn IRGENDEINE Buchung der Gruppe als Dauerauftrag gebucht wurde.
    /// Eine Gruppe kann gemischt sein (z.B. erste Zahlung manuell überwiesen,
    /// danach Dauerauftrag eingerichtet) — ein Treffer genügt.
    static func containsStandingOrder(_ transactions: [TransactionsResponse.Transaction]) -> Bool {
        transactions.contains(where: isStandingOrder)
    }
}
