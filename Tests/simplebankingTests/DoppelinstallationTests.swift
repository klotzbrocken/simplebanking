import XCTest
@testable import simplebanking

/// Gemeldet am 23.09.2026: Eine Spotlight-Aktion endete mit „LinkDaemon.ProcessRegistry.
/// Errors-Fehler 0". Ursache waren zwei registrierte Kopien der App — macOS schickte die
/// Aktion an die eine, laufen tat die andere. Diese Tests sichern die Pfadprüfung ab, an
/// der das erkannt wird; sie ist reine Zeichenkettenarbeit und darum hier prüfbar.
final class DoppelinstallationTests: XCTestCase {

    private func url(_ pfad: String) -> URL { URL(fileURLWithPath: pfad) }

    // MARK: - Der gemeldete Fall

    func test_zweiKopien_werdenErkannt() {
        let befund = Doppelinstallation.vergleichen(
            laufend: url("/Users/maik/simplebanking/SimpleBankingBuild/simplebanking.app"),
            registriert: url("/Applications/simplebanking.app"))
        XCTAssertEqual(befund, .andereKopieRegistriert(bevorzugt: url("/Applications/simplebanking.app")))
    }

    func test_einzigeKopie_meldetNichts() {
        let befund = Doppelinstallation.vergleichen(
            laufend: url("/Applications/simplebanking.app"),
            registriert: url("/Applications/simplebanking.app"))
        XCTAssertEqual(befund, .stimmigÜberein)
    }

    func test_ohneRegistrierung_bleibtEsUnbekannt() {
        // Frisch kopiert und noch nicht indiziert: lieber schweigen als falsch warnen.
        XCTAssertEqual(Doppelinstallation.vergleichen(laufend: url("/Applications/simplebanking.app"),
                                                      registriert: nil),
                       .unbekannt)
    }

    // MARK: - Schreibweisen desselben Pfads

    func test_abschliessenderSchraegstrichIstDerselbePfad() {
        // `bundleURL` liefert je nach Weg mal mit, mal ohne Schrägstrich.
        XCTAssertEqual(Doppelinstallation.vergleichen(laufend: url("/Applications/simplebanking.app/"),
                                                     registriert: url("/Applications/simplebanking.app")),
                       .stimmigÜberein)
    }

    func test_privateVarUndVarSindDerselbePfad() {
        // /var ist ein Symlink auf /private/var; LaunchServices und Bundle melden das
        // unterschiedlich. Ohne diese Normierung warnte die App vor sich selbst.
        let a = url("/private/var/folders/xy/simplebanking.app")
        let b = url("/var/folders/xy/simplebanking.app")
        XCTAssertEqual(Doppelinstallation.normiert(a), Doppelinstallation.normiert(b))
        XCTAssertEqual(Doppelinstallation.vergleichen(laufend: a, registriert: b), .stimmigÜberein)
    }

    func test_punktKomponentenWerdenAufgeloest() {
        XCTAssertEqual(Doppelinstallation.vergleichen(
            laufend: url("/Applications/./simplebanking.app"),
            registriert: url("/Applications/Utilities/../simplebanking.app")),
                       .stimmigÜberein)
    }

    // MARK: - Fälle, die Nutzer wirklich treffen

    func test_startAusDemDownloadOrdner_wirdGemeldet() {
        let befund = Doppelinstallation.vergleichen(
            laufend: url("/Users/anna/Downloads/simplebanking.app"),
            registriert: url("/Applications/simplebanking.app"))
        XCTAssertEqual(befund, .andereKopieRegistriert(bevorzugt: url("/Applications/simplebanking.app")))
    }

    func test_startVomGemountetenDMG_wirdGemeldet() {
        let befund = Doppelinstallation.vergleichen(
            laufend: url("/Volumes/simplebanking/simplebanking.app"),
            registriert: url("/Applications/simplebanking.app"))
        XCTAssertEqual(befund, .andereKopieRegistriert(bevorzugt: url("/Applications/simplebanking.app")))
    }

    func test_symlinkUndZielSindDerselbePfad() throws {
        // Der Fall aus der Praxis: `/Applications` liegt auf manchen Rechnern hinter
        // einem Symlink (verwaltete Macs, verschobene Programme-Ordner). Ohne Auflösung
        // hielte die App sich selbst für eine fremde Kopie und würde bei jedem Start warnen.
        let basis = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doppelinstallation-\(UUID().uuidString)")
        let echt = basis.appendingPathComponent("Programme")
        let verweis = basis.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: echt, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: verweis, withDestinationURL: echt)
        defer { try? FileManager.default.removeItem(at: basis) }

        let app = echt.appendingPathComponent("simplebanking.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        XCTAssertEqual(Doppelinstallation.vergleichen(
            laufend: verweis.appendingPathComponent("simplebanking.app"),
            registriert: app),
                       .stimmigÜberein)
    }

    func test_zweiEchtVerschiedeneOrdner_bleibenVerschieden() {
        // Gegenprobe zur Normierung: Sie darf nicht so viel glattbügeln, dass echte
        // Doppelkopien durchrutschen.
        XCTAssertNotEqual(Doppelinstallation.normiert(url("/Applications/simplebanking.app")),
                          Doppelinstallation.normiert(url("/Users/anna/Desktop/simplebanking.app")))
    }
}
