import XCTest
@testable import simplebanking

// MARK: - SQLGuard Tests
//
// Fokus: die LLM-Härtung (`validatedLLMQuery`) erzwingt technisch, dass LLM-
// generiertes SQL nur die minimierte Sicht `llm_tx` abfragt und niemals sensible
// Bezeichner (IBAN, Rohdaten, Absender, Basistabelle) enthält. Der System-Prompt
// ist keine Sicherheitsgrenze — diese Tests sind es.

final class SQLGuardTests: XCTestCase {

    // MARK: validatedReadOnlySQL (Basis, unverändert)

    func test_readOnly_allowsSelect() throws {
        let out = try SQLGuard.validatedReadOnlySQL("SELECT betrag FROM llm_tx")
        XCTAssertTrue(out.uppercased().hasPrefix("SELECT"))
    }

    func test_readOnly_rejectsWrite() {
        XCTAssertThrowsError(try SQLGuard.validatedReadOnlySQL("DELETE FROM transactions"))
        XCTAssertThrowsError(try SQLGuard.validatedReadOnlySQL("UPDATE transactions SET betrag = 0"))
        XCTAssertThrowsError(try SQLGuard.validatedReadOnlySQL("DROP TABLE transactions"))
    }

    func test_readOnly_rejectsMultipleStatements() {
        XCTAssertThrowsError(try SQLGuard.validatedReadOnlySQL("SELECT 1 FROM llm_tx; SELECT 2 FROM llm_tx"))
    }

    // MARK: validatedLLMQuery (Allowlist)

    func test_llm_acceptsSelectOnView() throws {
        let out = try SQLGuard.validatedLLMQuery("SELECT SUM(betrag) FROM llm_tx WHERE betrag < 0")
        XCTAssertTrue(out.lowercased().contains("llm_tx"))
        XCTAssertTrue(out.uppercased().contains("LIMIT")) // Default-LIMIT wird angehängt
    }

    func test_llm_acceptsWithCTEOnView() throws {
        let sql = "WITH x AS (SELECT betrag FROM llm_tx) SELECT SUM(betrag) FROM x"
        XCTAssertNoThrow(try SQLGuard.validatedLLMQuery(sql))
    }

    func test_llm_rejectsIbanColumn() {
        XCTAssertThrowsError(try SQLGuard.validatedLLMQuery("SELECT iban FROM llm_tx"))
    }

    func test_llm_rejectsRawJson() {
        XCTAssertThrowsError(try SQLGuard.validatedLLMQuery("SELECT raw_json FROM llm_tx"))
    }

    func test_llm_rejectsAbsender() {
        XCTAssertThrowsError(try SQLGuard.validatedLLMQuery("SELECT absender FROM llm_tx"))
    }

    func test_llm_rejectsBaseTable() {
        // Direkter Zugriff auf die Basistabelle ist gesperrt (auch qualifiziert).
        XCTAssertThrowsError(try SQLGuard.validatedLLMQuery("SELECT betrag FROM transactions"))
        XCTAssertThrowsError(try SQLGuard.validatedLLMQuery("SELECT betrag FROM main.transactions"))
    }

    func test_llm_rejectsForeignTable() {
        // Kein `llm_tx` referenziert → abgelehnt.
        XCTAssertThrowsError(try SQLGuard.validatedLLMQuery("SELECT * FROM sqlite_master"))
    }

    func test_llm_rejectsIbanInWhereClause() {
        // Sensibler Bezeichner auch in WHERE/Filter → abgelehnt.
        XCTAssertThrowsError(try SQLGuard.validatedLLMQuery("SELECT betrag FROM llm_tx WHERE iban = 'DE...'"))
    }

    func test_llm_stillRejectsWrites() {
        XCTAssertThrowsError(try SQLGuard.validatedLLMQuery("DELETE FROM llm_tx"))
    }

    // MARK: LIMIT-Deckel und Längenlimit
    //
    // Ein LIMIT wurde bisher NUR angehängt, wenn keins vorhanden war — der Deckel galt
    // damit ausgerechnet für die Abfragen nicht, die selbst eins mitbrachten.

    func test_llm_kapptZuGrossesLimit() throws {
        let out = try SQLGuard.validatedLLMQuery("SELECT betrag FROM llm_tx LIMIT 999999999")
        XCTAssertTrue(out.lowercased().hasSuffix("limit \(SQLGuard.maxRowLimit)"), out)
    }

    func test_llm_behaeltKleinesLimit() throws {
        let out = try SQLGuard.validatedLLMQuery("SELECT betrag FROM llm_tx LIMIT 25")
        XCTAssertTrue(out.lowercased().hasSuffix("limit 25"), out)
    }

    /// `LIMIT offset, count` — gekappt wird die Zeilenzahl, nicht der Offset.
    func test_llm_kapptZeilenzahlBeiOffsetForm() throws {
        let out = try SQLGuard.validatedLLMQuery("SELECT betrag FROM llm_tx LIMIT 50, 900000")
        XCTAssertTrue(out.lowercased().hasSuffix("limit 50, \(SQLGuard.maxRowLimit)"), out)
    }

    func test_llm_lehntUeberlangesSQLAb() {
        let filler = String(repeating: "x", count: SQLGuard.maxSQLLength)
        XCTAssertThrowsError(
            try SQLGuard.validatedLLMQuery("SELECT betrag FROM llm_tx WHERE empfaenger = '\(filler)'")
        ) { error in
            guard case SQLGuardError.tooLong = error else {
                return XCTFail("Erwartet wurde .tooLong, bekommen: \(error)")
            }
        }
    }
}
