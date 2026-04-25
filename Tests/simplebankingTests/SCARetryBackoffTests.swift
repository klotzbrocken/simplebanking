import XCTest
@testable import simplebanking

// MARK: - SCA Retry-Backoff Tests
//
// Schützt gegen Regression des Rate-Limit-Aborts. Vorher: 3 consecutive
// errors → SCA bricht ab → User muss 2FA neu starten. Bei N26/Sparkasse 429
// Bursts war das ein User-Trip-Hazard. Jetzt: 8 consecutive errors mit
// exponentiellem Backoff (cap 30s).

final class SCARetryBackoffTests: XCTestCase {

    // MARK: - exponential growth

    func test_backoff_zero_returnsZero() {
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 0), 0)
    }

    func test_backoff_first_returnsBase() {
        // n=1 → base * 2^0 = 2.0
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 1), 2.0)
    }

    func test_backoff_grows_exponentially() {
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 2), 4.0)
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 3), 8.0)
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 4), 16.0)
    }

    func test_backoff_capped_at30() {
        // 2 * 2^4 = 32 → capped to 30
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 5), 30.0)
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 6), 30.0)
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 8), 30.0)
    }

    func test_backoff_extremeInput_noOverflow() {
        // Defensive: pow(2, 100) würde inf werden — der Helper clamped den
        // Exponenten, also kommt immer der Cap-Wert zurück.
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 1000), 30.0)
    }

    // MARK: - custom base/cap (verwendet von pollRedirect mit kleinerem cap)

    func test_backoff_smallerCap_respected() {
        // pollRedirect verwendet cap=15 (weil eh schon 5s zwischen polls)
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 1, base: 2.0, cap: 15.0), 2.0)
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 4, base: 2.0, cap: 15.0), 15.0)
    }

    func test_backoff_largerBase_respected() {
        // Basis-Variation (für künftige Use-Cases)
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 1, base: 5.0, cap: 60.0), 5.0)
        XCTAssertEqual(YaxiService.scaBackoffSeconds(forConsecutiveErrors: 2, base: 5.0, cap: 60.0), 10.0)
    }

    // MARK: - threshold contract

    func test_threshold_isEightNotThree() {
        // Der Threshold steht in YaxiService.scaMaxConsecutiveErrors. Wenn
        // jemand das auf 3 zurücksetzt, würde dieser Test brechen — Erinnerung
        // dass die Erhöhung intentional war (Rate-Limit-Schutz).
        XCTAssertGreaterThanOrEqual(YaxiService.scaMaxConsecutiveErrors, 8,
            "Threshold darf nicht unter 8 fallen — schützt vor SCA-Abort bei Rate-Limit-Bursts")
    }

    // MARK: - cumulative wait time sanity

    func test_cumulativeBackoff_acrossAllRetries_isReasonable() {
        // 8 retries: 2 + 4 + 8 + 16 + 30 + 30 + 30 + 30 = 150s
        // Plus die natürlichen currentDelay-Pausen (typisch 1-5s) — Gesamtwartezeit
        // bei 8 Errors liegt im 3-4 Min-Bereich. Nicht zu kurz (Rate-Limit-Schutz),
        // nicht zu lang (User wartet sonst ewig).
        let total = (1...8).map { YaxiService.scaBackoffSeconds(forConsecutiveErrors: $0) }.reduce(0, +)
        XCTAssertGreaterThan(total, 100, "Backoff zu kurz, schützt nicht ausreichend gegen Bursts")
        XCTAssertLessThan(total, 300, "Backoff zu lang, User wird ungeduldig")
    }
}
