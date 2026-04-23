import XCTest
@testable import simplebanking

final class OFXImporterTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal OFX 1.x (SGML) fixture modeled after DKB exports.
    private let sgmlOfx = """
    OFXHEADER:100
    DATA:OFXSGML
    VERSION:102

    <OFX>
    <BANKMSGSRSV1>
    <STMTTRNRS>
    <STMTRS>
    <CURDEF>EUR
    <STMTTRN>
    <TRNTYPE>DEBIT
    <DTPOSTED>20260420
    <TRNAMT>-24.05
    <FITID>tx-123
    <NAME>Lotus Shop
    <MEMO>Einkauf Lotus
    </STMTTRN>
    <STMTTRN>
    <TRNTYPE>CREDIT
    <DTPOSTED>20260418
    <TRNAMT>2500.00
    <FITID>tx-124
    <NAME>Arbeitgeber GmbH
    <MEMO>Gehalt April
    </STMTTRN>
    </STMTRS>
    </STMTTRNRS>
    </BANKMSGSRSV1>
    </OFX>
    """

    /// Minimal OFX 2.x (XML) fixture.
    private let xmlOfx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <OFX>
      <BANKMSGSRSV1>
        <STMTTRNRS>
          <STMTRS>
            <CURDEF>EUR</CURDEF>
            <STMTTRN>
              <TRNTYPE>DEBIT</TRNTYPE>
              <DTPOSTED>20260420120000[0:GMT]</DTPOSTED>
              <TRNAMT>-19.99</TRNAMT>
              <FITID>abc-1</FITID>
              <NAME>AwesomeShop</NAME>
              <MEMO>Purchase reference 42</MEMO>
            </STMTTRN>
          </STMTRS>
        </STMTTRNRS>
      </BANKMSGSRSV1>
    </OFX>
    """

    // MARK: - Parse SGML

    func test_parse_sgml_returnsTwoTransactions() throws {
        let parsed = try OFXImporter.parse(ofx: sgmlOfx)
        XCTAssertEqual(parsed.transactions.count, 2)
        XCTAssertEqual(parsed.currency, "EUR")
        XCTAssertTrue(parsed.warnings.isEmpty)
    }

    func test_parse_sgml_debit_mapsToCreditor() throws {
        let parsed = try OFXImporter.parse(ofx: sgmlOfx)
        let debit = parsed.transactions[0]
        XCTAssertEqual(debit.bookingDate, "2026-04-20")
        XCTAssertEqual(debit.amount?.amount, "-24.05")
        XCTAssertEqual(debit.amount?.currency, "EUR")
        XCTAssertEqual(debit.creditor?.name, "Lotus Shop")
        XCTAssertNil(debit.debtor)
        XCTAssertEqual(debit.remittanceInformation, ["Einkauf Lotus"])
        XCTAssertNil(debit.endToEndId, "FITID must NOT go into endToEndId (dedup reasons)")
    }

    func test_parse_sgml_credit_mapsToDebtor() throws {
        let parsed = try OFXImporter.parse(ofx: sgmlOfx)
        let credit = parsed.transactions[1]
        XCTAssertEqual(credit.bookingDate, "2026-04-18")
        XCTAssertEqual(credit.amount?.amount, "2500.00")
        XCTAssertEqual(credit.debtor?.name, "Arbeitgeber GmbH")
        XCTAssertNil(credit.creditor)
        XCTAssertEqual(credit.remittanceInformation, ["Gehalt April"])
    }

    // MARK: - Parse XML

    func test_parse_xml_returnsOneTransaction() throws {
        let parsed = try OFXImporter.parse(ofx: xmlOfx)
        XCTAssertEqual(parsed.transactions.count, 1)
        let tx = parsed.transactions[0]
        XCTAssertEqual(tx.bookingDate, "2026-04-20")
        XCTAssertEqual(tx.amount?.amount, "-19.99")
        XCTAssertEqual(tx.creditor?.name, "AwesomeShop")
        XCTAssertEqual(tx.remittanceInformation, ["Purchase reference 42"])
    }

    // MARK: - Date parsing

    func test_parseDate_handlesPlainDate() {
        XCTAssertEqual(OFXImporter.parseDate("20260420"), "2026-04-20")
    }

    func test_parseDate_handlesDateWithTime() {
        XCTAssertEqual(OFXImporter.parseDate("20260420120000"), "2026-04-20")
    }

    func test_parseDate_handlesDateWithTimezone() {
        XCTAssertEqual(OFXImporter.parseDate("20260420120000.000[-05:EST]"), "2026-04-20")
    }

    func test_parseDate_rejectsShortInput() {
        XCTAssertNil(OFXImporter.parseDate("2026"))
        XCTAssertNil(OFXImporter.parseDate(""))
        XCTAssertNil(OFXImporter.parseDate("abc"))
    }

    // MARK: - Edge cases

    func test_parse_emptyInput_returnsNothing() throws {
        let parsed = try OFXImporter.parse(ofx: "")
        XCTAssertEqual(parsed.transactions.count, 0)
        XCTAssertEqual(parsed.currency, "EUR") // default
    }

    func test_parse_defaultsToEurWhenNoCurdef() throws {
        let noCurdef = sgmlOfx.replacingOccurrences(of: "<CURDEF>EUR", with: "")
        let parsed = try OFXImporter.parse(ofx: noCurdef)
        XCTAssertEqual(parsed.currency, "EUR")
    }

    func test_parse_customCurrency() throws {
        let usdOfx = sgmlOfx.replacingOccurrences(of: "<CURDEF>EUR", with: "<CURDEF>USD")
        let parsed = try OFXImporter.parse(ofx: usdOfx)
        XCTAssertEqual(parsed.currency, "USD")
        XCTAssertEqual(parsed.transactions[0].amount?.currency, "USD")
    }

    func test_parse_skipsBlockWithMissingRequiredFields() throws {
        let broken = """
        <OFX>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <FITID>tx-broken
        </STMTTRN>
        </OFX>
        """
        let parsed = try OFXImporter.parse(ofx: broken)
        XCTAssertEqual(parsed.transactions.count, 0, "Block without DTPOSTED/TRNAMT must be skipped")
        XCTAssertFalse(parsed.warnings.isEmpty, "Skip must produce a warning")
    }

    // MARK: - extractValue helper

    func test_extractValue_sgmlTag() {
        let s = "<NAME>Hello World\n<MEMO>Something"
        XCTAssertEqual(OFXImporter.extractValue(tag: "NAME", in: s), "Hello World")
        XCTAssertEqual(OFXImporter.extractValue(tag: "MEMO", in: s), "Something")
    }

    func test_extractValue_xmlTag() {
        let s = "<NAME>Hello World</NAME>"
        XCTAssertEqual(OFXImporter.extractValue(tag: "NAME", in: s), "Hello World")
    }

    func test_extractValue_missingTag_returnsNil() {
        let s = "<FOO>bar"
        XCTAssertNil(OFXImporter.extractValue(tag: "BAZ", in: s))
    }
}
