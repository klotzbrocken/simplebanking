import XCTest
@testable import simplebanking

// MARK: - Was VoiceOver am Menüleisten-Symbol vorliest
//
// Bis 2.1.0 trug der Button keine Beschriftung, also las VoiceOver den sichtbaren Titel
// vor: „— €", „…", bei ausgeblendetem Saldo drei Punkte. Diese Tests halten die
// Umwandlung fest — und vor allem die eine Zusage, die nicht brechen darf: Ein
// ausgeblendeter Kontostand wird nicht vorgelesen.

final class VorlesetextTests: XCTestCase {

    func testBetragBekommtBezug() {
        let text = Vorlesetext.leiste("1.234,56 €")
        XCTAssertTrue(text.hasPrefix("simplebanking,"), text)
        XCTAssertTrue(text.contains("Kontostand"), text)
        XCTAssertTrue(text.contains("1.234,56 €"), text)
    }

    /// Wer den Saldo ausblendet, tut das, weil jemand mitsehen könnte — mithören kann er
    /// genauso. Weder der Betrag noch die Maske dürfen in der Sprache landen.
    func testAusgeblendeterSaldoWirdNichtVorgelesen() {
        let text = Vorlesetext.leiste(" •.••• ")
        XCTAssertEqual(text, "simplebanking, Kontostand ausgeblendet")
        XCTAssertFalse(text.contains("•"))
        XCTAssertFalse(text.contains(where: \.isNumber))
    }

    func testKeinSaldoAbgerufen() {
        XCTAssertEqual(Vorlesetext.leiste("— €"), "simplebanking, kein Kontostand abgerufen")
        XCTAssertEqual(Vorlesetext.leiste("--,-- €"), "simplebanking, kein Kontostand abgerufen")
    }

    func testLaedt() {
        XCTAssertEqual(Vorlesetext.leiste("…"), "simplebanking, lädt")
        XCTAssertEqual(Vorlesetext.leiste("Lädt…"), "simplebanking, lädt")
    }

    /// Ein Wort trägt sich selbst — „Kontostand Verbinden" wäre Unsinn.
    func testWortTitelBleibtWieErIst() {
        XCTAssertEqual(Vorlesetext.leiste("Verbinden…"), "simplebanking, Verbinden…")
        XCTAssertEqual(Vorlesetext.leiste("Gesperrt"), "simplebanking, Gesperrt")
    }

    /// Im Flyout-Modus steht in der Leiste nur das Banklogo, ein Emoji oder ein
    /// einzelnes „€". Daraus ist nichts vorzulesen außer dem Programmnamen.
    func testOhneAussageNurDerName() {
        XCTAssertEqual(Vorlesetext.leiste(""), "simplebanking")
        XCTAssertEqual(Vorlesetext.leiste(" "), "simplebanking")
        XCTAssertEqual(Vorlesetext.leiste("€"), "simplebanking")
        XCTAssertEqual(Vorlesetext.leiste("🙂"), "simplebanking")
    }

    /// Das Stimmungs-Emoji ist Beiwerk vor dem Betrag. „Leicht lächelndes Gesicht
    /// 1.234,56 Euro" ist keine Auskunft.
    func testEmojiVorDemBetragFaelltWeg() {
        let text = Vorlesetext.leiste("🙂 1.234,56 €")
        XCTAssertEqual(text, "simplebanking, Kontostand 1.234,56 €")
    }

    /// Ziffern erfüllen `isEmoji` ebenfalls — die Prüfung muss die Emoji-*Darstellung*
    /// nehmen, sonst verschwindet der Betrag mit dem Emoji.
    func testZiffernBleibenStehen() {
        XCTAssertTrue(Vorlesetext.leiste("0,00 €").contains("0,00"))
        XCTAssertTrue(Vorlesetext.leiste("1 234").contains("1 234"))
    }

    /// Wo der Titel seine Bedeutung nicht trägt, gibt die Aufrufstelle sie mit: das
    /// Schloss-Zeichen, „TAN".
    func testZusatzSchlaegtDenTitel() {
        XCTAssertEqual(Vorlesetext.leiste("TAN", zusatz: "Freigabe erforderlich"),
                       "simplebanking, Freigabe erforderlich")
        XCTAssertEqual(Vorlesetext.leiste(" ", zusatz: "gesperrt"),
                       "simplebanking, gesperrt")
    }
}
