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

    static func isStandingOrder(_ transaction: TransactionsResponse.Transaction) -> Bool {
        isStandingOrder(text: transaction.additionalInformation)
    }

    /// `true`, wenn IRGENDEINE Buchung der Gruppe als Dauerauftrag gebucht wurde.
    /// Eine Gruppe kann gemischt sein (z.B. erste Zahlung manuell überwiesen,
    /// danach Dauerauftrag eingerichtet) — ein Treffer genügt.
    static func containsStandingOrder(_ transactions: [TransactionsResponse.Transaction]) -> Bool {
        transactions.contains(where: isStandingOrder)
    }
}
