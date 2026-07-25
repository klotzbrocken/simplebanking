import AppKit
import Foundation
import SwiftUI

struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let bodyFontName: String
    let headingFontName: String
    let accentHex: String
    let positiveHex: String
    let negativeHex: String
    let cardLightHex: String
    let cardDarkHex: String
    let panelLightHex: String
    let panelDarkHex: String
    // Optional per-appearance overrides for amount colors.
    // If nil, positiveHex / negativeHex are used for both light and dark.
    let positiveLightHex: String?
    let positiveDarkHex: String?
    let negativeLightHex: String?
    let negativeDarkHex: String?
    // Optionale „Ink"-Farbe (große Zahl + Text) für die vollflächige Theme-Fläche in
    // Flyout/Umsatzliste. nil → automatischer Luminanz-Kontrast zur Surface (cardColor).
    let inkLightHex: String?
    let inkDarkHex: String?

    // MARK: - Chrome-Schalter
    //
    // Rein deklarativ: sie bestimmen, OB ein vorhandenes Element gezeichnet wird bzw.
    // WOMIT ein vorhandener Platz gefüllt ist — nie die Anordnung. Alle Defaults
    // entsprechen dem Bestandsverhalten, damit Default- und Game-Boy-Theme unverändert
    // aussehen. Gebraucht werden sie für das BTX-Theme: Bildschirmtext kannte weder
    // Bildmarken noch Wasser-Animationen.
    var rippleEnabled: Bool = true
    var merchantLogosEnabled: Bool = true
    var categoryIconsEnabled: Bool = true
    /// Bankmarke im Flyout-Kopf. Getrennt von `merchantLogosEnabled`, weil ein Theme
    /// durchaus Händler-Logos zeigen und die Bankmarke weglassen könnte (oder umgekehrt).
    var bankLogosEnabled: Bool = true
    /// Beschriftungen in Großbuchstaben (BTX-Zeichensatz wurde in der Praxis so gesetzt).
    var uppercaseText: Bool = false
    /// Gepunktete Führungslinie zwischen Name und Betrag statt leerem Zwischenraum.
    var dottedLeaders: Bool = false
    /// Eckige Bedienelemente statt runder (Suchfeld, Pillen). BTX kannte keine Rundungen.
    var squareControls: Bool = false
    /// Bedien-Icons als SF-Symbol (`true`) oder als Textkürzel (`false`). BTX kannte
    /// keine grafischen Icons — Kommandos standen als Text in der Fußleiste.
    var glyphControls: Bool = true
    /// Farbe eines Rahmens um Flyout/Liste („Bildschirmrand"). nil → kein Rahmen.
    var screenBorderHex: String? = nil

    var screenBorderColor: NSColor? {
        guard let screenBorderHex else { return nil }
        return Self.color(from: screenBorderHex, fallback: .clear)
    }

    /// True für das eingebaute Default-Theme (nutzt Money-Heat statt flacher Theme-Farbe).
    var isDefault: Bool { id == ThemeManager.defaultThemeID }

    static let fallback = AppTheme(
        id: "default",
        name: "Default",
        bodyFontName: "System",
        headingFontName: "System",
        accentHex: "#4E79A7",       // Blue Strong (Color Harmony Palette)
        positiveHex: "#4F8A6A",     // Green Strong (light)
        negativeHex: "#C65A5A",     // Red Strong (light)
        cardLightHex: "#FFFFFF",
        cardDarkHex: "#1F1F1F",
        panelLightHex: "#F9F9F9",
        panelDarkHex: "#171717",
        positiveLightHex: "#4F8A6A", // Green Strong light
        positiveDarkHex: "#67B487",  // Green Strong dark
        negativeLightHex: "#C65A5A", // Red Strong light
        negativeDarkHex: "#D77979",  // Red Strong dark
        inkLightHex: nil,
        inkDarkHex: nil
    )

    // MARK: - Themed Flyout/Umsatzliste (flache Fläche statt Money-Heat)

    /// Vollflächige, flache Theme-Farbe für Flyout + Umsatzliste (= card-Farbe).
    func surfaceColor(dark: Bool) -> NSColor { dark ? cardDarkColor : cardLightColor }

    /// Vordergrund (große Zahl + Text) auf der Theme-Fläche. Explizit via ink*Hex,
    /// sonst automatischer Luminanz-Kontrast (dunkle Schrift auf heller Fläche etc.).
    func inkColor(dark: Bool) -> NSColor {
        if let hex = dark ? inkDarkHex : inkLightHex, let c = Optional(Self.color(from: hex, fallback: .labelColor)) {
            return c
        }
        return Self.contrastingInk(on: surfaceColor(dark: dark))
    }

    /// Schwarz oder Weiß je nach Helligkeit der Fläche (WCAG-nahe Luminanz).
    static func contrastingInk(on bg: NSColor) -> NSColor {
        let c = bg.usingColorSpace(.sRGB) ?? bg
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.55 ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    }

    var accentColor: NSColor { Self.color(from: accentHex, fallback: .controlAccentColor) }
    var positiveColor: NSColor { Self.color(from: positiveHex, fallback: .systemGreen) }
    var negativeColor: NSColor { Self.color(from: negativeHex, fallback: .systemRed) }
    var positiveLightColor: NSColor { Self.color(from: positiveLightHex ?? positiveHex, fallback: .systemGreen) }
    var positiveDarkColor: NSColor  { Self.color(from: positiveDarkHex  ?? positiveHex, fallback: .systemGreen) }
    var negativeLightColor: NSColor { Self.color(from: negativeLightHex ?? negativeHex, fallback: .systemRed) }
    var negativeDarkColor: NSColor  { Self.color(from: negativeDarkHex  ?? negativeHex, fallback: .systemRed) }
    var cardLightColor: NSColor { Self.color(from: cardLightHex, fallback: .white) }
    var cardDarkColor: NSColor { Self.color(from: cardDarkHex, fallback: NSColor(white: 0.2, alpha: 1.0)) }
    var panelLightColor: NSColor { Self.color(from: panelLightHex, fallback: NSColor(white: 0.92, alpha: 1.0)) }
    var panelDarkColor: NSColor { Self.color(from: panelDarkHex, fallback: NSColor(white: 0.12, alpha: 1.0)) }

    static func color(from hex: String, fallback: NSColor) -> NSColor {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }

        guard cleaned.count == 6 || cleaned.count == 8 else { return fallback }
        guard let value = UInt64(cleaned, radix: 16) else { return fallback }

        if cleaned.count == 6 {
            let r = CGFloat((value & 0xFF0000) >> 16) / 255.0
            let g = CGFloat((value & 0x00FF00) >> 8) / 255.0
            let b = CGFloat(value & 0x0000FF) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        }

        let a = CGFloat((value & 0xFF000000) >> 24) / 255.0
        let r = CGFloat((value & 0x00FF0000) >> 16) / 255.0
        let g = CGFloat((value & 0x0000FF00) >> 8) / 255.0
        let b = CGFloat(value & 0x000000FF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

final class ThemeManager: @unchecked Sendable {
    static let shared = ThemeManager()

    static let storageKey = "themeId"
    static let didChangeNotification = Notification.Name("ThemeChanged")
    static let defaultThemeID = "default"

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default

    private var cachedThemes: [AppTheme] = []
    private var hasLoadedThemes = false

    private init() {
        ensureThemeFiles()
        reloadThemes()
    }

    var currentTheme: AppTheme {
        let selectedID = defaults.string(forKey: Self.storageKey) ?? Self.defaultThemeID
        let themes = availableThemes()
        return themes.first(where: { $0.id == selectedID }) ?? themes.first ?? .fallback
    }

    func availableThemes() -> [AppTheme] {
        if !hasLoadedThemes {
            reloadThemes()
        }
        return cachedThemes
    }

    func ensureThemeFiles() {
        let directory = themesDirectoryURL
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (filename, content) in Self.builtInThemes {
                let target = directory.appendingPathComponent(filename)
                // Always overwrite built-in themes so updates from app upgrades apply
                try content.write(to: target, atomically: true, encoding: .utf8)
            }
            // Ausgemusterte Built-in-Themes (Ocean, Norton Commander) entfernen.
            for retired in Self.retiredThemeFiles {
                let stale = directory.appendingPathComponent(retired)
                if fileManager.fileExists(atPath: stale.path) {
                    try? fileManager.removeItem(at: stale)
                }
            }
        } catch {
            print("[Theme] Failed to ensure themes directory: \(error.localizedDescription)")
        }
    }

    func reloadThemes() {
        let directory = themesDirectoryURL
        ensureThemeFiles()

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            cachedThemes = [.fallback]
            hasLoadedThemes = true
            return
        }

        let themes = urls
            .filter { $0.pathExtension.lowercased() == "cfg" }
            .compactMap(parseTheme)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if themes.isEmpty {
            cachedThemes = [.fallback]
        } else {
            cachedThemes = themes
        }
        hasLoadedThemes = true

        let selectedID = defaults.string(forKey: Self.storageKey) ?? Self.defaultThemeID
        if !cachedThemes.contains(where: { $0.id == selectedID }) {
            defaults.set(Self.defaultThemeID, forKey: Self.storageKey)
        }
    }

    func setSelectedThemeID(_ id: String) {
        let themes = availableThemes()
        let resolvedID: String
        if themes.contains(where: { $0.id == id }) {
            resolvedID = id
        } else {
            resolvedID = themes.first?.id ?? Self.defaultThemeID
        }
        defaults.set(resolvedID, forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    var themesDirectoryPath: String {
        themesDirectoryURL.path
    }

    private var themesDirectoryURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("com.maik.simplebanking", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
    }

    /// Intern statt privat, damit Tests eine `.cfg` direkt gegen den echten Parser
    /// prüfen können (keine Attrappe — die Built-in-Themes gehen denselben Weg).
    func parseTheme(from url: URL) -> AppTheme? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var values: [String: String] = [:]
        data.split(whereSeparator: \.isNewline).forEach { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                return
            }
            guard let idx = line.firstIndex(of: "=") else { return }
            let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }

        let fallback = AppTheme.fallback
        let derivedID = url.deletingPathExtension().lastPathComponent

        return AppTheme(
            id: values["id"].flatMap { $0.isEmpty ? nil : $0 } ?? derivedID,
            name: values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? derivedID.capitalized,
            bodyFontName: values["bodyfont"] ?? fallback.bodyFontName,
            headingFontName: values["headingfont"] ?? fallback.headingFontName,
            accentHex: values["accent"] ?? fallback.accentHex,
            positiveHex: values["positive"] ?? fallback.positiveHex,
            negativeHex: values["negative"] ?? fallback.negativeHex,
            cardLightHex: values["cardlight"] ?? fallback.cardLightHex,
            cardDarkHex: values["carddark"] ?? fallback.cardDarkHex,
            panelLightHex: values["panellight"] ?? fallback.panelLightHex,
            panelDarkHex: values["paneldark"] ?? fallback.panelDarkHex,
            positiveLightHex: values["positivelight"],
            positiveDarkHex: values["positivedark"],
            negativeLightHex: values["negativelight"],
            negativeDarkHex: values["negativedark"],
            inkLightHex: values["inklight"],
            inkDarkHex: values["inkdark"],
            rippleEnabled: Self.parseBool(values["ripple"], default: true),
            merchantLogosEnabled: Self.parseBool(values["merchantlogos"], default: true),
            categoryIconsEnabled: Self.parseBool(values["categoryicons"], default: true),
            bankLogosEnabled: Self.parseBool(values["banklogos"], default: true),
            uppercaseText: Self.parseBool(values["uppercase"], default: false),
            dottedLeaders: Self.parseBool(values["dottedleaders"], default: false),
            squareControls: Self.parseBool(values["squarecontrols"], default: false),
            glyphControls: Self.parseBool(values["glyphcontrols"], default: true),
            screenBorderHex: values["screenborder"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// `on/off`, `true/false`, `yes/no`, `1/0` — alles andere (inkl. fehlendem Wert)
    /// fällt auf den Default zurück, damit ein Tippfehler im `.cfg` nicht still ein
    /// Feature abschaltet.
    static func parseBool(_ raw: String?, default fallback: Bool) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return fallback
        }
        switch raw {
        case "on", "true", "yes", "1":  return true
        case "off", "false", "no", "0": return false
        default:                        return fallback
        }
    }

    /// Intern statt privat: Tests prüfen die ausgelieferten `.cfg`-Inhalte direkt.
    static let builtInThemes: [String: String] = [
        "default.cfg": """
        # simplebanking Theme — Color Harmony Palette
        id=default
        name=Default
        bodyFont=System
        headingFont=System
        accent=#4E79A7
        positive=#4F8A6A
        negative=#C65A5A
        positiveLight=#4F8A6A
        positiveDark=#67B487
        negativeLight=#C65A5A
        negativeDark=#D77979
        cardLight=#FFFFFF
        cardDark=#1F1F1F
        panelLight=#F9F9F9
        panelDark=#171717
        """,
        "sunrise.cfg": """
        # simplebanking Theme
        id=sunrise
        name=Sunrise
        bodyFont=Avenir Next
        headingFont=Avenir Next Demi Bold
        accent=#CC6B2C
        positive=#2E8B57
        negative=#B23A48
        cardLight=#FFF8EF
        cardDark=#403327
        panelLight=#F4E2D0
        panelDark=#2A2018
        """,
        "gameboy.cfg": """
        # simplebanking Theme — Game Boy (authentische DMG-4-Ton-Palette)
        # Original Game-Boy-LCD: 4 Grüntöne, KEIN Rot. Flyout/Umsatzliste rendern
        # vollflächig flach in LCD-Grün (keine Money-Heat), Schrift im dunkelsten Grün.
        # Appearance-unabhängig (LCD sieht in Light/Dark gleich aus).
        #   #0F380F dunkelstes Grün · #306230 · #8BAC0F · #9BBC0F hellstes Grün
        id=gameboy
        name=Game Boy
        bodyFont=Menlo
        headingFont=Menlo Bold
        accent=#306230
        # Beträge monochrom (Vorzeichen unterscheidet Ein/Aus) — dunkelstes Grün auf Screen.
        positive=#0F380F
        negative=#0F380F
        positiveLight=#0F380F
        negativeLight=#0F380F
        positiveDark=#0F380F
        negativeDark=#0F380F
        # Flächen = LCD-Grün (flache Theme-Farbe für Flyout/Liste).
        cardLight=#9BBC0F
        cardDark=#8BAC0F
        panelLight=#8BAC0F
        panelDark=#306230
        # Ink = große Zahl + Text auf der Fläche (dunkelstes DMG-Grün).
        inkLight=#0F380F
        inkDark=#0F380F
        """,
        "btx.cfg": """
        # simplebanking Theme — BTX revisited (Bildschirmtext, 1983–2001)
        #
        # Hommage an den Dienst, über den in Deutschland das erste Online-Banking lief.
        # BTX kannte pro Zeichenzelle je eine Vorder- und Hintergrundfarbe aus acht
        # Grundfarben, eine Rasterschrift und KEINE Bildmarken — Händler wurden über
        # Mosaik-Blöcke aus der 2x3-Unterteilung einer Zeichenzelle dargestellt.
        # Deshalb sind Logos, Symbole und der Wasser-Effekt hier abgeschaltet.
        #
        # Palette (heller Modus, Entwurf 2a/2b):
        #   Schwarz #111111 · Rot #b0061f · Grün #0a7a24 · Gelb #e8b200
        #   Blau #0018a8 · Magenta #a00050 · Cyan #0033b0 · Schirm #cfcfcf
        # Appearance-unabhängig: ein BTX-Schirm sah in Hell wie Dunkel gleich aus.
        id=btx
        name=BTX revisited
        bodyFont=VT323
        headingFont=VT323
        accent=#0018a8
        positive=#0a7a24
        negative=#b0061f
        positiveLight=#0a7a24
        positiveDark=#0a7a24
        negativeLight=#b0061f
        negativeDark=#b0061f
        cardLight=#cfcfcf
        cardDark=#cfcfcf
        panelLight=#cfcfcf
        panelDark=#cfcfcf
        # Kontostand in BTX-Blau, der Leitfarbe der Originalseiten.
        inkLight=#0018a8
        inkDark=#0018a8
        # Chrome: keine Bildmarken, kein Ripple, Großbuchstaben, Punktlinien, gelber Rand.
        ripple=off
        merchantLogos=off
        categoryIcons=off
        bankLogos=off
        uppercase=on
        dottedLeaders=on
        squareControls=on
        glyphControls=off
        screenBorder=#e8b200
        """
    ]

    /// Früher ausgelieferte Built-in-Themes, die es nicht mehr gibt. Werden beim Start
    /// aus dem User-Theme-Verzeichnis entfernt (sonst blieben sie bei Bestands-
    /// installationen liegen, weil `ensureThemeFiles` nur schreibt, nie löscht).
    static let retiredThemeFiles = ["ocean.cfg", "norton-commander.cfg"]
}

