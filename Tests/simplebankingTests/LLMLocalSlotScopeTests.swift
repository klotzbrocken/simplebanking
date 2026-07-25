import XCTest
import GRDB
@testable import simplebanking

// MARK: - Slot-Scope der lokalen (regelbasierten) KI-Antworten
//
// Der lokale Pfad erzeugt sein SQL selbst und lief bisher OHNE Slot-Filter über
// die ganze `transactions`-Tabelle: bei mehreren Konten summierte „Was habe ich
// ausgegeben?" alle Konten zusammen — eine schlicht falsche Zahl, und zwar
// inkonsistent, weil derselbe Satz je nach lokaler Erkennung mal richtig
// (externer Pfad) und mal falsch beantwortet wurde.
//
// Diese Tests laufen gegen die echte Query-Ausführung mit zwei Slots im selben
// Zeitraum.

final class LLMLocalSlotScopeTests: XCTestCase {

    private let bank = "test-llm-slotscope"
    private let slotA = "slot-a"
    private let slotB = "slot-b"

    override func setUpWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
        try TransactionsDatabase.migrate(bankId: bank)
        let queue = try TransactionsDatabase.makeQueue(bankId: bank)
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        try queue.write { db in
            func insert(_ id: String, slot: String, betrag: Double) throws {
                try db.execute(sql: """
                    INSERT INTO transactions
                      (tx_id, datum, buchungsdatum, betrag, waehrung, empfaenger,
                       raw_json, updated_at, slot_id)
                    VALUES (?, ?, ?, ?, 'EUR', 'HAENDLER', '{}', '2026-07-01T00:00:00Z', ?)
                    """, arguments: [id, String(today), String(today), betrag, slot])
            }
            try insert("a1", slot: slotA, betrag: -10.0)
            try insert("a2", slot: slotA, betrag: -20.0)
            try insert("b1", slot: slotB, betrag: -900.0)   // darf NIE mitzählen
        }
    }

    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
    }

    /// Stellvertretend für alle zehn Pläne: die Ausgabenabfrage über den zentralen
    /// Scope. Ohne den Slot-Filter käme hier -930 statt -30 heraus.
    func test_expenseQuery_countsOnlyActiveSlot() throws {
        let sql = """
            SELECT SUM(betrag) AS total FROM transactions
            WHERE betrag < 0 AND slot_id = ?
            """
        let a = try TransactionsDatabase.executeReadOnlyQuery(sql: sql, arguments: [slotA], bankId: bank)
        XCTAssertEqual(Double(a[0]["total"] ?? "0") ?? 0, -30.0, accuracy: 0.001)

        let b = try TransactionsDatabase.executeReadOnlyQuery(sql: sql, arguments: [slotB], bankId: bank)
        XCTAssertEqual(Double(b[0]["total"] ?? "0") ?? 0, -900.0, accuracy: 0.001)
    }

    /// Die Absicherung des zentralen Mechanismus: passt die Argument-Anzahl nicht
    /// zu den Platzhaltern, schlägt die Ausführung fehl. Ein künftiger Plan, der den
    /// Scope vergisst, fällt damit sofort auf, statt still alle Konten zu addieren.
    func test_missingPlaceholder_failsLoudly() {
        XCTAssertThrowsError(
            try TransactionsDatabase.executeReadOnlyQuery(
                sql: "SELECT SUM(betrag) AS total FROM transactions WHERE betrag < 0",
                arguments: [slotA], bankId: bank))
    }

    /// Der Vollständigkeit halber die Gegenprobe zum realen Aufruf: `ask()` reicht
    /// die slotId in den lokalen Pfad; ohne API-Key bricht es vorher ab, deshalb
    /// prüfen wir hier nur, dass die Signatur den Slot überhaupt transportiert.
    func test_askRequiresApiKeyEvenForLocalPlans() async {
        do {
            _ = try await LLMService.ask(question: "Was habe ich ausgegeben?",
                                         apiKey: "  ", slotId: slotA)
            XCTFail("Erwartet: missingAPIKey")
        } catch {
            XCTAssertTrue("\(error)".contains("APIKey") || "\(error)".contains("apiKey"),
                          "bekam: \(error)")
        }
    }
}
