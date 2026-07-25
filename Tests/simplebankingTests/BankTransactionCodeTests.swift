import XCTest
import GRDB
@testable import simplebanking

// MARK: - Buchungstyp-Code der Bank
//
// `bankTransactionCodes` ist die einzige belastbare Auskunft darüber, ob eine
// Zahlung wiederkehrend ist — im Gegensatz zum Buchungstext ist sie weder
// sprach- noch institutsabhängig formuliert. Bis 2.0 wurde das Feld beim Mapping
// verworfen und war danach unwiederbringlich weg (auch aus `raw_json`, denn das
// ist die Serialisierung des App-eigenen Structs, nicht der Bankantwort).

final class BankTransactionCodeTests: XCTestCase {

    private let bank = "test-btc"

    // MARK: Verdichtung der API-Codes

    func test_compactsIsoCode() {
        let out = YaxiService.compactBankTransactionCode([
            .iso(domain: "PMNT", family: "ICDT", subFamily: "STDO")
        ])
        XCTAssertEqual(out, "ISO:PMNT/ICDT/STDO")
    }

    func test_compactsGermanGVC() {
        XCTAssertEqual(YaxiService.compactBankTransactionCode([.national(code: "52", country: "DE")]),
                       "GVC:52")
        XCTAssertEqual(YaxiService.compactBankTransactionCode([.national(code: "52", country: "AT")]),
                       "NAT-AT:52")
    }

    func test_compactsMultipleCodes() {
        let out = YaxiService.compactBankTransactionCode([
            .iso(domain: "PMNT", family: "ICDT", subFamily: "STDO"),
            .national(code: "52", country: "DE"),
        ])
        XCTAssertEqual(out, "ISO:PMNT/ICDT/STDO;GVC:52")
    }

    func test_emptyCodesYieldNil() {
        XCTAssertNil(YaxiService.compactBankTransactionCode([]))
    }

    // MARK: Auswertung

    func test_recognisesStandingOrderCodes() {
        XCTAssertTrue(BookingType.isStandingOrder(code: "ISO:PMNT/ICDT/STDO"))
        XCTAssertTrue(BookingType.isStandingOrder(code: "ISO:PMNT/RCDT/STDO"), "auch eingehend")
        XCTAssertTrue(BookingType.isStandingOrder(code: "GVC:52"))
        XCTAssertTrue(BookingType.isStandingOrder(code: "GVC:152"))
        XCTAssertTrue(BookingType.isStandingOrder(code: "SWIFT:X;GVC:52"), "einer von mehreren")
    }

    func test_rejectsOtherCodes() {
        XCTAssertFalse(BookingType.isStandingOrder(code: "ISO:PMNT/RDDT/ESDD"), "Lastschrift")
        XCTAssertFalse(BookingType.isStandingOrder(code: "ISO:PMNT/ICDT/ESCT"), "normale Überweisung")
        XCTAssertFalse(BookingType.isStandingOrder(code: "GVC:51"))
        XCTAssertFalse(BookingType.isStandingOrder(code: "NAT-AT:52"), "kein deutscher GVC")
        XCTAssertFalse(BookingType.isStandingOrder(code: nil))
        XCTAssertFalse(BookingType.isStandingOrder(code: ""))
    }

    /// Der Code hat Vorrang, der Buchungstext bleibt Rückfall für Banken ohne Codes.
    func test_codeAndTextAreBothHonoured() {
        let byCode = TransactionsResponse.Transaction(
            bookingDate: "2026-07-01", valueDate: "2026-07-01", status: "booked", endToEndId: nil,
            amount: .init(currency: "EUR", amount: "-1150.00"),
            creditor: .init(name: "Erika", iban: "DE02120300000000202051", bic: nil), debtor: nil,
            remittanceInformation: ["Miete"], additionalInformation: "ÜBERWEISUNG",
            purposeCode: nil, bankTransactionCode: "ISO:PMNT/ICDT/STDO")
        XCTAssertTrue(BookingType.isStandingOrder(byCode), "Code muss allein genügen")

        let byText = TransactionsResponse.Transaction(
            bookingDate: "2026-07-01", valueDate: "2026-07-01", status: "booked", endToEndId: nil,
            amount: .init(currency: "EUR", amount: "-1150.00"),
            creditor: .init(name: "Erika", iban: "DE02120300000000202051", bic: nil), debtor: nil,
            remittanceInformation: ["Miete"], additionalInformation: "DAUERAUFTRAG",
            purposeCode: nil, bankTransactionCode: nil)
        XCTAssertTrue(BookingType.isStandingOrder(byText), "Text bleibt Rückfall")
    }

    // MARK: Persistenz — überlebt der Code die Datenbank?

    /// Der Code braucht keine eigene Spalte: `TransactionRecord.toTransaction()`
    /// dekodiert aus `raw_json`, und das ist die Serialisierung genau dieses
    /// Structs. Dieser Test hält das fest — bricht die Annahme, schlägt er fehl,
    /// bevor die Erkennung still wieder blind wird.
    func test_codeSurvivesDatabaseRoundTrip() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
        try TransactionsDatabase.migrate(bankId: bank)
        defer { try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank) }

        let original = TransactionsResponse.Transaction(
            bookingDate: "2026-07-01", valueDate: "2026-07-01", status: "booked",
            endToEndId: "E2E-1",
            amount: .init(currency: "EUR", amount: "-1150.00"),
            creditor: .init(name: "Erika Beispiel", iban: "DE02120300000000202051", bic: nil),
            debtor: nil, remittanceInformation: ["Miete Juli"],
            additionalInformation: "ÜBERWEISUNG", purposeCode: nil,
            bankTransactionCode: "ISO:PMNT/ICDT/STDO;GVC:52")

        let record = try TransactionRecord(transaction: original, updatedAt: "2026-07-01T00:00:00Z")
        let restored = try XCTUnwrap(record.toTransaction())

        XCTAssertEqual(restored.bankTransactionCode, "ISO:PMNT/ICDT/STDO;GVC:52")
        XCTAssertTrue(BookingType.isStandingOrder(restored))
    }

    /// Altbestand ohne das Feld muss weiter dekodierbar bleiben.
    func test_oldRawJsonWithoutFieldStillDecodes() throws {
        let legacyJSON = """
        {"bookingDate":"2026-01-01","valueDate":"2026-01-01","status":"booked",
         "amount":{"currency":"EUR","amount":"-10,00"},
         "remittanceInformation":["Alt"]}
        """
        let decoded = try JSONDecoder().decode(TransactionsResponse.Transaction.self,
                                               from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.bankTransactionCode)
        XCTAssertFalse(BookingType.isStandingOrder(decoded))
    }
}
