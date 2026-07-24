import XCTest
import AppKit
@testable import simplebanking

// MARK: - Theme Surface/Ink Tests
//
// Themes wirken nur in Flyout + Umsatzliste: flache Surface-Farbe (card) + Ink
// (Vordergrund). Kein Money-Heat mehr pro Theme. Diese Tests sichern die Ink-Wahl
// (explizit vs. Luminanz-Kontrast) und dass Default kein eigenes Theming erzwingt.

final class ThemeSurfaceTests: XCTestCase {

    private func themed(inkLight: String?, cardLight: String) -> AppTheme {
        AppTheme(
            id: "t", name: "T", bodyFontName: "Menlo", headingFontName: "Menlo",
            accentHex: "#306230", positiveHex: "#0F380F", negativeHex: "#0F380F",
            cardLightHex: cardLight, cardDarkHex: "#8BAC0F",
            panelLightHex: "#8BAC0F", panelDarkHex: "#306230",
            positiveLightHex: nil, positiveDarkHex: nil,
            negativeLightHex: nil, negativeDarkHex: nil,
            inkLightHex: inkLight, inkDarkHex: nil
        )
    }

    func test_explicitInk_isUsed() {
        let t = themed(inkLight: "#0F380F", cardLight: "#9BBC0F")
        let ink = t.inkColor(dark: false).usingColorSpace(.sRGB)!
        // #0F380F ≈ (15,56,15)/255
        XCTAssertEqual(Double(ink.redComponent), 15.0/255.0, accuracy: 0.01)
        XCTAssertEqual(Double(ink.greenComponent), 56.0/255.0, accuracy: 0.01)
    }

    private func luminance(_ c: NSColor) -> Double {
        let s = c.usingColorSpace(.sRGB)!
        return 0.2126 * Double(s.redComponent) + 0.7152 * Double(s.greenComponent) + 0.0722 * Double(s.blueComponent)
    }

    func test_autoInk_darkOnLightSurface() {
        // Helle Fläche, kein explizites Ink → dunkler Kontrast.
        let t = themed(inkLight: nil, cardLight: "#9BBC0F")
        XCTAssertLessThan(luminance(t.inkColor(dark: false)), 0.3, "erwarte dunkle Schrift auf heller Fläche")
    }

    func test_autoInk_lightOnDarkSurface() {
        let t = themed(inkLight: nil, cardLight: "#123018") // dunkles Grün
        XCTAssertGreaterThan(luminance(t.inkColor(dark: false)), 0.7, "erwarte helle Schrift auf dunkler Fläche")
    }

    func test_default_isDefaultFlag() {
        XCTAssertTrue(AppTheme.fallback.isDefault)
        XCTAssertFalse(themed(inkLight: nil, cardLight: "#9BBC0F").isDefault)
    }

    func test_surfaceColor_isCardColor() {
        let t = themed(inkLight: nil, cardLight: "#9BBC0F")
        XCTAssertEqual(t.surfaceColor(dark: false), t.cardLightColor)
    }
}
