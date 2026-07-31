import XCTest
import AppKit
@testable import simplebanking

// MARK: - BTX-Theme und die Chrome-Schalter
//
// Die Schalter entscheiden, ob Bildmarken, Symbole und der Ripple gezeichnet werden.
// Ein falscher Default würde alle bestehenden Themes still verändern — deshalb sichert
// dieser Test beide Richtungen ab: Bestandsverhalten bleibt, BTX schaltet ab.

final class BTXThemeTests: XCTestCase {

    // MARK: Bool-Parser

    func test_parseBool_acceptedSpellings() {
        for raw in ["on", "true", "yes", "1", "ON", " True "] {
            XCTAssertTrue(ThemeManager.parseBool(raw, default: false), "nicht als true erkannt: \(raw)")
        }
        for raw in ["off", "false", "no", "0", "OFF", " False "] {
            XCTAssertFalse(ThemeManager.parseBool(raw, default: true), "nicht als false erkannt: \(raw)")
        }
    }

    /// Ein Tippfehler im `.cfg` darf kein Feature abschalten — er fällt auf den Default.
    func test_parseBool_unknownAndMissingFallBackToDefault() {
        XCTAssertTrue(ThemeManager.parseBool("vielleicht", default: true))
        XCTAssertFalse(ThemeManager.parseBool("vielleicht", default: false))
        XCTAssertTrue(ThemeManager.parseBool(nil as String?, default: true))
        XCTAssertTrue(ThemeManager.parseBool("", default: true))
        XCTAssertTrue(ThemeManager.parseBool("   ", default: true))
    }

    // MARK: Defaults

    func test_fallbackTheme_keepsExistingBehaviour() {
        let t = AppTheme.fallback
        XCTAssertTrue(t.rippleEnabled)
        XCTAssertTrue(t.merchantLogosEnabled)
        XCTAssertTrue(t.categoryIconsEnabled)
        XCTAssertTrue(t.bankLogosEnabled)
        XCTAssertFalse(t.uppercaseText)
        XCTAssertFalse(t.dottedLeaders)
        XCTAssertNil(t.screenBorderHex)
        XCTAssertNil(t.screenBorderColor)
    }

    // MARK: btx.cfg

    private func parsedBTX() throws -> AppTheme {
        let cfg = try XCTUnwrap(ThemeManager.builtInThemes["btx.cfg"],
                                "btx.cfg fehlt in den Built-in-Themes")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("btx-\(UUID().uuidString).cfg")
        try cfg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(ThemeManager.shared.parseTheme(from: url), "btx.cfg nicht parsebar")
    }

    func test_btxTheme_switchesOffEverythingBTXDidNotHave() throws {
        let t = try parsedBTX()
        XCTAssertEqual(t.id, "btx")
        XCTAssertFalse(t.rippleEnabled, "BTX kannte keine Animationen")
        XCTAssertFalse(t.merchantLogosEnabled)
        XCTAssertFalse(t.categoryIconsEnabled)
        XCTAssertFalse(t.bankLogosEnabled)
        XCTAssertTrue(t.uppercaseText)
        XCTAssertTrue(t.dottedLeaders)
        XCTAssertTrue(t.squareControls)
        XCTAssertFalse(t.glyphControls)
        XCTAssertTrue(t.lofiTypography, "seit 2.0.2 ein eigener Schlüssel, nicht mehr an glyphControls")
        XCTAssertEqual(t.screenBorderHex?.lowercased(), "#e8b200")
    }

    func test_fallbackTheme_keepsControlsGraphical() {
        let t = AppTheme.fallback
        XCTAssertFalse(t.squareControls, "Default bleibt rund")
        XCTAssertTrue(t.glyphControls, "Default behält grafische Icons")
    }

    /// Regression: die Lo-Fi-Gestaltung (große Raster-Typografie, Block-Felder,
    /// Flächen-Swaps) gehört NUR Themes mit `lofiTypography=on`. Game Boy und
    /// Sunrise sind reine Farb-Themes und müssen die Default-Metriken behalten —
    /// genau das war nach der ersten BTX-Runde verletzt.
    func test_colorThemes_areNotLofi() throws {
        for file in ["gameboy.cfg", "sunrise.cfg", "default.cfg"] {
            let cfg = try XCTUnwrap(ThemeManager.builtInThemes[file])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("t-\(UUID().uuidString).cfg")
            try cfg.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let t = try XCTUnwrap(ThemeManager.shared.parseTheme(from: url))
            XCTAssertFalse(t.lofiTypography, "\(file) darf NICHT in den Lo-Fi-Modus rutschen")
            XCTAssertTrue(t.glyphControls, "\(file): grafische Bedienelemente")
            XCTAssertFalse(t.uppercaseText, "\(file): keine Großschreibung")
            XCTAssertFalse(t.squareControls, "\(file): keine eckigen Controls")
        }
        let btx = try parsedBTX()
        XCTAssertTrue(btx.lofiTypography, "BTX ist das (bisher einzige) Lo-Fi-Theme")
    }

