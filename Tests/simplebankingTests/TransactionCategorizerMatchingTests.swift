import XCTest
@testable import simplebanking

// MARK: - Keyword-Matching des Kategorisierers
//
// Regression: Die Regeln matchten Keywords mit blankem `contains`. Kurze Marken-Tokens
// zündeten dadurch mitten in längeren Wörtern — eine PayPal-Lastschrift mit
// Verwendungszweck „J.P. Morgan Mobility Payments Solutions" landete als Baumarkt-
// Einkauf (OBI) in Shopping. Da `normalize()` zusätzlich Diakritika faltet, traf
// „uber" außerdem jedes „Überweisung".

final class TransactionCategorizerMatchingTests: XCTestCase {

    // MARK: Ganzes Wort (Marken, kurze Abkürzungen)

    func test_asWord_rejectsSubstringInsideWord() {
        // Der gemeldete Fall.
        XCTAssertFalse(TransactionCategorizer.matchesAsWord(
            "1051769757024/. j.p. morgan mobility payments solutions s.a", "obi"))
        // Umlaut-Faltung: „Überweisung" → „uberweisung".
        XCTAssertFalse(TransactionCategorizer.matchesAsWord("dauerauftrag uberweisung", "uber"))
        XCTAssertFalse(TransactionCategorizer.matchesAsWord("sublime text lizenz", "lime"))
        XCTAssertFalse(TransactionCategorizer.matchesAsWord("thunderbolt kabel", "bolt"))
        XCTAssertFalse(TransactionCategorizer.matchesAsWord("google groups", "ups"))
        XCTAssertFalse(TransactionCategorizer.matchesAsWord("neon software gmbh", "eon"))
    }

    func test_asWord_stillMatchesRealBrands() {
        XCTAssertTrue(TransactionCategorizer.matchesAsWord("obi markt siegen", "obi"))
        XCTAssertTrue(TransactionCategorizer.matchesAsWord("obi-markt siegen", "obi"))
        XCTAssertTrue(TransactionCategorizer.matchesAsWord("fahrt mit uber", "uber"))
        XCTAssertTrue(TransactionCategorizer.matchesAsWord("ups paketdienst", "ups"))
        // Ziffern sind keine Buchstaben → weiterhin Wortgrenze.
        XCTAssertTrue(TransactionCategorizer.matchesAsWord("obi1234 filiale", "obi"))
    }

    /// Marken mit Satzzeichen am Rand dürfen an der Grenzprüfung nicht scheitern.
    func test_asWord_punctuationEdgedNeedles() {
        XCTAssertTrue(TransactionCategorizer.matchesAsWord("rtl+premium abo", "rtl+"))
        XCTAssertTrue(TransactionCategorizer.matchesAsWord("h&m sagt danke", "h&m"))
        XCTAssertTrue(TransactionCategorizer.matchesAsWord("e.on energie deutschland", "e.on"))
    }

    // MARK: Wortanfang (deutsche Komposita)

    func test_atWordStart_allowsCompounds() {
        XCTAssertTrue(TransactionCategorizer.matchesAtWordStart("versicherungsbeitrag q3", "versicherung"))
        XCTAssertTrue(TransactionCategorizer.matchesAtWordStart("mietzahlung juli", "miet"))
        XCTAssertTrue(TransactionCategorizer.matchesAtWordStart("tankstelle jet 24h", "tankstelle"))
        XCTAssertTrue(TransactionCategorizer.matchesAtWordStart("stromabschlag august", "strom"))
    }

    func test_atWordStart_rejectsMidWord() {
        XCTAssertFalse(TransactionCategorizer.matchesAtWordStart("hochstromleitung", "strom"))
    }

    func test_emptyNeedle() {
        XCTAssertFalse(TransactionCategorizer.matchesAsWord("irgendwas", ""))
        XCTAssertFalse(TransactionCategorizer.matchesAtWordStart("irgendwas", ""))
    }

    // MARK: End-to-End über die echten Regeln aus categories_de.json

    func test_paypalMobilityIsNotShopping() {
        let category = TransactionCategorizer.category(
            txID: "test-mobility-\(UUID().uuidString)",
            slotId: "test-slot",
            amount: -24.90,
            empfaenger: "PayPal Europe S.a.r.l. et Cie S.C.A",
            absender: nil,
            verwendungszweck: "1051769757024/. J.P. Morgan Mobility Payments Solutions S.A, "
                + "Ihr Einkauf bei J.P. Morgan Mobility Payments Solutions S.A",
            additionalInformation: nil,
            effectiveMerchant: "J.P. Morgan Mobility Payments Solutions S.A"
        )
        XCTAssertNotEqual(category, .shopping, "obi darf nicht in Mobility zuenden")
    }

    func test_realObiBookingStillLandsInShopping() {
        let category = TransactionCategorizer.category(
            txID: "test-obi-\(UUID().uuidString)",
            slotId: "test-slot",
            amount: -89.90,
            empfaenger: "OBI Markt GmbH & Co. Deutschland KG",
            absender: nil,
            verwendungszweck: "OBI Markt Siegen",
            additionalInformation: nil,
            effectiveMerchant: "OBI"
        )
        XCTAssertEqual(category, .shopping)
    }
}
