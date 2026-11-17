import XCTest
import AppKit
@testable import simplebanking

/// Das Verschieben der Kontostand-Karte auf dem Schreibtisch. Gemeldet am 17.11.2026:
/// Einmal abgelegt, ließ sie sich nie wieder bewegen.
final class WidgetzugTests: XCTestCase {

    func testKleinesWackelnIstKeinZug() {
        let start = NSPoint(x: 100, y: 100)
        XCTAssertFalse(Widgetzug.zieht(von: start, nach: NSPoint(x: 102, y: 101)),
                       "Ein Klick mit zitternder Hand darf das Fenster nicht verschieben")
        XCTAssertFalse(Widgetzug.zieht(von: start, nach: start))
    }

    func testStreckeUeberDerSchwelleZieht() {
        let start = NSPoint(x: 100, y: 100)
        XCTAssertTrue(Widgetzug.zieht(von: start, nach: NSPoint(x: 110, y: 100)))
        XCTAssertTrue(Widgetzug.zieht(von: start, nach: NSPoint(x: 100, y: 88)),
                      "Auch senkrecht, nicht nur waagerecht")
    }

    /// Auf dem Schließen-Knopf zu verwackeln darf den Klick nicht in eine
    /// Fensterbewegung verwandeln.
    func testBedienelementeBehaltenIhrenZug() {
        XCTAssertTrue(Widgetzug.istBedienelement(NSButton()))
        XCTAssertTrue(Widgetzug.istBedienelement(NSTextField()))
        XCTAssertFalse(Widgetzug.istBedienelement(NSView()))
        XCTAssertFalse(Widgetzug.istBedienelement(nil))
    }

    /// SwiftUI packt seine Felder in eigene Hüllen, deshalb zählt die ganze Kette
    /// nach oben und nicht nur der getroffene View.
    func testHuelleUmEinBedienelementZaehltMit() {
        let huelle = NSView()
        let feld = NSTextField()
        huelle.addSubview(feld)
        XCTAssertTrue(Widgetzug.istBedienelement(feld))

        let karte = NSView()
        let innen = NSView()
        karte.addSubview(innen)
        XCTAssertFalse(Widgetzug.istBedienelement(innen))
    }
}
