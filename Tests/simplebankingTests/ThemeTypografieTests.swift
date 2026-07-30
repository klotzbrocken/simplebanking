import XCTest
import AppKit
import SwiftUI
@testable import simplebanking

// MARK: - Theme-Schrift erreicht die Zeilentexte
//
// Gemeldet: Die Typografie eines Themes wirkte auf Kontostand und Überschrift, nicht aber
// auf Empfänger, Absender, Betrag und Kategorien in der Umsatzliste.
//
// Ursache: Die Zeilentexte hingen an `ThemeChrome.lofi`, definiert als
// `!isDefault && !glyphControls`. Da `glyphControls` standardmäßig an ist, bedeutete das
// „nur BTX". Kontostand und Überschrift riefen `flyoutHeading` dagegen ungatet — deshalb
// wirkten sie.
//
// `rowBody`/`rowHeading` trennen das: Familie nach `themed`, Schriftgrad nur bei
// textgetriebenen Themes größer.

@MainActor
final class ThemeTypografieTests: XCTestCase {

    private var gesichertesTheme: String = ThemeManager.defaultThemeID

    override func setUp() async throws {
        try await super.setUp()
        gesichertesTheme = ThemeManager.shared.currentTheme.id
    }

    override func tearDown() async throws {
        ThemeManager.shared.selectThemeForTesting(id: gesichertesTheme)
        try await super.tearDown()
    }

    /// Ohne Theme bleibt es bei der Systemschrift — das Bild des Default-Themes darf sich
    /// durch diese Änderung nicht bewegen.
    func test_ohneTheme_kommtDieSystemschrift() {
        ThemeManager.shared.selectThemeForTesting(id: ThemeManager.defaultThemeID)
        // `weight` ausdrücklich: `Font.system(size:)` ohne Gewicht ist als *Wert* etwas
        // anderes als mit `.regular`, obwohl beide gleich aussehen.
        XCTAssertEqual(ThemeFonts.rowBody(size: 10), Font.system(size: 10, weight: .regular))
        XCTAssertEqual(ThemeFonts.rowBody(size: 10, lofiSize: 13),
                       Font.system(size: 10, weight: .regular),
                       "lofiSize darf ohne Theme keine Wirkung haben")
        XCTAssertEqual(ThemeFonts.rowHeading(size: 14, weight: .semibold),
                       Font.system(size: 14, weight: .semibold))
    }

    /// Der gemeldete Fall: Ein Theme mit eigener Schrift, aber ohne `glyphControls=off`.
    /// Vorher bekam die Zeile hier die Systemschrift.
    func test_mitTheme_kommtDieThemeSchrift() throws {
        let gameboy = try XCTUnwrap(
            ThemeManager.shared.availableThemes().first { $0.id != ThemeManager.defaultThemeID
                                                        && $0.glyphControls },
            "kein Theme mit glyphControls=on gefunden")
        ThemeManager.shared.selectThemeForTesting(id: gameboy.id)

        XCTAssertNotEqual(ThemeFonts.rowBody(size: 10), Font.system(size: 10),
                          "Zeilentext bekommt weiterhin die Systemschrift")
        // Bei gleichem Grad ist es genau die Flyout-Schrift des Themes.
        XCTAssertEqual(ThemeFonts.rowBody(size: 10), ThemeFonts.flyoutBody(size: 10))
        XCTAssertEqual(ThemeFonts.rowHeading(size: 14, weight: .medium),
                       ThemeFonts.flyoutHeading(size: 14, weight: .medium))
    }

    /// Die Punktgrade bleiben der Normalfall — `lofiSize` gilt nur für textgetriebene
    /// Themes. Sonst würde die Umsatzliste bei jedem Theme sichtbar größer beschriftet.
    func test_mitTheme_bleibenDieSchriftgradeWieBisher() throws {
        let gameboy = try XCTUnwrap(
            ThemeManager.shared.availableThemes().first { $0.id != ThemeManager.defaultThemeID
                                                        && $0.glyphControls })
        ThemeManager.shared.selectThemeForTesting(id: gameboy.id)
        XCTAssertEqual(ThemeFonts.rowBody(size: 10, lofiSize: 13),
                       ThemeFonts.flyoutBody(size: 10),
                       "der größere BTX-Grad ist bei einem normalen Theme durchgeschlagen")
    }