    /// Ein BTX-Schirm sah in Hell wie Dunkel gleich aus — die Palette darf nicht
    /// zwischen den Appearances springen.
    func test_btxTheme_isAppearanceIndependent() throws {
        let t = try parsedBTX()
        XCTAssertEqual(t.surfaceColor(dark: false), t.surfaceColor(dark: true))
        XCTAssertEqual(t.inkColor(dark: false), t.inkColor(dark: true))
        XCTAssertEqual(t.positiveLightColor, t.positiveDarkColor)
        XCTAssertEqual(t.negativeLightColor, t.negativeDarkColor)
    }

    func test_btxTheme_usesSpecifiedPalette() throws {
        let t = try parsedBTX()
        func rgb(_ c: NSColor) -> [Int] {
            let s = c.usingColorSpace(.sRGB)!
            return [s.redComponent, s.greenComponent, s.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        XCTAssertEqual(rgb(t.surfaceColor(dark: false)), [0xcf, 0xcf, 0xcf], "Schirm grau")
        XCTAssertEqual(rgb(t.inkColor(dark: false)), [0x00, 0x18, 0xa8], "Kontostand BTX-Blau")
        XCTAssertEqual(rgb(t.negativeLightColor), [0xb0, 0x06, 0x1f], "Rot")
        XCTAssertEqual(rgb(t.positiveLightColor), [0x0a, 0x7a, 0x24], "Grün")
    }

    // MARK: Mosaik

    func test_mosaicShapes_matchTemplate() {
        // Muster exakt wie in quelle/BTX Theme.dc.html (Konstante S).
        XCTAssertEqual(BTXMosaic.Shape.cup.rows,  ["x.x", "xxx", ".x."])
        XCTAssertEqual(BTXMosaic.Shape.pump.rows, ["xx.", "xxx", "xx."])
        XCTAssertEqual(BTXMosaic.Shape.bag.rows,  [".x.", "xxx", "xxx"])
        XCTAssertEqual(BTXMosaic.Shape.cart.rows, ["x.x", "xxx", "x.x"])
        XCTAssertEqual(BTXMosaic.Shape.bank.rows, ["xxx", "x.x", "xxx"])
        for shape in BTXMosaic.Shape.allCases {
            XCTAssertEqual(shape.rows.count, 3)
            XCTAssertTrue(shape.rows.allSatisfy { $0.count == 3 }, "\(shape) ist nicht 3×3")
        }
    }

    /// Jede Kategorie muss eine Zuordnung haben — der neutrale Bank-Block ist der
    /// vorgesehene Rückfall, aber niemals ein Absturz oder eine leere Zelle.
    func test_everyCategoryHasAMosaic() {
        for category in TransactionCategory.allCases {
            let style = BTXMosaic.style(for: category)
            XCTAssertFalse(style.hex.isEmpty, "keine Farbe für \(category)")
            XCTAssertTrue(style.hex.hasPrefix("#"), "Farbe ohne # für \(category)")
            XCTAssertEqual(style.shape.rows.count, 3)
        }
    }

    // MARK: Schrift

    func test_vt323IsBundledAndLoadable() throws {
        let url = Bundle.module.url(forResource: "VT323-Regular", withExtension: "ttf")
        XCTAssertNotNil(url, "VT323 liegt nicht in den Ressourcen")
        // OFL-1.1 verlangt, dass der Lizenztext mitgeliefert wird.
        XCTAssertNotNil(Bundle.module.url(forResource: "VT323-OFL", withExtension: "txt"),
                        "Lizenztext fehlt neben der Schrift")
        ThemeFonts.registerBundledFonts()
        XCTAssertNotNil(NSFont(name: "VT323", size: 12), "VT323 ließ sich nicht registrieren")
    }
}
