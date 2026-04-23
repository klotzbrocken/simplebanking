import XCTest
@testable import simplebanking

final class Camt053ImporterTests: XCTestCase {

    // MARK: - Fixtures

    /// camt.053.001.02 (DKB-style). Two transactions: 1 debit, 1 credit.
    private let dkbStyle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.02">
      <BkToCstmrStmt>
        <Stmt>
          <Id>STMT-1</Id>
          <Acct>
            <Id><IBAN>DE12345</IBAN></Id>
            <Ccy>EUR</Ccy>
          </Acct>
          <Ntry>
            <Amt Ccy="EUR">24.05</Amt>
            <CdtDbtInd>DBIT</CdtDbtInd>
            <Sts>BOOK</Sts>
            <BookgDt><Dt>2026-04-20</Dt></BookgDt>
            <ValDt><Dt>2026-04-20</Dt></ValDt>
            <AcctSvcrRef>REF-A-1</AcctSvcrRef>
            <NtryDtls>
              <TxDtls>
                <Refs><EndToEndId>E2E-42</EndToEndId></Refs>
                <RltdPties>
                  <Cdtr><Nm>Lotus Shop</Nm></Cdtr>
                  <CdtrAcct><Id><IBAN>DE99999</IBAN></Id></CdtrAcct>
                </RltdPties>
                <RmtInf>
                  <Ustrd>Einkauf Lotus</Ustrd>
                  <Ustrd>Referenz 2026/04</Ustrd>
                </RmtInf>
                <Purp><Cd>GDDS</Cd></Purp>
              </TxDtls>
            </NtryDtls>
            <AddtlNtryInf>LASTSCHRIFT</AddtlNtryInf>
          </Ntry>
          <Ntry>
            <Amt Ccy="EUR">2500.00</Amt>
            <CdtDbtInd>CRDT</CdtDbtInd>
            <Sts>BOOK</Sts>
            <BookgDt><Dt>2026-04-18</Dt></BookgDt>
            <ValDt><Dt>2026-04-18</Dt></ValDt>
            <NtryDtls>
              <TxDtls>
                <Refs><EndToEndId>E2E-100</EndToEndId></Refs>
                <RltdPties>
                  <Dbtr><Nm>Arbeitgeber GmbH</Nm></Dbtr>
                </RltdPties>
                <RmtInf>
                  <Ustrd>Gehalt April</Ustrd>
                </RmtInf>
              </TxDtls>
            </NtryDtls>
            <AddtlNtryInf>GEHALT</AddtlNtryInf>
          </Ntry>
        </Stmt>
      </BkToCstmrStmt>
    </Document>
    """

    /// camt.053.001.08 (newer namespace, same structure).
    private let commerzbankStyle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08">
      <BkToCstmrStmt>
        <Stmt>
          <Acct>
            <Ccy>EUR</Ccy>
          </Acct>
          <Ntry>
            <Amt Ccy="EUR">19.99</Amt>
            <CdtDbtInd>DBIT</CdtDbtInd>
            <BookgDt><Dt>2026-04-15</Dt></BookgDt>
            <NtryDtls>
              <TxDtls>
                <RltdPties>
                  <Cdtr><Nm>Online Shop AG</Nm></Cdtr>
                </RltdPties>
              </TxDtls>
            </NtryDtls>
          </Ntry>
        </Stmt>
      </BkToCstmrStmt>
    </Document>
    """

