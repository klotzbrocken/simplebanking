import Foundation
import CryptoKit

// MARK: - BankLogoCache
//
// Extrahiert SVG-Strings aus `BankLogoCatalog` lazy in den User-Cache-Dir,
// damit `NSImage(contentsOf: URL)` sie wie früher als file:// laden kann.
//
// Cache-Verzeichnis: `~/Library/Caches/<bundle>/bank-logos/<logoId>.svg`
// (+ `<logoId>-mask.svg` für mask-Varianten).
//
// **Stale-Detection:** ein `manifest.txt` im Cache hält den SHA-256-Hash der
// gebundelten `yaxi-bank-catalog.json`. Wenn beim App-Start ein anderer Hash
// gefunden wird (= App-Update mit aktualisiertem Catalog), wird der gesamte
// Cache gewiped + bei Bedarf neu extrahiert.
//
// Designentscheidung: lazy statt eager. Macht App-Start schneller (kein
// 172-File-Write), die meisten Banken werden nie gerendert. Trade-off: erstes
// Rendern pro Logo macht einen sync write zum Cache-Dir (~5 KB pro SVG).

enum BankLogoCache {

    private static let subdirectoryName = "bank-logos"
    private static let manifestFileName = "catalog-hash.txt"

    /// User-Cache-Dir-URL. Lazy erzeugt beim ersten Zugriff. `nil` wenn
    /// FileSystem-Operation scheitert (extrem selten).
    private static let cacheDirectoryURL: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "tech.yaxi.simplebanking"
        let dir = base.appendingPathComponent(bundleId).appendingPathComponent(subdirectoryName)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLogger.log("BankLogoCache: createDirectory failed: \(error)",
                          category: "BankLogos", level: "WARN")
            return nil
        }
        purgeIfCatalogChanged(in: dir)
        return dir
    }()

    /// Beim Start wird der bisherige Cache verworfen, wenn der Catalog-Hash
    /// sich geändert hat (= App-Update mit neuem Catalog). Pure-Side-Effect-
    /// Logik isoliert, damit testbar.
    private static func purgeIfCatalogChanged(in dir: URL) {
        let currentHash = catalogHash()
        let manifestURL = dir.appendingPathComponent(manifestFileName)
        let storedHash = (try? String(contentsOf: manifestURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard storedHash != currentHash else { return }

        // Hash unterschiedlich: alle SVG-Files in dir entfernen.
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent != manifestFileName {
                try? FileManager.default.removeItem(at: f)
            }
        }
        try? currentHash.write(to: manifestURL, atomically: true, encoding: .utf8)
        AppLogger.log("BankLogoCache: catalog changed → cache purged (new hash=\(currentHash.prefix(8)))",
                      category: "BankLogos")
    }

    /// SHA-256 des gebundelten Catalog-Files. Stabil zwischen Builds wenn
    /// catalog.json unverändert, ändert sich bei jedem Catalog-Update.
    private static func catalogHash() -> String {
        guard let url = Bundle.module.url(forResource: "yaxi-bank-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return "no-catalog" }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Public API

    /// Liefert eine file://-URL zu einem extrahierten SVG für `logoId`.
    /// Liegt das File noch nicht im Cache, wird es jetzt geschrieben.
    /// Bei unbekannter logoId UND verfügbarem `_default` wird ein Default-
    /// SVG-File angeboten. Bei totalem Fail (kein Cache-Dir o.ä.): `nil`.
    static func url(forLogoId logoId: String, mask: Bool = false) -> URL? {
        guard let dir = cacheDirectoryURL else { return nil }
        let svgString: String?
        let filename: String
        if mask {
            svgString = BankLogoCatalog.mask(forLogoId: logoId)
            filename = "\(logoId)-mask.svg"
        } else {
            svgString = BankLogoCatalog.svg(forLogoId: logoId) ?? BankLogoCatalog.defaultSVG
            filename = svgString == BankLogoCatalog.defaultSVG ? "_default.svg" : "\(logoId).svg"
        }
        guard let svg = svgString else { return nil }
        let fileURL = dir.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try svg.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                AppLogger.log("BankLogoCache: write failed for \(filename): \(error)",
                              category: "BankLogos", level: "WARN")
                return nil
            }
        }
        return fileURL
    }

    /// Pure helper für Tests: prüft, ob für `logoId` eine Mask-Variante im
    /// Catalog liegt.
    static func hasMask(forLogoId logoId: String) -> Bool {
        BankLogoCatalog.mask(forLogoId: logoId) != nil
    }

    // MARK: - Test-Hooks

    #if DEBUG
    /// Test-only: räumt den Cache-Inhalt komplett aus (für isolierte Tests).
    static func _testReset() {
        guard let dir = cacheDirectoryURL else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }
    #endif
}
