import XCTest
@testable import simplebanking

// MARK: - Wem gilt der Freigabe-Hinweis?
//
// Gemeldet am 02.09.2026: Fragte eine Bank nach einer Freigabe, stand „TAN" in der
// Menüleiste und der Hinweis über der Umsatzliste bei *jedem* Konto — auch nach einem
// Wechsel zu einer anderen Bank. Der Zustand war ein einzelnes Bool für die ganze App.

final class TanAnzeigeTests: XCTestCase {

    private let a = "slot-a"
    private let b = "slot-b"

    func test_ohneWartendeKeinHinweis() {
        XCTAssertFalse(TanAnzeige.zeigen(wartendeSlots: [], aktiverSlot: a, alleAktiv: false))
    }

    func test_wartendesAktivesKontoZeigtDenHinweis() {
        XCTAssertTrue(TanAnzeige.zeigen(wartendeSlots: [a], aktiverSlot: a, alleAktiv: false))
    }

    /// Der gemeldete Fehler: Nach dem Wechsel zu Konto B blieb der Hinweis von Konto A
    /// stehen.
    func test_fremdesWartendesKontoZeigtNichts() {
        XCTAssertFalse(TanAnzeige.zeigen(wartendeSlots: [a], aktiverSlot: b, alleAktiv: false))
    }

    /// Auch mit mehreren Wartenden entscheidet allein das angezeigte Konto.
    func test_mehrereWartendeAberNichtDasAngezeigte() {
        XCTAssertFalse(TanAnzeige.zeigen(wartendeSlots: [a, "slot-c"],
                                         aktiverSlot: b, alleAktiv: false))
        XCTAssertTrue(TanAnzeige.zeigen(wartendeSlots: [a, "slot-c"],
                                        aktiverSlot: a, alleAktiv: false))
    }

    /// In der Übersicht sind alle Konten gleichzeitig zu sehen — dort ist eine Freigabe
    /// auf irgendeinem von ihnen einschlägig.
    func test_uebersichtZeigtJedeWartendeBank() {
        XCTAssertTrue(TanAnzeige.zeigen(wartendeSlots: [a], aktiverSlot: b, alleAktiv: true))
    }

    /// Gegenprobe: Auch die Übersicht zeigt nichts, wenn niemand wartet. Sonst wäre der
    /// Test darüber mit einem schlichten `true` grün.
    func test_uebersichtOhneWartendeZeigtNichts() {
        XCTAssertFalse(TanAnzeige.zeigen(wartendeSlots: [], aktiverSlot: a, alleAktiv: true))
    }
}