    /// camt.053 with namespace prefix (rare but spec-valid).
    private let prefixedNamespace = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ns1:Document xmlns:ns1="urn:iso:std:iso:20022:tech:xsd:camt.053.001.02">
      <ns1:BkToCstmrStmt>
        <ns1:Stmt>
          <ns1:Acct><ns1:Ccy>EUR</ns1:Ccy></ns1:Acct>
          <ns1:Ntry>
            <ns1:Amt Ccy="EUR">10.00</ns1:Amt>
            <ns1:CdtDbtInd>DBIT</ns1:CdtDbtInd>
            <ns1:BookgDt><ns1:Dt>2026-04-01</ns1:Dt></ns1:BookgDt>
            <ns1:NtryDtls>
              <ns1:TxDtls>
                <ns1:RltdPties>
                  <ns1:Cdtr><ns1:Nm>Test</ns1:Nm></ns1:Cdtr>
                </ns1:RltdPties>
              </ns1:TxDtls>
            </ns1:NtryDtls>
          </ns1:Ntry>
        </ns1:Stmt>
      </ns1:BkToCstmrStmt>
    </ns1:Document>
    """

    // MARK: - Basic parsing

    func test_parse_dkbStyle_returnsTwoTransactions() throws {
        let parsed = try Camt053Importer.parse(xml: dkbStyle)
        XCTAssertEqual(parsed.transactions.count, 2)
        XCTAssertEqual(parsed.statementCurrency, "EUR")
        XCTAssertTrue(parsed.warnings.isEmpty)
    }

    func test_parse_debit_mapsToCreditor() throws {
        let parsed = try Camt053Importer.parse(xml: dkbStyle)
        let debit = parsed.transactions[0]
        XCTAssertEqual(debit.bookingDate, "2026-04-20")
        XCTAssertEqual(debit.valueDate, "2026-04-20")
        XCTAssertEqual(debit.amount?.amount, "-24.05", "DBIT must produce negative signed amount")
        XCTAssertEqual(debit.amount?.currency, "EUR")
        XCTAssertEqual(debit.status, "Booked")
        XCTAssertEqual(debit.endToEndId, "E2E-42")
        XCTAssertEqual(debit.creditor?.name, "Lotus Shop")
        XCTAssertEqual(debit.creditor?.iban, "DE99999")
        XCTAssertNil(debit.debtor)
        XCTAssertEqual(debit.remittanceInformation, ["Einkauf Lotus", "Referenz 2026/04"])
        XCTAssertEqual(debit.purposeCode, "GDDS")
        XCTAssertEqual(debit.additionalInformation, "LASTSCHRIFT")
    }

    func test_parse_credit_mapsToDebtor() throws {
        let parsed = try Camt053Importer.parse(xml: dkbStyle)
        let credit = parsed.transactions[1]
        XCTAssertEqual(credit.bookingDate, "2026-04-18")
        XCTAssertEqual(credit.amount?.amount, "2500.00", "CRDT must produce positive amount")
        XCTAssertEqual(credit.debtor?.name, "Arbeitgeber GmbH")
        XCTAssertNil(credit.creditor)
        XCTAssertEqual(credit.remittanceInformation, ["Gehalt April"])
        XCTAssertEqual(credit.endToEndId, "E2E-100")
    }

    // MARK: - Namespace / dialect tolerance

    func test_parse_newerNamespace_works() throws {
        let parsed = try Camt053Importer.parse(xml: commerzbankStyle)
        XCTAssertEqual(parsed.transactions.count, 1)
        let tx = parsed.transactions[0]
        XCTAssertEqual(tx.bookingDate, "2026-04-15")
        XCTAssertEqual(tx.amount?.amount, "-19.99")
        XCTAssertEqual(tx.creditor?.name, "Online Shop AG")
    }

    func test_parse_prefixedNamespace_works() throws {
        let parsed = try Camt053Importer.parse(xml: prefixedNamespace)
        XCTAssertEqual(parsed.transactions.count, 1, "Parser must handle ns-prefixed elements")
        XCTAssertEqual(parsed.transactions[0].creditor?.name, "Test")
        XCTAssertEqual(parsed.transactions[0].amount?.currency, "EUR")
    }

    // MARK: - Scoping / edge cases

    func test_parse_skipsEntryWithoutBookingDate() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Document>
          <BkToCstmrStmt><Stmt>
            <Acct><Ccy>EUR</Ccy></Acct>
            <Ntry>
              <Amt Ccy="EUR">10.00</Amt>
              <CdtDbtInd>DBIT</CdtDbtInd>
            </Ntry>
          </Stmt></BkToCstmrStmt>
        </Document>
        """
        let parsed = try Camt053Importer.parse(xml: xml)
        XCTAssertEqual(parsed.transactions.count, 0)
        XCTAssertFalse(parsed.warnings.isEmpty)
    }

    func test_parse_skipsEntryWithoutAmount() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Document>
          <BkToCstmrStmt><Stmt>
            <Acct><Ccy>EUR</Ccy></Acct>
            <Ntry>
              <CdtDbtInd>DBIT</CdtDbtInd>
              <BookgDt><Dt>2026-04-01</Dt></BookgDt>
            </Ntry>
          </Stmt></BkToCstmrStmt>
        </Document>
        """
        let parsed = try Camt053Importer.parse(xml: xml)
        XCTAssertEqual(parsed.transactions.count, 0)
        XCTAssertFalse(parsed.warnings.isEmpty)
    }

    func test_parse_ibanInsideCdtrAcct_notAssignedToCreditorName() throws {
        // Regression guard: IBAN wrapped in CdtrAcct must NOT leak into creditor.name
        let parsed = try Camt053Importer.parse(xml: dkbStyle)
        XCTAssertEqual(parsed.transactions[0].creditor?.name, "Lotus Shop")
        XCTAssertEqual(parsed.transactions[0].creditor?.iban, "DE99999")
        XCTAssertNotEqual(parsed.transactions[0].creditor?.name, "DE99999")
    }

    func test_parse_statusMapping() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Document>
          <BkToCstmrStmt><Stmt>
            <Acct><Ccy>EUR</Ccy></Acct>
            <Ntry>
              <Amt Ccy="EUR">5.00</Amt>
              <CdtDbtInd>DBIT</CdtDbtInd>
              <Sts>PDNG</Sts>
              <BookgDt><Dt>2026-04-20</Dt></BookgDt>
            </Ntry>
          </Stmt></BkToCstmrStmt>
        </Document>
        """
        let parsed = try Camt053Importer.parse(xml: xml)
        XCTAssertEqual(parsed.transactions[0].status, "Pending")
    }

    func test_parse_multipleTxDtls_onlyFirstImportedWithWarning() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Document>
          <BkToCstmrStmt><Stmt>
            <Acct><Ccy>EUR</Ccy></Acct>
            <Ntry>
              <Amt Ccy="EUR">30.00</Amt>
              <CdtDbtInd>DBIT</CdtDbtInd>
              <BookgDt><Dt>2026-04-20</Dt></BookgDt>
              <NtryDtls>
                <TxDtls>
                  <Refs><EndToEndId>FIRST</EndToEndId></Refs>
                  <RltdPties><Cdtr><Nm>First Creditor</Nm></Cdtr></RltdPties>
                </TxDtls>
                <TxDtls>
                  <Refs><EndToEndId>SECOND</EndToEndId></Refs>
                  <RltdPties><Cdtr><Nm>Second Creditor</Nm></Cdtr></RltdPties>
                </TxDtls>
              </NtryDtls>
            </Ntry>
          </Stmt></BkToCstmrStmt>
        </Document>
        """
        let parsed = try Camt053Importer.parse(xml: xml)
        XCTAssertEqual(parsed.transactions.count, 1)
        XCTAssertEqual(parsed.transactions[0].endToEndId, "FIRST")
        XCTAssertEqual(parsed.transactions[0].creditor?.name, "First Creditor")
        XCTAssertFalse(parsed.warnings.isEmpty)
        XCTAssertTrue(parsed.warnings.contains { $0.lowercased().contains("batch") })
    }

    func test_parse_malformedXml_throws() {
        let broken = "<Document><Ntry>"
        XCTAssertThrowsError(try Camt053Importer.parse(xml: broken))
    }
}