    /// BTX behält seine größeren Grade — VT323 baut klein, deshalb war das so gewählt.
    func test_btx_behaeltDieGroesserenGrade() throws {
        let btx = try XCTUnwrap(
            ThemeManager.shared.availableThemes().first { !$0.glyphControls },
            "kein textgetriebenes Theme gefunden")
        ThemeManager.shared.selectThemeForTesting(id: btx.id)
        XCTAssertTrue(ThemeChrome.lofi)
        XCTAssertEqual(ThemeFonts.rowBody(size: 10, lofiSize: 13),
                       ThemeFonts.flyoutBody(size: 13))
        XCTAssertEqual(ThemeFonts.rowHeading(size: 14, weight: .semibold,
                                             lofiSize: 17, lofiWeight: .medium),
                       ThemeFonts.flyoutHeading(size: 17, weight: .medium))
    }

    /// Die Geometrie-Zusage aus THEMES.md §1: Zeilenhöhen stammen aus der Systemschrift
    /// und dürfen sich durch die Theme-Familie nicht verschieben. Ohne diese Klammer
    /// hätte die Umstellung der Schriften die Kartenhöhen verändert.
    func test_zeilenhoehenBleibenUnabhaengigVomTheme() throws {
        let hoehenVorher = [12.0, 14.0, 22.0, 38.0].map {
            ThemeFonts.lineHeight(forSize: $0, weight: .bold)
        }
        for theme in ThemeManager.shared.availableThemes() {
            ThemeManager.shared.selectThemeForTesting(id: theme.id)
            let hoehenJetzt = [12.0, 14.0, 22.0, 38.0].map {
                ThemeFonts.lineHeight(forSize: $0, weight: .bold)
            }
            XCTAssertEqual(hoehenVorher, hoehenJetzt, "\(theme.id) verschiebt die Zeilenhöhen")
        }
    }
}

// MARK: - Kontoring folgt der Theme-Palette
//
// Der Ring hatte zwei Farbfunktionen und wählte nach `!glyphControls` — also nur für BTX.
// Jedes andere Theme bekam das feste Grün/Rot der App, obwohl es eigene Einnahmen- und
// Ausgabenfarben mitbringt.

final class KontoringFarbenTests: XCTestCase {

    /// Die Theme-Farben sind dynamische Katalogfarben (`NSColor(name:) { appearance in … }`).
    /// Jeder Zugriff liefert eine neue Instanz, `==` auf `Color` vergleicht also
    /// Identitäten statt Farbwerten. Verglichen werden deshalb die **aufgelösten**
    /// Komponenten in einer festen Erscheinung.
    private func rgb(_ farbe: Color, dark: Bool = false) throws -> [CGFloat] {
        let erscheinung = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var werte: [CGFloat] = []
        erscheinung.performAsCurrentDrawingAppearance {
            if let c = NSColor(farbe).usingColorSpace(.sRGB) {
                werte = [c.redComponent, c.greenComponent, c.blueComponent]
            }
        }
        return werte
    }

    private func assertGleicheFarbe(_ a: Color, _ b: Color,
                                    _ hinweis: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let ra = try rgb(a), rb = try rgb(b)
        XCTAssertEqual(ra.count, 3, "Farbe a nicht auflösbar", file: file, line: line)
        for (x, y) in zip(ra, rb) {
            XCTAssertEqual(x, y, accuracy: 0.002, hinweis, file: file, line: line)
        }
    }

    // MARK: Bänder

    func test_baenderFolgenDenSchwellen() {
        XCTAssertEqual(GreenZoneRing.band(fraction: 0.0, isDispo: false), .knapp)
        XCTAssertEqual(GreenZoneRing.band(fraction: 0.33, isDispo: false), .knapp)
        XCTAssertEqual(GreenZoneRing.band(fraction: 0.34, isDispo: false), .mittel)
        XCTAssertEqual(GreenZoneRing.band(fraction: 0.66, isDispo: false), .mittel)
        XCTAssertEqual(GreenZoneRing.band(fraction: 0.67, isDispo: false), .gut)
        XCTAssertEqual(GreenZoneRing.band(fraction: 1.0, isDispo: false), .gut)
    }

    /// Dispo schlägt jeden Bruchteil — auch einen guten.
    func test_dispoSchlaegtAlles() {
        for f in [0.0, 0.5, 1.0] {
            XCTAssertEqual(GreenZoneRing.band(fraction: f, isDispo: true), .dispo)
        }
    }

