import XCTest
@testable import simplebanking

/// Die zweite Hälfte des am 01.10.2026 gemeldeten Fehlers, siehe `DurchlaufpostenTests`.
///
/// Die Betragsprüfung ist `max |x − Mittel| / Mittel < Schranke`. Für **zwei** Werte ist
/// das identisch mit |a−b|/(a+b) — und die bisherige Schranke 0,35 ließ damit einen
/// **Faktor 2,08** zwischen beiden Beträgen durchgehen. 350,00 € und 609,59 € ergeben
/// 0,27 und galten als „konsistent".
///
/// Zwei Beträge sind der Mindestfall der Erkennung. Dort muss die Gleichheit der Beträge
/// die Regelmäßigkeit tragen, weil sonst nichts sie trägt.
final class ErkennungBeiZweiBuchungenTests: XCTestCase {

    private func buchung(_ datum: String, _ betrag: Double,
                         empfaenger: String) -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: datum, valueDate: datum, status: "booked", endToEndId: nil,
            amount: TransactionsResponse.Amount(currency: "EUR",
                                                amount: String(format: "%.2f", -betrag)),
            creditor: TransactionsResponse.Party(name: empfaenger, iban: "DE02120300000000202051", bic: nil),
            debtor: nil, remittanceInformation: ["Zahlung"],
            additionalInformation: nil, purposeCode: nil)
    }

    private func erkannt(_ a: Double, _ b: Double, name: String = "Irgendwer") -> [RecurringPayment] {
        FixedCostsAnalyzer.analyze(transactions: [buchung("2026-08-09", a, empfaenger: name),
                                                  buchung("2026-09-09", b, empfaenger: name)])
    }

    // MARK: - Was nicht mehr durchgeht

    /// Faktor 1,74. Ohne die PayPal-Regel wäre genau das der Posten über 479,80 € gewesen.
    func test_faktorFast2_giltNichtMehrAlsRegelmaessig() {
        XCTAssertTrue(erkannt(350.00, 609.59).isEmpty)
    }

    /// Aus demselben Konto: 43,50 € und 83,00 € (Varianz 0,31).
    func test_knappUnterDerAltenSchranke_giltNichtMehr() {
        XCTAssertTrue(erkannt(43.50, 83.00).isEmpty)
    }

    /// Und ein Fall, der zeigt, worum es geht: Tanken ist keine Fixkostenposition.
    /// 30,69 € und 45,99 € lagen bei 0,20 und wurden gezählt.
    func test_tankenZweimal_giltNichtMehr() {
        XCTAssertTrue(erkannt(30.69, 45.99).isEmpty)
    }

    // MARK: - Was weiter erkannt werden muss

    /// Die echten Posten aus demselben Konto. Fielen die weg, wäre die Zahl nicht
    /// richtiger, sondern nur kleiner.
    func test_gleicheBetraege_bleibenErkannt() {
        for betrag in [35.40, 34.81, 27.99, 20.34, 6.99, 4.99] {
            XCTAssertEqual(erkannt(betrag, betrag).count, 1, "\(betrag)")
        }
    }

    /// Anthropic im echten Konto: 23,80 € und 20,55 € (Varianz 0,073) — ein echtes Abo
    /// mit nutzungsabhängigem Anteil.
    func test_kleineSchwankung_bleibtErkannt() {
        XCTAssertEqual(erkannt(23.80, 20.55).count, 1)
    }

    /// Freenet: 19,94 € und 20,72 €.
    func test_sehrKleineSchwankung_bleibtErkannt() {
        XCTAssertEqual(erkannt(19.94, 20.72).count, 1)
    }

    /// Die Grenze liegt bei 0,10 — hier 0,0909 (30,00 €/25,00 €).
    func test_direktUnterDerGrenze_bleibtErkannt() {
        XCTAssertEqual(erkannt(30.00, 25.00).count, 1)
    }

    // MARK: - Bekannte Marken haben etwas mehr Luft

    /// Eine Preiserhöhung beim zweiten Mal ist ein echter Fall, und bei einer bekannten
    /// Marke ist der Name schon ein starkes Indiz. 9,99 € → 12,99 € liegt bei 0,13 —
    /// unter der Schranke für bekannte Marken, über der für alle anderen.
    func test_preiserhoehungBeiBekannterMarke_bleibtErkannt() {
        XCTAssertEqual(erkannt(9.99, 12.99, name: "Netflix").count, 1)
    }

    /// Unbekannter Empfänger, dieselben Beträge: bleibt draußen.
    func test_dieselbeSpanneBeiUnbekanntemEmpfaenger_bleibtDraussen() {
        XCTAssertTrue(erkannt(9.99, 12.99).isEmpty)
    }

    /// Und die Obergrenze auch für bekannte Marken: Ein Sprung um 40 % zwischen zwei
    /// aufeinanderfolgenden Buchungen braucht eine dritte, um zu zählen.
    func test_grosserSprungBeiBekannterMarke_brauchtEineDritteBuchung() {
        XCTAssertTrue(erkannt(9.99, 13.99, name: "Netflix").isEmpty)
    }

    // MARK: - Ab drei Buchungen gilt die alte Schranke

    /// Mit drei Buchungen trägt der Abstand der Termine die Regelmäßigkeit mit; die enge
    /// Schranke gilt dort ausdrücklich nicht.
    func test_abDreiBuchungen_bleibtDieAlteSchranke() {
        let tx = [buchung("2026-07-09", 100, empfaenger: "Irgendwer"),
                  buchung("2026-08-09", 125, empfaenger: "Irgendwer"),
                  buchung("2026-09-09", 115, empfaenger: "Irgendwer")]
        XCTAssertEqual(FixedCostsAnalyzer.analyze(transactions: tx).count, 1)
    }
}
