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

    static let fallback = AppTheme(
        id: "default",
        name: "Default",
        bodyFontName: "System",
        headingFontName: "System",
        accentHex: "#0A84FF",
        positiveHex: "#34C759",
        negativeHex: "#E00103",
        cardLightHex: "#FFFFFF",
        cardDarkHex: "#333333",
        panelLightHex: "#EBEBEB",
        panelDarkHex: "#1F1F1F"
    )

    var accentColor: NSColor { Self.color(from: accentHex, fallback: .controlAccentColor) }
    var positiveColor: NSColor { Self.color(from: positiveHex, fallback: .systemGreen) }
    var negativeColor: NSColor { Self.color(from: negativeHex, fallback: .systemRed) }
    var cardLightColor: NSColor { Self.color(from: cardLightHex, fallback: .white) }
    var cardDarkColor: NSColor { Self.color(from: cardDarkHex, fallback: NSColor(white: 0.2, alpha: 1.0)) }
    var panelLightColor: NSColor { Self.color(from: panelLightHex, fallback: NSColor(white: 0.92, alpha: 1.0)) }
    var panelDarkColor: NSColor { Self.color(from: panelDarkHex, fallback: NSColor(white: 0.12, alpha: 1.0)) }

    private static func color(from hex: String, fallback: NSColor) -> NSColor {
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
                if !fileManager.fileExists(atPath: target.path) {
                    try content.write(to: target, atomically: true, encoding: .utf8)
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
            panelDarkHex: values["paneldark"] ?? fallback.panelDarkHex
        )
    }

    private static let builtInThemes: [String: String] = [
        "default.cfg": """
        # simplebanking Theme
        id=default
        name=Default
        bodyFont=System
        headingFont=System
        accent=#0A84FF
        positive=#34C759
        negative=#E00103
        cardLight=#FFFFFF
        cardDark=#333333
        panelLight=#EBEBEB
        panelDark=#1F1F1F
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
        accent=#00AAAA
        positive=#00AA00
        negative=#AA0000
        cardLight=#0000AA
        cardDark=#0000AA
        panelLight=#000055
        panelDark=#000055
        """,
        "gameboy.cfg": """
        # simplebanking Theme
        id=gameboy
        name=Game Boy
        bodyFont=Courier New
        headingFont=Courier New Bold
        accent=#0F380F
        positive=#306230
        negative=#8BAC0F
        cardLight=#9BBC0F
        cardDark=#0F380F
        panelLight=#8BAC0F
        panelDark=#0F380F
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
        Color(nsColor: ThemeManager.shared.currentTheme.negativeColor)
    }

    static var incomeGreen: Color {
        Color(nsColor: ThemeManager.shared.currentTheme.positiveColor)
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

    static var themeAccent: Color {
        Color(nsColor: ThemeManager.shared.currentTheme.accentColor)
    }
}
