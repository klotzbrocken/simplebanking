import XCTest
import Sparkle
@testable import simplebanking

@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: - istFortsetzFehler

    func testFortsetzFehlerWirdErkannt() {
        let fehler = NSError(domain: SUSparkleErrorDomain,
                             code: Int(SUError.resumeAppcastError.rawValue),
                             userInfo: [NSLocalizedDescriptionKey: "Failed to resume installing update."])
        XCTAssertTrue(UpdateChecker.istFortsetzFehler(fehler))
    }

    func testAndererSparkleFehlerLoestKeinAufraeumenAus() {
        // Eine abgelehnte Signatur heilt kein Aufräumen — und ein Aufräumen
        // verdeckte sie nur.
        let fehler = NSError(domain: SUSparkleErrorDomain,
                             code: Int(SUError.signatureError.rawValue))
        XCTAssertFalse(UpdateChecker.istFortsetzFehler(fehler))
    }

    func testFremderFehlerbereichZaehltNicht() {
        let fehler = NSError(domain: NSURLErrorDomain,
                             code: Int(SUError.resumeAppcastError.rawValue))
        XCTAssertFalse(UpdateChecker.istFortsetzFehler(fehler))
    }

    // MARK: - Aufräumziele

    func testLaunchdAuftraegeHeissenWieSparkleSieEintraegt() {
        XCTAssertEqual(UpdateChecker.launchdAuftraege(bundleId: "tech.yaxi.simplebanking"),
                       ["tech.yaxi.simplebanking-sparkle-progress",
                        "tech.yaxi.simplebanking-sparkle-updater"])
    }

    func testCacheOrdnerLiegtUnterBundleIdUndSparkle() {
        let wurzel = URL(fileURLWithPath: "/Users/test/Library/Caches", isDirectory: true)
        let ordner = UpdateChecker.sparkleCacheOrdner(bundleId: "tech.yaxi.simplebanking",
                                                      cachesWurzel: wurzel)
        XCTAssertEqual(ordner.path,
                       "/Users/test/Library/Caches/tech.yaxi.simplebanking/org.sparkle-project.Sparkle")
    }
}

// MARK: - Höhe des Flyouts mit Update-Band

/// Die Flyout-Höhe stand an drei Stellen fest verdrahtet; das Band ist der erste
/// Summand, der dazukommt. Diese Tests halten fest, dass er genau dann zählt, wenn
/// das Band auch sichtbar ist — ein vergessener Summand schneidet den Inhalt ab.
final class FlyoutHoeheTests: XCTestCase {

    func testOhneUpdateBleibtDieHoeheWieBisher() {
        XCTAssertEqual(
            Flyoutmasse.fensterhoehe(hasDots: false, updateVersion: nil, drawerOffen: false),
            140)
        XCTAssertEqual(
            Flyoutmasse.fensterhoehe(hasDots: true, updateVersion: nil, drawerOffen: false),
            178)
    }

    func testMitUpdateKommtGenauDasBandDazu() {
        let ohne = Flyoutmasse.fensterhoehe(hasDots: false, updateVersion: nil, drawerOffen: false)
        let mit = Flyoutmasse.fensterhoehe(hasDots: false, updateVersion: "2.1.0", drawerOffen: false)
        XCTAssertEqual(mit - ohne, Flyoutmasse.updateBandHoehe)
    }

    /// Band und Drawer schließen sich nicht aus — beide verlängern dasselbe Fenster.
    func testBandUndDrawerAddierenSich() {
        XCTAssertEqual(
            Flyoutmasse.fensterhoehe(hasDots: true, updateVersion: "2.1.0", drawerOffen: true),
            178 + Flyoutmasse.updateBandHoehe + QuickSendDrawerView.totalDrawerHeight)
    }
}
