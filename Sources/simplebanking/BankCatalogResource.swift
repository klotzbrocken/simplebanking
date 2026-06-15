import Foundation

// MARK: - BankCatalogResource
//
// Lokalisiert `yaxi-bank-catalog.json` **ohne** den SwiftPM-`Bundle.module`-
// Accessor. Hintergrund: `Bundle.module` ist ein `static let`, dessen Init mit
// einem nicht abfangbaren `fatalError` (EXC_BREAKPOINT) trappt, wenn das
// generierte `simplebanking_simplebanking.bundle` nicht **neben** dem Executable
// bzw. an der `.app`-Wurzel liegt (`Bundle.main.bundleURL + bundleName`). In
// einem von Hand assemblierten `.app` (build-app.sh) liegt es dort nicht — jeder
// `Bundle.module`-Zugriff crashte deshalb beim Start, sobald ein konfigurierter
// Bank-Slot angewandt wurde (1.6.0-Regression).
//
// Diese Suche ist defensiv und trappt NIE: sie liefert `nil`, wenn der Katalog
// nirgends gefunden wird, und die Aufrufer (BankLogoCatalog/BankLogoCache) haben
// dafür bereits einen sauberen Fallback.
//
// Auflösungs-Reihenfolge:
//   1. `Bundle.main` → `Contents/Resources/yaxi-bank-catalog.json`
//      (Standard-Ort, signier-/notarisierungs-sicher; build-app.sh kopiert die
//       Datei wie jede andere Resource dorthin).
//   2. SwiftPM-Resource-Bundle, manuell gesucht (für `swift test`, wo das Bundle
//      neben dem XCTest-Runner liegt) — via `Bundle(path:)`, das nicht trappt.
enum BankCatalogResource {
    private final class Token {}

    static let fileURL: URL? = {
        let name = "yaxi-bank-catalog"
        let ext = "json"

        // 1) App: bare Resource in Contents/Resources/
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }

        // 2) SwiftPM-Resource-Bundle ohne den trappenden Bundle.module-Accessor.
        let bundleName = "simplebanking_simplebanking.bundle"
        let token = Bundle(for: Token.self)
        var roots: [URL] = [token.bundleURL.deletingLastPathComponent(), token.bundleURL]
        if let r = token.resourceURL { roots.append(r) }
        roots.append(Bundle.main.bundleURL)
        if let r = Bundle.main.resourceURL { roots.append(r) }
        for root in roots {
            let candidate = root.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: candidate),
               let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }

        // 3) Resource direkt in ein Bundle gemergt (manche Test-Layouts).
        return token.url(forResource: name, withExtension: ext)
    }()
}