/// Lese-Fassade für die Chrome-Schalter des aktiven Themes — gleiches Idiom wie die
/// `Color.themed*`-Accessoren. Views fragen hier ab, statt `ThemeManager` zu kennen.
enum ThemeChrome {
    private static var theme: AppTheme { ThemeManager.shared.currentTheme }

    static var rippleEnabled: Bool { theme.rippleEnabled }
    static var merchantLogosEnabled: Bool { theme.merchantLogosEnabled }
    static var categoryIconsEnabled: Bool { theme.categoryIconsEnabled }
    static var bankLogosEnabled: Bool { theme.bankLogosEnabled }
    static var uppercaseText: Bool { theme.uppercaseText }
    static var dottedLeaders: Bool { theme.dottedLeaders }
    static var squareControls: Bool { theme.squareControls }
    static var glyphControls: Bool { theme.glyphControls }

    /// Eckenradius für Bedienelemente: 0 bei `squareControls`, sonst der übergebene Wert.
    static func cornerRadius(_ rounded: CGFloat) -> CGFloat { theme.squareControls ? 0 : rounded }

    /// `nil` beim Default-Theme — Aufrufer behalten dann ihr Bestandsverhalten.
    static var textCase: Text.Case? { theme.uppercaseText ? .uppercase : nil }

