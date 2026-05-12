import XCTest
@testable import simplebanking

final class BankCountryResolverTests: XCTestCase {

    // MARK: - Default

    func test_defaultsToGermany_forNeutralName() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Sparkasse"),       .de)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Deutsche Bank"),   .de)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Commerzbank"),     .de)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "ING"),             .de)
    }

    // MARK: - Austria

    func test_austria_byKeyword() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Bank Austria"),       .at)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Hypo Oberösterreich"), .at)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "BAWAG P.S.K."),        .at)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "easybank"),            .at)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Oberbank"),            .at)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Raiffeisenlandesbank Niederösterreich-Wien"), .at)
    }

    // MARK: - Belgium / Spain / Italy

    func test_belgium() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "ING Belgium"),            .be)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Deutsche Bank Belgium"),  .be)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "ING België"),             .be)
    }

    func test_spain() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "ING España"),             .es)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Deutsche Bank España"),   .es)
    }

    func test_italy() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "ING Italia"),             .it)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Deutsche Bank Italia"),   .it)
    }

    // MARK: - Switzerland / Netherlands / France / Luxembourg / UK

    func test_switzerland() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "UBS"),               .ch)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Raiffeisen Schweiz"), .ch)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Zürcher Kantonalbank"), .ch)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "PostFinance"),       .ch)
    }

    func test_netherlands() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "ABN AMRO"),  .nl)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Rabobank"),  .nl)
    }

    func test_france() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Banque de France"), .fr)
    }

    func test_luxembourg() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Bank Luxembourg"),  .lu)
    }

    func test_unitedKingdom() {
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Barclays"),  .gb)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "HSBC"),      .gb)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Lloyds"),    .gb)
    }

    // MARK: - Overrides

    func test_overrides_winOverHeuristic() {
        // Berenberg klingt nicht offensichtlich nach DE — Override zwingt es.
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Berenberg Bank"), .de)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "HypoVereinsbank"), .de)
        XCTAssertEqual(BankCountryResolver.resolve(displayName: "Targobank"),       .de)
    }

    // MARK: - Country metadata

    func test_eachCountry_hasFlagAndDisplayName() {
        for c in BankCountry.allCases {
            XCTAssertFalse(c.flag.isEmpty, "missing flag for \(c)")
            XCTAssertFalse(c.displayName.isEmpty, "missing displayName for \(c)")
            XCTAssertFalse(c.iso.isEmpty, "missing iso for \(c)")
        }
    }
}
