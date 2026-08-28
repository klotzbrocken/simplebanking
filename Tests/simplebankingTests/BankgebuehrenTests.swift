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

    private func buchung(zweck: String, betrag: String = "-10,99",
                         empfaenger: String? = nil,
                         buchungstext: String? = nil) -> TransactionsResponse.Transaction {
        var tx = TransactionsResponse.Transaction(
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
        tx.bankTransactionCode = nil
        return tx
    }

    // MARK: Erkennen

    /// **Genau die Form aus dem echten Bestand.** Zwei Dinge daran haben die erste Fassung
    /// zu Fall gebracht: Der Betrag steht mit **Komma** („-10,99") — `Double` liefert
    /// darauf nil, und jede echte Buchung fiel schon an der ersten Prüfung durch, während
    /// die Tests mit Punkt geschrieben grün blieben. Und die Bank liefert einen Code:
    /// `SWIFT:CHG` heißt *Charges*, sie sagt es also selbst.
    func test_echteFormMitKommaUndCode() {
        var tx = buchung(zweck: "Entgeltabrechnung", betrag: "-10,99",
                         buchungstext: "ENTGELTABSCHLUSS")
        tx.bankTransactionCode = "SWIFT:CHG;GVC:809"
        XCTAssertTrue(Bankgebuehren.istGebuehr(tx))
    }

    func test_buchungscodeAlleinGenuegt() {
        var tx = buchung(zweck: "ohne verwertbaren Text", betrag: "-3,50")
        tx.bankTransactionCode = "SWIFT:CHG;GVC:809"
        XCTAssertTrue(Bankgebuehren.istGebuehr(tx), "der Code der Bank ist die beste Auskunft")
    }

    func test_fremderCodeGenuegtNicht() {
        var tx = buchung(zweck: "Miete", betrag: "-800,00")
        tx.bankTransactionCode = "SWIFT:TRF;GVC:166"
        XCTAssertFalse(Bankgebuehren.istGebuehr(tx))
    }

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
        XCTAssertFalse(Bankgebuehren.istGebuehr(buchung(zweck: "Entgeltabrechnung", betrag: "10,99")))
    }

    func test_ohneTextKeineGebuehr() {
        XCTAssertFalse(Bankgebuehren.istGebuehr(buchung(zweck: "")))
    }

    private func gruppe(_ daten: [String], betrag: String = "-10,99")
        -> [TransactionsResponse.Transaction] {
        daten.map { datum in
            TransactionsResponse.Transaction(
                bookingDate: datum, valueDate: datum, status: "booked", endToEndId: nil,
                amount: .init(currency: "EUR", amount: betrag),
                creditor: nil, debtor: nil,
                remittanceInformation: ["Entgeltabrechnung siehe Anlage"],
                additionalInformation: nil, purposeCode: nil)
        }
    }

    // MARK: Der Beleg

    /// **Der Fall, an dem die erste Fassung scheiterte.** Die Listen zeigen 60 Tage; darin
    /// liegen von einer Monatsgebühr höchstens zwei Buchungen. Eine Mindestzahl von drei
    /// war damit in der Praxis nie erreichbar — die Erkennung lief, zeigte aber nie etwas.
    func test_zweiMonatsbuchungenGenuegen() {
        XCTAssertTrue(Bankgebuehren.giltAlsWiederkehrend(gruppe(["2026-06-30", "2026-07-31"])))
    }

    /// Der Beleg steckt nicht in der Anzahl, sondern in Betrag und Abstand.
    func test_unterschiedlicheBetraegeSindKeinBeleg() {
        let gemischt = gruppe(["2026-06-30"]) + gruppe(["2026-07-31"], betrag: "-3,50")
        XCTAssertFalse(Bankgebuehren.giltAlsWiederkehrend(gemischt))
    }

    func test_zweiBuchungenDerselbenWocheSindKeinBeleg() {
        XCTAssertFalse(Bankgebuehren.giltAlsWiederkehrend(gruppe(["2026-07-28", "2026-07-31"])))
    }

    func test_quartalsweiseGehtAuch() {
        XCTAssertTrue(Bankgebuehren.giltAlsWiederkehrend(gruppe(["2026-03-31", "2026-06-30"])))
    }

    func test_eineEinzelneBuchungGenuegtNicht() {
        XCTAssertFalse(Bankgebuehren.giltAlsWiederkehrend(gruppe(["2026-07-31"])))
    }

    // MARK: Die Zeile unter dem Kontostand

    func test_betragKommtAusZweiMonatsbuchungen() {
        XCTAssertEqual(Bankgebuehren.betrag(aus: gruppe(["2026-06-30", "2026-07-31"])) ?? 0,
                       10.99, accuracy: 0.001)
    }

    /// **Ohne Gebühr keine Zeile.** `nil` heißt für die Anzeige „Position weglassen" —
    /// „Bankgebühren 0,00 €" wäre keine Auskunft, sondern eine Behauptung, und es gibt
    /// Konten ohne Gebühren.
    func test_ohneGebuehrKeinBetrag() {
        XCTAssertNil(Bankgebuehren.betrag(aus: []))
        XCTAssertNil(Bankgebuehren.betrag(aus: gruppe(["2026-07-31"])), "eine allein genügt nicht")
        XCTAssertNil(Bankgebuehren.betrag(aus: gruppe(["2026-07-28", "2026-07-31"])), "kein Rhythmus")
    }

    // MARK: In den Fixkosten

    /// Drei gleichartige Belastungen — genau die Mindestmenge. Sie erscheinen als **ein**
    /// Eintrag, nicht als drei, und tragen die eigene Kategorie.
    func test_dreiBuchungenErgebenEinenFixkostenEintrag() {
        let monate = ["2026-05-29", "2026-06-30", "2026-07-31"]
        let txs = monate.map { datum -> TransactionsResponse.Transaction in
            TransactionsResponse.Transaction(
                bookingDate: datum, valueDate: datum, status: "booked", endToEndId: nil,
                amount: .init(currency: "EUR", amount: "-10,99"),
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
                amount: .init(currency: "EUR", amount: "-10,99"),
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

    /// Zwei Monatsbuchungen reichen — das ist der reale Fall im 60-Tage-Fenster.
    func test_zweiMonatsbuchungenErscheinenInDerAnsicht() throws {
        let treffer = SubscriptionDetector.detect(in: gruppe(["2026-06-30", "2026-07-31"]))
            .filter { $0.displayName == Bankgebuehren.bezeichnung }
        XCTAssertEqual(treffer.count, 1, "im 60-Tage-Fenster gibt es nicht mehr")
    }

    /// Zwei Buchungen derselben Woche dagegen nicht — dort fehlt der Rhythmus.
    func test_ohneRhythmusKeinEintrag() {
        XCTAssertTrue(FixedCostsAnalyzer.analyze(transactions: gruppe(["2026-07-28", "2026-07-31"]))
            .filter { $0.merchant == Bankgebuehren.bezeichnung }.isEmpty)
    }
}