    // MARK: Farben

    /// Ohne Theme bleibt die App-Palette — unverändert gegenüber vorher.
    func test_ohneTheme_bleibtDieAppPalette() throws {
        try assertGleicheFarbe(GreenZoneRing.color(for: .knapp,  themed: false), .sbRedStrong)
        try assertGleicheFarbe(GreenZoneRing.color(for: .dispo,  themed: false), .sbRedStrong)
        try assertGleicheFarbe(GreenZoneRing.color(for: .mittel, themed: false), .sbOrangeStrong)
        try assertGleicheFarbe(GreenZoneRing.color(for: .gut,    themed: false), .sbGreenStrong)
    }

    /// Der gemeldete Punkt: Mit Theme kommen dessen Einnahmen- und Ausgabenfarben.
    func test_mitTheme_kommenDieThemeFarben() throws {
        try assertGleicheFarbe(GreenZoneRing.color(for: .knapp, themed: true), .themedExpense)
        try assertGleicheFarbe(GreenZoneRing.color(for: .dispo, themed: true), .themedExpense)
        try assertGleicheFarbe(GreenZoneRing.color(for: .gut,   themed: true), .themedIncome)
    }

    /// Das Mittelband hat im Vertrag keinen eigenen Wert und bekommt die Mischung —
    /// aber nicht bei BTX, dort ist das Bernstein Teil eines ausgelieferten Themes.
    func test_mittelbandMischtDiePalette_ausserBeiBTX() throws {
        try assertGleicheFarbe(GreenZoneRing.color(for: .mittel, themed: true), .themedMidBand)
        // BTX behält sein Bernstein — die Mischung darf es nicht ersetzen.
        let btx = try rgb(GreenZoneRing.color(for: .mittel, themed: true, lofi: true))
        let mischung = try rgb(.themedMidBand)
        XCTAssertNotEqual(btx, mischung)
    }

    /// Die Mischung muss wirklich zwischen den beiden Palettenfarben liegen, nicht eine
    /// von ihnen sein — sonst wäre das Mittelband nicht unterscheidbar.
    func test_mittelbandLiegtZwischenDenPalettenfarben() throws {
        let mitte = try rgb(.themedMidBand)
        let aus = try rgb(.themedExpense)
        let ein = try rgb(.themedIncome)
        XCTAssertEqual(mitte.count, 3)
        XCTAssertNotEqual(mitte, aus)
        XCTAssertNotEqual(mitte, ein)
        for i in 0..<3 {
            let unten = min(aus[i], ein[i]), oben = max(aus[i], ein[i])
            XCTAssertTrue(mitte[i] >= unten - 0.002 && mitte[i] <= oben + 0.002,
                          "Kanal \(i) liegt außerhalb der beiden Farben")
        }
    }
}

// MARK: - Wallpaper
//
// Zwei neue Vertragsschlüssel. Sie erben die Pfad- und Maßprüfung des globalen Logos,
// bekommen aber eine eigene Byte-Grenze: 512 KB reichen für ein Logo, nicht für 840 × 620.

final class ThemeWallpaperTests: XCTestCase {

