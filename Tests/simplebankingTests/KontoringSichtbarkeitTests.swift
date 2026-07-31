import XCTest
@testable import simplebanking

// MARK: - Wer über den Kontoring entscheidet
//
// Festgelegt am 31.07.: Der Ring ist da — in Flyout UND Umsatzliste —, außer der Nutzer
// hat ihn abgeschaltet, das Theme hat ihn abgeschaltet, oder das Theme bringt eine
// eigene Grafik mit, die ihn ersetzt.
//
// Drei Beteiligte an einer Fläche: Deshalb steht die Rangfolge als reine Funktion an
// einer Stelle und nicht als Bedingung an drei Zeichenstellen. Genau daran ist es schon
// einmal auseinandergelaufen — das Flyout hing an einem Schlüssel ohne Oberfläche und
// verlor den Ring, ohne dass es jemandem auffiel.

final class KontoringSichtbarkeitTests: XCTestCase {

    private func sichtbar(nutzer: Bool, theme: Bool, grafik: Bool) -> Bool {
        ThemeChrome.kontoringSichtbar(nutzerSchalter: nutzer,
                                      themeErlaubtRing: theme,
                                      grafikGesetzt: grafik)
    }

    /// Der Normalfall: kein Theme-Eingriff, Nutzer hat nichts abgeschaltet.
    func test_standard_zeigtDenRing() {
        XCTAssertTrue(sichtbar(nutzer: true, theme: true, grafik: false))
    }

    // MARK: Die drei Ausnahmen

    func test_nutzerSchaltetAus() {
        XCTAssertFalse(sichtbar(nutzer: false, theme: true, grafik: false))
    }

    func test_themeSchaltetAus() {
        XCTAssertFalse(sichtbar(nutzer: true, theme: false, grafik: false))
    }

    /// Die Grafik verbirgt den Ring nicht, sie tritt an seine Stelle — die Fläche ist
    /// also belegt.
    func test_grafikBelegtDieFlaeche() {
        XCTAssertTrue(sichtbar(nutzer: true, theme: true, grafik: true))
    }

    // MARK: Rangfolge

    /// Die Grafik sticht den Nutzerschalter. Das ist kein Übergehen: Solange ein Theme
    /// die Fläche belegt, ist der Schalter in den Einstellungen gesperrt — sein
    /// gespeicherter Wert stammt aus einer Zeit, in der er etwas anderes bedeutete.
    func test_grafikSticht_denNutzerschalter() {
        XCTAssertTrue(sichtbar(nutzer: false, theme: true, grafik: true))
    }

    /// Und sie sticht auch die Abschaltung durch das Theme. Setzt ein Theme beides,
    /// widerspricht es sich selbst; dann gilt die konkretere Aussage — das Bild, das es
    /// mitliefert.
    func test_grafikSticht_dieThemeAbschaltung() {
        XCTAssertTrue(sichtbar(nutzer: true, theme: false, grafik: true))
        XCTAssertTrue(sichtbar(nutzer: false, theme: false, grafik: true))
    }

    /// Vollständigkeit: alle acht Kombinationen, damit die Rangfolge nicht durch eine
    /// spätere Umstellung still kippt.
    func test_alleKombinationen() {
        let erwartet: [(Bool, Bool, Bool, Bool)] = [
            // nutzer, theme, grafik, sichtbar
            (true,  true,  true,  true),
            (true,  true,  false, true),
            (true,  false, true,  true),
            (true,  false, false, false),
            (false, true,  true,  true),
            (false, true,  false, false),
            (false, false, true,  true),
            (false, false, false, false),
        ]
        for (n, t, g, soll) in erwartet {
            XCTAssertEqual(sichtbar(nutzer: n, theme: t, grafik: g), soll,
                           "nutzer=\(n) theme=\(t) grafik=\(g)")
        }
    }

    // MARK: Der neue Schlüssel

    private func parse(_ cfg: String) throws -> AppTheme {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).cfg")
        try cfg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(ThemeManager.shared.parseTheme(from: url))
    }

    func test_accountRingWirdGelesen() throws {
        XCTAssertFalse(try parse("id=t\naccountRing=off").accountRingEnabled)
        XCTAssertTrue(try parse("id=t\naccountRing=on").accountRingEnabled)
    }

    /// Standard ist an — der Ring gehört zum Bestandsverhalten, ein Theme muss ihn
    /// ausdrücklich abwählen.
    func test_standardIstAn() throws {
        XCTAssertTrue(try parse("id=t").accountRingEnabled)
        XCTAssertTrue(try parse("id=t\naccountRing=unsinn").accountRingEnabled)
    }

    /// Kein mitgeliefertes Theme schaltet ihn ab — auch BTX nicht, dort wird der Ring
    /// zur Mosaik-Blockleiste statt zu verschwinden.
    func test_mitgelieferteThemesBehaltenDenRing() throws {
        for datei in ["default.cfg", "sunrise.cfg", "gameboy.cfg", "btx.cfg"] {
            let cfg = try XCTUnwrap(ThemeManager.builtInThemes[datei], "\(datei) fehlt")
            XCTAssertTrue(try parse(cfg).accountRingEnabled, "\(datei)")
        }
    }
}
