import AppKit
import Foundation

// MARK: - Merchant Logo Service
// Loads bundled SVG logos for known merchants; falls back to DuckDuckGo favicon for unknowns.

@MainActor
final class MerchantLogoService: ObservableObject {
    static let shared = MerchantLogoService()

    @Published private(set) var imageCache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    // MARK: - Merchant → SVG filename mapping
    // Key: normalized merchant name (lowercase, trimmed)
    // Value: SVG filename without extension in Resources/merchant-logos/
    private static let svgMap: [String: String] = [
        // Lebensmittel
        "rewe": "rewe",
        "nahkauf": "nahkauf",
        "edeka": "edeka",
        "marktkauf": "marktkauf",
        "aldi": "aldi-nord",
        "aldi nord": "aldi-nord",
        "aldi sud": "aldi-sued",
        "aldi süd": "aldi-sued",
        "lidl": "lidl",
        "netto": "netto-marken-discount",
        "netto marken-discount": "netto-marken-discount",
        "kaufland": "kaufland",
        "penny": "penny",
        "norma": "norma",
        "np discount": "np-discount",
        "tegut": "tegut",
        "alnatura": "alnatura",
        "hit": "hit",
        "combi": "combi-verbrauchermarkt",
        "famila": "famila",
        "v-markt": "v-markt",
        "mix markt": "mix-markt",
        "trinkgut": "trinkgut",
        "getranke hoffmann": "getraenke-hoffmann",
        "getränke hoffmann": "getraenke-hoffmann",
        "reformhaus": "reformhaus",
        "denn's biomarkt": "denns-biomarkt",
        "denns biomarkt": "denns-biomarkt",
        "tchibo": "tchibo",

        // Drogerie / Gesundheit / Optik
        "dm": "dm",
        "rossmann": "rossmann",
        "mueller": "mueller",
        "müller": "mueller",
        "fielmann": "fielmann",
        "apollo-optik": "apollo-optik",
        "apollo optik": "apollo-optik",
        "budnikowsky": "budnikowsky",

        // Elektronik / Technik
        "saturn": "saturn",
        "mediamarkt": "media-markt",
        "media markt": "media-markt",
        "expert": "expert",
        "euronics": "euronics",
        "mediamax": "mediamax",
        "hercules": "hercules",

        // DIY / Baumarkt / Einrichten
        "ikea": "ikea",
        "obi": "obi",
        "bauhaus": "bauhaus",
        "hornbach": "hornbach",
        "toom": "toom",
        "hagebaumarkt": "hagebaumarkt",
        "hellweg": "hellweg",
        "hammer": "hammer",
        "tedox": "tedox",
        "thomas philipps": "thomas-philipps",

        // Möbel / Wohnen
        "xxxlutz": "xxxlutz",
        "hoeffner": "hoeffner",
        "höffner": "hoeffner",
        "segmuller": "segmueller",
        "segmüller": "segmueller",
        "poco": "poco",
        "roller": "roller",
        "jysk": "jysk",
        "daenisches bettenlager": "daenisches-bettenlager",
        "dänisches bettenlager": "daenisches-bettenlager",
        "sb-mobel boss": "sb-moebel-boss",
        "sb-möbel boss": "sb-moebel-boss",
        "moebel hardeck": "moebel-hardeck",
        "möbel hardeck": "moebel-hardeck",
        "moebel kraft": "moebel-kraft",
        "möbel kraft": "moebel-kraft",
        "moebel martin": "moebel-martin",
        "möbel martin": "moebel-martin",
        "moemax": "moemax",
        "mömax": "moemax",
        "porta mobel": "porta-moebel",
        "porta möbel": "porta-moebel",
        "dehner": "dehner",

        // Mode / Schuhe / Accessoires
        "h&m": "hundm",
        "zara": "zara",
        "primark": "primark",
        "deichmann": "deichmann",
        "c&a": "cunda",
        "kik": "kik",
        "new yorker": "new-yorker",
        "nkd": "nkd",
        "takko": "takko-fashion",
        "takko fashion": "takko-fashion",
        "ernsting's family": "ernstings-family",
        "ernstings family": "ernstings-family",
        "peek und cloppenburg": "peek-und-cloppenburg",
        "peek & cloppenburg": "peek-und-cloppenburg",
        "breuninger": "breuninger",
        "galeria": "galeria-karstadt-kaufhof",
        "galeria karstadt kaufhof": "galeria-karstadt-kaufhof",
        "woolworth": "woolworth",
        "tedi": "tedi",

        // Hobby / Sport / Freizeit
        "intersport": "intersport",
        "decathlon": "decathlon",
        "sport 2000": "sport-2000",
        "fressnapf": "fressnapf",
        "das futterhaus": "das-futterhaus",
        "thalia": "thalia",
        "vedes": "vedes",
        "zeg": "zeg",

        // Tech (bereits gebundelt via Bank-Logos oder DuckDuckGo)
        "apple": "apple",
    ]

