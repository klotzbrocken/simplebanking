import XCTest
@testable import simplebanking

/// Der Name, den die Bank einem Konto gibt — und wann er den Banknamen verdrängt.
final class KontonameTests: XCTestCase {

    // MARK: - fuerSlot

    func testAnzeigenameSchlaegtProduktnameUndInhaber() {
        XCTAssertEqual(
            Kontoname.fuerSlot(anzeigename: "Extra-Konto", produktname: "Tagesgeld",
                               inhaber: "Maik Klotz", iban: "DE89370400440532013000"),
            "Extra-Konto")
    }

    func testProduktnameWennAnzeigenameFehlt() {
        XCTAssertEqual(
            Kontoname.fuerSlot(anzeigename: nil, produktname: "S-Vita Basic",
                               inhaber: "Maik Klotz", iban: "DE89370400440532013000"),
            "S-Vita Basic")
    }

    func testLeerUndNurLeerzeichenZaehlenNichtAlsName() {
        XCTAssertEqual(
            Kontoname.fuerSlot(anzeigename: "", produktname: "   ",
                               inhaber: "Maik Klotz", iban: "DE89370400440532013000"),
            "Maik Klotz")
    }

    /// Ohne jeden Namen entscheidet die IBAN: Zwei Kacheln mit demselben Banknamen
    /// sind nicht auseinanderzuhalten, „…3000" schon.
    func testOhneNamenDieLetztenVierStellenDerIban() {
        XCTAssertEqual(
            Kontoname.fuerSlot(anzeigename: nil, produktname: nil, inhaber: nil,
                               iban: "DE89 3704 0044 0532 0130 00"),
            "…3000")
    }

    func testOhneNamenUndOhneBrauchbareIbanKeinName() {
        XCTAssertNil(Kontoname.fuerSlot(anzeigename: nil, produktname: nil,
                                        inhaber: nil, iban: "DE"))
    }

    // MARK: - fuerErstenSlot

    /// Die Eingabe des Nutzers schlägt alles, auch bei mehreren Konten.
    func testEingetippterKurznameGewinnt() {
        XCTAssertEqual(
            Kontoname.fuerErstenSlot(eingetippt: "Privat", weitereKonten: 2,
                                     anzeigename: "Girokonto", produktname: nil,
                                     inhaber: nil, iban: "DE89370400440532013000"),
            "Privat")
    }

    /// Ein einzelnes Konto behält den Banknamen: „Sparkasse Siegen" sagt in der
    /// Kopfzeile mehr als „Girokonto".
    func testEinzelnesKontoBehaeltDenBanknamen() {
        XCTAssertNil(
            Kontoname.fuerErstenSlot(eingetippt: nil, weitereKonten: 0,
                                     anzeigename: "Girokonto", produktname: nil,
                                     inhaber: nil, iban: "DE89370400440532013000"))
    }

    func testAbZweiKontenBekommtAuchDasErsteSeinenNamen() {
        XCTAssertEqual(
            Kontoname.fuerErstenSlot(eingetippt: nil, weitereKonten: 1,
                                     anzeigename: "Girokonto", produktname: nil,
                                     inhaber: nil, iban: "DE89370400440532013000"),
            "Girokonto")
    }

    func testLeerEingetipptZaehltAlsNichtEingetippt() {
        XCTAssertNil(
            Kontoname.fuerErstenSlot(eingetippt: "   ", weitereKonten: 0,
                                     anzeigename: "Girokonto", produktname: nil,
                                     inhaber: nil, iban: "DE89370400440532013000"))
    }

    // MARK: - fuerFortschritt

    /// Im Wartetext zählt nur, ob ein Name vorliegt — auch beim einzigen Konto.
    func testFortschrittNimmtAuchBeimEinzigenKontoDenNamen() {
        XCTAssertEqual(
            Kontoname.fuerFortschritt(anzeigename: nil, produktname: "Girokonto"),
            "Girokonto")
    }

    /// Die IBAN-Notlösung gehört nicht in einen Wartetext: „…3000" erklärt nichts.
    func testFortschrittOhneNamenBleibtLeer() {
        XCTAssertNil(Kontoname.fuerFortschritt(anzeigename: "", produktname: nil))
    }
}
