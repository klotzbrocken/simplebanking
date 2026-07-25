import XCTest
@testable import simplebanking

// MARK: - Daueraufträge als Wiederkehr-Signal
//
// Bis 2.0 wertete die App den Buchungstyp der Bank überhaupt nicht aus: ob etwas
// wiederkehrend ist, wurde ausschließlich aus Beträgen und Datumsabständen
// erraten. Miete, Sparrate oder Vereinsbeitrag per Dauerauftrag fielen dadurch
// aus „Abos & Verträge" — teils weil im Datenfenster nur ein oder zwei Buchungen
// lagen, teils wegen der 600-€-Grenze für Empfänger ohne bekannte Marke.
//
// Weder `FixedCostsAnalyzer` noch `SubscriptionDetector` hatten bis dahin einen
// einzigen Test.

final class StandingOrderDetectionTests: XCTestCase {

    // MARK: Fixtures

    private func tx(_ date: String, amount: Double, name: String,
                    bookingText: String? = nil, purpose: String = "Zahlung",
                    iban: String = "DE02120300000000202051") -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: date, valueDate: date, status: "booked", endToEndId: nil,
            amount: .init(currency: "EUR", amount: String(format: "%.2f", amount)),
            creditor: .init(name: name, iban: iban, bic: nil),
            debtor: nil,
            remittanceInformation: [purpose],
            additionalInformation: bookingText,
            purposeCode: nil
        )
    }

    // MARK: BookingType

    func test_recognisesStandingOrderMarkers() {
        for text in ["DAUERAUFTRAG", "Dauerauftrag", "SEPA-DAUERAUFTRAG",
                     "DAUERAUFTR.", "Dauerauftragsgutschrift", "Standing Order"] {
            XCTAssertTrue(BookingType.isStandingOrder(text: text), "nicht erkannt: \(text)")
        }
    }

    func test_ignoresOtherBookingTexts() {
        for text in ["ÜBERWEISUNG", "SEPA-LASTSCHRIFT", "KARTENZAHLUNG", "", "Gutschrift"] {
            XCTAssertFalse(BookingType.isStandingOrder(text: text), "Fehlalarm: \(text)")
        }
        XCTAssertFalse(BookingType.isStandingOrder(text: nil))
    }

    /// Der Verwendungszweck wird vom Zahler frei getippt — „Kündigung Dauerauftrag"
    /// als Zweck einer einmaligen Überweisung darf NICHT als Dauerauftrag gelten.
    /// Deshalb wird ausschließlich der Buchungstext der Bank ausgewertet.
    func test_onlyBankBookingTextCounts_notUserPurpose() {
        let t = tx("2026-07-01", amount: -50, name: "Max Mustermann",
                   bookingText: "ÜBERWEISUNG", purpose: "Kündigung Dauerauftrag")
        XCTAssertFalse(BookingType.isStandingOrder(t))
    }

    // MARK: FixedCostsAnalyzer — Miete per Dauerauftrag

    /// Der Kernfall: Miete an eine Privatperson, zweimal gebucht.
    func test_rentByStandingOrder_isRecognisedAsFixedCost() {
        let txs = [
            tx("2026-06-01", amount: -1150, name: "Erika Beispiel", bookingText: "DAUERAUFTRAG"),
            tx("2026-07-01", amount: -1150, name: "Erika Beispiel", bookingText: "DAUERAUFTRAG"),
        ]
        let found = FixedCostsAnalyzer.analyze(transactions: txs)
        XCTAssertEqual(found.count, 1, "Miete per Dauerauftrag muss als Fixkosten erscheinen")
        XCTAssertEqual(found.first?.frequency, .monthly)
        XCTAssertGreaterThanOrEqual(found.first?.confidence ?? 0, 0.6,
                                    "Bestaetigte Wiederkehr sollte auch in Noch-offen zaehlen")
    }

    /// EINE Buchung genügt — aber die daraus geratene Frequenz darf keine Geldsumme
    /// bewegen. Deshalb liegt die Confidence bewusst zwischen den beiden Schwellen:
    /// über 0.5 (erscheint in den Listen), unter 0.6 (zählt nicht in „Noch offen").
    func test_singleStandingOrder_appearsButDoesNotCountTowardLeftToPay() {
        let txs = [tx("2026-07-01", amount: -1150, name: "Erika Beispiel",
                      bookingText: "DAUERAUFTRAG")]
        let found = FixedCostsAnalyzer.analyze(transactions: txs)
        XCTAssertEqual(found.count, 1)
        let confidence = found.first?.confidence ?? 0
        XCTAssertGreaterThanOrEqual(confidence, 0.5, "sichtbar in Fixkosten/Abos")
        XCTAssertLessThan(confidence, 0.6, "darf Noch-offen NICHT erhoehen")
    }

    /// Gegenprobe: ohne Dauerauftrags-Kennung bleibt eine einzelne Zahlung
    /// unauffällig — sonst würde jeder Einmalkauf zu Fixkosten.
    func test_singleOrdinaryPayment_isNotRecurring() {
        let txs = [tx("2026-07-01", amount: -1150, name: "Möbelhaus",
                      bookingText: "ÜBERWEISUNG")]
        XCTAssertTrue(FixedCostsAnalyzer.analyze(transactions: txs).isEmpty)
    }

    // MARK: SubscriptionDetector — „Abos & Verträge"

    func test_rentByStandingOrder_appearsInSubscriptions() {
        let txs = [
            tx("2026-05-01", amount: -1150, name: "Erika Beispiel", bookingText: "DAUERAUFTRAG"),
            tx("2026-06-01", amount: -1150, name: "Erika Beispiel", bookingText: "DAUERAUFTRAG"),
            tx("2026-07-01", amount: -1150, name: "Erika Beispiel", bookingText: "DAUERAUFTRAG"),
        ]
        let found = SubscriptionDetector.detect(in: txs)
        XCTAssertEqual(found.count, 1, "1150 € Miete lag über dem alten 600-€-Deckel")
        XCTAssertEqual(found.first?.averageAmount ?? 0, 1150, accuracy: 0.01)
    }

    /// Der Deckel wächst mit der Beleglage: drei nahezu identische Beträge im
    /// Monatsrhythmus reichen auch ohne Dauerauftrags-Kennung (z.B. Miete per
    /// Lastschrift einer Hausverwaltung, die in keiner Marken-Tabelle steht).
    func test_strongEvidenceLiftsAmountCeiling_withoutStandingOrder() {
        let txs = [
            tx("2026-05-01", amount: -1200, name: "Immobilien Meier GbR", bookingText: "SEPA-LASTSCHRIFT"),
            tx("2026-06-01", amount: -1200, name: "Immobilien Meier GbR", bookingText: "SEPA-LASTSCHRIFT"),
            tx("2026-07-01", amount: -1200, name: "Immobilien Meier GbR", bookingText: "SEPA-LASTSCHRIFT"),
        ]
        XCTAssertEqual(SubscriptionDetector.detect(in: txs).count, 1)
    }

    /// Und die Gegenprobe zum Deckel: ein teurer Einmalkauf bleibt draußen.
    func test_expensiveOneOff_stillRejected() {
        let txs = [
            tx("2026-06-14", amount: -2400, name: "Elektronik Grosshandel", bookingText: "KARTENZAHLUNG"),
            tx("2026-07-02", amount: -180,  name: "Elektronik Grosshandel", bookingText: "KARTENZAHLUNG"),
        ]
        XCTAssertTrue(SubscriptionDetector.detect(in: txs).isEmpty,
                      "Stark schwankende Beträge sind kein Vertrag")
    }
}
