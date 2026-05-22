import Foundation

// MARK: - BankLogoCatalog
//
// Loader für `Resources/yaxi-bank-catalog.json` — YAXI's offizieller
// Bank-Logo-Catalog (Schema: docs.yaxi.tech/integrations.html#_bank_logos).
//
// Pro logoId enthält der Catalog:
//   • `svg`            — inline SVG-String (Vector-Logo)
//   • `svgMask`        — optional, Single-color-Silhouette (für Tinting/Dark-Mode)
//   • `primaryColor`   — Brand-Hauptfarbe als Hex-String
//   • `secondaryColor` — optional, zweite Brand-Farbe
//
// Daten werden EINMAL pro App-Lifecycle aus dem Bundle gelesen + dekodiert.
// SVG-Strings landen in `BankLogoCache` (separates File) und werden
// bei Bedarf in den User-Cache extrahiert (für NSImage-File-URL-Loading).

enum BankLogoCatalog {

    struct Entry: Decodable, Equatable {
        let svg: String
        let maskSvg: String?
        let primaryColor: String?
        let secondaryColor: String?
    }

    private static let loaded: (entries: [String: Entry], schema: String?) = loadFromBundle()
    private static var entries: [String: Entry] { loaded.entries }

    /// Schema-Version aus dem `$schema`-Feld (zur Diagnose, nicht funktional genutzt).
    static var schemaURL: String? { loaded.schema }

    private static func loadFromBundle() -> (entries: [String: Entry], schema: String?) {
        // SwiftPM-Resource-Bundle. `Bundle.module` greift sowohl im App-Bundle
        // (Release) als auch im Test-Bundle, anders als `Bundle.main`.
        let bundle: Bundle = .module
        guard let url = bundle.url(forResource: "yaxi-bank-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            AppLogger.log("BankLogoCatalog: catalog file missing in bundle",
                          category: "BankLogos", level: "ERROR")
            return ([:], nil)
        }
        // Manueller Parse: top-level Dict mit `$schema` (String) + N×Entry.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.log("BankLogoCatalog: catalog JSON parse failed",
                          category: "BankLogos", level: "ERROR")
            return ([:], nil)
        }
        let schema = raw["$schema"] as? String

        var result: [String: Entry] = [:]
        let decoder = JSONDecoder()
        for (key, value) in raw where !key.hasPrefix("$") {
            guard let dict = value as? [String: Any],
                  let entryData = try? JSONSerialization.data(withJSONObject: dict),
                  let entry = try? decoder.decode(Entry.self, from: entryData) else {
                continue
            }
            result[key] = entry
        }
        AppLogger.log("BankLogoCatalog: loaded \(result.count) entries from bundle",
                      category: "BankLogos")
        return (result, schema)
    }

    // MARK: - Public API

    /// Alle logoIds, die der Catalog kennt (ohne `_default`).
    static var availableLogoIds: Set<String> {
        Set(entries.keys.filter { !$0.hasPrefix("_") })
    }

    /// Inline-SVG für eine logoId. Liefert `nil` wenn unbekannt.
    static func svg(forLogoId logoId: String) -> String? {
        entries[logoId]?.svg
    }

    /// Mask-Variante (Single-color), nur wenn YAXI eine separate ausweist.
    static func mask(forLogoId logoId: String) -> String? {
        entries[logoId]?.maskSvg
    }

    /// Brand-Hauptfarbe als Hex-String inkl. `#`-Präfix. `nil` wenn unbekannt.
    static func primaryColor(forLogoId logoId: String) -> String? {
        entries[logoId]?.primaryColor
    }

    /// Brand-Sekundärfarbe als Hex-String. Optional auch bei bekannten Banken.
    static func secondaryColor(forLogoId logoId: String) -> String? {
        entries[logoId]?.secondaryColor
    }

    /// Generischer Default-SVG (`_default`), gerendert wenn keine logoId trifft.
    static var defaultSVG: String? {
        entries["_default"]?.svg
    }
}