    /// Lo-Fi-Modus: die tiefgreifende Text-Terminal-Gestaltung (größere Rasterschrift-
    /// Typografie, „double height"-Kontostand, Block-Felder, Flächen-Swaps im Sparmodus,
    /// bündige Zeilen ohne Gutter). Hängt an `glyphControls=off` — dem Schalter, der ein
    /// Theme zur textgetriebenen Oberfläche erklärt (derzeit nur BTX). Themes wie
    /// Game Boy oder Sunrise, die nur Farben und Schriftfamilie setzen, behalten
    /// exakt die Default-Metriken.
    static var lofi: Bool { !theme.isDefault && !theme.glyphControls }
}

enum ThemeFonts {
    /// Registriert die mitgelieferten Schriften im Prozess, damit `NSFont(name:)` sie
    /// findet. Muss vor dem ersten Rendern laufen (App-Start) — ohne Registrierung
    /// fällt `themedFont` still auf die Systemschrift zurück und das Theme sieht
    /// unauffällig aus, statt zu brechen.
    ///
    /// `Bundle.main` zuerst (so liegt es im gebauten .app, siehe build-app.sh),
    /// `Bundle.module` als Rückfall für `swift run` und Tests.
    static func registerBundledFonts() {
        for name in ["VT323-Regular", "SpaceMono-Regular", "SpaceMono-Bold"] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // Themes wirken NUR in Flyout + Umsatzliste. Die globalen `body`/`heading` sind
    // daher bewusst NICHT mehr theme-abhängig (sonst leckte z.B. Game Boys Menlo in
    // Settings/TransferSheet). Für die theme-getönten Stellen: `flyoutHeading/flyoutBody`.
    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func heading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Theme-Schrift für die große Saldo-Zahl / Kopfzeile im Flyout (theme-abhängig).
    static func flyoutHeading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        themedFont(named: ThemeManager.shared.currentTheme.headingFontName, size: size, weight: weight)
    }

