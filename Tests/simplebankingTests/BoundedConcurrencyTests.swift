import XCTest
@testable import simplebanking

final class BoundedConcurrencyTests: XCTestCase {

    /// Zählt gleichzeitig laufende Tasks und merkt sich das beobachtete Maximum.
    private actor ConcurrencyGauge {
        private(set) var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    func test_preservesInputOrder() async throws {
        let input = Array(0..<20)
        // Frühe Elemente künstlich langsamer → würde Reihenfolge brechen, wenn
        // nach Fertigstellung statt nach Index einsortiert würde.
        let out = try await boundedConcurrentMap(input, maxConcurrent: 5) { n -> Int in
            try await Task.sleep(nanoseconds: UInt64((20 - n)) * 1_000_000)
            return n * 10
        }
        XCTAssertEqual(out, input.map { $0 * 10 })
    }

    func test_respectsConcurrencyLimit() async throws {
        let gauge = ConcurrencyGauge()
        _ = try await boundedConcurrentMap(Array(0..<30), maxConcurrent: 4) { _ -> Int in
            await gauge.enter()
            try await Task.sleep(nanoseconds: 2_000_000)
            await gauge.leave()
            return 0
        }
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, 4, "Fenster überschritten (peak \(peak))")
        XCTAssertGreaterThan(peak, 1, "Es lief offenbar nichts parallel")
    }

    func test_emptyInput() async throws {
        let out = try await boundedConcurrentMap([Int](), maxConcurrent: 3) { $0 }
        XCTAssertTrue(out.isEmpty)
    }

    struct Boom: Error {}

    func test_propagatesError() async {
        do {
            _ = try await boundedConcurrentMap(Array(0..<10), maxConcurrent: 3) { n -> Int in
                if n == 7 { throw Boom() }
                try await Task.sleep(nanoseconds: 1_000_000)
                return n
            }
            XCTFail("Fehler hätte propagiert werden müssen")
        } catch is Boom {
            // erwartet
        } catch {
            XCTFail("Falscher Fehlertyp: \(error)")
        }
    }

    func test_allResultsPresent() async throws {
        let out = try await boundedConcurrentMap(Array(1...50), maxConcurrent: 8) { $0 * $0 }
        XCTAssertEqual(out.count, 50)
        XCTAssertEqual(Set(out), Set((1...50).map { $0 * $0 }))
    }
}
