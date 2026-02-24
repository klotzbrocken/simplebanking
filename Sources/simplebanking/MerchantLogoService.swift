import AppKit
import Foundation

// MARK: - Merchant Logo Service
// Fetches monochrome favicons from DuckDuckGo for known merchants

@MainActor
final class MerchantLogoService: ObservableObject {
    static let shared = MerchantLogoService()

    @Published private(set) var imageCache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    // normalized_merchant → domain mapping
    private static let domainMap: [String: String] = [
        "rewe": "rewe.de",
        "nahkauf": "rewe.de",
        "edeka": "edeka.de",
        "aldi": "aldi.de",
        "lidl": "lidl.de",
        "netto": "netto-online.de",
        "kaufland": "kaufland.de",
        "dm": "dm.de",
        "rossmann": "rossmann.de",
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
        "ikea": "ikea.de",
        "saturn": "saturn.de",
        "mediamarkt": "mediamarkt.de",
        "otto": "otto.de",
        "zalando": "zalando.de",
        "h&m": "hm.com",
        "zara": "zara.com",
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
        "commerzbank": "commerzbank.de",
        "sparkasse": "sparkasse.de",
        "postbank": "postbank.de",
        "ing": "ing.de",
        "dkb": "dkb.de",
        "n26": "n26.com",
        "revolut": "revolut.com",
        "wise": "wise.com",
        "ebay": "ebay.de",
        "etsy": "etsy.com",
        "microsoft": "microsoft.com",
        "apple": "apple.com",
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
        "gls": "gls-pakete.de",
        "ups": "ups.com",
        "fedex": "fedex.de",
    ]

    private init() {}

    func domain(for normalizedMerchant: String) -> String? {
        Self.domainMap[normalizedMerchant.lowercased()]
    }

    func image(for normalizedMerchant: String) -> NSImage? {
        guard let domain = domain(for: normalizedMerchant) else { return nil }
        return imageCache[domain]
    }

    func preload(normalizedMerchant: String) {
        guard let domain = domain(for: normalizedMerchant) else { return }
        guard imageCache[domain] == nil, !inFlight.contains(domain) else { return }
        inFlight.insert(domain)
        Task {
            await fetchAndCache(domain: domain)
        }
    }

    private func fetchAndCache(domain: String) async {
        let urlString = "https://icons.duckduckgo.com/ip3/\(domain).ico"
        guard let url = URL(string: urlString) else {
            await MainActor.run { inFlight.remove(domain) }
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              !data.isEmpty,
              let image = NSImage(data: data) else {
            await MainActor.run { inFlight.remove(domain) }
            return
        }
        // Farb-Icons (kein isTemplate)
        await MainActor.run {
            imageCache[domain] = image
            inFlight.remove(domain)
        }
    }
}