    private func parse(_ cfg: String) throws -> AppTheme {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).cfg")
        try cfg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(ThemeManager.shared.parseTheme(from: url))
    }

    /// Drei Flächen, drei mögliche Bilder. Ein Bild kann sie nicht bedienen: Das Flyout
    /// ist 2,5:1 breit-flach, die schmale Liste 0,56:1 hochkant, die breite 1,35:1 quer.
    /// Ein Motiv am unteren Bildrand überlebt die Verankerung oben im Flyout nicht.
    func test_flaechenspezifischeSchluesselWerdenGelesen() throws {
        let t = try parse("""
        id=t
        wallpaper=grund.png
        wallpaperFlyout=flach.png
        wallpaperWide=quer.png
        wallpaperFlyoutDark=flach-dunkel.png
        wallpaperWideDark=quer-dunkel.png
        """)
        XCTAssertEqual(t.wallpaperFileName, "grund.png")
        XCTAssertEqual(t.wallpaperFlyoutFileName, "flach.png")
        XCTAssertEqual(t.wallpaperWideFileName, "quer.png")
        XCTAssertEqual(t.wallpaperFlyoutDarkFileName, "flach-dunkel.png")
        XCTAssertEqual(t.wallpaperWideDarkFileName, "quer-dunkel.png")
    }

    /// Ein Theme mit einer einzigen Datei muss gültig bleiben — die Flächen fallen auf
    /// das Grundbild zurück.
    func test_ohneFlaechenbilder_bleibtEsBeimGrundbild() throws {
        let t = try parse("id=t\nwallpaper=grund.png")
        XCTAssertNil(t.wallpaperFlyoutFileName)
        XCTAssertNil(t.wallpaperWideFileName)
    }

    func test_schluesselWerdenGelesen() throws {
        let t = try parse("id=t\nwallpaper=hinten.png\nwallpaperDark=hinten-dunkel.png")
        XCTAssertEqual(t.wallpaperFileName, "hinten.png")
        XCTAssertEqual(t.wallpaperDarkFileName, "hinten-dunkel.png")
    }

    /// Additiv: Ohne die Schlüssel ändert sich nichts, und kein mitgeliefertes Theme
    /// bringt eines mit.
    func test_ohneSchluessel_keinWallpaper() throws {
        XCTAssertNil(AppTheme.fallback.wallpaperFileName)
        XCTAssertNil(try parse("id=t\nwallpaper=").wallpaperFileName)
        for datei in ["default.cfg", "sunrise.cfg", "gameboy.cfg", "btx.cfg"] {
            let cfg = try XCTUnwrap(ThemeManager.builtInThemes[datei], "\(datei) fehlt")
            XCTAssertNil(try parse(cfg).wallpaperFileName, "\(datei) bringt ein Wallpaper mit")
        }
    }

    /// Dieselbe Namensprüfung wie beim Logo — der Angriffsweg ist derselbe.
    func test_pfadpruefungGiltAuchFuersWallpaper() {
        XCTAssertNil(ThemeChrome.themeAssetURL(named: "../../Pictures/privat.png", art: "Wallpaper"))
        XCTAssertNil(ThemeChrome.themeAssetURL(named: "/etc/passwd", art: "Wallpaper"))
        XCTAssertNil(ThemeChrome.themeAssetURL(named: "unter/ordner.png", art: "Wallpaper"))
    }

    /// Die höhere Grenze ist der Punkt: Ein Wallpaper in @2x sprengt die Logo-Grenze.
    func test_wallpaperDarfGroesserSeinAlsEinLogo() {
        XCTAssertGreaterThan(ThemeChrome.maxWallpaperBytes, ThemeChrome.maxLogoBytes)
        XCTAssertEqual(ThemeChrome.maxLogoBytes, 512 * 1024)
        XCTAssertEqual(ThemeChrome.maxWallpaperBytes, 4 * 1024 * 1024)
    }

    /// Die Maßgrenze gilt weiter — sie schützt vor dem Dekodieren, nicht vor der Dateigröße.
    func test_masseGrenzeGiltAuchFuersWallpaper() throws {
        let url = try schreibePNG(breite: ThemeChrome.maxLogoEdge + 1, hoehe: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(ThemeChrome.logoDimensionsAreSane(at: url))
    }

    // MARK: Oberkante für die Sprechblasen-Nase

    /// In den Zipfel der Sprechblase lässt sich kein Bild zeichnen — er braucht eine
    /// Farbe. Sie muss von der OBEREN Kante kommen, nicht von der unteren.
    func test_oberkantenfarbe_kommtVonOben() throws {
        let bild = NSImage(size: NSSize(width: 40, height: 100))
        bild.lockFocus()
        NSColor.systemRed.setFill();  NSRect(x: 0, y: 50, width: 40, height: 50).fill()  // oben
        NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0,  width: 40, height: 50).fill()  // unten
        bild.unlockFocus()

        let farbe = try XCTUnwrap(ThemeChrome.averageTopEdgeColor(of: bild))
        let srgb = try XCTUnwrap(farbe.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(srgb.redComponent, srgb.blueComponent,
                             "Die Nase bekommt die Farbe der Unterkante")
    }

    func test_oberkantenfarbe_beiLeeremBildKeineFarbe() {
        XCTAssertNil(ThemeChrome.averageTopEdgeColor(of: NSImage(size: .zero)))
    }

    private func schreibePNG(breite: Int, hoehe: Int) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: breite, pixelsHigh: hoehe,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let daten = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp-\(UUID().uuidString).png")
        try daten.write(to: url)
        return url
    }
}
