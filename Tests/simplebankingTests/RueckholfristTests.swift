import XCTest
@testable import simplebanking

// MARK: - Rückholfrist einer Lastschrift
//
// Acht Wochen nach der Belastung lässt sich eine SEPA-Basislastschrift ohne Angabe von
// Gründen zurückgeben. Das steht auf keinem Auszug — wer es nicht weiß, merkt es erst,
// wenn die Frist vorbei ist.
//
// Der wichtigste Test ist der, der **nichts** liefert: Die Zeile verleitet zu einer
// Handlung, also darf sie nur erscheinen, wenn die Bank die Buchungsart wirklich gemeldet
// hat. Geraten wird hier nicht.

final class RueckholfristTests: XCTestCase {

    private let kalender = Calendar(identifier: .gregorian)

    private func tag(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return kalender.startOfDay(for: f.date(from: text)!)
    }

    private func buchung(code: String?, betrag: String = "-89.00",
                         datum: String? = "2026-08-01") -> TransactionsResponse.Transaction {
        var tx = TransactionsResponse.Transaction(
            bookingDate: datum,
            valueDate: datum,
            status: "booked",
            endToEndId: nil,
            amount: .init(currency: "EUR", amount: betrag),
            creditor: .init(name: "Vattenfall", iban: nil, bic: nil),
            debtor: nil,
            remittanceInformation: ["Strom"],
            additionalInformation: nil,
            purposeCode: nil
        )
        tx.bankTransactionCode = code
        return tx
    }

    // MARK: Erkennung

    func test_isoBasislastschriftWirdErkannt() {
        XCTAssertTrue(Rueckholfrist.istLastschrift(code: "ISO:PMNT/RDDT/ESDD"))
    }

    /// Die Form, die im echten Bestand steht — geprüft an 219 Buchungen dieser
    /// Installation. Ohne den `SWIFT:`-Zweig fiele davon der größere Teil durch.
    func test_swiftCodeDerEchtenDatenWirdErkannt() {
        XCTAssertTrue(Rueckholfrist.istLastschrift(code: "SWIFT:DDT;GVC:105"))
        XCTAssertTrue(Rueckholfrist.istLastschrift(code: "SWIFT:DDT;GVC:106"))
        XCTAssertFalse(Rueckholfrist.istLastschrift(code: "SWIFT:STO;GVC:117"), "Dauerauftrag")
        XCTAssertFalse(Rueckholfrist.istLastschrift(code: "SWIFT:TRF;GVC:166"), "Überweisung")
        XCTAssertFalse(Rueckholfrist.istLastschrift(code: "SWIFT:MSC;GVC:083"), "Sonstiges")
    }

    func test_deutscherGvcWirdErkannt() {
        XCTAssertTrue(Rueckholfrist.istLastschrift(code: "GVC:105"))
        XCTAssertTrue(Rueckholfrist.istLastschrift(code: "GVC:005"))
    }

    func test_dauerauftragUndUeberweisungSindKeineLastschrift() {
        XCTAssertFalse(Rueckholfrist.istLastschrift(code: "ISO:PMNT/ICDT/STDO"))
        XCTAssertFalse(Rueckholfrist.istLastschrift(code: "GVC:52"))
        XCTAssertFalse(Rueckholfrist.istLastschrift(code: nil))
        XCTAssertFalse(Rueckholfrist.istLastschrift(code: ""))
    }

    // MARK: Berechnung

    func test_achtWochenAbBelastung() throws {
        let frist = try XCTUnwrap(Rueckholfrist.fuer(buchung(code: "ISO:PMNT/RDDT/ESDD"),
                                                     heute: tag("2026-08-01")))
        XCTAssertEqual(frist.verbleibendeTage, Rueckholfrist.tage)
        XCTAssertEqual(frist.endet, tag("2026-09-26"))
        XCTAssertFalse(frist.istKnapp)
    }

    func test_derLetzteTagIstKnapp() throws {
        // 50 Tage nach der Belastung bleiben sechs.
        let frist = try XCTUnwrap(Rueckholfrist.fuer(buchung(code: "GVC:105"),
                                                     heute: tag("2026-09-20")))
        XCTAssertEqual(frist.verbleibendeTage, 6)
        XCTAssertTrue(frist.istKnapp)
    }

    /// Abgelaufen heißt: keine Zeile. Eine Frist mit „noch 0 Tage" wäre schlimmer als gar
    /// keine Auskunft.
    func test_abgelaufeneFristLiefertNichts() {
        XCTAssertNil(Rueckholfrist.fuer(buchung(code: "GVC:105"), heute: tag("2026-09-26")))
        XCTAssertNil(Rueckholfrist.fuer(buchung(code: "GVC:105"), heute: tag("2026-12-01")))
    }

    // MARK: Wann es keine Frist gibt

    func test_ohneBuchungscodeKeineFrist() {
        XCTAssertNil(Rueckholfrist.fuer(buchung(code: nil), heute: tag("2026-08-02")))
    }

    func test_kartenzahlungBekommtKeineFrist() {
        XCTAssertNil(Rueckholfrist.fuer(buchung(code: "ISO:PMNT/CCRD/POSD"), heute: tag("2026-08-02")))
    }

    /// Eine Gutschrift holt niemand zurück — auch nicht die Erstattung einer Lastschrift.
    func test_gutschriftBekommtKeineFrist() {
        XCTAssertNil(Rueckholfrist.fuer(buchung(code: "ISO:PMNT/RDDT/ESDD", betrag: "89.00"),
                                        heute: tag("2026-08-02")))
    }

    func test_ohneDatumKeineFrist() {
        XCTAssertNil(Rueckholfrist.fuer(buchung(code: "GVC:105", datum: nil),
                                        heute: tag("2026-08-02")))
    }

    // MARK: Text

    func test_textIstWeichFormuliert() throws {
        let frist = try XCTUnwrap(Rueckholfrist.fuer(buchung(code: "GVC:105"),
                                                     heute: tag("2026-08-01")))
        let text = Rueckholfrist.text(frist)
        XCTAssertTrue(text.contains("56"), text)
        XCTAssertTrue(text.lowercased().contains("ggfs") || text.lowercased().contains("possibly"),
                      "die Einschränkung muss im Text stehen: \(text)")
    }
}
