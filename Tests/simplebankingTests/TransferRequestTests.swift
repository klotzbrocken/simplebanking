import XCTest
@testable import simplebanking

// MARK: - TransferRequest Tests
//
// Verifiziert IBAN-Validation (mod-97 + Land-Längen), Betrag-Limits,
// Name- und Verwendungszweck-Längen, plus Normalisierung (Whitespace,
// Großschreibung).

final class TransferRequestTests: XCTestCase {

    // MARK: - IBAN normalization

    func test_normalizeIban_removesSpacesAndUppercases() {
        let raw = "  de89  3704 0044  0532 0130 00  "
        let normalized = TransferRequest.normalizeIban(raw)
        XCTAssertEqual(normalized, "DE89370400440532013000")
    }

    // MARK: - IBAN validation — happy paths

    func test_validateIban_validGermanIban() throws {
        try TransferRequest.validateIban("DE89370400440532013000")
    }

    func test_validateIban_validBritishIban() throws {
        try TransferRequest.validateIban("GB82WEST12345698765432")
    }

    func test_validateIban_validDutchIban() throws {
        try TransferRequest.validateIban("NL58YAXI1234567890")
    }

    // MARK: - IBAN validation — failures

    func test_validateIban_rejectsTooShort() {
        XCTAssertThrowsError(try TransferRequest.validateIban("DE12345"))
    }

    func test_validateIban_rejectsTooLong() {
        XCTAssertThrowsError(try TransferRequest.validateIban(String(repeating: "A", count: 35)))
    }

    func test_validateIban_rejectsBadCountryLength() {
        // German IBAN MUST be 22 chars; 23 chars but otherwise valid format → reject
        XCTAssertThrowsError(try TransferRequest.validateIban("DE893704004405320130000"))
    }

    func test_validateIban_rejectsBadCheckDigits() {
        // Numeric prefix mismatch → mod-97 fails
        XCTAssertThrowsError(try TransferRequest.validateIban("DE99370400440532013000"))
    }

    func test_validateIban_rejectsLowercaseCountryCode() {
        // Country code muss letters sein; lowercase passes count but mod-97 fails
        XCTAssertThrowsError(try TransferRequest.validateIban("de89370400440532013000"))
    }

    func test_validateIban_rejectsNonAlphanumericInBban() {
        XCTAssertThrowsError(try TransferRequest.validateIban("DE89-37040044-0532013000"))
    }

    // MARK: - Init validation

    func test_init_acceptsValidRequest() throws {
        let req = try TransferRequest(
            creditorName: "Max Mustermann",
            creditorIban: "DE89 3704 0044 0532 0130 00",
            amountEUR: Decimal(string: "42.50") ?? 0,
            remittance: "Miete Mai",
            endToEndId: nil
        )
        XCTAssertEqual(req.creditorName, "Max Mustermann")
        XCTAssertEqual(req.creditorIban, "DE89370400440532013000")  // normalisiert
        XCTAssertEqual(req.amountEUR, Decimal(string: "42.50"))
        XCTAssertEqual(req.remittance, "Miete Mai")
        XCTAssertNil(req.endToEndId)
    }

    func test_init_rejectsEmptyName() {
        XCTAssertThrowsError(try TransferRequest(
            creditorName: "   ",
            creditorIban: "DE89370400440532013000",
            amountEUR: 10
        )) { error in
            XCTAssertEqual(error as? TransferRequestError, .emptyName)
        }
    }

    func test_init_rejectsTooLongName() {
        let longName = String(repeating: "A", count: 71)
        XCTAssertThrowsError(try TransferRequest(
            creditorName: longName,
            creditorIban: "DE89370400440532013000",
            amountEUR: 10
        )) { error in
            XCTAssertEqual(error as? TransferRequestError, .nameTooLong(actual: 71))
        }
    }

    func test_init_rejectsZeroAmount() {
        XCTAssertThrowsError(try TransferRequest(
            creditorName: "Max",
            creditorIban: "DE89370400440532013000",
            amountEUR: 0
        )) { error in
            XCTAssertEqual(error as? TransferRequestError, .nonPositiveAmount)
        }
    }

    func test_init_rejectsNegativeAmount() {
        XCTAssertThrowsError(try TransferRequest(
            creditorName: "Max",
            creditorIban: "DE89370400440532013000",
            amountEUR: -5
        )) { error in
            XCTAssertEqual(error as? TransferRequestError, .nonPositiveAmount)
        }
    }

    func test_init_rejectsAmountAboveSafetyLimit() {
        XCTAssertThrowsError(try TransferRequest(
            creditorName: "Max",
            creditorIban: "DE89370400440532013000",
            amountEUR: Decimal(string: "100001") ?? 0
        )) { error in
            XCTAssertEqual(error as? TransferRequestError, .amountTooLarge)
        }
    }

    func test_init_rejectsTooLongRemittance() {
        let longRemittance = String(repeating: "x", count: 141)
        XCTAssertThrowsError(try TransferRequest(
            creditorName: "Max",
            creditorIban: "DE89370400440532013000",
            amountEUR: 10,
            remittance: longRemittance
        )) { error in
            XCTAssertEqual(error as? TransferRequestError, .remittanceTooLong(actual: 141))
        }
    }

    func test_init_rejectsTooLongEndToEndId() {
        let longId = String(repeating: "X", count: 36)
        XCTAssertThrowsError(try TransferRequest(
            creditorName: "Max",
            creditorIban: "DE89370400440532013000",
            amountEUR: 10,
            endToEndId: longId
        )) { error in
            XCTAssertEqual(error as? TransferRequestError, .endToEndIdTooLong(actual: 36))
        }
    }

    // MARK: - Trimming/normalization edge cases

    func test_init_trimsName() throws {
        let req = try TransferRequest(
            creditorName: "  Max  ",
            creditorIban: "DE89370400440532013000",
            amountEUR: 10
        )
        XCTAssertEqual(req.creditorName, "Max")
    }

    func test_init_emptyRemittanceBecomesNil() throws {
        let req = try TransferRequest(
            creditorName: "Max",
            creditorIban: "DE89370400440532013000",
            amountEUR: 10,
            remittance: "   "
        )
        XCTAssertNil(req.remittance)
    }

    func test_init_emptyEndToEndIdBecomesNil() throws {
        let req = try TransferRequest(
            creditorName: "Max",
            creditorIban: "DE89370400440532013000",
            amountEUR: 10,
            endToEndId: ""
        )
        XCTAssertNil(req.endToEndId)
    }

    func test_init_atSafetyLimitAccepted() throws {
        let req = try TransferRequest(
            creditorName: "Max",
            creditorIban: "DE89370400440532013000",
            amountEUR: Decimal(string: "100000") ?? 0
        )
        XCTAssertEqual(req.amountEUR, Decimal(string: "100000"))
    }
}
