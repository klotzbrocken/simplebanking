import AppKit
import Foundation
import ImageIO
import SwiftUI

/// Einfärbung der Kategorie-Symbole.
enum IconStyle: String, Equatable {
    /// Ohne Theme Systemgrau wie bisher, mit Theme die Textfarbe — löst die
    /// Lesbarkeit auf dunklen Flächen, ohne dass ein Theme etwas setzen muss.
    case auto
    /// Immer die Textfarbe des Themes.
    case ink
    /// Die Farbe der Kategorie (dieselbe, die Ringe und Mosaik-Blöcke verwenden).
    case color

    static func parse(_ raw: String?) -> IconStyle {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let wert = IconStyle(rawValue: raw) else { return .auto }
        return wert
    }
}

/// Darstellung der Bankmarke.
enum LogoStyle: String, Equatable {
    /// Das Marken-SVG in seinen Farben.
    case color
    /// Einfarbige Silhouette in der Textfarbe des Themes — passt sich damit Hell und
    /// Dunkel an. Bevorzugt die Maske aus dem YAXI-Katalog; für die rund drei Viertel
    /// der Banken ohne Maske wird das Farblogo über seinen Alphakanal geplättet. Bei
    /// detailreichen Marken wird daraus ein Fleck — das ist der Preis der Einheitlichkeit
    /// und der Grund, warum `color` der Standard bleibt.
    case mono

