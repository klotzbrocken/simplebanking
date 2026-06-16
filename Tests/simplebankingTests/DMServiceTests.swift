import XCTest
@testable import simplebanking

final class DMServiceTests: XCTestCase {

    // MARK: - Preis-Parsing (DAN-Auflösung)

    func test_parsePriceCents_handlesNonBreakingSpaceAndComma() {
        XCTAssertEqual(DMService.parsePriceCents("1,25\u{00a0}€"), 125)
        XCTAssertEqual(DMService.parsePriceCents("1,25 €"), 125)
        XCTAssertEqual(DMService.parsePriceCents("0,95 €"), 95)
        XCTAssertEqual(DMService.parsePriceCents("12,99 €"), 1299)
        XCTAssertEqual(DMService.parsePriceCents("1.299,00 €"), 129900)
    }

    func test_parsePriceCents_returnsNilOnGarbage() {
        XCTAssertNil(DMService.parsePriceCents("—"))
        XCTAssertNil(DMService.parsePriceCents(""))
    }

    // MARK: - JWT-Ablauf

    /// Baut ein Minimal-JWT mit gegebenem `exp` (nur der Payload zählt für isExpired).
    private func jwt(exp: Double) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": exp])
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(b64).sig"
    }

    func test_isExpired_trueForPastExp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(DMService.isExpired(jwt(exp: 999_000), now: now))
    }

    func test_isExpired_falseForFutureExp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(DMService.isExpired(jwt(exp: 1_000_300), now: now))
    }

    func test_isExpired_falseForUnparsableToken() {
        XCTAssertFalse(DMService.isExpired("not-a-jwt"))
        XCTAssertFalse(DMService.isExpired(""))
    }
}
