import AppKit
import Foundation

/// Wikimedia Commons Logo-URLs für alle Dienste in CancellationLinks.
/// Verwendet die Wikimedia Special:FilePath-URL.
enum LogoAssets {
    /// Gibt die Wikimedia-Commons-URL für ein Logo zurück.
    /// `displayName` muss dem `Entry.displayName` aus CancellationLinks entsprechen.
    /// `width` fragt gerenderte Thumbnails an (wichtig für SVG-Dateien).
    static func url(for displayName: String, width: Int = 72) -> URL? {
        guard let filename = logos[displayName] else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(filename)?width=\(width)")
    }

    /// Wikimedia-Commons-Seite (für Attribution / Lizenzinfo)
    static func pageURL(for displayName: String) -> URL? {
        guard let filename = logos[displayName] else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/File:\(filename)")
    }

    static var allDisplayNames: [String] {
        Array(logos.keys)
    }

    // MARK: - Logo Registry

    private static let logos: [String: String] = [
        "Netflix":              "Netflix_2015_logo.svg",
        "Spotify":              "Spotify_logo_with_text.svg",
        "Disney+":              "Disney%2B_logo.svg",
        "Amazon Prime":         "Amazon_Prime_Logo.svg",
        "DAZN":                 "DAZN_Logo.svg",
        "WOW / Sky":            "Sky_Deutschland_Fernsehen_logo.svg",
        "YouTube Premium":      "YouTube_Premium_logo.svg",
        "Joyn PLUS+":           "Joyn_2024.svg",
        "RTL+":                 "RTL%2B_logo.svg",
        "ChatGPT Plus":         "OpenAI_logo_2025_%28symbol%29.svg",
        "Apple (iCloud/One)":   "Apple_logo_grey.svg",
        "Google One":           "Google_%22G%22_logo.svg",
        "Microsoft 365":        "Microsoft_365_%282022%29.svg",
        "Adobe Creative Cloud": "Adobe_Corporate_logo.svg",
        "Telekom":              "Deutsche_Telekom_2022.svg",
        "Vodafone":             "Vodafone_Logo.svg",
        "o2 / Blau":            "O2_logo.svg",
        "HUK-COBURG":           "HUK-Coburg_logo.svg",
        "McFIT / RSG Group":    "McFit_logo.svg",
        "Urban Sports Club":    "Urban_Sports_Club_logo.svg",
        "Deutschlandticket":    "Deutschlandticket_Logo.svg",
        "BahnCard":             "Deutsche_Bahn_AG-Logo.svg",
        "HelloFresh":           "HelloFresh_logo.svg",
        "Audible":              "Audible_logo.svg",
        "SPIEGEL+":             "Der_Spiegel_logo.svg",
        "ADAC":                 "ADAC-Logo.svg",
        "waipu.tv":             "Waipu.tv_logo.svg",
        "Zattoo":               "Zattoo_logo.svg",
        "Paramount+":           "Paramount%2B_logo.svg",
        "Kindle Unlimited":     "Amazon_Kindle_logo.svg",
        "NordVPN":              "NordVPN_logo.svg",
        "clever fit":           "Clever_fit_logo.svg",
        "Fitness First":        "Fitness_First_logo.svg",
        "congstar":             "Congstar_logo.svg",
        "1&1":                  "1%261_Logo_2023.svg",
        "freenet / mobilcom":   "Freenet_AG_logo.svg",
        "Lieferando":           "Lieferando_logo.svg",
        "Dropbox":              "Dropbox_logo_2017.svg",
        "Parship":              "Parship_logo.svg",
        "Rundfunkbeitrag":      "ARD-ZDF-Deutschlandradio-Beitragsservice_logo.svg",
    ]
}

@MainActor
final class SubscriptionLogoStore: ObservableObject {
    static let shared = SubscriptionLogoStore()

    @Published private(set) var images: [String: NSImage] = [:]

    private var requestedNames: Set<String> = []
    private static let cacheMaxAgeSeconds: TimeInterval = 7 * 24 * 3600 // 7 Tage

    private static let cacheDir: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("tech.yaxi.simplebanking/subscription-logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    func preloadInitial(displayNames: [String]) {
        preload(displayNames: displayNames)
    }

    func preload(displayNames: [String]) {
        for displayName in Set(displayNames) {
            loadIfNeeded(displayName: displayName)
        }
    }

    func image(for displayName: String) -> NSImage? {
        images[displayName]
    }

    private func loadIfNeeded(displayName: String) {
        guard !displayName.isEmpty else { return }
        guard images[displayName] == nil else { return }
        guard !requestedNames.contains(displayName) else { return }
        guard let url = LogoAssets.url(for: displayName) else { return }

        requestedNames.insert(displayName)

        Task {
            let cacheFile = Self.cacheFile(for: displayName)

            // 1. Disk-Cache sofort laden → kein Flackern
            if let cached = Self.loadFromDisk(at: cacheFile) {
                await MainActor.run { images[displayName] = cached }
                // Cache frisch genug → kein Netzwerk-Request
                if !Self.isCacheStale(at: cacheFile) { return }
            }

            // 2. Im Hintergrund aktualisieren
            do {
                // Explizites Timeout 15s — Logos sind kleine Bilder, sollten schnell laden.
                // Ohne Timeout würde URLSession.shared bis zum macOS-Default (60s) hängen.
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
                guard let image = NSImage(data: data) else { return }
                if let cacheFile { try? data.write(to: cacheFile) }
                await MainActor.run { images[displayName] = image }
            } catch {
                // Netzwerkfehler – gecachtes Bild bleibt sichtbar
            }
            requestedNames.remove(displayName)
        }
    }

    private static func cacheFile(for displayName: String) -> URL? {
        guard let dir = cacheDir else { return nil }
        // Dateiname: URL-sicherer Hash des displayName
        let safe = displayName
            .unicodeScalars
            .map { $0.value }
            .reduce(5381) { ($0 &<< 5) &+ $0 &+ Int($1) }
        return dir.appendingPathComponent("\(abs(safe)).png")
    }

    private static func loadFromDisk(at url: URL?) -> NSImage? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private static func isCacheStale(at url: URL?) -> Bool {
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) > cacheMaxAgeSeconds
    }
}
