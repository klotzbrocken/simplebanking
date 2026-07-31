import XCTest
import SwiftUI
@testable import simplebanking

// MARK: - Textkommandos und Rasterschrift sind zwei Entscheidungen
//
// `ThemeChrome.lofi` hing bis 2.0.2 an `glyphControls=off`. Das war eine Abkürzung aus
// der BTX-Arbeit: Damals gab es genau ein Theme, das beides wollte — Bedien-Icons als
// Text UND größere Rasterschrift-Grade —, und ein Schalter reichte dafür.
//
// Für jedes andere Theme war die Kopplung eine Falle. Wer nur Textkommandos statt Icons
// wollte, bekam ungefragt andere Schriftgrade, Blockleisten statt Ringe und veränderte
// Metriken dazu, ohne sie abwählen zu können. Gemeldet am 31.07.
//
// Seitdem: `glyphControls` betrifft nur die Bedienelemente, `lofiTypography` die
// Rasterschrift-Gestaltung. BTX setzt beides und sieht unverändert aus.

final class LofiEntkopplungTests: XCTestCase {

    private var gesichertesTheme: String = ThemeManager.defaultThemeID

    override func setUp() async throws {
        try await super.setUp()
        gesichertesTheme = ThemeManager.shared.currentTheme.id
    }

    override func tearDown() async throws {
        ThemeManager.shared.selectThemeForTesting(id: gesichertesTheme)
        try await super.tearDown()
    }

    private func parse(_ cfg: String) throws -> AppTheme {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).cfg")
        try cfg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(ThemeManager.shared.parseTheme(from: url))
    }

    // MARK: Der gemeldete Fall

    /// Der Kern der Änderung: Ein Theme, das nur seine Bedienelemente als Text will,
    /// bekommt keine anderen Schriftgrade mehr.
    func test_glyphControlsAus_zieht_dieTypografieNichtMehrMit() throws {
        let t = try parse("id=t\nglyphControls=off")
        XCTAssertFalse(t.glyphControls, "die Bedienelemente sollen Text werden")
        XCTAssertFalse(t.lofiTypography,
                       "… aber nur die. Die Rasterschrift-Gestaltung ist ein eigener Schlüssel")
    }

    /// Und umgekehrt: Wer die Rasterschrift-Grade will, muss die Icons nicht aufgeben.
    func test_typografieOhneTextkommandos_istMoeglich() throws {
        let t = try parse("id=t\nlofiTypography=on")
        XCTAssertTrue(t.lofiTypography)
        XCTAssertTrue(t.glyphControls, "die Icons bleiben, solange sie nicht abgewählt sind")
    }

    // MARK: Der neue Schlüssel

    func test_wirdGelesen() throws {
        XCTAssertTrue(try parse("id=t\nlofiTypography=on").lofiTypography)
        XCTAssertTrue(try parse("id=t\nlofiTypography=ON").lofiTypography)
        XCTAssertFalse(try parse("id=t\nlofiTypography=off").lofiTypography)
    }

    /// Standard ist aus — sonst hätte diese Änderung jedes bestehende Theme umgestellt.
    /// Wie bei allen Chrome-Schaltern gilt: unbekannter Wert heißt Standard.
    func test_standardIstAus() throws {
        XCTAssertFalse(try parse("id=t").lofiTypography)
        XCTAssertFalse(try parse("id=t\nlofiTypography=vielleicht").lofiTypography)
    }

    // MARK: Mitgelieferte Themes

    /// BTX braucht beides und muss es jetzt ausdrücklich sagen. Fehlt der Schlüssel in
    /// `btx.cfg`, verliert das Theme still seine Gestaltung — genau die Art Regression,
    /// die man erst im Screenshot bemerkt.
    func test_btxSetztBeideSchalter() throws {
        let cfg = try XCTUnwrap(ThemeManager.builtInThemes["btx.cfg"])
        let t = try parse(cfg)
        XCTAssertFalse(t.glyphControls, "BTX kannte keine grafischen Icons")
        XCTAssertTrue(t.lofiTypography, "BTX braucht die größeren VT323-Grade")
    }

    /// Die übrigen mitgelieferten Themes setzen nur Farben und Schriftfamilie — sie
    /// behalten die Default-Metriken.
    func test_uebrigeMitgelieferteThemes_ohneLofi() throws {
        for datei in ["default.cfg", "sunrise.cfg", "gameboy.cfg"] {
            let cfg = try XCTUnwrap(ThemeManager.builtInThemes[datei], "\(datei) fehlt")
            XCTAssertFalse(try parse(cfg).lofiTypography, "\(datei)")
        }
    }

    // MARK: Wirkung auf ThemeChrome

    @MainActor
    func test_lofiFolgtDemNeuenSchalter() throws {
        let btx = try XCTUnwrap(
            ThemeManager.shared.availableThemes().first { $0.lofiTypography },
            "kein Theme mit Rasterschrift-Gestaltung gefunden")
        ThemeManager.shared.selectThemeForTesting(id: btx.id)
        XCTAssertTrue(ThemeChrome.lofi)
        XCTAssertTrue(ThemeChrome.lofiTypography)

        let schlicht = try XCTUnwrap(
            ThemeManager.shared.availableThemes().first {
                $0.id != ThemeManager.defaultThemeID && !$0.lofiTypography
            })
        ThemeManager.shared.selectThemeForTesting(id: schlicht.id)
        XCTAssertFalse(ThemeChrome.lofi)
    }

    /// Das Default-Theme kann den Schlüssel nicht setzen — und selbst wenn es ihn
    /// mitbrächte, bliebe `lofi` aus. Es ist kein Theme, sondern deren Abwesenheit.
    @MainActor
    func test_ohneTheme_bleibtLofiAus() {
        ThemeManager.shared.selectThemeForTesting(id: ThemeManager.defaultThemeID)
        XCTAssertFalse(ThemeChrome.lofi)
    }

    /// Die Zusage aus §1 von THEMES.md gilt weiter: Die Schriftgrade der Umsatzliste
    /// ändern sich nur mit dem neuen Schlüssel, nicht mit den Bedien-Icons.
    @MainActor
    func test_schriftgrade_haengenNichtAnDenBedienIcons() throws {
        let schlicht = try XCTUnwrap(
            ThemeManager.shared.availableThemes().first {
                $0.id != ThemeManager.defaultThemeID && !$0.lofiTypography
            })
        ThemeManager.shared.selectThemeForTesting(id: schlicht.id)
        XCTAssertEqual(ThemeFonts.rowBody(size: 10, lofiSize: 13),
                       ThemeFonts.flyoutBody(size: 10),
                       "der größere Grad ist ohne lofiTypography durchgeschlagen")
    }
}
