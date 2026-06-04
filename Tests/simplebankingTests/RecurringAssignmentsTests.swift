import XCTest
@testable import simplebanking

final class RecurringAssignmentsTests: XCTestCase {

    private let storageKey = "recurringAssignments.v1"
    private let migratedFlag = "recurringAssignments.migratedFromLegacy.v1"
    private let legacyKeys = ["fixedCosts.excluded", "subscriptions.userConfirmed",
                              "subscriptions.userExcluded", "subscriptions.tabOverrides"]

    override func setUp() {
        super.setUp()
        clearAll()
    }
    override func tearDown() {
        clearAll()
        super.tearDown()
    }
    private func clearAll() {
        let d = UserDefaults.standard
        ([storageKey, migratedFlag] + legacyKeys).forEach { d.removeObject(forKey: $0) }
    }

    // MARK: canonicalKey

    func test_canonicalKey_stripsSuffixAndLowercases() {
        XCTAssertEqual(RecurringAssignments.canonicalKey("Telekom|12345678"), "telekom")
        XCTAssertEqual(RecurringAssignments.canonicalKey("Netflix|agg"), "netflix")
        XCTAssertEqual(RecurringAssignments.canonicalKey("  Spotify  "), "spotify")
        XCTAssertEqual(RecurringAssignments.canonicalKey("Netflix"), "netflix")
    }

    // MARK: setting / queries roundtrip

    func test_settingExclude_thenQuery() {
        let s = RecurringAssignments().setting("Netflix|agg") { $0.state = .excluded }
        XCTAssertTrue(s.isExcluded("Netflix"))
        XCTAssertTrue(s.isExcluded("netflix|whatever"))
        XCTAssertEqual(s.excludedCanonicalKeys(), ["netflix"])
    }

    func test_settingConfirmAndTab() {
        let s = RecurringAssignments()
            .setting("Spotify") { $0.state = .confirmed }
            .setting("Spotify") { $0.tab = "Verträge" }
        XCTAssertTrue(s.isConfirmed("spotify"))
        XCTAssertEqual(s.assignment(for: "Spotify").tab, "Verträge")
    }

    func test_settingBackToNeutral_removesEntry() {
        var s = RecurringAssignments().setting("X") { $0.state = .excluded }
        XCTAssertEqual(s.byKey.count, 1)
        s = s.setting("X") { $0.state = .neutral }
        XCTAssertTrue(s.byKey.isEmpty)
    }

    func test_jsonRoundtrip() {
        let s = RecurringAssignments().setting("Netflix") { $0.state = .excluded }
        let decoded = RecurringAssignments.decode(s.jsonString)
        XCTAssertEqual(decoded, s)
    }

    // MARK: Migration

    func test_migration_foldsAllFourLegacyKeys() {
        let d = UserDefaults.standard
        d.set("Netflix\nTelekom|12345678", forKey: "fixedCosts.excluded")
        d.set("Spotify", forKey: "subscriptions.userConfirmed")
        d.set("Dubious|agg", forKey: "subscriptions.userExcluded")
        d.set("Audible§Verträge", forKey: "subscriptions.tabOverrides")

        RecurringAssignments.migrateLegacyIfNeeded()
        let s = RecurringAssignments.decode(d.string(forKey: storageKey) ?? "")

        XCTAssertTrue(s.isExcluded("netflix"))
        XCTAssertTrue(s.isExcluded("telekom"))
        XCTAssertTrue(s.isExcluded("dubious"))
        XCTAssertTrue(s.isConfirmed("spotify"))
        XCTAssertEqual(s.assignment(for: "audible").tab, "Verträge")
        XCTAssertTrue(s.isConfirmed("audible"))   // tab override implies confirmation
        XCTAssertTrue(d.bool(forKey: migratedFlag))
    }

    func test_migration_isIdempotent() {
        let d = UserDefaults.standard
        d.set("Netflix", forKey: "fixedCosts.excluded")
        RecurringAssignments.migrateLegacyIfNeeded()
        // user re-includes Netflix after migration
        RecurringAssignments().save()   // empty store
        d.set("Netflix", forKey: "fixedCosts.excluded")   // legacy key still there
        RecurringAssignments.migrateLegacyIfNeeded()       // must NOT re-add
        let s = RecurringAssignments.decode(d.string(forKey: storageKey) ?? "")
        XCTAssertFalse(s.isExcluded("netflix"))
    }

    func test_migration_exclusionWinsOverConfirmation() {
        let d = UserDefaults.standard
        d.set("Netflix", forKey: "subscriptions.userExcluded")
        d.set("Netflix", forKey: "subscriptions.userConfirmed")
        RecurringAssignments.migrateLegacyIfNeeded()
        let s = RecurringAssignments.decode(d.string(forKey: storageKey) ?? "")
        XCTAssertTrue(s.isExcluded("netflix"))
        XCTAssertFalse(s.isConfirmed("netflix"))
    }

    // MARK: FixedCostsAnalyzer honors the unified store

    func test_fixedCostsAnalyzer_respectsUnifiedExclusion() {
        let d = UserDefaults.standard
        d.set(true, forKey: migratedFlag)   // skip migration interference
        RecurringAssignments().setting("Netflix") { $0.state = .excluded }.save()

        let txs = (0..<3).map { i in
            makeRecurringTx(merchant: "Netflix", amount: -12.99, month: 3 + i)
        }
        let result = FixedCostsAnalyzer.analyze(transactions: txs)
        XCTAssertFalse(result.contains { RecurringAssignments.canonicalKey($0.groupKey) == "netflix" })
    }

    // MARK: Helper

    private func makeRecurringTx(merchant: String, amount: Double, month: Int) -> TransactionsResponse.Transaction {
        let amt = TransactionsResponse.Amount(currency: "EUR", amount: String(format: "%.2f", amount))
        let party = TransactionsResponse.Party(name: merchant, iban: nil, bic: nil)
        let date = String(format: "2026-%02d-15", month)
        return TransactionsResponse.Transaction(
            bookingDate: date, valueDate: date, status: "booked",
            endToEndId: "\(merchant)-\(month)", amount: amt,
            creditor: party, debtor: nil,
            remittanceInformation: [merchant], additionalInformation: merchant, purposeCode: nil
        )
    }
}
