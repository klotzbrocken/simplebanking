import XCTest
import GRDB
@testable import simplebanking

// MARK: - Isolation des LLM-SQL (End-to-End)
//
// `SQLGuard` prüft Textmuster und kann nur erkennen, dass `llm_tx` VORKOMMT —
// nicht, dass es die einzige Quelle ist. Genau daran hing die Sicherheitszusage
// des KI-Chats („nur die minimierte, slot-gefilterte Sicht wird gesendet"):
// ein JOIN, eine CTE oder eine Unterabfrage auf `rewe_receipts` oder
// `sqlite_master` passierte die Prüfung und lief gegen die echte Datenbank.
//
// Die Grenze liegt jetzt in `executeLLMQuery`: eine In-Memory-Sandbox, die
// AUSSCHLIESSLICH `llm_tx` enthält. Diese Tests fahren die Bypässe scharf gegen
// eine DB mit echten Fremddaten — sie müssen an „no such table" scheitern.

final class LLMSandboxTests: XCTestCase {

    private let bank = "test-llm-sandbox"
    private let slotA = "slot-a"
    private let slotB = "slot-b"

    override func setUpWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
        try TransactionsDatabase.migrate(bankId: bank)
        try seed()
    }

    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
    }

    /// Zwei Slots plus ein Einkaufsbon — der Bon ist das Exfiltrations-Ziel,
    /// das der Guard allein nicht schützt.
    private func seed() throws {
        let queue = try TransactionsDatabase.makeQueue(bankId: bank)
        try queue.write { db in
            func insert(_ txID: String, slot: String, betrag: Double, empfaenger: String) throws {
                try db.execute(sql: """
                    INSERT INTO transactions
                      (tx_id, datum, buchungsdatum, betrag, waehrung, empfaenger, absender,
                       iban, verwendungszweck, raw_json, updated_at, slot_id)
                    VALUES (?, '2026-07-01', '2026-07-01', ?, 'EUR', ?, 'GEHEIM-ABSENDER',
                       'DE00GEHEIMEIBAN', 'Zweck', '{"secret":"roh"}', '2026-07-01T00:00:00Z', ?)
                    """, arguments: [txID, betrag, empfaenger, slot])
            }
            try insert("a1", slot: slotA, betrag: -10.0, empfaenger: "BÄCKER")
            try insert("a2", slot: slotA, betrag: -20.0, empfaenger: "TANKE")
            try insert("b1", slot: slotB, betrag: -500.0, empfaenger: "FREMDKONTO")

            try db.execute(sql: """
                INSERT INTO rewe_receipts
                  (slot_id, receipt_id, timestamp, total_cents, market_name, market_city,
                   cancelled, items_json, parsed, fetched_at)
                VALUES (?, 'r1', '2026-07-01T10:00:00Z', 4242, 'APOTHEKE', 'Siegen',
                   0, '[{"name":"SENSIBEL"}]', 1, '2026-07-01T10:00:00Z')
                """, arguments: [slotA])
        }
    }

    private func run(_ sql: String, slot: String? = nil) throws -> [[String: String]] {
        try TransactionsDatabase.executeLLMQuery(sql: sql, slotId: slot ?? slotA, bankId: bank)
    }

    // MARK: Der Normalfall funktioniert weiter

    func test_plainQueryOnView_works() throws {
        let rows = try run("SELECT SUM(betrag) AS s FROM llm_tx")
        XCTAssertEqual(rows.count, 1)
        // Nur Slot A: -10 + -20 = -30 (die -500 aus Slot B dürfen NICHT einfließen).
        XCTAssertEqual(Double(rows[0]["s"] ?? "0") ?? 0, -30.0, accuracy: 0.001)
    }

    func test_slotFilter_isolatesAccounts() throws {
        let a = try run("SELECT empfaenger FROM llm_tx", slot: slotA)
        XCTAssertEqual(Set(a.compactMap { $0["empfaenger"] }), ["BÄCKER", "TANKE"])
        let b = try run("SELECT empfaenger FROM llm_tx", slot: slotB)
        XCTAssertEqual(Set(b.compactMap { $0["empfaenger"] }), ["FREMDKONTO"])
    }

    func test_sensitiveColumnsAreNotEvenPresent() throws {
        let rows = try run("SELECT * FROM llm_tx")
        let keys = Set(rows.flatMap { $0.keys })
        XCTAssertFalse(keys.contains("iban"))
        XCTAssertFalse(keys.contains("raw_json"))
        XCTAssertFalse(keys.contains("absender"))
        XCTAssertTrue(keys.contains("betrag"), "Erlaubte Spalten müssen da sein")
    }

    // MARK: Die Bypässe, die SQLGuard passieren — hier müssen sie scheitern

    /// Alle vier hier verwendeten Abfragen sind vom Guard AKZEPTIERT.
    /// Das ist der Kern: die Textprüfung reicht nicht, die Sandbox muss halten.
    func test_guardAcceptsTheseBypasses() throws {
        for sql in Self.bypassQueries {
            XCTAssertNoThrow(try SQLGuard.validatedLLMQuery(sql),
                             "Erwartet: SQLGuard lässt das durch — \(sql)")
        }
    }

    func test_join_onForeignTable_failsInSandbox() {
        XCTAssertThrowsError(try run("SELECT * FROM llm_tx JOIN rewe_receipts ON 1=1")) { error in
            XCTAssertTrue("\(error)".lowercased().contains("no such table"),
                          "Erwartet 'no such table', bekam: \(error)")
        }
    }

    func test_cte_onForeignTable_failsInSandbox() {
        XCTAssertThrowsError(
            try run("WITH x AS (SELECT total_cents FROM rewe_receipts) SELECT betrag FROM llm_tx, x"))
    }

    func test_subquery_onForeignTable_failsInSandbox() {
        XCTAssertThrowsError(
            try run("SELECT (SELECT total_cents FROM rewe_receipts LIMIT 1) AS leak, betrag FROM llm_tx"))
    }

    /// `sqlite_master` existiert in der Sandbox zwar (SQLite legt es immer an),
    /// verrät dort aber nur `llm_tx` — nicht das Schema der echten Datenbank.
    func test_sqliteMaster_revealsOnlySandbox() throws {
        let rows = try run("SELECT name FROM llm_tx, sqlite_master")
        let names = Set(rows.compactMap { $0["name"] })
        XCTAssertEqual(names, ["llm_tx"])
        XCTAssertFalse(names.contains("transactions"))
        XCTAssertFalse(names.contains("rewe_receipts"))
    }

    /// Die echte Datenbank darf durch einen LLM-Aufruf nicht verändert werden.
    func test_realDatabaseIsUntouched() throws {
        _ = try? run("SELECT * FROM llm_tx JOIN rewe_receipts ON 1=1")
        _ = try run("SELECT betrag FROM llm_tx")
        let queue = try TransactionsDatabase.makeQueue(bankId: bank)
        let counts: (Int, Int) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rewe_receipts") ?? -1)
        }
        XCTAssertEqual(counts.0, 3)
        XCTAssertEqual(counts.1, 1)
    }

    private static let bypassQueries = [
        "SELECT * FROM llm_tx JOIN rewe_receipts ON 1=1",
        "WITH x AS (SELECT total_cents FROM rewe_receipts) SELECT betrag FROM llm_tx, x",
        "SELECT (SELECT total_cents FROM rewe_receipts LIMIT 1) AS leak, betrag FROM llm_tx",
        "SELECT name FROM llm_tx, sqlite_master",
    ]
}
