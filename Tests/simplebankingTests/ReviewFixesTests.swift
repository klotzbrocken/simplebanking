import XCTest
@testable import simplebanking

final class ReviewFixesTests: XCTestCase {

    private func item(_ cents: Int) -> ReweLineItem {
        ReweLineItem(name: "x", quantity: nil, totalCents: cents, taxCategory: nil)
    }

    // MARK: - P2b: dm-Beträge auf Bon-Summe skalieren

    func test_scaleItemsToTotal_proportionalAndSumsExact() {
        let scaled = DMService.scaleItemsToTotal([item(100), item(200), item(300)], total: 1200)
        XCTAssertEqual(scaled.map(\.totalCents), [200, 400, 600])
        XCTAssertEqual(scaled.reduce(0) { $0 + $1.totalCents }, 1200)
    }

    func test_scaleItemsToTotal_zeroPricesDistributedEvenly() {
        let scaled = DMService.scaleItemsToTotal([item(0), item(0), item(0)], total: 90)
        XCTAssertEqual(scaled.reduce(0) { $0 + $1.totalCents }, 90)
        XCTAssertTrue(scaled.allSatisfy { $0.totalCents == 30 })
    }

    func test_scaleItemsToTotal_roundingRemainderOnLargest() {
        // 1/3 + 1/3 + 1/3 von 100 → Rest landet auf dem größten Posten, Summe exakt.
        let scaled = DMService.scaleItemsToTotal([item(10), item(10), item(80)], total: 100)
        XCTAssertEqual(scaled.reduce(0) { $0 + $1.totalCents }, 100)
        XCTAssertEqual(scaled.max(by: { $0.totalCents < $1.totalCents })?.totalCents, 80)
    }

    func test_scaleItemsToTotal_edgeCases() {
        XCTAssertEqual(DMService.scaleItemsToTotal([], total: 100).count, 0)
        XCTAssertEqual(DMService.scaleItemsToTotal([item(5)], total: 0).map(\.totalCents), [5]) // total 0 → unverändert
    }

    // MARK: - CLI PATH-Scan (Shell-Config)

    func test_cliPathLineMatches() {
        XCTAssertTrue(CLIInstaller.pathLineMatches(#"export PATH="$HOME/.local/bin:$PATH""#))
        XCTAssertTrue(CLIInstaller.pathLineMatches(#"  path+=("$HOME/.local/bin")"#))
        XCTAssertTrue(CLIInstaller.pathLineMatches("fish_add_path ~/.local/bin"))
        XCTAssertTrue(CLIInstaller.pathLineMatches("foo\nexport PATH=~/.local/bin:$PATH\nbar"))
        XCTAssertFalse(CLIInstaller.pathLineMatches(#"# export PATH="$HOME/.local/bin:$PATH""#))
        XCTAssertFalse(CLIInstaller.pathLineMatches("export EDITOR=vim"))
        XCTAssertFalse(CLIInstaller.pathLineMatches("# nur ein kommentar über .local/bin path"))
        XCTAssertFalse(CLIInstaller.pathLineMatches(""))
    }

    // MARK: - P2c: MerchantSession-Domains

    func test_merchantSessionDomains() {
        XCTAssertEqual(MerchantSession.domains(for: .rewe), ["rewe.de"])
        XCTAssertEqual(MerchantSession.domains(for: .dm), ["dm.de", "dmtech.com"])
        XCTAssertEqual(MerchantSession.domains(for: .amazon), ["amazon.de"])
        XCTAssertTrue(MerchantSession.domains(for: .yaxi).isEmpty)
    }
}
