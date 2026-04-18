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
        negativeDarkHex: "#D77979"   // Red Strong dark
    )

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

    private func parseTheme(from url: URL) -> AppTheme? {
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
            negativeDarkHex: values["negativedark"]
        )
    }

    private static let builtInThemes: [String: String] = [
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
        "ocean.cfg": """
        # simplebanking Theme
        id=ocean
        name=Ocean
        bodyFont=Helvetica Neue
        headingFont=Helvetica Neue Bold
        accent=#1F6F8B
        positive=#2A9D8F
        negative=#D1495B
        cardLight=#F2FAFD
        cardDark=#1F2A30
        panelLight=#DDEBF1
        panelDark=#141C21
        """,
        "norton-commander.cfg": """
        # simplebanking Theme
        id=norton-commander
        name=Norton Commander
        bodyFont=Menlo
        headingFont=Menlo Bold
        accent=#00CCCC
        positive=#00CC00
        negative=#FF3333
        cardLight=#D6E4FF
        cardDark=#0000AA
        panelLight=#B8CEFF
        panelDark=#000077
        """,
        "gameboy.cfg": """
        # simplebanking Theme — Game Boy (Mockup palette)
        id=gameboy
        name=Game Boy
        bodyFont=Courier New
        headingFont=Courier New Bold
        accent=#8CC040
        positive=#8CC040
        negative=#D06850
        # Light mode: dark amounts on sage green for readability
        positiveLight=#2A5820
        negativeLight=#8B2A18
        # Dark mode: bright lime / coral on dark olive (matches mockup)
        positiveDark=#8CC040
        negativeDark=#D06850
        cardLight=#D4E8B0
        cardDark=#2B3A18
        panelLight=#C0D49C
        panelDark=#3A4B28
        """
    ]
}

enum ThemeFonts {
    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        themedFont(named: ThemeManager.shared.currentTheme.bodyFontName, size: size, weight: weight)
    }

    static func heading(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        themedFont(named: ThemeManager.shared.currentTheme.headingFontName, size: size, weight: weight)
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
    static var expenseRed: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let theme = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? theme.negativeDarkColor
                : theme.negativeLightColor
        })
    }

    static var incomeGreen: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let theme = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? theme.positiveDarkColor
                : theme.positiveLightColor
        })
    }

    static var cardBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let theme = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? theme.cardDarkColor
                : theme.cardLightColor
        })
    }

    static var panelBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let theme = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? theme.panelDarkColor
                : theme.panelLightColor
        })
    }

    /// Cooler panel background used in Freeze mode — Blue Soft aus der Color Harmony Palette.
    static var freezePanelBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return AppTheme.color(from: isDark ? "#1F3144" : "#EAF1F8", fallback: .controlBackgroundColor)
        })
    }

    static var themeAccent: Color {
        Color(nsColor: ThemeManager.shared.currentTheme.accentColor)
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

    // Neutral — warm taupe for "other" / rest categories.
    // Not system gray — deliberately part of the palette so "other" reads as
    // a real category, not leftover space.
    static var sbNeutralStrong: Color { dynamicHex(light: "#8A7F70", dark: "#A89D8D") }
    static var sbNeutralMid: Color    { dynamicHex(light: "#B0A699", dark: "#BAB0A3") }
    static var sbNeutralSoft: Color   { dynamicHex(light: "#EEEAE3", dark: "#2E2A24") }
}
