import XCTest
@testable import simplebanking

// MARK: - Die vier neuen Vertragsschlüssel
//
// `logo` / `logoDark` (globale Bildmarke statt Bankmarke) und `icon.<name>`
// (einzeln austauschbare Bedien-Icons).
//
// Der Vertrag ist additiv: Ohne diese Schlüssel muss sich nichts ändern. Genau das
// prüft die erste Gruppe — sie ist die Klammer gegen den Fehler, der bei den
// Lo-Fi-Schaltern schon einmal passiert ist, als Game Boy und Sunrise ungefragt
// mitverändert wurden.

final class ThemeContractV2Tests: XCTestCase {

    /// Schreibt eine .cfg in eine Temp-Datei und parst sie — dasselbe Idiom wie
    /// `BTXThemeTests.parsedBTX()`.
    private func parse(_ cfg: String) throws -> AppTheme {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).cfg")
        try cfg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(ThemeManager.shared.parseTheme(from: url))
    }

    // MARK: Defaults — ohne die Schlüssel ändert sich nichts

    func test_fallbackTheme_kenntKeineNeuenSchluessel() {
        let t = AppTheme.fallback
        XCTAssertNil(t.logoFileName)
        XCTAssertNil(t.logoDarkFileName)
        XCTAssertTrue(t.iconOverrides.isEmpty)
    }

    /// Die mitgelieferten Themes dürfen von der Erweiterung unberührt bleiben — auch
    /// BTX, das sonst jeden Schalter setzt.
    func test_mitgelieferteThemes_bekommenKeineNeuenEigenschaften() throws {
        for file in ["default.cfg", "sunrise.cfg", "gameboy.cfg", "btx.cfg"] {
            let cfg = try XCTUnwrap(ThemeManager.builtInThemes[file], "\(file) fehlt")
            let t = try parse(cfg)
            XCTAssertNil(t.logoFileName, "\(file) darf kein globales Logo mitbringen")
            XCTAssertTrue(t.iconOverrides.isEmpty, "\(file) darf keine Icons überschreiben")
        }
    }


    // MARK: logo

    func test_logo_wirdGelesen() throws {
        let t = try parse("id=t\nlogo=firma.png\nlogoDark=firma-hell.png")
        XCTAssertEqual(t.logoFileName, "firma.png")
        XCTAssertEqual(t.logoDarkFileName, "firma-hell.png")
    }

    func test_logo_leererWertIstKeinLogo() throws {
        XCTAssertNil(try parse("id=t\nlogo=").logoFileName)
    }

    // MARK: icon.<name>

    func test_iconOverrides_werdenGesammelt() throws {
        let t = try parse("""
        id=t
        icon.filter=slider.horizontal.3
        icon.send=arrow.up.circle
        """)
        XCTAssertEqual(t.iconOverrides["filter"], "slider.horizontal.3")
        XCTAssertEqual(t.iconOverrides["send"], "arrow.up.circle")
        XCTAssertEqual(t.iconOverrides.count, 2)
    }

    func test_iconOverrides_ignorierenLeereNamenUndWerte() throws {
        let t = try parse("id=t\nicon.=foo\nicon.filter=")
        XCTAssertTrue(t.iconOverrides.isEmpty)
    }

    // MARK: Registry

    /// Jede Funktion braucht ein Symbol, das es wirklich gibt, und ein Kürzel für
    /// textgetriebene Themes. Ohne diesen Test könnte ein Tippfehler in der Registry
    /// selbst ein leeres Icon erzeugen.
    func test_jedesRegistryIcon_hatEinGueltigesSymbolUndEinKuerzel() {
        for icon in ChromeIcon.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: icon.defaultSymbol, accessibilityDescription: nil),
                "\(icon.rawValue): '\(icon.defaultSymbol)' ist kein bekanntes SF-Symbol")
            XCTAssertNotNil(
                NSImage(systemSymbolName: icon.defaultActiveSymbol, accessibilityDescription: nil),
                "\(icon.rawValue).active: '\(icon.defaultActiveSymbol)' ist kein bekanntes SF-Symbol")
            XCTAssertFalse(icon.textFallback.isEmpty, "\(icon.rawValue) ohne Textkürzel")
        }
    }

    /// Die Registry muss exakt die Symbole tragen, die vorher als Literale in den Views
    /// standen — sonst hätte allein das Einführen der Registry das Bild verändert.
    /// Die Werte sind bewusst hier ausgeschrieben und nicht aus dem Enum abgeleitet:
    /// ein Test, der `defaultSymbol` gegen `defaultSymbol` prüft, prüft nichts.
    func test_registryEntsprichtDemBisherigenBestand() {
        let erwartet: [ChromeIcon: (ruhe: String, aktiv: String)] = [
            .filter:     ("line.3.horizontal.decrease", "line.3.horizontal.decrease.circle.fill"),
            .categories: ("tag", "tag.fill"),
            .savings:    ("centsign.circle", "centsign.circle.fill"),
            .send:       ("paperplane", "paperplane"),
            .dashboard:  ("square.grid.2x2", "square.grid.2x2"),
            .inbox:      ("bell", "bell.fill"),
            .refresh:    ("arrow.clockwise", "arrow.clockwise"),
            .pin:        ("pin", "pin.fill"),
            .settings:   ("gearshape", "gearshape"),
            .clear:      ("xmark.circle.fill", "xmark.circle.fill"),
        ]
        XCTAssertEqual(Set(erwartet.keys), Set(ChromeIcon.allCases),
                       "Neues Icon in der Registry? Dann hier den Bestandswert ergänzen.")
        for (icon, werte) in erwartet {
            XCTAssertEqual(icon.defaultSymbol, werte.ruhe, "\(icon.rawValue) Ruhezustand")
            XCTAssertEqual(icon.defaultActiveSymbol, werte.aktiv, "\(icon.rawValue) aktiv")
        }
    }

    func test_iconOverride_kennt_aktiveVariante() throws {
        let t = try parse("id=t\nicon.filter=star\nicon.filter.active=star.fill")
        XCTAssertEqual(t.iconOverrides["filter"], "star")
        XCTAssertEqual(t.iconOverrides["filter.active"], "star.fill")
    }

    // MARK: Zeilenhöhe

    /// Die feste Höhe muss der entsprechen, die das Textsystem ohnehin verwendet —
    /// sonst hätte das Fixieren der Metriken das Bild verschoben.
    func test_lineHeight_entsprichtDerLayoutHoeheDerSystemschrift() {
        for size in [12.0, 14.0, 22.0, 32.0, 38.0] as [CGFloat] {
            let expected = NSLayoutManager().defaultLineHeight(
                for: NSFont.systemFont(ofSize: size, weight: .bold))
            XCTAssertEqual(ThemeFonts.lineHeight(forSize: size, weight: .bold), expected,
                           accuracy: 0.5, "Größe \(size)")
        }
    }
}
