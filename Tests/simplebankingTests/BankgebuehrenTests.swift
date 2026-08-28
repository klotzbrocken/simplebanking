import XCTest
@testable import simplebanking

// MARK: - Was die Bank selbst abbucht
//
// Am echten Bestand nachgesehen, und der Blick hat den Entwurf korrigiert: Die Sparkasse
// bucht ihr Entgelt **ohne Empfängernamen** — sie ist ja ihr eigener Empfänger.
//
//     2026-07-31   -10,99   Empfänger: —   „Entgeltabrechnung siehe Anlage"
//
// Der naheliegende Abgleich gegen den Banknamen hätte davon nichts gefunden. Das Signal
// steckt im Verwendungszweck, das leere Empfängerfeld bestätigt es.
//
// Die Zahl landet unter dem Kontostand. Deshalb prüfen die meisten Tests hier, wann
// **nichts** erkannt wird.

final class BankgebuehrenTests: XCTestCase {

    private func buchung(zweck: String, betrag: String = "-10.99",
                         empfaenger: String? = nil,
                         buchungstext: String? = nil) -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: "2026-07-31",
            valueDate: "2026-07-31",
            status: "booked",
            endToEndId: nil,
            amount: .init(currency: "EUR", amount: betrag),
            creditor: empfaenger.map { .init(name: $0, iban: nil, bic: nil) },
            debtor: nil,
            remittanceInformation: [zweck],
            additionalInformation: buchungstext,
            purposeCode: nil
        )
    }

    // MARK: Erkennen

    /// Die Form, die im echten Bestand steht.
    func test_entgeltabrechnungOhneEmpfaengerWirdErkannt() {
        XCTAssertTrue(Bankgebuehren.istGebuehr(buchung(zweck: "Entgeltabrechnung siehe Anlage")))
    }

    func test_weitereSchreibweisen() {
        for zweck in ["Kontoführungsentgelt", "Grundpreis Girokonto",
                      "Buchungsposten 12 Stück", "Rechnungsabschluss 30.06."] {
            XCTAssertTrue(Bankgebuehren.istGebuehr(buchung(zweck: zweck)), zweck)
        }
    }

    func test_auchAusDemBuchungstext() {
        XCTAssertTrue(Bankgebuehren.istGebuehr(buchung(zweck: "", buchungstext: "ENTGELTABRECHNUNG")))
    }

    // MARK: Nicht erkennen

    /// Der wichtigste Fall: Eine Gebühr, die jemand anderes verlangt, ist keine
    /// Kontoführung — sonst stünde die Mahnung der Stadtwerke als Bankgebühr da.
    func test_fremdeGebuehrenZaehlenNicht() {
        XCTAssertFalse(Bankgebuehren.istGebuehr(buchung(zweck: "Mahngebühr Rechnung 4711",
                                                        empfaenger: "Stadtwerke")))
        XCTAssertFalse(Bankgebuehren.istGebuehr(buchung(zweck: "Bearbeitungsgebühr",
                                                        empfaenger: "Autohaus Meier")))
    }

    /// Steht ein Empfänger da, muss er zur Bank gehören — ohne bekannten Banknamen
    /// bleibt die Buchung draußen.
    func test_mitEmpfaengerNurBeiPassenderBank() {
        let tx = buchung(zweck: "Entgeltabrechnung", empfaenger: "Sparkasse Siegen")
        XCTAssertFalse(Bankgebuehren.istGebuehr(tx), "ohne Banknamen keine Annahme")
        XCTAssertTrue(Bankgebuehren.istGebuehr(tx, bankname: "Sparkasse Siegen"))
        XCTAssertFalse(Bankgebuehren.istGebuehr(tx, bankname: "C24 Bank"))
    }

    func test_gutschriftIstKeineGebuehr() {
        XCTAssertFalse(Bankgebuehren.istGebuehr(buchung(zweck: "Entgeltabrechnung", betrag: "10.99")))
    }

    func test_ohneTextKeineGebuehr() {
        XCTAssertFalse(Bankgebuehren.istGebuehr(buchung(zweck: "")))
    }

    // MARK: In den Fixkosten

    /// Drei gleichartige Belastungen — genau die Mindestmenge. Sie erscheinen als **ein**
    /// Eintrag, nicht als drei, und tragen die eigene Kategorie.
    func test_dreiBuchungenErgebenEinenFixkostenEintrag() {
        let monate = ["2026-05-29", "2026-06-30", "2026-07-31"]
        let txs = monate.map { datum -> TransactionsResponse.Transaction in
            TransactionsResponse.Transaction(
                bookingDate: datum, valueDate: datum, status: "booked", endToEndId: nil,
                amount: .init(currency: "EUR", amount: "-10.99"),
                creditor: nil, debtor: nil,
                remittanceInformation: ["Entgeltabrechnung siehe Anlage"],
                additionalInformation: nil, purposeCode: nil)
        }

        let treffer = FixedCostsAnalyzer.analyze(transactions: txs)
            .filter { $0.merchant == Bankgebuehren.bezeichnung }
        XCTAssertEqual(treffer.count, 1)
        XCTAssertEqual(treffer.first?.category, .bankFees)
        XCTAssertEqual(treffer.first?.occurrences, 3)
        XCTAssertEqual(treffer.first?.averageAmount ?? 0, 10.99, accuracy: 0.01)
    }

    /// **Der Test, der gefehlt hat.** Der Rechner allein macht nichts sichtbar: Die
    /// Abo-/Fixkosten-Ansicht speist sich aus `SubscriptionDetector`, nicht aus
    /// `FixedCostsAnalyzer`. Ohne diesen Weg wäre die Erkennung gebaut, geprüft — und
    /// nirgends zu sehen.
    func test_gebuehrErscheintInDerAbosAnsicht() throws {
        let monate = ["2026-05-29", "2026-06-30", "2026-07-31"]
        let txs = monate.map { datum -> TransactionsResponse.Transaction in
            TransactionsResponse.Transaction(
                bookingDate: datum, valueDate: datum, status: "booked", endToEndId: nil,
                amount: .init(currency: "EUR", amount: "-10.99"),
                creditor: nil, debtor: nil,
                remittanceInformation: ["Entgeltabrechnung siehe Anlage"],
                additionalInformation: nil, purposeCode: nil)
        }

        let treffer = SubscriptionDetector.detect(in: txs)
            .filter { $0.displayName == Bankgebuehren.bezeichnung }
        let eintrag = try XCTUnwrap(treffer.first, "die Gebühr fehlt in der Ansicht")
        XCTAssertEqual(treffer.count, 1)
        XCTAssertEqual(eintrag.category, .bankFees)
        XCTAssertEqual(eintrag.occurrences, 3)
        XCTAssertEqual(eintrag.defaultTab, .verbindlichkeiten,
                       "eine Kontoführungsgebühr ist kein Abo")
    }

    /// Zwei können ein Zufall sein.
    func test_zweiBuchungenErgebenNochNichts() {
        let txs = ["2026-06-30", "2026-07-31"].map { datum -> TransactionsResponse.Transaction in
            TransactionsResponse.Transaction(
                bookingDate: datum, valueDate: datum, status: "booked", endToEndId: nil,
                amount: .init(currency: "EUR", amount: "-10.99"),
                creditor: nil, debtor: nil,
                remittanceInformation: ["Entgeltabrechnung siehe Anlage"],
                additionalInformation: nil, purposeCode: nil)
        }
        XCTAssertTrue(FixedCostsAnalyzer.analyze(transactions: txs)
            .filter { $0.merchant == Bankgebuehren.bezeichnung }.isEmpty)
    }
}
