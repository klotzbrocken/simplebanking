import XCTest
@testable import simplebanking

// MARK: - YaxiOAuthCallback Path-Matcher Tests
//
// Schützt gegen Random-Hits auf den lokalen Listener (Port-Scanner,
// Browser-Probes, andere lokale Services). Nur die exakte Callback-URL
// die wir bei Routex registrieren darf den Polling-Wakeup auslösen.

final class YaxiOAuthCallbackTests: XCTestCase {

    // MARK: - happy path

    func test_matchesExpectedPath_simpleGET() {
        let req = "GET /simplebanking-auth-callback HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertTrue(YaxiOAuthCallback.requestMatchesExpectedPath(data: req.data(using: .utf8)))
    }

    func test_matchesExpectedPath_withQueryString() {
        // Bank/Routex könnten Query-Parameter dranhängen — Path soll trotzdem matchen.
        let req = "GET /simplebanking-auth-callback?status=ok&foo=bar HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertTrue(YaxiOAuthCallback.requestMatchesExpectedPath(data: req.data(using: .utf8)))
    }

    func test_matchesExpectedPath_postMethod() {
        // Falls eine Bank POST statt GET nutzt — auch ok.
        let req = "POST /simplebanking-auth-callback HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertTrue(YaxiOAuthCallback.requestMatchesExpectedPath(data: req.data(using: .utf8)))
    }

    // MARK: - rejection paths

    func test_doesNotMatch_rootPath() {
        // Browser-Probe auf "/" darf NICHT triggern.
        let req = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertFalse(YaxiOAuthCallback.requestMatchesExpectedPath(data: req.data(using: .utf8)))
    }

    func test_doesNotMatch_arbitraryPath() {
        let req = "GET /admin HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertFalse(YaxiOAuthCallback.requestMatchesExpectedPath(data: req.data(using: .utf8)))
    }

    func test_doesNotMatch_pathPrefix() {
        // "/simplebanking-auth-callback-extra" darf nicht matchen (kein prefix-match).
        let req = "GET /simplebanking-auth-callback-extra HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertFalse(YaxiOAuthCallback.requestMatchesExpectedPath(data: req.data(using: .utf8)))
    }

    func test_doesNotMatch_pathSuffix() {
        let req = "GET /something/simplebanking-auth-callback HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertFalse(YaxiOAuthCallback.requestMatchesExpectedPath(data: req.data(using: .utf8)))
    }

    func test_doesNotMatch_emptyData() {
        XCTAssertFalse(YaxiOAuthCallback.requestMatchesExpectedPath(data: nil))
        XCTAssertFalse(YaxiOAuthCallback.requestMatchesExpectedPath(data: Data()))
    }

    func test_doesNotMatch_garbageData() {
        // Random TCP-Garbage (z.B. wenn jemand non-HTTP-Daten schickt).
        let garbage = Data([0x00, 0x01, 0xFF, 0xFE, 0xCA, 0xFE])
        XCTAssertFalse(YaxiOAuthCallback.requestMatchesExpectedPath(data: garbage))
    }

    func test_doesNotMatch_partialRequestLine() {
        // Nur Methode, kein Path → reject.
        let req = "GET\r\n"
        XCTAssertFalse(YaxiOAuthCallback.requestMatchesExpectedPath(data: req.data(using: .utf8)))
    }
}