    static func parse(_ raw: String?) -> LogoStyle {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let wert = LogoStyle(rawValue: raw) else { return .color }
        return wert
    }
}

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
    /// Farbe der **Bedienelemente im Ruhezustand**: Lupe und Platzhalter im Suchfeld,
    /// Fußzeilen-Symbole, Filter- und Kategorie-Symbole, Pager.
    ///
    /// Ohne diesen Schlüssel wird die Ink-Farbe gedämpft verwendet. Vorher standen dort
    /// System-Farben, und die folgen der macOS-Darstellung statt dem Theme — bei einem
    /// dunklen Theme mit hellem Erscheinungsbild wurden sie schwarz auf dunkel.
    var controlInkLightHex: String? = nil
    var controlInkDarkHex: String? = nil

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
    ///
    /// Betrifft **nur** die Bedienelemente. Die übrige Lo-Fi-Gestaltung hängt an
    /// `lofiTypography` — siehe dort, warum das getrennt ist.
    var glyphControls: Bool = true
    /// Kontoring (Ampel) zeichnen. `false` lässt die Fläche leer — für Themes, denen
    /// der Ring ins Bild funkt. Ein `ringImage` sticht diesen Schalter, siehe
    /// `kontoringSichtbar`.
    var accountRingEnabled: Bool = true
    /// Rasterschrift-Gestaltung: größere Schriftgrade, „double height"-Kontostand,
    /// Block-Felder, Blockleisten statt Ringe, bündige Zeilen ohne Gutter.
    ///
    /// Früher hing das an `glyphControls=off`. Ein Theme, das nur seine Bedienelemente
    /// als Text wollte, bekam ungefragt auch andere Schriftgrade — zwei Entscheidungen
    /// an einem Schalter. Jetzt getrennt: Wer beides will (BTX), setzt beides.
    var lofiTypography: Bool = false
    /// Farbe eines Rahmens um Flyout/Liste („Bildschirmrand"). nil → kein Rahmen.
    var screenBorderHex: String? = nil

    /// Dateiname eines eigenen Logos, **relativ zum Theme-Ordner**. Ersetzt die
    /// Bankmarke in Flyout und Umsatzliste — für ALLE Konten, unabhängig von der Bank.
    ///
    /// Verhältnis zu `bankLogosEnabled`: der entscheidet weiterhin, **ob** überhaupt
    /// eine Bildmarke erscheint, `logoFileName` nur **welche**. Bei `bankLogos=off`
    /// (BTX) bleibt es also beim Mosaik-Block. Ein Schalter, der einen anderen
    /// aushebelt, wäre schwer erklärbar.
    var logoFileName: String? = nil
    /// Optionale Variante für den Dunkelmodus. Bei Banken weiß
    /// `BankLogoAssets.isDark(brandId:)`, wie die Marke gebaut ist — bei einem fremden
    /// Bild weiß das niemand, deshalb wird nichts automatisch invertiert.
    var logoDarkFileName: String? = nil

    /// Hintergrundbild für Flyout und Umsatzliste, **relativ zum Theme-Ordner**.
    /// Ersetzt die flache Theme-Farbe (`cardLight`/`cardDark`) und damit auch den
    /// Money-Heat-Verlauf, der bei aktivem Theme ohnehin entfällt.
    ///
    /// Beide Flächen haben feste Maße — die Umsatzliste 348 × 620 schmal und 840 × 620
    /// breit, das Flyout 348 breit. Nur die Flyout-Höhe wechselt (Punkte, Drawer).
    /// Deshalb wird das Bild flächenfüllend skaliert und **oben verankert**, statt exakte
    /// Maße zu verlangen: Ein Theme mit einer Datei funktioniert so in allen Zuständen.
    var wallpaperFileName: String? = nil
    /// Variante für den Dunkelmodus. Ohne diesen Schlüssel gilt `wallpaper` in beiden
    /// Modi — wie beim Logo wird nichts automatisch invertiert.
    var wallpaperDarkFileName: String? = nil

    /// Eigenes Bild nur fürs Flyout, und eigenes nur für die breite Liste.
    ///
    /// Die drei Flächen haben Seitenverhältnisse von 2,5:1 (Flyout 348 × 140) über
    /// 0,56:1 (schmale Liste 348 × 620) bis 1,35:1 (breite Liste 840 × 620). Ein
    /// einzelnes Bild kann das nicht bedienen: Was in der schmalen Liste passt, zeigt im
    /// Flyout nur den oberen Rand. Wer ein Motiv unten im Bild hat, verliert es dort
    /// vollständig.
    ///
    /// Beide sind optional und fallen auf `wallpaper` zurück. Ein Theme mit einer
    /// einzigen Datei bleibt damit gültig.
    var wallpaperFlyoutFileName: String? = nil
    var wallpaperFlyoutDarkFileName: String? = nil
    var wallpaperWideFileName: String? = nil
    var wallpaperWideDarkFileName: String? = nil

    /// Grafik **statt** des Kontorings, gleiche Fläche (72 × 72).
    ///
    /// Ring und Grafik schließen einander aus — beides nebeneinander gäbe es den Platz
    /// nicht her. Setzt ein Theme dieses Bild, gewinnt es: Der Schalter „Kontoring
    /// anzeigen" in den Einstellungen wird gesperrt, damit nicht zwei Stellen um
    /// dieselbe Fläche streiten und der Nutzer einen Schalter ohne Wirkung sieht.
    ///
    /// Getrennt von `logo`, das über dem Kontostand sitzt: Sonst stünde dasselbe Bild
    /// zweimal nebeneinander im selben Fenster.
    var ringImageFileName: String? = nil
    var ringImageDarkFileName: String? = nil

    /// Wie die Kategorie-Symbole der Umsatzzeilen eingefärbt werden.
    ///
    /// Sie standen fest auf Systemgrau — auf einer dunklen Theme-Fläche oder einem
    /// dunklen Wallpaper praktisch unsichtbar.
    var categoryIconStyle: IconStyle = .auto

    /// Wie die Bankmarke in Flyout und Umsatzliste gezeichnet wird.
    var bankLogoStyle: LogoStyle = .color

    /// Pro Funktion austauschbares SF-Symbol, z. B. `icon.filter=slider.horizontal.3`.
    /// Leer → überall die Standardsymbole. Greift nur, solange `glyphControls` an ist;
    /// bei textgetriebenen Themes stehen weiterhin die Kürzel.
    var iconOverrides: [String: String] = [:]

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
        inkDarkHex: nil,
        controlInkLightHex: nil,
        controlInkDarkHex: nil
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

    /// Farbe der Bedienelemente im Ruhezustand. Ohne eigenen Schlüssel die Ink-Farbe
    /// gedämpft — dieselbe Familie, aber zurückgenommen, damit sie neben dem Kontostand
    /// nicht mit ihm konkurriert. 0,65 ist an das gedämpfte Ink der Untertitel angelehnt.
    func controlInkColor(dark: Bool) -> NSColor {
        if let hex = dark ? controlInkDarkHex : controlInkLightHex {
            return Self.color(from: hex, fallback: inkColor(dark: dark))
        }
        return inkColor(dark: dark).withAlphaComponent(0.65)
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

    /// Im Testlauf eine Wegwerf-Domain statt der echten — sonst änderte ein Test, der
    /// das Theme umschaltet, die Einstellung des Nutzers. Dieselbe Erkennung und
    /// Begründung wie bei `MultibankingStore.defaults` und `CredentialsStore.appSupportURL`.
    /// `nonisolated(unsafe)`, weil `ThemeManager` selbst `@unchecked Sendable` ist und
    /// `UserDefaults` nicht als Sendable gilt — dieselbe Bewertung wie bei den übrigen
    /// prozessweiten Werten hier. Der Wert wird einmal berechnet und nie verändert.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let sandbox = "simplebanking.tests.theme"
        if NSClassFromString("XCTestCase") != nil, let d = UserDefaults(suiteName: sandbox) {
            d.removePersistentDomain(forName: sandbox)
            return d
        }
        return .standard
    }()

    private var defaults: UserDefaults { Self.defaults }
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

    #if DEBUG
    /// Nur für Tests: schaltet das Theme um. Im Betrieb schreibt die Oberfläche den
    /// Schlüssel selbst; hier braucht es einen benannten Weg, damit Tests nicht am
    /// UserDefaults-Schlüssel kleben.
    func selectThemeForTesting(id: String) {
        defaults.set(id, forKey: Self.storageKey)
    }
    #endif

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

    /// Unter Tests ein eigenes Verzeichnis — sonst schriebe jeder Import-Test in die
    /// echte Theme-Sammlung des Nutzers, und ein abgebrochener Lauf ließe seinen Müll
    /// dort liegen. Dieselbe Erkennung wie bei `CredentialsStore` und
    /// `MultibankingStore.defaults`: `XCTestCase` existiert genau dann, wenn das
    /// Test-Bundle geladen ist — vom Linker garantiert, keine Heuristik.
    private var themesDirectoryURL: URL {
        if NSClassFromString("XCTestCase") != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("simplebanking-tests-themes", isDirectory: true)
        }
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
            controlInkLightHex: values["controlinklight"] ?? values["controlink"],
            controlInkDarkHex: values["controlinkdark"] ?? values["controlink"],
            rippleEnabled: Self.parseBool(values["ripple"], default: true),
            merchantLogosEnabled: Self.parseBool(values["merchantlogos"], default: true),
            categoryIconsEnabled: Self.parseBool(values["categoryicons"], default: true),
            bankLogosEnabled: Self.parseBool(values["banklogos"], default: true),
            uppercaseText: Self.parseBool(values["uppercase"], default: false),
            dottedLeaders: Self.parseBool(values["dottedleaders"], default: false),
            squareControls: Self.parseBool(values["squarecontrols"], default: false),
            glyphControls: Self.parseBool(values["glyphcontrols"], default: true),
            accountRingEnabled: Self.parseBool(values["accountring"], default: true),
            lofiTypography: Self.parseBool(values["lofitypography"], default: false),
            screenBorderHex: values["screenborder"].flatMap { $0.isEmpty ? nil : $0 },
            logoFileName: values["logo"].flatMap { $0.isEmpty ? nil : $0 },
            logoDarkFileName: values["logodark"].flatMap { $0.isEmpty ? nil : $0 },
            wallpaperFileName: values["wallpaper"].flatMap { $0.isEmpty ? nil : $0 },
            wallpaperDarkFileName: values["wallpaperdark"].flatMap { $0.isEmpty ? nil : $0 },
            wallpaperFlyoutFileName: values["wallpaperflyout"].flatMap { $0.isEmpty ? nil : $0 },
            wallpaperFlyoutDarkFileName: values["wallpaperflyoutdark"].flatMap { $0.isEmpty ? nil : $0 },
            wallpaperWideFileName: values["wallpaperwide"].flatMap { $0.isEmpty ? nil : $0 },
            wallpaperWideDarkFileName: values["wallpaperwidedark"].flatMap { $0.isEmpty ? nil : $0 },
            ringImageFileName: values["ringimage"].flatMap { $0.isEmpty ? nil : $0 },
            ringImageDarkFileName: values["ringimagedark"].flatMap { $0.isEmpty ? nil : $0 },
            categoryIconStyle: IconStyle.parse(values["categoryiconstyle"]),
            bankLogoStyle: LogoStyle.parse(values["banklogostyle"]),
            iconOverrides: Self.parseIconOverrides(from: values)
        )
    }


    /// Sammelt alle `icon.<name>=<sf-symbol>`-Zeilen ein. Der Schlüssel wird auf den
    /// Teil hinter dem Punkt reduziert; die Gültigkeit des Symbolnamens prüft erst
    /// `ThemeChrome.symbol(for:)` — ein Tippfehler soll kein Icon verschwinden lassen,
    /// sondern auf den Standard zurückfallen.
    static func parseIconOverrides(from values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values where key.hasPrefix("icon.") {
            let name = String(key.dropFirst("icon.".count))
            let symbol = value.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !symbol.isEmpty else { continue }
            result[name] = symbol
        }
        return result
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
        # Die Rasterschrift-Gestaltung hängt seit 2.0.2 an einem eigenen Schlüssel —
        # vorher kam sie ungefragt mit `glyphControls=off`. BTX will beides.
        lofiTypography=on
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
    static var lofiTypography: Bool { theme.lofiTypography }

    /// Eckenradius für Bedienelemente: 0 bei `squareControls`, sonst der übergebene Wert.
    static func cornerRadius(_ rounded: CGFloat) -> CGFloat { theme.squareControls ? 0 : rounded }

    /// `nil` beim Default-Theme — Aufrufer behalten dann ihr Bestandsverhalten.
    static var textCase: Text.Case? { theme.uppercaseText ? .uppercase : nil }

    /// Lo-Fi-Modus: die tiefgreifende Text-Terminal-Gestaltung (größere Rasterschrift-
    /// Typografie, „double height"-Kontostand, Block-Felder, Blockleisten statt Ringe,
    /// Flächen-Swaps im Sparmodus, bündige Zeilen ohne Gutter).
    ///
    /// Hing bis 2.0.2 an `glyphControls=off`. Das war eine Abkürzung aus der BTX-Arbeit:
    /// Damals gab es genau ein Theme, das beides wollte, und ein Schalter reichte. Für
    /// jedes andere Theme war die Kopplung eine Falle — wer nur Textkommandos statt
    /// Icons wollte, bekam ungefragt andere Schriftgrade dazu und konnte das nicht
    /// abwählen.
    ///
    /// Jetzt ein eigener Schlüssel. Themes wie Game Boy oder Sunrise, die nur Farben und
    /// Schriftfamilie setzen, behalten wie bisher exakt die Default-Metriken — sie haben
    /// ihn nicht gesetzt, und sein Standard ist `off`.
    static var lofi: Bool { !theme.isDefault && theme.lofiTypography }


    // MARK: - Austauschbare Bedien-Icons

    /// Symbol für eine Funktion: Theme-Override, sonst der Standard.
    ///
    /// Ein unbekannter Symbolname fällt auf den Standard zurück, statt ein leeres
    /// Bild zu zeichnen — dieselbe Haltung wie bei `parseBool`: Ein Tippfehler im
    /// `.cfg` darf keine Bedienung unsichtbar machen.
    /// `active` wählt die gefüllte/hervorgehobene Variante — Themes können beide
    /// getrennt setzen (`icon.filter` und `icon.filter.active`).
    static func symbol(for icon: ChromeIcon, active: Bool = false) -> String {
        let key = active ? "\(icon.rawValue).active" : icon.rawValue
        let fallback = active ? icon.defaultActiveSymbol : icon.defaultSymbol
        guard let override = theme.iconOverrides[key],
              NSImage(systemSymbolName: override, accessibilityDescription: nil) != nil
        else { return fallback }
        return override
    }

    /// Lädt ein Theme-Bild mit allen Schranken, oder `nil`.
    ///
    /// Gecacht, weil ein SwiftUI-Body sehr oft ausgewertet wird und
    /// `NSImage(contentsOf:)` jedes Mal von der Platte läse. Schlüssel ist Pfad plus
    /// Änderungsdatum — damit sieht man ein ausgetauschtes Bild ohne Neustart.
    @MainActor
    static func themeImage(at url: URL, maxBytes: Int, art: String) -> NSImage? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > 0, size <= maxBytes else {
            if size > maxBytes {
                AppLogger.log("Theme-\(art) übersprungen: \(url.lastPathComponent) ist \(size / 1024) KB, erlaubt sind \(maxBytes / 1024) KB",
                              category: "Theme", level: "WARN")
            }
            return nil
        }
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)"
        if let cached = bildCache[key] { return cached }
        guard logoDimensionsAreSane(at: url) else {
            AppLogger.log("Theme-\(art) übersprungen: \(url.lastPathComponent) hat unzulässige Bildmaße (max \(maxLogoEdge) px je Kante, \(maxLogoPixels / 1_000_000) MP gesamt)",
                          category: "Theme", level: "WARN")
            return nil
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        // Höchstens Logo + Wallpaper gleichzeitig, hell oder dunkel — vier Einträge
        // genügen, danach beginnt der Cache von vorn.
        if bildCache.count >= 4 { bildCache.removeAll() }
        bildCache[key] = image
        return image
    }

    @MainActor
    static var globalLogoImage: NSImage? {
        guard let url = globalLogoURL else { return nil }
        return themeImage(at: url, maxBytes: maxLogoBytes, art: "Logo")
    }

    /// Das Wallpaper einer Fläche als fertiges Bild, oder `nil`.
    @MainActor
    static func wallpaperImage(for flaeche: WallpaperFlaeche) -> NSImage? {
        guard let url = wallpaperURL(for: flaeche) else { return nil }
        return themeImage(at: url, maxBytes: maxWallpaperBytes, art: "Wallpaper")
    }

    @MainActor
    static var wallpaperImage: NSImage? { wallpaperImage(for: .listeSchmal) }

    /// Durchschnittsfarbe der **oberen Bildkante** des Wallpapers.
    ///
    /// Gebraucht für die Sprechblasen-Nase des Flyouts: Dort lässt sich kein Bild
    /// zeichnen, der Zipfel wird flächig getönt (`tintFlyoutPopoverArrow`). Ohne diesen
    /// Wert behielte er die alte Theme-Farbe und stäche unter einem Wallpaper heraus —
    /// dieselbe Stelle, die vor der Nasen-Tönung weiß geblieben war.
    @MainActor
    static var wallpaperTopEdgeColor: NSColor? {
        // Ausdrücklich das Flyout-Bild: Die Nase sitzt am Flyout, und seit es ein eigenes
        // Bild dafür geben kann, wäre die Oberkante des Listenbildes die falsche Quelle.
        guard let bild = wallpaperImage(for: .flyout) else { return nil }
        return averageTopEdgeColor(of: bild)
    }

    /// Mittelt einen schmalen Streifen an der Oberkante zu einer Farbe, indem er auf
    /// einen einzigen Bildpunkt gezeichnet wird.
    static func averageTopEdgeColor(of image: NSImage, stripFraction: CGFloat = 0.06) -> NSColor? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let streifen = max(1, image.size.height * stripFraction)
        // `from:` rechnet von unten links — die Oberkante liegt bei height - streifen.
        let quelle = NSRect(x: 0, y: image.size.height - streifen,
                            width: image.size.width, height: streifen)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1),
                   from: quelle, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0)
    }

    /// Theme-Ordner sollen weitergebbar bleiben, und die Datei wird beim Themewechsel
    /// synchron geladen.
    static let maxLogoBytes = 512 * 1024

    /// Die Byte-Grenze sagt nichts über den Speicher beim Dekodieren: Ein stark
    /// komprimiertes PNG von 300 KB kann 40 000 × 40 000 Pixel groß sein und beim
    /// Zeichnen mehrere Gigabyte belegen. Deshalb zusätzlich eine Grenze für die
    /// Bildmaße — geprüft aus den Metadaten, **bevor** dekodiert wird.
    static let maxLogoEdge = 8_000
    static let maxLogoPixels = 16_000_000

    /// Was THEMES.md §4.1 zusagt: PNG, PDF, SVG. Nicht mehr — ein Theme soll ein Logo
    /// mitbringen, keine beliebige Datei öffnen lassen.
    static let allowedLogoExtensions: Set<String> = ["png", "pdf", "svg"]

    /// Byte-Grenze fürs Wallpaper. Deutlich höher als beim Logo: 840 × 620 in @2x sind
    /// 1680 × 1240 Pixel, und dafür reichen 512 KB nicht.
    static let maxWallpaperBytes = 4 * 1024 * 1024

    @MainActor private static var bildCache: [String: NSImage] = [:]

    /// Prüft den Dateinamen aus der `.cfg`.
    ///
    /// THEMES.md verspricht „Dateiname **relativ zum Theme-Ordner**" — genau das wird
    /// hier erzwungen und nichts darüber hinaus. Ohne die Prüfung genügte
    /// `logo=../../Pictures/privat.png`, um ein beliebiges Bild des Nutzers in die App
    /// zu holen: `appendingPathComponent` normalisiert nicht, das Dateisystem löst `..`
    /// erst beim Öffnen auf. Themes sind ausdrücklich zum Weitergeben gedacht (§8), ein
    /// fremdes darf deshalb nicht aus seinem Ordner herausgreifen.
    /// Prüft **und normalisiert** in einem Schritt: Der Rückgabewert ist der Name, der
    /// tatsächlich an den Theme-Ordner angehängt werden darf — `nil`, wenn er unzulässig
    /// ist. Zwei getrennte Funktionen wären hier eine Falle: Prüfte die eine den
    /// beschnittenen Wert und baute die andere den Pfad aus dem rohen, hätte ein
    /// angehängter Zeilenumbruch die Prüfung bestanden und eine andere Datei geöffnet.
    static func sanitizedLogoFileName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 255 else { return nil }
        // Ein einzelner Name — keine Verzeichnisanteile, kein Aufstieg, nichts Verstecktes.
        guard !name.contains("/"), !name.contains("\\"), !name.contains(".."),
              !name.hasPrefix("."), !name.contains("\0"),
              name.rangeOfCharacter(from: .newlines) == nil
        else { return nil }
        guard allowedLogoExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
        return name
    }

    static func isValidLogoFileName(_ raw: String) -> Bool {
        sanitizedLogoFileName(raw) != nil
    }

    /// Löst einen Dateinamen aus der `.cfg` zu einer Datei **im Theme-Ordner** auf.
    ///
    /// Gemeinsamer Weg für Logo und Wallpaper: Beide stehen in derselben bearbeitbaren
    /// Datei und tragen dieselbe Gefahr. `art` geht nur in die Protokollzeile ein, damit
    /// im Log steht, welcher Schlüssel abgelehnt wurde.
    static func themeAssetURL(named name: String, art: String) -> URL? {
        guard let sauber = sanitizedLogoFileName(name) else {
            AppLogger.log("Theme-\(art) abgelehnt: „\(name)\" ist kein einfacher Dateiname im Theme-Ordner (erlaubt: \(allowedLogoExtensions.sorted().joined(separator: ", ")))",
                          category: "Theme", level: "WARN")
            return nil
        }
        let ordner = URL(fileURLWithPath: ThemeManager.shared.themesDirectoryPath)
            .resolvingSymlinksInPath().standardizedFileURL
        let url = ordner.appendingPathComponent(sauber)
        // Zweiter Riegel gegen Verknüpfungen: Der Name ist harmlos, aber die Datei
        // selbst kann ein Symlink nach draußen sein — ein weitergegebener Ordner
        // bringt so etwas leicht mit.
        let ziel = url.resolvingSymlinksInPath().standardizedFileURL
        guard ziel.path.hasPrefix(ordner.path + "/") else {
            AppLogger.log("Theme-\(art) abgelehnt: \(name) zeigt aus dem Theme-Ordner heraus",
                          category: "Theme", level: "WARN")
            return nil
        }
        // Fehlende Datei → still zurück auf das Bisherige. Ein Theme darf keine leere
        // Fläche hinterlassen, nur weil ein Bild vergessen wurde.
        return FileManager.default.fileExists(atPath: ziel.path) ? ziel : nil
    }

    /// Ein globales Logo ersetzt die Bankmarke — aber nur, wenn Bildmarken überhaupt
    /// gezeichnet werden. `bankLogos` entscheidet OB, `logo` nur WOMIT.
    static var globalLogoURL: URL? {
        guard theme.bankLogosEnabled else { return nil }
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = (dark ? theme.logoDarkFileName : nil) ?? theme.logoFileName
        guard let name else { return nil }
        return themeAssetURL(named: name, art: "Logo")
    }

    /// Die drei Flächen, die ein eigenes Wallpaper haben können.
    enum WallpaperFlaeche {
        /// 348 × 140 bzw. 178, plus Drawer-Höhe — sehr breit und flach.
        case flyout
        /// 348 × 620 — hochkant.
        case listeSchmal
        /// 840 × 620 — querformat.
        case listeBreit
    }

    static var accountRingEnabled: Bool { theme.accountRingEnabled }

    /// Zusätzlicher Innenabstand, wenn ein Bildschirmrahmen gezeichnet wird.
    ///
    /// Der Rahmen liegt als Overlay **innen** auf und verbraucht keinen Layout-Platz —
    /// er legt sich also über das, was am Rand steht. Ohne Ausgleich kleben die
    /// Fußzeilen-Symbole auf der Kante. Die Blende ist 5 pt (Flyout) bzw. 6 pt (Liste)
    /// stark; 8 gibt ihr Luft, ohne die festen Fensterhöhen anzutasten.
    ///
    /// Hing bis 2.0.2 an `lofi` — ein Theme mit Rahmen, aber ohne Rasterschrift bekam
    /// deshalb gar keinen Ausgleich. Genau der Fall, der gemeldet wurde.
    static var randAusgleich: CGFloat { theme.screenBorderHex == nil ? 0 : 8 }

    /// Ob auf der Ringfläche etwas steht — in Flyout und Umsatzliste dieselbe Antwort.
    ///
    /// Die Rangfolge, von stark nach schwach:
    ///
    /// 1. **Grafik des Themes** (`ringImage`). Sie ersetzt den Ring, statt ihn zu
    ///    verbergen — deshalb sticht sie auch einen abgeschalteten Ring. Der Schalter in
    ///    den Einstellungen ist in diesem Fall gesperrt, sein gespeicherter Wert also
    ///    ohnehin nicht das, was der Nutzer zuletzt gemeint hat.
    /// 2. **Theme sagt nein** (`accountRing=off`). Ein Theme, dem der Ring ins Bild
    ///    funkt, darf ihn weglassen.
    /// 3. **Nutzerschalter.** Sonst entscheidet „Kontoring anzeigen".
    ///
    /// Reine Funktion mit ausdrücklichen Eingaben, damit die Rangfolge prüfbar ist,
    /// ohne für jede Kombination ein Theme anlegen zu müssen.
    static func kontoringSichtbar(nutzerSchalter: Bool,
                                  themeErlaubtRing: Bool,
                                  grafikGesetzt: Bool) -> Bool {
        if grafikGesetzt { return true }
        guard themeErlaubtRing else { return false }
        return nutzerSchalter
    }

    /// Dieselbe Frage, beantwortet aus dem aktiven Theme.
    @MainActor
    static func kontoringSichtbar(nutzerSchalter: Bool) -> Bool {
        kontoringSichtbar(nutzerSchalter: nutzerSchalter,
                          themeErlaubtRing: accountRingEnabled,
                          grafikGesetzt: ringImageActive)
    }

    static var categoryIconStyle: IconStyle { theme.categoryIconStyle }
    static var bankLogoStyle: LogoStyle { theme.bankLogoStyle }

    /// Farbe eines Kategorie-Symbols in der Umsatzzeile.
    ///
    /// `kategoriefarbe` ist die Farbe, die Ringe und Mosaik-Blöcke für diese Kategorie
    /// verwenden — sie wird nur im Modus `color` gebraucht und deshalb erst dann gelesen.
    static func categoryIconColor(_ kategoriefarbe: @autoclosure () -> Color) -> Color {
        let themed = !theme.isDefault
        switch theme.categoryIconStyle {
        case .ink:   return themed ? .themedInk : .secondary
        case .color: return kategoriefarbe()
        case .auto:  return themed ? .themedInk : .secondary
        }
    }

    /// Grafik statt Kontoring, oder `nil`.
    static var ringImageURL: URL? {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = (dark ? theme.ringImageDarkFileName : nil) ?? theme.ringImageFileName
        guard let name else { return nil }
        return themeAssetURL(named: name, art: "Ringbild")
    }

    /// True, wenn das Theme den Ringplatz belegt. Der Schalter „Kontoring anzeigen"
    /// wird dann gesperrt — sonst stritten Theme und Einstellung um dieselbe Fläche.
    static var ringImageActive: Bool { ringImageURL != nil }

    @MainActor
    static var ringImage: NSImage? {
        guard let url = ringImageURL else { return nil }
        return themeImage(at: url, maxBytes: maxLogoBytes, art: "Ringbild")
    }

    /// True, sobald das aktive Theme ein **Grundbild** mitbringt.
    ///
    /// Bewusst am Grundbild und nicht an den flächenspezifischen Schlüsseln: Von dieser
    /// Auskunft hängt ab, ob die Farbflächen durchsichtig werden. Wäre sie schon bei
    /// einem reinen `wallpaperFlyout` wahr, hätte die Umsatzliste durchsichtige Flächen
    /// ohne Bild dahinter — ein durchscheinendes Fenster statt eines Hintergrunds.
    static var wallpaperActive: Bool { wallpaperURL(for: .listeSchmal) != nil }

    /// Wallpaper einer Fläche. Fällt auf das Grundbild zurück, sodass ein Theme mit einer
    /// einzigen Datei gültig bleibt.
    static func wallpaperURL(for flaeche: WallpaperFlaeche) -> URL? {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let spezifisch: String? = {
            switch flaeche {
            case .flyout:      return (dark ? theme.wallpaperFlyoutDarkFileName : nil) ?? theme.wallpaperFlyoutFileName
            case .listeBreit:  return (dark ? theme.wallpaperWideDarkFileName : nil) ?? theme.wallpaperWideFileName
            case .listeSchmal: return nil
            }
        }()
        let grund = (dark ? theme.wallpaperDarkFileName : nil) ?? theme.wallpaperFileName
        // Ein flächenspezifisches Bild ohne Grundbild ist eine Falle: `wallpaperActive`
        // hängt am Grundbild, die Farbflächen blieben also deckend, und das spezifische
        // Bild läge unsichtbar darunter. Lieber deutlich melden als still ignorieren.
        if spezifisch != nil, grund == nil {
            AppLogger.log("Theme-Wallpaper: flächenspezifisches Bild ohne `wallpaper` — ohne Grundbild bleibt überall die Farbe. Bitte zusätzlich `wallpaper=` setzen.",
                          category: "Theme", level: "WARN")
            return nil
        }
        guard let name = spezifisch ?? grund else { return nil }
        return themeAssetURL(named: name, art: "Wallpaper")
    }

    /// Rückwärtskompatibler Zugriff auf das Grundbild.
    static var wallpaperURL: URL? { wallpaperURL(for: .listeSchmal) }

    /// Liest die Bildmaße aus den Metadaten, ohne zu dekodieren.
    ///
    /// Liefert `true`, wenn keine Maße zu ermitteln sind — bei SVG kennt ImageIO keine
    /// Pixelgröße, und ein Vektorbild hat auch keine. Dort bleibt die Byte-Grenze die
    /// einzige Schranke; das ist eine bewusste Lücke und keine vergessene.
    static func logoDimensionsAreSane(at url: URL) -> Bool {
        guard let quelle = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(quelle, 0, nil) as? [CFString: Any]
        else { return true }
        let breite = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let hoehe = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard breite > 0, hoehe > 0 else { return true }
        return breite <= maxLogoEdge && hoehe <= maxLogoEdge
            && breite * hoehe <= maxLogoPixels
    }
}

