import XCTest
import Foundation
import GRDB
@testable import simplebanking

// MARK: - Demo-Daten für die Werkzeuge außerhalb der App
//
// Die App zeigt im Demo-Modus Buchungen, die sie bei jedem Aufruf frisch erzeugt und nie
// ablegt. CLI, MCP und die Raycast-Erweiterung lesen dagegen `transactions-demo.db`.
// Diese Trennung ist einmal auseinandergelaufen: Die Schreibfunktion hatte keinen einzigen
// Aufrufer, und sie vergab Slot-Namen (`demo-main/daily/bills`), die zu den injizierten
// Konten (`demo-slot-N`) nicht passten. Ergebnis: `sb balance` zeigte Demo-Salden,
// `sb tx` blieb leer. Die Tests halten beide Hälften fest.

final class DemoDatenbankTests: XCTestCase {

    private func demoQueue() throws -> DatabaseQueue {
        try TransactionsDatabase.makeQueue(bankId: "demo")
    }

    private func slotsInDB() throws -> [String] {
        try demoQueue().read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT slot_id FROM transactions ORDER BY slot_id")
        }
    }

    private func anzahl(slot: String) throws -> Int {
        try demoQueue().read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE slot_id = ?",
                             arguments: [slot]) ?? 0
        }
    }

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: try! TransactionsDatabase.databaseURL(bankId: "demo"))
    }

    /// Der Kern: Die Buchungen tragen genau die IDs, unter denen die CLI ihre Demo-Konten
    /// führt. Stimmen sie nicht überein, findet `WHERE slot_id = ?` nie etwas.
    func test_buchungenTragenDieInjiziertenSlotIDs() throws {
        let slots = ["demo-slot-0", "demo-slot-1", "demo-slot-2"]
        TransactionsDatabase.writeDemoDB(seed: 4711, slotIds: slots)

        XCTAssertEqual(try slotsInDB(), slots,
                       "die Demo-DB muss dieselben Slots führen wie die injizierten Konten")
        for s in slots {
            XCTAssertGreaterThan(try anzahl(slot: s), 0, "\(s) blieb ohne Buchungen")
        }
    }

    /// Der Wechsel Multi → Single. Bliebe demo-slot-1/2 stehen, zeigte `sb tx` Buchungen
    /// von Konten, die `sb balance` gar nicht kennt.
    func test_stilwechselRaeumtNichtMehrAktiveSlotsAb() throws {
        TransactionsDatabase.writeDemoDB(seed: 4711,
                                         slotIds: ["demo-slot-0", "demo-slot-1", "demo-slot-2"])
        TransactionsDatabase.writeDemoDB(seed: 4711, slotIds: ["demo-slot-0"])

        XCTAssertEqual(try slotsInDB(), ["demo-slot-0"],
                       "nach dem Wechsel auf Single darf nur noch ein Slot übrig sein")
    }

    /// Ohne Slots gar nichts tun — insbesondere kein `NOT IN ()`, das SQLite ablehnt,
    /// und kein Leerräumen einer Datenbank, die gleich wieder gebraucht wird.
    func test_ohneSlotsBleibtDerBestandUnberuehrt() throws {
        TransactionsDatabase.writeDemoDB(seed: 4711, slotIds: ["demo-slot-0"])
        let vorher = try anzahl(slot: "demo-slot-0")

        TransactionsDatabase.writeDemoDB(seed: 4711, slotIds: [])

        XCTAssertEqual(try anzahl(slot: "demo-slot-0"), vorher)
    }

    /// Derselbe Seed muss denselben Bestand ergeben — sonst wackeln Screenshots und
    /// die Salden in den Preferences passen nicht mehr zu den Buchungen.
    func test_gleicherSeedGleicherBestand() throws {
        TransactionsDatabase.writeDemoDB(seed: 99, slotIds: ["demo-slot-0"])
        let erst = try anzahl(slot: "demo-slot-0")
        TransactionsDatabase.writeDemoDB(seed: 99, slotIds: ["demo-slot-0"])

        XCTAssertEqual(try anzahl(slot: "demo-slot-0"), erst,
                       "zweimal derselbe Seed darf den Bestand nicht verdoppeln oder verändern")
    }
}
