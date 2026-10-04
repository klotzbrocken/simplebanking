import XCTest
import MCPRahmen

/// `prepare_transfer` ist seit 04.10.2026 wieder da — gebunden an eine aktive
/// simplesend-Lizenz. Diese Rechnung entscheidet darüber. Sie ist absichtlich dieselbe,
/// die die App ohne Netz anlegt: Die letzte Server-Bestätigung liegt im Gnadenfenster.
///
/// Den Schlüssel selbst liest der Server nicht — er steht im Schlüsselbund, und ein
/// zweites Binary, das ihn anfasst, fragt den Nutzer um Freigabe. Der Zeitstempel trägt
/// dieselbe Aussage: `LicenseManager` setzt ihn nur nach erfolgreicher Bestätigung und
/// löscht ihn in `deactivateLocally()` zusammen mit dem Schlüssel.
final class LizenzFensterTests: XCTestCase {

    private let jetzt = Date(timeIntervalSince1970: 1_790_000_000)
    private let tag: TimeInterval = 24 * 60 * 60

    private func aktiv(_ bestaetigt: Date?) -> Bool {
        LizenzFenster.istAktiv(bestaetigtAm: bestaetigt, jetzt: jetzt)
    }

    // MARK: - Der Normalfall

    func test_frischBestaetigt_istAktiv() {
        XCTAssertTrue(aktiv(jetzt.addingTimeInterval(-tag)))
    }

    func test_geradeEben_istAktiv() {
        XCTAssertTrue(aktiv(jetzt))
    }

    // MARK: - Was ohne Lizenz passiert

    /// Die wichtigste Zeile: Ohne Bestätigung gibt es das Werkzeug nicht. Eine App, die
    /// nie eine Lizenz gesehen hat, hat diesen Schlüssel gar nicht gesetzt.
    func test_ohneBestaetigung_nie() {
        XCTAssertFalse(aktiv(nil))
    }

    // MARK: - Die Ränder des Gnadenfensters

    func test_knappInnerhalb_istAktiv() {
        XCTAssertTrue(aktiv(jetzt.addingTimeInterval(-LizenzFenster.gnadenfenster + 60)))
    }

    func test_genauAmRand_istNichtMehrAktiv() {
        XCTAssertFalse(aktiv(jetzt.addingTimeInterval(-LizenzFenster.gnadenfenster)))
    }

    func test_laengstAbgelaufen_istNichtAktiv() {
        XCTAssertFalse(aktiv(jetzt.addingTimeInterval(-100 * tag)))
    }

    /// Ein Zeitstempel in der Zukunft heißt verstellte Uhr oder zurückgedrehtes Datum.
    /// Das als „besonders frisch" zu lesen wäre genau der falsche Schluss — dann
    /// verlängerte eine falsch gestellte Uhr die Lizenz beliebig.
    func test_zeitstempelInDerZukunft_zaehltAlsAbgelaufen() {
        XCTAssertFalse(aktiv(jetzt.addingTimeInterval(tag)))
    }

    /// Das Fenster muss zu `LicenseConfig.offlineGracePeriod` passen. Läuft es
    /// auseinander, bietet der Server das Werkzeug an, während die App die Lizenz
    /// längst für abgelaufen hält — oder umgekehrt.
    func test_fensterIstVierzehnTage() {
        XCTAssertEqual(LizenzFenster.gnadenfenster, 14 * 24 * 60 * 60)
    }
}
