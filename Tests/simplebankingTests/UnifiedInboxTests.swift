import XCTest

// MARK: - Unified Inbox Unit Tests
//
// These tests cover pure logic that is inlined here to avoid SPM's
// executable-target-cannot-be-imported constraint.
// DB integration tests should be run via the app's built-in diagnostic tools.

final class UnifiedInboxTests: XCTestCase {

    // MARK: - Test 1: Empty slot guard (mirrors TransactionsDatabase.loadUnifiedTransactions)

    func test_loadUnifiedTransactions_emptySlots_returnsEmpty() {
        // The real implementation returns [] immediately without touching SQLite.
        // This test verifies the pure guard logic.
        let slots: [String] = []
        let result = simulatedUnifiedLoad(slots: slots)
        XCTAssertTrue(result.isEmpty, "Empty slot list must return [] without a SQL error")
    }

    /// Mirrors the guard at the top of `loadUnifiedTransactions`.
    private func simulatedUnifiedLoad(slots: [String]?) -> [String] {
        if let slots, slots.isEmpty { return [] }
        return ["mock-transaction"]  // would come from DB in real code
    }

    // MARK: - Test 2: Balance sum

    func test_unifiedBalance_sameCurrency_sums() {
        let result = unifiedBalanceString(amounts: [("EUR", 1000), ("EUR", 500)])
        XCTAssert(result.contains("1500"), "Same-currency balances must be summed: \(result)")
        XCTAssert(result.contains("€"), "Must show EUR symbol: \(result)")
    }

    func test_unifiedBalance_mixedCurrency_showsSeparate() {
        let result = unifiedBalanceString(amounts: [("EUR", 1234), ("USD", 456)])
        XCTAssert(result.contains("€"), "Must show EUR: \(result)")
        XCTAssert(result.contains("$"), "Must show USD: \(result)")
        XCTAssert(result.contains("·"), "Must use separator: \(result)")
    }

    func test_unifiedBalance_threeCurrencies_capsAtTwoPlusN() {
        let result = unifiedBalanceString(amounts: [("EUR", 1234), ("USD", 789), ("GBP", 456)])
        XCTAssert(result.contains("+1"), "Must cap at 2 currencies + '+1': \(result)")
    }

    func test_unifiedBalance_noSlots_returnsNil() {
        let result = unifiedBalanceStringOrNil(amounts: [])
        XCTAssertNil(result, "No cached balances must yield nil")
    }

    // MARK: - Test 3: Internal transfer detection

    func test_internalTransfer_ibansMatch_tagsBothLegs() {
        let ownIBANs: Set<String> = ["DE0011", "DE0022"]
        let txA = FakeTx(amount: -100, date: "2026-03-15", counterpartyIBAN: "DE0022")
        let txB = FakeTx(amount: 100, date: "2026-03-15", counterpartyIBAN: "DE0011")
        let ids = detectTransfers(transactions: [txA, txB], ownIBANs: ownIBANs)
        XCTAssertEqual(ids.count, 2, "Both legs must be tagged")
    }

    func test_internalTransfer_noIbanMatch_noTag() {
        let ownIBANs: Set<String> = ["DE0011", "DE0022"]
        let txA = FakeTx(amount: -100, date: "2026-03-15", counterpartyIBAN: "DE9999")
        let ids = detectTransfers(transactions: [txA], ownIBANs: ownIBANs)
        XCTAssertTrue(ids.isEmpty, "Non-own IBAN must not be tagged")
    }

    func test_internalTransfer_amountMismatchBeyondTolerance_noTag() {
        // 100 vs 101.50: delta = 1.50, exceeds ±0.01 tolerance
        let ownIBANs: Set<String> = ["DE0011", "DE0022"]
        let txA = FakeTx(amount: -100, date: "2026-03-15", counterpartyIBAN: "DE0022")
        let txB = FakeTx(amount: 101.50, date: "2026-03-15", counterpartyIBAN: "DE0011")
        let ids = detectTransfers(transactions: [txA, txB], ownIBANs: ownIBANs)
        XCTAssertTrue(ids.isEmpty, "Amount mismatch beyond ±0.01 must not be tagged")
    }

    func test_internalTransfer_feeWithinTolerance_tagsBothLegs() {
        // 100 vs 99.99: delta = 0.01, within tolerance
        let ownIBANs: Set<String> = ["DE0011", "DE0022"]
        let txA = FakeTx(amount: -100, date: "2026-03-15", counterpartyIBAN: "DE0022")
        let txB = FakeTx(amount: 99.99, date: "2026-03-15", counterpartyIBAN: "DE0011")
        let ids = detectTransfers(transactions: [txA, txB], ownIBANs: ownIBANs)
        XCTAssertEqual(ids.count, 2, "Amount within ±0.01 tolerance must be tagged")
    }

