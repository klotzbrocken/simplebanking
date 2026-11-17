import XCTest
import AppKit
@testable import simplebanking

/// Der Doppelklick oben in der Umsatzliste. Gemeldet am 11.11.2026: Er tat nichts,
/// weil die SwiftUI-Fläche über AppKits Titelleiste liegt.
final class TitelleistenzoneTests: XCTestCase {

    private let fenster = NSSize(width: 348, height: 620)

    func testNebenDerAmpelZaehlt() {
        XCTAssertTrue(Titelleistenzone.istZoomklick(NSPoint(x: 120, y: 610),
                                                     fenster: fenster, ampelRechts: 78))
    }

    func testAufDerAmpelNicht() {
        XCTAssertFalse(Titelleistenzone.istZoomklick(NSPoint(x: 40, y: 610),
                                                      fenster: fenster, ampelRechts: 78),
                       "Der zweite Klick auf Schließen darf nicht zum Zoom werden")
    }

    func testAufDemFensterChromeRechtsNicht() {
        XCTAssertFalse(Titelleistenzone.istZoomklick(NSPoint(x: 330, y: 610),
                                                      fenster: fenster, ampelRechts: 78),
                       "Dort liegen Aktualisieren, Oben halten und Einstellungen")
    }

    func testUnterhalbDesStreifensNicht() {
        XCTAssertFalse(Titelleistenzone.istZoomklick(NSPoint(x: 120, y: 560),
                                                      fenster: fenster, ampelRechts: 78),
                       "Ein Doppelklick in der Liste öffnet eine Buchung")
    }

    /// Seit der Seitenleiste steht deren Knopf rechts neben der Ampel, also im selben
    /// Streifen. `Umsatzfenster.ampelRechts` zählt ihn mit; ohne das würde ein
    /// Doppelklick darauf das Fenster zoomen, statt die Leiste zweimal umzuschalten.
    func testAufDemSeitenleistenKnopfNicht() {
        let ampelMitKnopf = Seitenleiste.ampelBreite + Seitenleiste.knopfBreite + Seitenleiste.knopfAbstand
        let aufDemKnopf = NSPoint(x: Seitenleiste.ampelBreite + Seitenleiste.knopfBreite / 2, y: 610)
        XCTAssertFalse(Titelleistenzone.istZoomklick(aufDemKnopf, fenster: fenster,
                                                     ampelRechts: ampelMitKnopf),
                       "Der Knopf gehört nicht zur Zoomzone")
        XCTAssertTrue(Titelleistenzone.istZoomklick(NSPoint(x: ampelMitKnopf + 10, y: 610),
                                                    fenster: fenster, ampelRechts: ampelMitKnopf),
                      "Rechts daneben bleibt es ein Zoomklick")
    }
}
