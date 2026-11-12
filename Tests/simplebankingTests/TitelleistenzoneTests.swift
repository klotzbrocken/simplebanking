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
}