    func test_internalTransfer_dateBeyondOneDayWindow_noTag() {
        let ownIBANs: Set<String> = ["DE0011", "DE0022"]
        let txA = FakeTx(amount: -100, date: "2026-03-15", counterpartyIBAN: "DE0022")
        let txB = FakeTx(amount: 100, date: "2026-03-17", counterpartyIBAN: "DE0011")  // 2 days apart
        let ids = detectTransfers(transactions: [txA, txB], ownIBANs: ownIBANs)
        XCTAssertTrue(ids.isEmpty, "Dates >1 day apart must not be tagged")
    }

    // MARK: - Test 4: lastSeenTxSig migration

    func test_migration_copiesLegacyKey() {
        let defaults = UserDefaults(suiteName: "test-migration-\(UUID())")!
        defaults.set("old-sig", forKey: "lastSeenTxSig")
        defaults.removeObject(forKey: "simplebanking.lastSeenTxSig.legacy")

        migrateLastSeenTxSig(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "simplebanking.lastSeenTxSig.legacy"), "old-sig")
    }

    func test_migration_doesNotOverwriteExistingPerSlotKey() {
        let defaults = UserDefaults(suiteName: "test-migration-\(UUID())")!
        defaults.set("old-sig", forKey: "lastSeenTxSig")
        defaults.set("already-set", forKey: "simplebanking.lastSeenTxSig.legacy")

        migrateLastSeenTxSig(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "simplebanking.lastSeenTxSig.legacy"), "already-set")
    }
}

// MARK: - Test helpers

private struct FakeTx {
    let id: String = UUID().uuidString
    let amount: Double
    let date: String
    let counterpartyIBAN: String
}

private let isoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func dayDiff(_ a: String, _ b: String) -> Int {
    guard let da = isoDateFormatter.date(from: a),
          let db = isoDateFormatter.date(from: b) else { return Int.max }
    return abs(Calendar(identifier: .gregorian).dateComponents([.day], from: da, to: db).day ?? Int.max)
}

/// Pure internal-transfer detection (mirrors TransactionsViewModel.detectInternalTransfers).
private func detectTransfers(transactions: [FakeTx], ownIBANs: Set<String>) -> Set<String> {
    var found: Set<String> = []
    for i in 0..<transactions.count {
        let a = transactions[i]
        guard ownIBANs.contains(a.counterpartyIBAN) else { continue }
        for j in (i + 1)..<transactions.count {
            let b = transactions[j]
            guard ownIBANs.contains(b.counterpartyIBAN) else { continue }
            guard abs(abs(a.amount) - abs(b.amount)) < 0.015 else { continue }  // ±€0.01 tolerance
            guard dayDiff(a.date, b.date) <= 1 else { continue }
            found.insert(a.id)
            found.insert(b.id)
        }
    }
    return found
}

/// Pure unified balance formatter (mirrors BalanceBar.computeUnifiedBalanceTitle).
private func unifiedBalanceString(amounts: [(String, Double)]) -> String {
    var byCurrency: [String: Double] = [:]
    for (currency, amount) in amounts {
        byCurrency[currency, default: 0] += amount
    }
    let sorted = byCurrency.sorted { abs($0.value) > abs($1.value) }
    func sym(_ c: String) -> String {
        switch c { case "EUR": return "€"; case "USD": return "$"; case "GBP": return "£"; default: return c }
    }
    func fmt(_ c: String, _ v: Double) -> String { "\(sym(c)) \(Int(abs(v)))" }
    var parts = sorted.prefix(2).map { fmt($0.key, $0.value) }
    let overflow = sorted.count - 2
    if overflow > 0 { parts.append("+\(overflow)") }
    return parts.joined(separator: " · ")
}

private func unifiedBalanceStringOrNil(amounts: [(String, Double)]) -> String? {
    var byCurrency: [String: Double] = [:]
    for (currency, amount) in amounts { byCurrency[currency, default: 0] += amount }
    guard !byCurrency.isEmpty else { return nil }
    return unifiedBalanceString(amounts: amounts)
}

/// Mirrors BalanceBar.migrateLastSeenTxSigIfNeeded.
private func migrateLastSeenTxSig(defaults: UserDefaults) {
    let legacyKey = "simplebanking.lastSeenTxSig.legacy"
    guard defaults.string(forKey: legacyKey) == nil,
          let old = defaults.string(forKey: "lastSeenTxSig"), !old.isEmpty else { return }
    defaults.set(old, forKey: legacyKey)
}
