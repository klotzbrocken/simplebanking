import XCTest
@testable import MCPRahmen

// MARK: - Rahmenprüfung des MCP-Protokolls
//
// Die frühere Fassung prüfte die Größengrenze direkt nach der ersten Headerzeile und ließ
// jede weitere den geprüften Wert überschreiben, ohne erneut zu prüfen. Genau dieser Weg
// ist unten der wichtigste Test.

final class MCPRahmenTests: XCTestCase {

    private func laenge(_ zeilen: [String]) -> Int? {
        try? MCPRahmen.koerperLaenge(headerZeilen: zeilen).get()
    }

    private func fehler(_ zeilen: [String]) -> MCPRahmen.Fehler? {
        switch MCPRahmen.koerperLaenge(headerZeilen: zeilen) {
        case .success: return nil
        case .failure(let f): return f
        }
    }

    func test_einzelnerGueltigerHeader() {
        XCTAssertEqual(laenge(["Content-Length: 42"]), 42)
    }

    func test_grossKleinschreibungEgal() {
        XCTAssertEqual(laenge(["content-length:42"]), 42)
        XCTAssertEqual(laenge(["CONTENT-LENGTH:  42  "]), 42)
    }

    func test_andereHeaderStoerenNicht() {
        XCTAssertEqual(laenge(["Content-Type: application/json",
                               "Content-Length: 42"]), 42)
    }

    /// Der gemeldete Befund, wörtlich nachgebaut: Ein zweiter Header überschrieb den
    /// bereits geprüften Wert und umging so die Speichergrenze.
    func test_zweiterHeaderUmgehtDieGrenzeNicht() {
        let angriff = ["Content-Length: 10", "Content-Length: 2000000000"]
        XCTAssertNil(laenge(angriff))
        XCTAssertEqual(fehler(angriff), .doppelterHeader)
    }

    /// Auch zwei identische Werte sind ein Protokollfehler — „der letzte gewinnt" ist
    /// genau die Haltung, die den Befund erst ermöglicht hat.
    func test_doppelterHeaderAuchBeiGleichemWert() {
        XCTAssertEqual(fehler(["Content-Length: 10", "Content-Length: 10"]), .doppelterHeader)
    }

    func test_ueberDerGrenzeAbgelehnt() {
        XCTAssertEqual(fehler(["Content-Length: \(maxNachrichtenGroesse + 1)"]),
                       .zuGross(maxNachrichtenGroesse + 1))
    }

    /// Positive Gegenprobe zur Grenze: Genau auf der Grenze muss durchgehen, sonst wäre
    /// der Test oben auch mit einer viel zu strengen Umsetzung grün.
    func test_genauAufDerGrenzeGehtDurch() {
        XCTAssertEqual(laenge(["Content-Length: \(maxNachrichtenGroesse)"]),
                       maxNachrichtenGroesse)
    }

    func test_negativerWertAbgelehnt() {
        XCTAssertEqual(fehler(["Content-Length: -5"]), .ungueltigerWert("-5"))
    }

    func test_nullAbgelehnt() {
        XCTAssertEqual(fehler(["Content-Length: 0"]), .ungueltigerWert("0"))
    }

    func test_unsinnAbgelehnt() {
        XCTAssertEqual(fehler(["Content-Length: viel"]), .ungueltigerWert("viel"))
    }

    func test_fehlenderHeaderAbgelehnt() {
        XCTAssertEqual(fehler(["Content-Type: application/json"]), .fehlenderHeader)
        XCTAssertEqual(fehler([]), .fehlenderHeader)
    }

    /// Die Headerzeile hat eine eigene, engere Grenze als die Nachricht. Die erste Zeile
    /// behält bewusst die große — im NDJSON-Modus ist sie die ganze Nachricht.
    func test_headerGrenzeIstEngerAlsNachrichtengrenze() {
        XCTAssertLessThan(maxHeaderZeile, maxNachrichtenGroesse)
    }
}
