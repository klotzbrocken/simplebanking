import XCTest
@testable import simplebanking

// MARK: - BankRequestQueue Tests
//
// P1.1 regression: The earlier `defer { Task { await release } }` pattern
// could leave `inFlight` populated past the function return, making
// directly-sequential follow-up calls falsely see "bank busy". `withSlot`
// uses an in-actor `defer` so release is guaranteed before return.

final class BankRequestQueueTests: XCTestCase {

    func test_withSlot_releasesAfterSuccess() async {
        let q = BankRequestQueue()
        let r = await q.withSlot("A") { return 42 }
        XCTAssertEqual(r, 42)
        let busy = await q.isBusy(slotId: "A")
        XCTAssertFalse(busy)
    }

    func test_withSlot_releasesAfterThrow() async {
        struct Boom: Error {}
        let q = BankRequestQueue()
        do {
            _ = try await q.withSlot("A") { throw Boom() }
            XCTFail("should have thrown")
        } catch {
            // expected
        }
        let busy = await q.isBusy(slotId: "A")
        XCTAssertFalse(busy)
    }

    func test_withSlot_secondCallReturnsNilWhileBusy() async {
        let q = BankRequestQueue()
        async let first: Int? = q.withSlot("A") {
            try? await Task.sleep(nanoseconds: 100_000_000)  // hold the slot ~100ms
            return 1
        }
        try? await Task.sleep(nanoseconds: 10_000_000)  // ensure first has acquired
        let second = await q.withSlot("A") { return 2 }
        XCTAssertNil(second, "concurrent call must see slot as busy")
        let firstResult = await first
        XCTAssertEqual(firstResult, 1)
        let busyAfter = await q.isBusy(slotId: "A")
        XCTAssertFalse(busyAfter)
    }

    /// Regression for P1.1: directly-sequential calls must both succeed.
    /// Old async-defer pattern caused the second call to see "bank busy"
    /// because release was scheduled rather than run.
    func test_withSlot_sequentialCallsBothSucceed() async {
        let q = BankRequestQueue()
        let r1 = await q.withSlot("A") { return 1 }
        let r2 = await q.withSlot("A") { return 2 }
        XCTAssertEqual(r1, 1)
        XCTAssertEqual(r2, 2)
    }

    func test_withSlot_differentSlotsRunInParallel() async {
        let q = BankRequestQueue()
        async let a = q.withSlot("A") {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "A"
        }
        async let b = q.withSlot("B") {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "B"
        }
        let (ra, rb) = await (a, b)
        XCTAssertEqual(ra, "A")
        XCTAssertEqual(rb, "B")
    }
}