/// Die Bedien-Icons, die ein Theme einzeln austauschen darf.
///
/// Vorher stand jedes Symbol als Literal in seiner View, rund vierzehnmal dasselbe
/// `if glyphControls { Image(systemName:) } else { BTXTextControl(…) }`. Ohne eine
/// solche Aufzählung gäbe es keinen Namen, den ein Theme adressieren könnte.
///
/// `defaultSymbol` ist jeweils exakt das heutige Symbol, `textFallback` exakt das
/// heutige BTX-Kürzel — die Registry ändert für sich genommen nichts.
enum ChromeIcon: String, CaseIterable {
    case filter, categories, savings, send, dashboard, inbox, refresh, pin, settings, clear

    /// Symbol im Ruhezustand — exakt das heutige.
    var defaultSymbol: String {
        switch self {
        case .filter:     return "line.3.horizontal.decrease"
        case .categories: return "tag"
        case .savings:    return "centsign.circle"
        case .send:       return "paperplane"
        case .dashboard:  return "square.grid.2x2"
        case .inbox:      return "bell"
        case .refresh:    return "arrow.clockwise"
        case .pin:        return "pin"
        case .settings:   return "gearshape"
        case .clear:      return "xmark.circle.fill"
        }
    }

    /// Symbol im aktiven Zustand. Nicht durchgehend „Basis + `.fill`" — der Filter
    /// wechselt heute von `line.3.horizontal.decrease` auf
    /// `line.3.horizontal.decrease.circle.fill`, bekommt also zusätzlich den Kreis.
    /// Deshalb steht die Variante ausgeschrieben, statt sie abzuleiten.
    var defaultActiveSymbol: String {
        switch self {
        case .filter:     return "line.3.horizontal.decrease.circle.fill"
        case .categories: return "tag.fill"
        case .savings:    return "centsign.circle.fill"
        case .inbox:      return "bell.fill"
        case .pin:        return "pin.fill"
        // Ohne eigenen Aktiv-Zustand — hier bleibt es beim Ruhesymbol.
        case .send, .dashboard, .refresh, .settings, .clear: return defaultSymbol
        }
    }

