import XCTest
@testable import simplebanking

// MARK: - SessionStore Slot-Isolation Tests
//
// Regression-Gate für den Aileen-Bug 2026-05-19:
// Vor dem Refactor hatte `SessionStore` vier globale in-memory Felder
// (balancesSession, transactionsSession, transferSession, storedConnectionData),
// die durch `reloadForActiveSlot()` zwischen Slots umgeswitcht wurden. Bei
// einem fetchBalances/fetchTransactions OHNE vorangegangenen Reload landete
// das active-slot-Material in den Bank-Call eines nicht-aktiven Slots —
// User mit mehreren Konten unter einer Bank sahen nur EIN Konto.
//
// Diese Tests sichern, dass jeder Slot seinen eigenen in-memory State hat
// und Reads für Slot A nie Slot B's Daten zurückgeben.

@MainActor
final class SessionStoreSlotIsolationTests: XCTestCase {

    private let slotA = "test-slot-A-7e8f"
    private let slotB = "test-slot-B-1b2c"
    private let slotC = "test-slot-C-3d4e"

    override func tearDown() async throws {
        let store = YaxiService.sessionStore
        for slot in [slotA, slotB, slotC, "legacy"] {
            await store.clearAll(slotId: slot)
            await store.invalidateCache(slotId: slot)
        }
        try await super.tearDown()
    }

    func test_connectionData_isolated_per_slot() async {
        let store = YaxiService.sessionStore
        let cdA = Data("conn-data-slot-A".utf8)
        let cdB = Data("conn-data-slot-B".utf8)

        await store.updateConnectionData(cdA, slotId: slotA)
        await store.updateConnectionData(cdB, slotId: slotB)

        let readA = await store.connectionData(slotId: slotA)
        let readB = await store.connectionData(slotId: slotB)

        XCTAssertEqual(readA, cdA, "Slot A muss seine eigene connectionData zurückbekommen")
        XCTAssertEqual(readB, cdB, "Slot B muss seine eigene connectionData zurückbekommen")
        XCTAssertNotEqual(readA, readB, "Slots dürfen kein Cross-Talk haben")
    }

    func test_sessions_isolated_per_slot_per_scope() async {
        let store = YaxiService.sessionStore
        let balA = Data("bal-A".utf8)
        let txA  = Data("tx-A".utf8)
        let balB = Data("bal-B".utf8)

        await store.update(scope: .balances,     session: balA, connectionData: nil, slotId: slotA)
        await store.update(scope: .transactions, session: txA,  connectionData: nil, slotId: slotA)
        await store.update(scope: .balances,     session: balB, connectionData: nil, slotId: slotB)

        let aBal = await store.session(for: .balances,     slotId: slotA)
        let aTx  = await store.session(for: .transactions, slotId: slotA)
        let bBal = await store.session(for: .balances,     slotId: slotB)
        let bTx  = await store.session(for: .transactions, slotId: slotB)

        XCTAssertEqual(aBal, balA)
        XCTAssertEqual(aTx,  txA)
        XCTAssertEqual(bBal, balB)
        XCTAssertNil(  bTx, "Slot B hat nie eine transactions-Session bekommen — darf nicht von Slot A leaken")
    }

    func test_aileen_bug_reproducer() async {
        // Slot A schreibt connectionData; Slot B liest — soll NICHT A's Daten sehen.
        let store = YaxiService.sessionStore
        let cdA = Data("A-secret-1234".utf8)
        let cdB = Data("B-secret-5678".utf8)

        await store.updateConnectionData(cdA, slotId: slotA)
        let readBeforeB = await store.connectionData(slotId: slotB)
        XCTAssertNil(readBeforeB, "Slot B ohne eigene connectionData darf nicht Slot A's Daten leaken")

        await store.updateConnectionData(cdB, slotId: slotB)
        let readAfterA = await store.connectionData(slotId: slotA)
        let readAfterB = await store.connectionData(slotId: slotB)
        XCTAssertEqual(readAfterA, cdA, "Slot A unverändert")
        XCTAssertEqual(readAfterB, cdB, "Slot B hat eigene Daten")
    }

    func test_clearAll_only_affects_target_slot() async {
        let store = YaxiService.sessionStore
        await store.updateConnectionData(Data("A".utf8), slotId: slotA)
        await store.updateConnectionData(Data("B".utf8), slotId: slotB)
        await store.updateConnectionData(Data("C".utf8), slotId: slotC)

        await store.clearAll(slotId: slotB)

        let a = await store.connectionData(slotId: slotA)
        let b = await store.connectionData(slotId: slotB)
        let c = await store.connectionData(slotId: slotC)
        XCTAssertNotNil(a, "Slot A sollte nach clearAll(B) noch da sein")
        XCTAssertNil(   b, "Slot B sollte leer sein")
        XCTAssertNotNil(c, "Slot C sollte nach clearAll(B) noch da sein")
    }

    func test_clearSessionsOnly_preserves_connectionData() async {
        let store = YaxiService.sessionStore
        let cd = Data("conn-data".utf8)
        let session = Data("balances-session".utf8)
        await store.update(scope: .balances, session: session, connectionData: cd, slotId: slotA)

        await store.clearSessionsOnly(slotId: slotA)

        let bal = await store.session(for: .balances, slotId: slotA)
        let storedCD = await store.connectionData(slotId: slotA)
        XCTAssertNil(bal, "Session muss weg sein")
        XCTAssertEqual(storedCD, cd, "connectionData muss erhalten bleiben")
    }

    func test_clearConnectionDataOnly_preserves_sessions() async {
        let store = YaxiService.sessionStore
        let cd = Data("conn-data".utf8)
        let session = Data("balances-session".utf8)
        await store.update(scope: .balances, session: session, connectionData: cd, slotId: slotA)

        await store.clearConnectionDataOnly(slotId: slotA)

        let storedCD = await store.connectionData(slotId: slotA)
        let bal = await store.session(for: .balances, slotId: slotA)
        XCTAssertNil(storedCD, "connectionData muss weg sein")
        XCTAssertEqual(bal, session, "Session muss erhalten bleiben")
    }

    func test_copyConnectionDataAndSessions_invalidates_target_cache() async {
        let store = YaxiService.sessionStore
        let cdA = Data("source-A".utf8)
        let cdB_old = Data("old-B-data".utf8)

        await store.updateConnectionData(cdA, slotId: slotA)
        await store.updateConnectionData(cdB_old, slotId: slotB)
        // Vorab-Read um sicher in den Cache zu kommen
        _ = await store.connectionData(slotId: slotB)

        await store.copyConnectionDataAndSessions(fromSlotId: slotA, toSlotId: slotB)

        let readB = await store.connectionData(slotId: slotB)
        XCTAssertEqual(readB, cdA, "Target-Slot muss nach Copy die Source-Daten sehen, nicht den stale Memory-Cache")
    }

    func test_invalidateCache_does_not_lose_disk_data() async {
        let store = YaxiService.sessionStore
        let initial = Data("initial".utf8)
        await store.updateConnectionData(initial, slotId: slotA)
        _ = await store.connectionData(slotId: slotA)  // populate cache

        await store.invalidateCache(slotId: slotA)

        let afterInvalidate = await store.connectionData(slotId: slotA)
        XCTAssertEqual(afterInvalidate, initial, "Disk-Daten müssen nach Invalidate weiterhin gelesen werden")
    }
}
