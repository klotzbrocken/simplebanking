import XCTest
@testable import simplebanking

/// Die „Verfügbar"-Zeile unter dem Saldo (2.2.1).
///
/// Anlass (13.11.2026, YAXI-Support): Die ING-Schnittstelle liefert **nur**
/// `interimBooked`. Die ING-App zeigt dagegen den Stand abzüglich bereits vorgemerkter
/// Abbuchungen — 489,71 statt 505,21 bei 15,50 vorgemerkt. YAXI kann die 489,71 nicht
/// liefern („kriegen wir da leider nicht über die API"); wer sie sehen will, muss
/// rechnen. Die Rechnung gab es schon, nur wurde ihr Ergebnis nirgends gezeigt.
final class VerfuegbarerSaldoTests: XCTestCase {

    private func buchung(_ betrag: Double, status: String = "pending")
        -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: "2026-11-13", valueDate: "2026-11-13", status: status,
            endToEndId: nil,
            amount: TransactionsResponse.Amount(currency: "EUR",
                                                amount: String(format: "%.2f", betrag)),
            creditor: nil, debtor: nil,
            remittanceInformation: nil, additionalInformation: nil, purposeCode: nil
        )
    }

    /// Der gemeldete Fall, mit seinen echten Zahlen.
    func testDerIngFall() {
        let verfuegbar = AvailableBalance.compute(adjustedBooked: 505.21,
                                                  pendingTx: [buchung(-15.50)])
        XCTAssertEqual(verfuegbar, 489.71, accuracy: 0.005)
    }

    func testVorgemerkteEingaengeZaehlenNicht() {
        // Ein erwarteter Eingang ist nicht zugesagt und darf die Zahl nicht aufblähen —
        // dieselbe Strenge wie bei der Bank. Nur die Lastschrift zieht ab.
        let verfuegbar = AvailableBalance.compute(adjustedBooked: 100,
                                                  pendingTx: [buchung(-10), buchung(250)])
        XCTAssertEqual(verfuegbar, 90, accuracy: 0.005)
    }

    func testGebuchteBuchungenZaehlenNicht() {
        // Was gebucht ist, steckt schon im Saldo. Es ein zweites Mal abzuziehen wäre
        // genau der Fehler, den diese Zeile vermeiden soll.
        let verfuegbar = AvailableBalance.compute(adjustedBooked: 100,
                                                  pendingTx: [buchung(-10, status: "booked")])
        XCTAssertEqual(verfuegbar, 100, accuracy: 0.005)
    }

    func testOhneVormerkungGibtEsNichtsZuZeigen() {
        // Die Oberfläche entscheidet daran, ob die Position überhaupt erscheint: Ohne
        // Vormerkung stünde dieselbe Zahl zweimal untereinander.
        XCTAssertEqual(AvailableBalance.pendingDebitSum([buchung(50)]), 0, accuracy: 0.005)
        XCTAssertEqual(AvailableBalance.pendingDebitSum([]), 0, accuracy: 0.005)
    }

    func testMehrereVormerkungenSummierenSich() {
        let verfuegbar = AvailableBalance.compute(
            adjustedBooked: 1000, pendingTx: [buchung(-15.50), buchung(-4.49), buchung(-80)])
        XCTAssertEqual(verfuegbar, 900.01, accuracy: 0.005)
    }
}