    /// Kürzel für textgetriebene Themes (`glyphControls=off`).
    var textFallback: String {
        switch self {
        case .filter:     return "Filter"
        case .categories: return "Kat."
        case .savings:    return "Sparen"
        case .send:       return "Senden"
        case .dashboard:  return "Auswertung"
        case .inbox:      return "Inbox"
        case .refresh:    return "Neu"
        case .pin:        return "Pin"
        case .settings:   return "Optionen"
        case .clear:      return "X"
        }
    }
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
    ///
    /// Die Schrift kommt ausschließlich aus dem Theme (`headingFont` / `bodyFont` im
    /// `.cfg`) — bewusst ohne Einstellung in der App. Sie ist Teil der Gestaltung, die
    /// ein Theme mitbringt, nicht etwas, das der Nutzer darüberlegt.
    static func flyoutHeading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        themedFont(named: ThemeManager.shared.currentTheme.headingFontName, size: size, weight: weight)
    }

    static func flyoutBody(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        themedFont(named: ThemeManager.shared.currentTheme.bodyFontName, size: size, weight: weight)
    }

    // MARK: - Zeilentexte in Flyout und Umsatzliste
    //
    // Vorher stand an diesen Stellen `lofi ? flyoutBody(…) : .system(…)`. `lofi` hing
    // damals an `!glyphControls` — in der Praxis also „das ist BTX". Damit erreichte
    // die Theme-Schrift den Kontostand und die Überschriften (die rufen `flyoutHeading`
    // ungatet), nicht aber Empfänger, Betrag oder Kategorie in der Umsatzliste. Ein
    // Theme mit eigener Schrift wirkte deshalb nur halb.
    //
    // `size`/`weight` gelten für den Normalfall — auch für Themes mit eigener Schrift.
    // `lofiSize`/`lofiWeight` gelten nur für textgetriebene Themes (BTX/VT323), deren
    // Schrift kleiner baut und deshalb größere Grade braucht. Ohne Theme kommt weiterhin
    // die Systemschrift; das Bild des Default-Themes bleibt damit unverändert.
    //
    // Die Geometrie kann sich dabei nicht verschieben: Zeilenhöhen stammen aus
    // `lineHeight(forSize:weight:)` und damit aus der Systemschrift, nicht aus der
    // Theme-Familie.

    static func rowBody(size: CGFloat, weight: Font.Weight = .regular,
                        lofiSize: CGFloat? = nil, lofiWeight: Font.Weight? = nil) -> Font {
        guard !ThemeManager.shared.currentTheme.isDefault else {
            return .system(size: size, weight: weight)
        }
        guard ThemeChrome.lofi else { return flyoutBody(size: size, weight: weight) }
        return flyoutBody(size: lofiSize ?? size, weight: lofiWeight ?? weight)
    }

    static func rowHeading(size: CGFloat, weight: Font.Weight = .semibold,
                           lofiSize: CGFloat? = nil, lofiWeight: Font.Weight? = nil) -> Font {
        guard !ThemeManager.shared.currentTheme.isDefault else {
            return .system(size: size, weight: weight)
        }
        guard ThemeChrome.lofi else { return flyoutHeading(size: size, weight: weight) }
        return flyoutHeading(size: lofiSize ?? size, weight: lofiWeight ?? weight)
    }

    /// Feste Zeilenhöhe für theme-getönte Textstellen — abgeleitet aus der
    /// **Systemschrift** dieser Größe, nicht aus der Theme-Schrift.
    ///
    /// Der Punkt ist genau diese Trennung: Ohne feste Höhe bestimmt die gewählte
    /// Schriftfamilie die Zeilenhöhe, und damit die Höhe der Saldo-Karte und des ganzen
    /// Flyouts. Bei Game Boy ist das schon einmal passiert — Kontostand und Umsätze
    /// wurden zu groß, und die Höhe wanderte zusätzlich mit der Länge des Betrags.
    /// Weil der Wert aus der Systemschrift kommt, bleibt das heutige Bild identisch,
    /// egal welche Familie ein Theme oder der Nutzer später wählt.
    ///
    /// `ascender - descender + leading` ist die Standard-Zeilenhöhe; `descender` ist
    /// negativ, deshalb die Subtraktion.
    static func lineHeight(forSize size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil(font.ascender - font.descender + font.leading)
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
    /// Bedienelemente im Ruhezustand — themed statt System.
    static var themedControlInk: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return ThemeManager.shared.currentTheme.controlInkColor(dark: dark)
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
    /// Die Theme-Fläche — oder durchsichtig, wenn ein Wallpaper darunterliegt.
    ///
    /// Flyout und Liste malen ihre Flächen mehrfach übereinander (Karte, Kopfzeile,
    /// Panel). Jede davon würde ein Wallpaper verdecken, das nur ganz unten liegt.
    /// Deshalb weichen sie zurück, sobald eines aktiv ist, statt das Bild in jede
    /// einzelne Ebene zu kopieren.
    static var themedSurfaceOrClear: Color {
        ThemeChrome.wallpaperActive ? .clear : themedSurface
    }

    /// Mittelband des Kontorings: die Mischung aus Ausgaben- und Einnahmenfarbe.
    ///
    /// Der Ring hat drei Bänder (knapp / mittel / gut). Für das mittlere gibt es im
    /// Theme-Vertrag keinen eigenen Wert, und es soll auch keiner dazukommen — ein
    /// weiterer Schlüssel für eine Farbe, die zwischen zwei vorhandenen liegt, wäre
    /// Ballast. Die Mischung folgt der Palette automatisch: Bei einer roten/grünen
    /// Palette wird es olivgelb, bei einer blau/violetten entsprechend anders.
    static var themedMidBand: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let t = ThemeManager.shared.currentTheme
            let dark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let negativ = (dark ? t.negativeDarkColor : t.negativeLightColor).usingColorSpace(.sRGB)
            let positiv = (dark ? t.positiveDarkColor : t.positiveLightColor).usingColorSpace(.sRGB)
            guard let negativ, let positiv else { return .systemOrange }
            return negativ.blended(withFraction: 0.5, of: positiv) ?? negativ
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


// MARK: - Wallpaper-Ebene

/// Zeichnet das Theme-Wallpaper flächenfüllend, **oben verankert**, Überhang beschnitten.
///
/// Die Verankerung oben ist die Entscheidung, die ein Theme mit einer einzigen Datei
/// tragfähig macht: Die Umsatzliste hat zwei feste Breiten (348 und 840 bei 620 Höhe),
/// das Flyout wechselt seine Höhe (Punkte, Schnellüberweisungs-Drawer). Wer exakte Maße
/// verlangte, bräuchte vier Dateien und bekäme trotzdem beim Aufklappen des Drawers ein
/// falsches Bild. So bleibt oben immer derselbe Bildausschnitt stehen, und nach unten
/// wird gezeigt, was Platz hat.
///
/// Ohne Wallpaper zeichnet der View nichts — Aufrufer können ihn bedingungslos einhängen.
struct ThemeWallpaper: View {
    /// Welche Fläche gezeichnet wird — bestimmt, welches der drei Bilder greift.
    let flaeche: ThemeChrome.WallpaperFlaeche

    // Kein `@ObservedObject`: `ThemeManager` ist kein ObservableObject, die übrigen
    // Theme-Stellen lesen `currentTheme` ebenfalls direkt. Ein Themewechsel baut
    // Flyout und Liste neu auf.
    var body: some View {
        if let bild = ThemeChrome.wallpaperImage(for: flaeche) {
            Image(nsImage: bild)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
        }
    }
}


// MARK: - Bankmarke nach Theme-Stil

/// Zeichnet die Bankmarke in Flyout und Umsatzliste — farbig oder einfarbig.
///
/// `bankLogoStyle=mono` macht daraus eine Silhouette in der Textfarbe des Themes und
/// passt sich damit Hell und Dunkel von selbst an. Bevorzugt wird die einfarbige Maske
/// aus dem YAXI-Katalog; wo es keine gibt — und das ist bei rund drei Vierteln der
/// Banken so —, wird das Farblogo über seinen Alphakanal geplättet. Bei detailreichen
/// Marken wird daraus ein Fleck. Genau deshalb bleibt `color` der Standard.
struct BankMark: View {
    let image: NSImage
    var brandId: String? = nil
    var size: CGFloat = 20
    var cornerRadius: CGFloat = 5
    /// Für die Invertierung im Dunkelmodus (nur im Farbmodus relevant).
    var dark: Bool = false

    var body: some View {
        if ThemeChrome.bankLogoStyle == .mono, let mono = Self.monoImage(image, brandId: brandId) {
            Image(nsImage: mono)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundColor(.themedInk)
        } else if dark, BankLogoAssets.isDark(brandId: brandId ?? "") {
            farbig.colorInvert()
        } else {
            farbig
        }
    }

    private var farbig: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Liefert ein Bild, das als Schablone gezeichnet werden kann.
    ///
    /// Der Maskenzugriff geht über `brandId`. Für zehn der gepflegten Marken weicht die
    /// id vom Katalogschlüssel ab (`commerzbank` lädt unter `commerz`) — dort schlägt der
    /// Zugriff fehl und es wird geplättet. Das ist bekannt und hier bewusst nicht
    /// repariert: Der Versatz gehört in die Markenauflösung, nicht hierher.
    @MainActor
    static func monoImage(_ original: NSImage, brandId: String?) -> NSImage? {
        if let id = brandId, BankLogoCache.hasMask(forLogoId: id),
           let url = BankLogoCache.url(forLogoId: id, mask: true),
           let maske = NSImage(contentsOf: url) {
            maske.isTemplate = true
            return maske
        }
        // Kopie, damit das geteilte Farbbild nicht dauerhaft zur Schablone wird — es
        // wird an anderer Stelle weiterhin farbig gebraucht.
        guard let kopie = original.copy() as? NSImage else { return nil }
        kopie.isTemplate = true
        return kopie
    }
}
