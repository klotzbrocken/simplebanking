import AppKit
import Foundation

// MARK: - Robust App-Icon-Lookup
//
// Vorher hatten wir 3 Callsites (BalanceBar, SettingsPanel, MasterPasswordPanel)
// mit dem identischen fragilen Pattern:
//
//     NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName)
//
// `NSImage(named: "AppIcon")` schaut nach Asset-Catalog "AppIcon" — wir haben
// kein xcassets, also returnt das **nil**. Plus `NSImage.applicationIconName`
// liefert nur was zurück, wenn macOS die App "kennt" (im Applications-Folder
// installiert). Beim direkten Run aus dem Build-Folder war das nicht der Fall —
// User sah leeres Icon im Setup + Master-Password-Panel.
//
// Dieser Helper hat eine 3-stufige Fallback-Chain:
//
//   1. `NSImage(named: "AppIcon")`              — funktioniert mit Asset-Catalog
//                                                  oder `CFBundleIconName` in Info.plist
//   2. `NSApp.applicationIconImage`             — system-resolved app icon
//   3. `Bundle.main.url(forResource: "AppIcon", withExtension: "icns")`
//                                              → direkter Disk-Read aus
//                                                Resources/AppIcon.icns

enum AppIconLoader {

    /// Liefert das App-Icon. Bei Failure (nichts gefunden) nil.
    static func load() -> NSImage? {
        // 1) Asset-Catalog / CFBundleIconName-Pfad
        if let img = NSImage(named: "AppIcon"), img.isValid {
            return img
        }
        // 2) System-resolved (NSApplicationIcon)
        if let img = NSImage(named: NSImage.applicationIconName), img.isValid {
            return img
        }
        if let img = NSApp?.applicationIconImage, img.isValid {
            return img
        }
        // 3) Direkter Bundle-Disk-Read
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url), img.isValid {
            return img
        }
        return nil
    }
}
