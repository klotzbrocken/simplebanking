import XCTest
@testable import simplebanking

// MARK: - PayPal NVP-Parser & -Mapper
//
// Reine Funktionen (kein Netzwerk): NVP-Body → Dictionary, Balance-Extraktion,
// Success-/Error-Erkennung und TransactionSearch → normales Transaktionsmodell.

final class PayPalServiceTests: XCTestCase {

    // MARK: parseNVP

    func test_parseNVP_decodesAndSplits() {
        let nvp = PayPalService.parseNVP("ACK=Success&L_NAME0=John+Doe&L_EMAIL0=john%40x.com")
        XCTAssertEqual(nvp["ACK"], "Success")
        XCTAssertEqual(nvp["L_NAME0"], "John Doe")
        XCTAssertEqual(nvp["L_EMAIL0"], "john@x.com")
    }

    func test_parseNVP_emptyValue() {
        let nvp = PayPalService.parseNVP("A=&B=x")
        XCTAssertEqual(nvp["A"], "")
        XCTAssertEqual(nvp["B"], "x")
    }

    // MARK: balance

    func test_balance_fromLAmt0() {
        let nvp = PayPalService.parseNVP("ACK=Success&L_AMT0=123.45&L_CURRENCYCODE0=EUR")
        XCTAssertEqual(PayPalService.balance(fromNVP: nvp), 123.45)
    }

    func test_balance_negative() {
        let nvp = PayPalService.parseNVP("L_AMT0=-8.20")
        XCTAssertEqual(PayPalService.balance(fromNVP: nvp), -8.20)
    }

    func test_balance_nilWhenMissing() {
        XCTAssertNil(PayPalService.balance(fromNVP: ["ACK": "Success"]))
    }

    // MARK: success / error

    func test_isSuccess() {
        XCTAssertTrue(PayPalService.isSuccess(["ACK": "Success"]))
        XCTAssertTrue(PayPalService.isSuccess(["ACK": "SuccessWithWarning"]))
        XCTAssertFalse(PayPalService.isSuccess(["ACK": "Failure"]))
        XCTAssertFalse(PayPalService.isSuccess([:]))
    }

    func test_errorMessage_prefersLongMessage() {
        let nvp = ["L_SHORTMESSAGE0": "Kurz", "L_LONGMESSAGE0": "Ausführliche Meldung"]
        XCTAssertEqual(PayPalService.errorMessage(nvp), "Ausführliche Meldung")
    }

    // MARK: transactions mapper

    private var twoTxNVP: String {
        "ACK=Success"
        + "&L_TIMESTAMP0=2026-01-15T10%3a30%3a00Z&L_TYPE0=Payment&L_NAME0=John+Doe"
        + "&L_TRANSACTIONID0=ABC123&L_STATUS0=Completed&L_AMT0=-12.50&L_CURRENCYCODE0=EUR"
        + "&L_TIMESTAMP1=2026-01-14T09%3a00%3a00Z&L_TYPE1=Refund&L_NAME1=Jane"
        + "&L_TRANSACTIONID1=DEF456&L_STATUS1=Completed&L_AMT1=5.00&L_CURRENCYCODE1=EUR"
    }

    func test_transactions_count() {
        let nvp = PayPalService.parseNVP(twoTxNVP)
        let tx = PayPalService.transactions(fromNVP: nvp, slotId: "slot-1")
        XCTAssertEqual(tx.count, 2)
    }

    func test_transactions_outgoing_mapsToCreditor() {
        let nvp = PayPalService.parseNVP(twoTxNVP)
        let tx = PayPalService.transactions(fromNVP: nvp, slotId: "slot-1")[0]
        XCTAssertEqual(tx.amount?.amount, "-12.50")
        XCTAssertEqual(tx.amount?.currency, "EUR")
        XCTAssertEqual(tx.bookingDate, "2026-01-15")
        XCTAssertEqual(tx.endToEndId, "ABC123")
        XCTAssertEqual(tx.creditor?.name, "John Doe")   // Ausgabe → Empfänger = Kreditor
        XCTAssertNil(tx.debtor)
        XCTAssertEqual(tx.slotId, "slot-1")
    }

    func test_transactions_incoming_mapsToDebtor() {
        let nvp = PayPalService.parseNVP(twoTxNVP)
        let tx = PayPalService.transactions(fromNVP: nvp, slotId: "slot-1")[1]
        XCTAssertEqual(tx.amount?.amount, "5.00")
        XCTAssertEqual(tx.bookingDate, "2026-01-14")
        XCTAssertEqual(tx.debtor?.name, "Jane")         // Eingang → Absender = Debitor
        XCTAssertNil(tx.creditor)
    }

    func test_transactions_emptyWhenNoEntries() {
        let nvp = PayPalService.parseNVP("ACK=Success&TIMESTAMP=2026-01-01T00%3a00%3a00Z")
        XCTAssertTrue(PayPalService.transactions(fromNVP: nvp, slotId: "s").isEmpty)
    }
}