    static func flyoutBody(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        themedFont(named: ThemeManager.shared.currentTheme.bodyFontName, size: size, weight: weight)
    }

    private static func themedFont(named name: String, size: CGFloat, weight: Font.Weight) -> Font {
        if name.caseInsensitiveCompare("System") == .orderedSame {
            return .system(size: size, weight: weight)
        }
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }
}

extension Color {
    // Globale Tokens sind bewusst auf das DEFAULT-Theme fixiert (nicht `currentTheme`),
    // damit Themes NUR in Flyout + Umsatzliste wirken. Die theme-getönten Varianten für
    // Flyout/Liste heißen `themedSurface/themedInk/themedIncome/themedExpense/themedAccent`.
    private static func defaultDynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }

    static var expenseRed: Color {
        defaultDynamic(AppTheme.fallback.negativeLightColor, AppTheme.fallback.negativeDarkColor)
    }
    static var incomeGreen: Color {
        defaultDynamic(AppTheme.fallback.positiveLightColor, AppTheme.fallback.positiveDarkColor)
    }
    static var cardBackground: Color {
        defaultDynamic(AppTheme.fallback.cardLightColor, AppTheme.fallback.cardDarkColor)
    }
    static var panelBackground: Color {
        defaultDynamic(AppTheme.fallback.panelLightColor, AppTheme.fallback.panelDarkColor)
    }

    // MARK: - Theme-getönte Farben — NUR für Flyout + Umsatzliste

    /// Vollflächige, flache Theme-Farbe (ersetzt Money-Heat bei aktivem Theme).
    static var themedSurface: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return ThemeManager.shared.currentTheme.surfaceColor(dark: dark)
        })
    }
    /// Vordergrund (große Zahl + Text) auf der Theme-Fläche.
    static var themedInk: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return ThemeManager.shared.currentTheme.inkColor(dark: dark)
        })
    }
    static var themedIncome: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let t = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? t.positiveDarkColor : t.positiveLightColor
        })
    }
    static var themedExpense: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let t = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? t.negativeDarkColor : t.negativeLightColor
        })
    }
    static var themedAccent: Color { Color(nsColor: ThemeManager.shared.currentTheme.accentColor) }

    /// Rahmenfarbe des „Bildschirms" (BTX: gelber Rand). nil → kein Rahmen.
    static var themedScreenBorder: Color? {
        ThemeManager.shared.currentTheme.screenBorderColor.map(Color.init(nsColor:))
    }

    /// Mint-Hintergrund für die Aufrunden-Ansicht — überschreibt Bank-Tint
    /// wenn der View-Mode aktiv ist (Phase B-3).
    static var roundupPanelBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return AppTheme.color(from: isDark ? "#1F3A2C" : "#E6F3EB", fallback: .controlBackgroundColor)
        })
    }

    /// Akzentfarbe für Aufrunden-Toggle / Banner-Texte / Icon (mint-tinged green).
    static var roundupAccent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return AppTheme.color(from: isDark ? "#8FD3A8" : "#2F8B5A", fallback: .systemGreen)
        })
    }

    /// Globaler Akzent — auf Default fixiert (Themes wirken nur in Flyout/Liste; dort
    /// `themedAccent`).
    static var themeAccent: Color {
        Color(nsColor: AppTheme.fallback.accentColor)
    }

    // MARK: - Semantic Color Tokens (Color Harmony Palette)
    //
    // Quelle: simplebanking-color-harmony-lovable-brief.md
    // Konsequente Anwendung: KEINE feature-eigenen Akzentfarben mehr.
    // - Blue   = info / active / report / analyse / neutral emphasis
    // - Green  = stable / healthy / good / enough buffer
    // - Orange = observe / warning / medium risk
    // - Red    = critical / overdraft / negative / urgent
    //
    // Variants:
    // - Strong = Icon, Ring, Number, active state
    // - Mid    = hover, selected chip, secondary emphasis
    // - Soft   = background fill, badge fill, subtle surfaces

    private static func dynamicHex(light lightHex: String, dark darkHex: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return AppTheme.color(from: isDark ? darkHex : lightHex, fallback: .gray)
        })
    }

    // Neutrals
    static var sbBackground: Color    { dynamicHex(light: "#F9F9F9", dark: "#171717") }
    static var sbSurface: Color       { dynamicHex(light: "#FFFFFF", dark: "#1F1F1F") }
    static var sbSurfaceSoft: Color   { dynamicHex(light: "#F2F2F2", dark: "#262626") }
    static var sbBorder: Color        { dynamicHex(light: "#E5E5E5", dark: "#343434") }
    static var sbTextPrimary: Color   { dynamicHex(light: "#1C1C1C", dark: "#F3F3F3") }
    static var sbTextSecondary: Color { dynamicHex(light: "#6B6B6B", dark: "#B3B3B3") }

    // Blue — info / active / report / analyse / neutral emphasis
    static var sbBlueStrong: Color { dynamicHex(light: "#4E79A7", dark: "#6FA3D9") }
    static var sbBlueMid: Color    { dynamicHex(light: "#7FA6CE", dark: "#8DB7E3") }
    static var sbBlueSoft: Color   { dynamicHex(light: "#EAF1F8", dark: "#1F3144") }

    // Green — stable / healthy / good
    static var sbGreenStrong: Color { dynamicHex(light: "#4F8A6A", dark: "#67B487") }
    static var sbGreenMid: Color    { dynamicHex(light: "#7FAE94", dark: "#89C7A1") }
    static var sbGreenSoft: Color   { dynamicHex(light: "#E8F2EC", dark: "#1E3428") }

    // Orange — observe / warning / medium
    static var sbOrangeStrong: Color { dynamicHex(light: "#C98A3D", dark: "#D9A354") }
    static var sbOrangeMid: Color    { dynamicHex(light: "#E0B36B", dark: "#E4BA78") }
    static var sbOrangeSoft: Color   { dynamicHex(light: "#F8EFD9", dark: "#3C2E1B") }

    // Red — critical / overdraft / urgent
    static var sbRedStrong: Color { dynamicHex(light: "#C65A5A", dark: "#D77979") }
    static var sbRedMid: Color    { dynamicHex(light: "#D98A8A", dark: "#E39A9A") }
    static var sbRedSoft: Color   { dynamicHex(light: "#F8E9E9", dark: "#402222") }

    // Burgundy — deep overdraft (Stufe unter Red, „tief im Dispo")
    static var sbBurgundyStrong: Color { dynamicHex(light: "#7A2A2A", dark: "#B05050") }

    // Emerald — very good buffer (Stufe über Green, „sehr wohlhabend")
    static var sbEmeraldStrong: Color { dynamicHex(light: "#2D6F4D", dark: "#5DBE8B") }

    // Neutral — warm taupe for "other" / rest categories.
    // Not system gray — deliberately part of the palette so "other" reads as
    // a real category, not leftover space.
    static var sbNeutralStrong: Color { dynamicHex(light: "#8A7F70", dark: "#A89D8D") }
    static var sbNeutralMid: Color    { dynamicHex(light: "#B0A699", dark: "#BAB0A3") }
    static var sbNeutralSoft: Color   { dynamicHex(light: "#EEEAE3", dark: "#2E2A24") }
}