    // DuckDuckGo fallback für Händler ohne gebundelte SVG
    private static let domainFallback: [String: String] = [
        "paypal": "paypal.com",
        "klarna": "klarna.com",
        "amazon": "amazon.de",
        "google": "google.com",
        "youtube": "youtube.com",
        "apple services": "apple.com",
        "anthropic": "anthropic.com",
        "openai": "openai.com",
        "netflix": "netflix.com",
        "spotify": "spotify.com",
        "deutsche bahn": "bahn.de",
        "otto": "otto.de",
        "zalando": "zalando.de",
        "mc donalds": "mcdonalds.de",
        "mcdonald's": "mcdonalds.de",
        "starbucks": "starbucks.de",
        "uber": "uber.com",
        "telekom": "telekom.de",
        "vodafone": "vodafone.de",
        "o2": "o2online.de",
        "1&1": "1und1.de",
        "rundfunkbeitrag": "rundfunkbeitrag.de",
        "barmer": "barmer.de",
        "aok": "aok.de",
        "dak": "dak.de",
        "wise": "wise.com",
        "ebay": "ebay.de",
        "etsy": "etsy.com",
        "microsoft": "microsoft.com",
        "disney+": "disneyplus.com",
        "deezer": "deezer.com",
        "audible": "audible.de",
        "dropbox": "dropbox.com",
        "adobe": "adobe.com",
        "lieferando": "lieferando.de",
        "wolt": "wolt.com",
        "dpd": "dpd.de",
        "dhl": "dhl.de",
        "hermes": "myhermes.de",
        "ups": "ups.com",
        "fedex": "fedex.de",
    ]

    private init() {}

    func image(for normalizedMerchant: String) -> NSImage? {
        let key = normalizedMerchant.lowercased()
        return imageCache[key]
    }

    func preload(normalizedMerchant: String) {
        let key = normalizedMerchant.lowercased()
        guard imageCache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)

        // 1. Try bundled SVG
        if let svgName = Self.svgMap[key],
           let url = Bundle.main.url(forResource: svgName, withExtension: "svg", subdirectory: "merchant-logos"),
           let image = NSImage(contentsOf: url) {
            imageCache[key] = image
            inFlight.remove(key)
            return
        }

        // 2. Fall back to DuckDuckGo favicon
        if let domain = Self.domainFallback[key] {
            Task {
                await fetchAndCache(key: key, domain: domain)
            }
        } else {
            inFlight.remove(key)
        }
    }

    private func fetchAndCache(key: String, domain: String) async {
        let urlString = "https://icons.duckduckgo.com/ip3/\(domain).ico"
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              !data.isEmpty,
              let image = NSImage(data: data) else {
            await MainActor.run { inFlight.remove(key) }
            return
        }
        await MainActor.run {
            imageCache[key] = image
            inFlight.remove(key)
        }
    }
}
