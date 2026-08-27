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

// MARK: - Intents und der Demo-Bestand

final class IntentDemoQuelleTests: XCTestCase {

    /// Im Demo-Modus muss ein Kurzbefehl aus der Demo-Datenbank lesen. Sonst kämen die
    /// Salden aus den Demo-Konten und die Umsätze aus dem echten Bestand — eine Auskunft
    /// aus zwei Quellen, die niemand auseinanderhalten kann.
    func test_demoModusLiestDenDemoBestand() {
        XCTAssertEqual(IntentDaten.datenbank(demo: true), "demo")
    }

    func test_ohneDemoModusDerEchteBestand() {
        XCTAssertEqual(IntentDaten.datenbank(demo: false), "primary")
    }
}

// MARK: - Währungen dürfen nicht zusammenfallen
//
// 1.000 EUR + 1.000 USD sind nicht 2.000 EUR. Die Anwendung holt bewusst keine
// Umrechnungskurse — dann gibt es keine einzelne Zahl, die stimmt, und der einzige
// ehrliche Weg ist, die Währungen nebeneinanderzustellen. Vorher setzte `kontostaende()`
// für jedes Konto fest „EUR" und summierte quer durch.

final class WaehrungTrennungTests: XCTestCase {

    private func b(_ summe: Double, _ waehrung: String) -> IntentDaten.Betrag {
        IntentDaten.Betrag(summe: summe, waehrung: waehrung)
    }

    func test_gleicheWaehrungWirdSummiert() {
        let aus = IntentDaten.jeWaehrung([b(1000, "EUR"), b(234.50, "EUR")])
        XCTAssertEqual(aus.count, 1)
        XCTAssertEqual(aus.first?.summe, 1234.50)
        XCTAssertEqual(aus.first?.waehrung, "EUR")
    }

    func test_verschiedeneWaehrungenBleibenGetrennt() {
        let aus = IntentDaten.jeWaehrung([b(1000, "EUR"), b(1000, "USD")])
        XCTAssertEqual(aus.count, 2, "zwei Währungen dürfen nicht zu einer Zahl werden")
        XCTAssertEqual(Set(aus.map(\.waehrung)), ["EUR", "USD"])
        XCTAssertFalse(aus.contains { $0.summe == 2000 })
    }

    /// Die größte Gruppe zuerst — der Rückgabewert eines Intents ist eine einzelne Zahl
    /// und kann nur eine tragen. Dann soll es die gewichtigste sein.
    func test_groessteGruppeStehtVorn() {
        let aus = IntentDaten.jeWaehrung([b(10, "USD"), b(-5000, "EUR"), b(100, "CHF")])
        XCTAssertEqual(aus.first?.waehrung, "EUR")
    }

    func test_ohnePostenKommtNichts() {
        XCTAssertTrue(IntentDaten.jeWaehrung([]).isEmpty)
    }

    func test_satzNenntBeideWaehrungenUndErfindetKeineSumme() {
        let satz = IntentDaten.satz(fuer: [b(1000, "EUR"), b(1000, "USD")], konten: 2)
        XCTAssertTrue(satz.contains("1.000"), satz)
        XCTAssertTrue(satz.contains("$") || satz.uppercased().contains("USD"), satz)
        XCTAssertFalse(satz.contains("2.000"), "eine Gesamtsumme darf es hier nicht geben")
    }

    func test_ohneKontostandSagtDerSatzDas() {
        XCTAssertFalse(IntentDaten.satz(fuer: [], konten: 0).isEmpty)
        XCTAssertFalse(IntentDaten.satz(fuer: [], konten: 0).contains("0,00"))
    }

    /// Ein Dollarbetrag darf nicht als Eurobetrag erscheinen — genau das tat der eine,
    /// fest auf Euro gestellte Formatierer.
    func test_dollarSiehtNichtWieEuroAus() {
        let eur = IntentDaten.formatiert(1000, waehrung: "EUR")
        let usd = IntentDaten.formatiert(1000, waehrung: "USD")
        XCTAssertNotEqual(eur, usd)
        XCTAssertFalse(usd.contains("€"), usd)
    }
}
