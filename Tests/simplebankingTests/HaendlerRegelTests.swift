import XCTest
@testable import simplebanking

/// Warum es diese Tests gibt: Gemeldet am 14.11.2026 — „der Empfänger springt immer
/// zurück auf Unbekannt". In den Einstellungen des Melders standen zwei Regeln zum
/// selben Muster: die ältere auf „Unbekannt", die jüngere auf den richtigen Namen.
/// Das Feld „Angezeigter Empfänger" ist mit dem aufgelösten Namen vorbelegt, und das
/// ist bei einer Buchung ohne erkennbare Gegenseite eben „Unbekannt" — ein Klick auf
/// „Als Regel speichern" genügte, um den Platzhalter festzuschreiben. Die zweite,
/// richtige Regel tat danach sichtbar nichts, weil die erste gewinnt.
final class HaendlerRegelTests: XCTestCase {

    private var angelegt: [UUID] = []

    override func tearDown() {
        angelegt.forEach { _ = MerchantResolver.removeRule(id: $0) }
        angelegt = []
        super.tearDown()
    }

    private func muster() -> String { "Regeltest-\(UUID().uuidString.prefix(8))" }

    private func buchung(empfaenger: String) -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: "2026-11-14", valueDate: "2026-11-14", status: "booked",
            endToEndId: nil,
            amount: TransactionsResponse.Amount(currency: "EUR", amount: "-10.00"),
            creditor: TransactionsResponse.Party(name: empfaenger, iban: nil, bic: nil),
            debtor: nil,
            remittanceInformation: [empfaenger], additionalInformation: nil, purposeCode: nil
        )
    }

    func testDerPlatzhalterLaesstSichNichtAlsRegelzielSpeichern() {
        let m = muster()
        let regel = MerchantResolver.saveRule(pattern: m, merchant: "Unbekannt", scope: .empfaenger)
        if let regel { angelegt.append(regel.id) }
        XCTAssertNil(regel, "\u{201E}Unbekannt\u{201C} ist kein Name, sondern das Eingeständnis, keinen zu kennen")
        XCTAssertFalse(MerchantResolver.userRules().contains { $0.pattern == m },
                       "und es darf auch nichts gespeichert worden sein")
    }

    func testZweiteRegelZumSelbenMusterErsetztDieErste() throws {
        let m = muster()
        let erste = try XCTUnwrap(MerchantResolver.saveRule(pattern: m, merchant: "Falsch", scope: .empfaenger))
        angelegt.append(erste.id)
        let zweite = try XCTUnwrap(MerchantResolver.saveRule(pattern: m, merchant: "Richtig", scope: .empfaenger))
        angelegt.append(zweite.id)

        XCTAssertEqual(MerchantResolver.userRules().filter { $0.pattern == m }.count, 1,
                       "zwei Regeln zum selben Muster sind nicht additiv — es gewinnt die ältere")
        XCTAssertEqual(MerchantResolver.resolve(transaction: buchung(empfaenger: m)).effectiveMerchant,
                       "Richtig")
    }

    /// Bestandsdaten: Wer die Regel schon hat, wird sie ohne Zutun los.
    func testBestandsregelAufDenPlatzhalterWirdBeimLesenAussortiert() {
        let m = muster()
        var rohe = MerchantResolver.userRules()
        rohe.append(MerchantUserRule(
            id: UUID(), enabled: true, priority: 100,
            matchScope: .empfaenger, matchType: .contains,
            pattern: m, merchant: "Unbekannt",
            createdAt: Date(), updatedAt: Date()))
        UserDefaults.standard.set(try? JSONEncoder().encode(rohe),
                                  forKey: MerchantResolver.rulesStorageKey)

        XCTAssertFalse(MerchantResolver.userRules().contains { $0.pattern == m })
        XCTAssertNotEqual(MerchantResolver.resolve(transaction: buchung(empfaenger: m)).effectiveMerchant,
                          "Unbekannt", "die Buchung trägt ihren Empfängernamen wieder selbst")
    }
}
