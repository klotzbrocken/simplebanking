import XCTest
@testable import simplebanking

// MARK: - AIHTTPError tests
//
// Vorher: User sah "AI API Fehler (401)" für ungültigen Key UND "AI API Fehler
// (429)" für Rate-Limit — beide nicht actionable. Jetzt: status-spezifische
// Texte + Retry-After-parsing.

final class AIHTTPErrorTests: XCTestCase {

    private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    // MARK: - status code mapping

    func test_401_mapsToUnauthorized() {
        let err = AIHTTPError.from(provider: "Anthropic", response: response(status: 401))
        XCTAssertEqual(err, .unauthorized(provider: "Anthropic"))
        XCTAssertFalse(err.isRetryable, "401 = key falsch, retry sinnlos")
    }

    func test_403_mapsToForbidden() {
        let err = AIHTTPError.from(provider: "OpenAI", response: response(status: 403))
        XCTAssertEqual(err, .forbidden(provider: "OpenAI"))
        XCTAssertFalse(err.isRetryable)
    }

    func test_429_withRetryAfter_parsesSeconds() {
        let err = AIHTTPError.from(
            provider: "Mistral",
            response: response(status: 429, headers: ["Retry-After": "120"]))
        XCTAssertEqual(err, .rateLimited(provider: "Mistral", retryAfterSeconds: 120))
        XCTAssertTrue(err.isRetryable)
    }

    func test_429_withoutRetryAfter_yieldsNilRetryHint() {
        let err = AIHTTPError.from(provider: "Mistral", response: response(status: 429))
        XCTAssertEqual(err, .rateLimited(provider: "Mistral", retryAfterSeconds: nil))
    }

    func test_429_withInvalidRetryAfter_yieldsNil() {
        // HTTP-Date format wird nicht geparst — wir handhaben nur numeric.
        let err = AIHTTPError.from(
            provider: "Mistral",
            response: response(status: 429, headers: ["Retry-After": "Wed, 21 Oct 2025 07:28:00 GMT"]))
        XCTAssertEqual(err, .rateLimited(provider: "Mistral", retryAfterSeconds: nil))
    }

    func test_500_mapsToServerError() {
        let err = AIHTTPError.from(provider: "Anthropic", response: response(status: 500))
        XCTAssertEqual(err, .serverError(provider: "Anthropic", statusCode: 500))
        XCTAssertTrue(err.isRetryable)
    }

    func test_503_mapsToServerError() {
        let err = AIHTTPError.from(provider: "OpenAI", response: response(status: 503))
        XCTAssertEqual(err, .serverError(provider: "OpenAI", statusCode: 503))
    }

    func test_400_mapsToClientError() {
        let err = AIHTTPError.from(provider: "Anthropic", response: response(status: 400))
        XCTAssertEqual(err, .clientError(provider: "Anthropic", statusCode: 400))
        XCTAssertFalse(err.isRetryable, "Bad-Request retry hilft nicht — Request ist invalid")
    }

    // MARK: - localizedDescription has actionable hint

    func test_unauthorized_messageMentionsKey() {
        let err = AIHTTPError.unauthorized(provider: "Anthropic")
        XCTAssertNotNil(err.errorDescription)
        let msg = err.errorDescription!
        XCTAssertTrue(msg.contains("Anthropic"))
        // Either German "Schlüssel" or English "key"
        XCTAssertTrue(msg.contains("Schlüssel") || msg.contains("key"),
            "Unauthorized message muss API-Key erwähnen damit User weiß was zu tun ist")
    }

    func test_rateLimited_withSeconds_mentionsRetryAfter() {
        let err = AIHTTPError.rateLimited(provider: "Mistral", retryAfterSeconds: 60)
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("60"), "Retry-After Sekunden müssen im Text auftauchen")
    }

    func test_rateLimited_withoutSeconds_mentionsRateLimit() {
        let err = AIHTTPError.rateLimited(provider: "Mistral", retryAfterSeconds: nil)
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("Rate") || msg.contains("rate"))
    }

    func test_allCases_haveErrorDescription() {
        let cases: [AIHTTPError] = [
            .unauthorized(provider: "X"),
            .forbidden(provider: "X"),
            .rateLimited(provider: "X", retryAfterSeconds: nil),
            .rateLimited(provider: "X", retryAfterSeconds: 30),
            .serverError(provider: "X", statusCode: 500),
            .clientError(provider: "X", statusCode: 400)
        ]
        for c in cases {
            XCTAssertNotNil(c.errorDescription, "errorDescription fehlt für \(c)")
            XCTAssertFalse(c.errorDescription?.isEmpty ?? true)
        }
    }
}
