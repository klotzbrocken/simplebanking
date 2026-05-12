import XCTest
@testable import simplebanking

/// Tests für `LicenseManager.initialStatusFromCache(...)` — die pure Funktion,
/// die den synchronen Start-Status anhand von Keychain-Präsenz + persistiertem
/// `lastValidatedAt` berechnet.
///
/// Bug-Hintergrund (2026-05-11): der alte Init setzte `.licensed` sofort,
/// sobald ein Key + `lastValidatedAt` existierten — unabhängig vom Alter.
/// Damit konnte `sendMoney()` einen Transfer mit dem Transfer-Pair signieren,
/// obwohl die 14-Tage-Offline-Grace bereits abgelaufen war.
@MainActor
final class LicenseManagerInitialStatusTests: XCTestCase {

    private let grace: TimeInterval = 14 * 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // fixed anchor

    func test_noKey_returnsUnlicensed() {
        let status = LicenseManager.initialStatusFromCache(
            hasKey: false,
            lastValidatedAt: now.addingTimeInterval(-3600),
            now: now,
            gracePeriod: grace
        )
        XCTAssertEqual(status, .unlicensed)
    }

    func test_keyButNoValidationDate_returnsUnlicensed() {
        // Key vorhanden, aber lastValidatedAt nie gesetzt → war nie verifiziert.
        let status = LicenseManager.initialStatusFromCache(
            hasKey: true,
            lastValidatedAt: nil,
            now: now,
            gracePeriod: grace
        )
        XCTAssertEqual(status, .unlicensed)
    }

    func test_keyAndRecentValidation_returnsOfflineGrace() {
        let last = now.addingTimeInterval(-(24 * 60 * 60))   // 1 Tag alt
        let status = LicenseManager.initialStatusFromCache(
            hasKey: true,
            lastValidatedAt: last,
            now: now,
            gracePeriod: grace
        )
        XCTAssertEqual(status, .offlineGrace(lastValidatedAt: last))
    }

    func test_keyAndValidationAtExactGraceBoundary_returnsUnlicensed() {
        // age == gracePeriod → außerhalb (Grenze inklusiv unten, exklusiv oben).
        let last = now.addingTimeInterval(-grace)
        let status = LicenseManager.initialStatusFromCache(
            hasKey: true,
            lastValidatedAt: last,
            now: now,
            gracePeriod: grace
        )
        XCTAssertEqual(status, .unlicensed)
    }

    func test_keyAndOldValidation_returnsUnlicensed() {
        let last = now.addingTimeInterval(-(15 * 24 * 60 * 60))   // 15 Tage alt
        let status = LicenseManager.initialStatusFromCache(
            hasKey: true,
            lastValidatedAt: last,
            now: now,
            gracePeriod: grace
        )
        XCTAssertEqual(status, .unlicensed)
    }

    func test_keyAndFutureValidation_returnsUnlicensed() {
        // Clock-Skew / Datums-Reset: lastValidatedAt liegt in der Zukunft.
        // Defensiv als „abgelaufen" behandeln, sonst hätte ein Angreifer
        // mit Datum-vor-Reset-Trick freie Bahn.
        let last = now.addingTimeInterval(60 * 60)   // 1h in der Zukunft
        let status = LicenseManager.initialStatusFromCache(
            hasKey: true,
            lastValidatedAt: last,
            now: now,
            gracePeriod: grace
        )
        XCTAssertEqual(status, .unlicensed)
    }
}
