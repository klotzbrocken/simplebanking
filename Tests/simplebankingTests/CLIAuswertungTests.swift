import XCTest
@testable import simplebanking

/// `sb fixed` und `sb subs` lesen dieselbe Datei wie die MCP-Werkzeuge
/// ([[MCPSchnappschuss]]). Die CLI ist ein eigenes Ziel und lässt sich von hier nicht
/// importieren — geprüft wird deshalb der Vertrag, auf den sie sich verlässt: die
/// Felder, die sie liest, und der Pfad, unter dem sie sucht.
///
/// Bricht einer davon, fällt es sonst erst auf, wenn jemand den Befehl aufruft.
final class CLIAuswertungTests: XCTestCase {

    private var gesichert: Data?

    override func setUp() {
        super.setUp()
        gesichert = try? Data(contentsOf: MCPSchnappschuss.dateiURL)
    }

    override func tearDown() {
        if let gesichert {
            try? gesichert.write(to: MCPSchnappschuss.dateiURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        }
        super.tearDown()
    }

    /// Der Pfad ist in drei Zielen getrennt hingeschrieben (App, MCP-Server, CLI) — es
    /// gibt keinen Compiler, der sie zusammenhält.
    func test_pfadIstDerVereinbarte() {
        XCTAssertEqual(MCPSchnappschuss.dateiURL.lastPathComponent, "auswertung.json")
        XCTAssertEqual(MCPSchnappschuss.dateiURL.deletingLastPathComponent().lastPathComponent,
                       "simplebanking")
    }

    /// Die Feldnamen, die CLI und MCP-Server erwarten. Eine Umbenennung in der App ohne
    /// die beiden anderen Ziele macht die Befehle wortlos leer.
    func test_dieGelesenenFelderSindDa() throws {
        try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        MCPSchnappschuss.schreibe(
            slotId: "s1", bankName: "Testbank", gehaltstag: 15,
            zyklusStart: Date(timeIntervalSince1970: 1_789_000_000),
            zyklusEnde: Date(timeIntervalSince1970: 1_791_600_000),
            zahlungen: [RecurringPayment(merchant: "Netflix", groupKey: "netflix",
                                         averageAmount: 13.99, occurrences: 4, months: 4,
                                         frequency: .monthly, lastDate: "2026-09-08",
                                         category: .streaming, confidence: 0.9)],
            offen: [], historie: [])

        let daten = try Data(contentsOf: MCPSchnappschuss.dateiURL)
        let wurzel = try XCTUnwrap(try JSONSerialization.jsonObject(with: daten) as? [String: Any])
        let slots = try XCTUnwrap(wurzel["slots"] as? [String: Any])
        let konto = try XCTUnwrap(slots["s1"] as? [String: Any])

        for feld in ["bank_name", "updated_at", "salary_day", "cycle_start", "cycle_end",
                     "monthly_total_eur", "open_total_eur", "fixed_costs", "subscriptions"] {
            XCTAssertNotNil(konto[feld], "Feld \(feld) fehlt — CLI und MCP lesen es")
        }

        let posten = try XCTUnwrap((konto["fixed_costs"] as? [[String: Any]])?.first)
        for feld in ["merchant", "group_key", "amount_eur", "frequency",
                     "occurrences", "months", "confidence", "category",
                     "last_date", "next_due", "open_this_cycle"] {
            XCTAssertNotNil(posten[feld], "Posten-Feld \(feld) fehlt")
        }
    }

    /// Ganzzahlen müssen Ganzzahlen bleiben. Die CLI bringt Gleitkommawerte beim
    /// JSON-Ausgeben auf zwei Stellen; träfe das auch Monate und Vorkommen, stünde dort
    /// „4.0" statt „4".
    func test_ganzzahlenBleibenGanzzahlen() throws {
        try? FileManager.default.removeItem(at: MCPSchnappschuss.dateiURL)
        MCPSchnappschuss.schreibe(
            slotId: "s1", bankName: "T", gehaltstag: 15,
            zyklusStart: Date(), zyklusEnde: Date(),
            zahlungen: [RecurringPayment(merchant: "A", groupKey: "a", averageAmount: 10,
                                         occurrences: 4, months: 3, frequency: .monthly,
                                         lastDate: "2026-09-08", category: .other,
                                         confidence: 0.9)],
            offen: [], historie: [])
        let text = try String(contentsOf: MCPSchnappschuss.dateiURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"months\" : 3"), text)
        XCTAssertTrue(text.contains("\"occurrences\" : 4"), text)
        XCTAssertTrue(text.contains("\"salary_day\" : 15"), text)
    }
}
