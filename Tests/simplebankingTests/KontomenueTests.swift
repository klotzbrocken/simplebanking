import XCTest
@testable import simplebanking

/// Das Untermenü „Konto" ist der Weg zu Konten, die im Flyout nicht mehr nebeneinander
/// passen (gemeldet am 04.11.2026, zehn Konten). `NSMenu` lässt sich hier nicht aufbauen,
/// die Auswahlregeln schon — deshalb liegen sie in `Kontomenue.eintraege`.
final class KontomenueTests: XCTestCase {

    private func slot(_ name: String,
                      nickname: String? = nil,
                      source: SlotSource? = nil) -> BankSlot {
        BankSlot(id: name, iban: "DE00\(name)", displayName: name,
                 logoId: nil, nickname: nickname, source: source)
    }

    func testEinEintragJeKonto() {
        let slots = (1...10).map { slot("Bank \($0)") }
        let e = Kontomenue.eintraege(slots: slots, activeIndex: 0, unified: false)
        // 10 Konten + „Alle Konten"
        XCTAssertEqual(e.count, 11)
        XCTAssertEqual(e.prefix(10).map(\.titel), slots.map(\.displayName))
        XCTAssertEqual(e.compactMap(\.index), Array(0...9))
    }

    func testHakenGenauAmAktiven() {
        let slots = (1...3).map { slot("Bank \($0)") }
        let e = Kontomenue.eintraege(slots: slots, activeIndex: 1, unified: false)
        XCTAssertEqual(e.filter(\.aktiv).map(\.index), [1])
    }

    /// Bei „Alle Konten" bleibt `activeIndex` stehen, damit der Rückweg dort landet, wo
    /// man herkam — der Haken darf trotzdem nicht an zwei Stellen hängen.
    func testImAggregatTraegtNurAlleKontenDenHaken() {
        let slots = (1...3).map { slot("Bank \($0)") }
        let e = Kontomenue.eintraege(slots: slots, activeIndex: 1, unified: true)
        XCTAssertEqual(e.filter(\.aktiv).count, 1)
        XCTAssertTrue(e.last?.istAlle == true)
        XCTAssertTrue(e.last?.aktiv == true)
    }

    func testAlleKontenErstAbZweiEchtenKonten() {
        XCTAssertFalse(Kontomenue.eintraege(slots: [slot("A")], activeIndex: 0, unified: false)
            .contains { $0.istAlle })
        XCTAssertTrue(Kontomenue.eintraege(slots: [slot("A"), slot("B")], activeIndex: 0, unified: false)
            .contains { $0.istAlle })
    }

    /// Bon-Slots (REWE/dm/Amazon) haben keinen Saldo, der sich aggregieren ließe —
    /// dieselbe Schranke wie `canAggregate` im Flyout.
    func testBonSlotsZaehlenNichtFuerAlleKonten() {
        let slots = [slot("Sparkasse"), slot("REWE", source: .rewe)]
        let e = Kontomenue.eintraege(slots: slots, activeIndex: 0, unified: false)
        XCTAssertEqual(e.count, 2)
        XCTAssertFalse(e.contains { $0.istAlle })
    }

    func testSpitznameSchlaegtBanknamen() {
        XCTAssertEqual(Kontomenue.beschriftung(slot("Sparkasse", nickname: "Privat")), "Privat")
        XCTAssertEqual(Kontomenue.beschriftung(slot("Sparkasse", nickname: "")), "Sparkasse")
    }

    /// Ein leerer Menütitel wäre eine nicht anklickbare Leerzeile.
    func testKontoOhneNamenBekommtPlatzhalter() {
        let leer = BankSlot(id: "x", iban: "DE0", displayName: "", logoId: nil)
        XCTAssertFalse(Kontomenue.beschriftung(leer).isEmpty)
    }
}
