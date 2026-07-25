import XCTest
import GRDB
@testable import simplebanking

// MARK: - Alle regelbasierten Pläne ausführen
//
// Der Slot-Filter sitzt zentral im Scope, den jeder Plan an seine WHERE-Klausel
// anhängt, und wird als `?` gebunden. Genau daraus folgt das Risiko: hängt EIN
// Plan den Scope nicht an, fehlt sein Platzhalter — und die Ausführung wirft
// wegen der Argument-Anzahl. Das wäre ein Laufzeitfehler in einer Nutzerfrage,
// den kein Kompilat und keine statische Zählung findet.
//
// Diese Tests führen deshalb jeden Plan wirklich aus. `ask()` prüft nur, dass
// der API-Key nicht leer ist, und beantwortet regelbasierte Fragen danach
// vollständig lokal — es geht dabei nichts ins Netz.

final class LLMAllPlansSmokeTests: XCTestCase {

    private let slot = "slot-plans"

    override func setUpWithError() throws {
        CredentialsStore.activeSlotId = slot
        try? TransactionsDatabase.deleteDatabaseFileIfExists()
        try TransactionsDatabase.migrate()
        let queue = try TransactionsDatabase.makeQueue()
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        try queue.write { db in
            func insert(_ id: String, slot: String, betrag: Double, empfaenger: String) throws {
                try db.execute(sql: """
                    INSERT INTO transactions
                      (tx_id, datum, buchungsdatum, betrag, waehrung, empfaenger,
                       verwendungszweck, search_text, effective_merchant,
                       raw_json, updated_at, slot_id)
                    VALUES (?, ?, ?, ?, 'EUR', ?, 'Zweck', ?, ?, '{}', '2026-07-01T00:00:00Z', ?)
                    """, arguments: [id, today, today, betrag, empfaenger,
                                     empfaenger.lowercased(), empfaenger, slot])
            }
            try insert("t1", slot: slot, betrag: -12.5, empfaenger: "REWE")
            try insert("t2", slot: slot, betrag: 2000.0, empfaenger: "ARBEITGEBER GEHALT")
            try insert("t3", slot: slot, betrag: -40.0, empfaenger: "ALLIANZ VERSICHERUNG")
            try insert("t4", slot: slot, betrag: -9.99, empfaenger: "NETFLIX ABO")
            try insert("t5", slot: slot, betrag: -100.0, empfaenger: "GA NR BARGELD")
            // Zweiter Slot — darf in keiner Antwort auftauchen.
            try insert("x1", slot: "slot-other", betrag: -9999.0, empfaenger: "FREMD")
        }
    }

    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists()
        CredentialsStore.activeSlotId = "legacy"
    }

    /// Je eine Frage pro Plan (Reihenfolge wie die Dispatch-Kette in `ruleBasedPlan`).
    private static let questionsPerPlan: [(plan: String, question: String)] = [
        ("summaryPlan",       "Gib mir eine Zusammenfassung"),
        ("cashPlan",          "Wie viel Bargeld habe ich abgehoben?"),
        ("insurancePlan",     "Was zahle ich für Versicherungen?"),
        ("subscriptionsPlan", "Welche Abos habe ich?"),
        ("fixedCostsPlan",    "Wie hoch sind meine Fixkosten?"),
        ("groceryPlan",       "Was gebe ich für Lebensmittel aus?"),
        ("topExpensesPlan",   "Wofür habe ich am meisten ausgegeben?"),
        ("merchantPlan",      "Wie viel habe ich bei REWE ausgegeben?"),
        ("incomePlan",        "Wie hoch waren meine Einnahmen?"),
        ("expensePlan",       "Wie viel habe ich ausgegeben?"),
    ]

    func test_everyRuleBasedPlanExecutes() async throws {
        for (plan, question) in Self.questionsPerPlan {
            do {
                let answer = try await LLMService.ask(question: question,
                                                      apiKey: "dummy-not-used-locally",
                                                      slotId: slot)
                XCTAssertTrue(answer.sql.contains("?"),
                              "\(plan): Plan ohne gebundenen Slot-Platzhalter — Scope vergessen?")
                XCTAssertFalse(answer.answerText.isEmpty, "\(plan): leere Antwort")
            } catch {
                XCTFail("\(plan) / '\(question)' schlug fehl: \(error)")
            }
        }
    }

    /// Die Zahl selbst muss stimmen: nur der aktive Slot zählt. Ohne den Filter
    /// flösse die -9999 aus dem zweiten Konto mit ein.
    func test_expenseAnswer_excludesOtherSlot() async throws {
        let answer = try await LLMService.ask(question: "Wie viel habe ich ausgegeben?",
                                              apiKey: "dummy", slotId: slot)
        XCTAssertFalse(answer.answerText.contains("9.999"),
                       "Fremdes Konto in der Antwort: \(answer.answerText)")
        XCTAssertFalse(answer.answerText.contains("10.161"),
                       "Summe über beide Konten: \(answer.answerText)")
    }
}
