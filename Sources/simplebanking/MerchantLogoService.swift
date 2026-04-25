import AppKit
import Foundation

// MARK: - Merchant Logo Service
// Priority: 1) bundled SVG  2) Brandfetch (Labs, wenn aktiviert)  3) DuckDuckGo favicon

@MainActor
final class MerchantLogoService: ObservableObject {
    static let shared = MerchantLogoService()

    @Published private(set) var imageCache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var persistedLogosLoaded = false
    private(set) var customLogoKeys: Set<String> = []

    // MARK: - Merchant → bundled SVG filename
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
        "combi markt": "combi-verbrauchermarkt",
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
        "muller": "mueller",        // normalizeForSearch strips ü→u
        "fielmann": "fielmann",
        "apollo-optik": "apollo-optik",
        "apollo optik": "apollo-optik",
        "budnikowsky": "budnikowsky",
        "douglas": "douglas",
        "parfümerie douglas": "douglas",
        "parfumerie douglas": "douglas",

        // Elektronik / Technik
        "saturn": "saturn",
        "mediamarkt": "media-markt",
        "media markt": "media-markt",
        "expert": "expert",
        "euronics": "euronics",
        "mediamax": "mediamax",
        "hercules": "hercules",
        "acer": "acer",
        "lenovo": "lenovo",
        "garmin": "garmin",
        "thomann": "thomann",
        "notebooksbilliger": "notebooksbilliger",
        "gamestop": "gamestop",
        "game stop": "gamestop",
        "microsoft": "microsoft",

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
        "hoffner": "hoeffner",      // normalizeForSearch strips ö→o
        "segmuller": "segmueller",
        "segmüller": "segmueller",
        // "segmuller" already covers normalizeForSearch(segmüller)
        "poco": "poco",
        "roller": "roller",
        "jysk": "jysk",
        "daenisches bettenlager": "daenisches-bettenlager",
        "dänisches bettenlager": "daenisches-bettenlager",
        "danisches bettenlager": "daenisches-bettenlager",  // normalizeForSearch strips ä→a
        "sb-mobel boss": "sb-moebel-boss",
        "sb-möbel boss": "sb-moebel-boss",
        "moebel hardeck": "moebel-hardeck",
        "möbel hardeck": "moebel-hardeck",
        "mobel hardeck": "moebel-hardeck",  // normalizeForSearch strips ö→o
        "moebel kraft": "moebel-kraft",
        "möbel kraft": "moebel-kraft",
        "mobel kraft": "moebel-kraft",
        "moebel martin": "moebel-martin",
        "möbel martin": "moebel-martin",
        "mobel martin": "moebel-martin",
        "moemax": "moemax",
        "mömax": "moemax",
        "momax": "moemax",          // normalizeForSearch strips ö→o
        "porta mobel": "porta-moebel",
        "porta möbel": "porta-moebel",
        "porta moebel": "porta-moebel",     // canonical from merchantAliases
        "dehner": "dehner",
        "westwing": "westwing",
        "maisons du monde": "maisons-du-monde",

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
        "adidas": "adidas",
        "nike": "nike",
        "puma": "puma",
        "gucci": "gucci",
        "mango": "mango",
        "sheego": "sheego",
        "ulla popken": "ulla-popken",
        "trigema": "trigema",
        "snipes": "snipes",
        "bonprix": "bonprix",
        "madeleine": "madeleine",
        "net-a-porter": "net-a-porter",
        "net a porter": "net-a-porter",
        "calida": "calida",

        // Online / E-Commerce
        "amazon": "amazon",
        "otto": "otto",
        "zalando": "zalando",
        "about you": "about-you",
        "aboutyou": "about-you",
        "baur": "baur",
        "flaconi": "flaconi",
        "spreadshirt": "spreadshirt",
        "swarovski": "swarovski",
        "hugendubel": "hugendubel",
        "yves rocher": "yves-rocher",
        "yves-rocher": "yves-rocher",
        "amorelie": "amorelie",
        "jako": "jako",
        "momox": "momox-fashion",
        "momox fashion": "momox-fashion",
        "contorion": "contorion",

        // Beauty / Parfümerie (bereits oben via douglas)

        // Hobby / Sport / Freizeit
        "intersport": "intersport",
        "decathlon": "decathlon",
        "sport 2000": "sport-2000",
        "fressnapf": "fressnapf",
        "das futterhaus": "das-futterhaus",
        "thalia": "thalia",
        "vedes": "vedes",
        "zeg": "zeg",
        "weight watchers": "weight-watchers",

        // Tech / Apple
        "apple": "apple",
    ]

    // MARK: - Domain-Whitelist für Remote-Logos (Brandfetch / DuckDuckGo)
    // Nur explizit gelistete bekannte Marken → verhindert Fehlzuordnungen
    static let domainWhitelist: [String: String] = [
        // Lebensmittel
        "rewe": "rewe.de",
        "nahkauf": "nahkauf.de",
        "edeka": "edeka.de",
        "marktkauf": "marktkauf.de",
        "aldi": "aldi-nord.de",
        "aldi nord": "aldi-nord.de",
        "aldi sud": "aldi-sued.de",
        "lidl": "lidl.de",
        "netto": "netto-online.de",
        "netto marken-discount": "netto-online.de",
        "kaufland": "kaufland.de",
        "penny": "penny.de",
        "norma": "norma-online.de",
        "np discount": "np-discount.de",
        "tegut": "tegut.de",
        "alnatura": "alnatura.de",
        "tchibo": "tchibo.de",
        "famila": "famila.de",
        "combi": "combi-sagt-ja.de",
        "v-markt": "v-markt.de",
        "mix markt": "mix-markt.de",
        "trinkgut": "trinkgut.de",
        "getraenke hoffmann": "getraenke-hoffmann.de",
        "reformhaus": "reformhaus.de",
        "denns biomarkt": "denns.com",
        "denn's biomarkt": "denns.com",

        // Drogerie / Gesundheit / Optik
        "dm": "dm.de",
        "rossmann": "rossmann.de",
        "mueller": "mueller.de",
        "müller": "mueller.de",
        "muller": "mueller.de",
        "fielmann": "fielmann.de",
        "apollo-optik": "apollo-optik.de",
        "apollo optik": "apollo-optik.de",
        "budnikowsky": "budni.de",
        "douglas": "douglas.de",

        // Elektronik / Technik
        "saturn": "saturn.de",
        "mediamarkt": "mediamarkt.de",
        "media markt": "mediamarkt.de",
        "expert": "expert.de",
        "euronics": "euronics.de",
        "thomann": "thomann.de",
        "notebooksbilliger": "notebooksbilliger.de",
        "gamestop": "gamestop.de",
        "garmin": "garmin.de",
        "lenovo": "lenovo.com",
        "acer": "acer.com",

        // DIY / Baumarkt
        "ikea": "ikea.de",
        "obi": "obi.de",
        "bauhaus": "bauhaus.eu",
        "hornbach": "hornbach.de",
        "hagebaumarkt": "hagebaumarkt.de",
        "toom": "toom.de",
        "hellweg": "hellweg.de",
        "tedox": "tedox.de",
        "thomas philipps": "thomas-philipps.de",

        // Möbel / Wohnen
        "xxxlutz": "xxxlutz.de",
        "hoeffner": "hoeffner.de",
        "höffner": "hoeffner.de",
        "hoffner": "hoeffner.de",
        "segmueller": "segmueller.de",
        "segmüller": "segmueller.de",
        "segmuller": "segmueller.de",
        "poco": "poco.de",
        "roller": "roller.de",
        "jysk": "jysk.de",
        "daenisches bettenlager": "dänisches-bettenlager.de",
        "danisches bettenlager": "dänisches-bettenlager.de",
        "sb-moebel boss": "sb-moebel-boss.de",
        "moebel hardeck": "moebelhaus-hardeck.de",
        "moebel kraft": "moebel-kraft.de",
        "moebel martin": "moebel-martin.de",
        "moemax": "moemax.de",
        "momax": "moemax.de",
        "porta moebel": "porta-moebel.de",
        "dehner": "dehner.de",
        "westwing": "westwing.de",
        "maisons du monde": "maisonsdumonde.de",

        // Mode / Schuhe / Accessoires
        "h&m": "hm.com",
        "zara": "zara.com",
        "primark": "primark.com",
        "deichmann": "deichmann.com",
        "c&a": "c-and-a.com",
        "kik": "kik.de",
        "new yorker": "newyorker.de",
        "nkd": "nkd.de",
        "takko fashion": "takko.com",
        "ernstings family": "ernstings-family.de",
        "ernsting's family": "ernstings-family.de",
        "peek & cloppenburg": "peek-cloppenburg.de",
        "peek und cloppenburg": "peek-cloppenburg.de",
        "breuninger": "breuninger.com",
        "galeria": "galeria.de",
        "galeria karstadt kaufhof": "galeria.de",
        "woolworth": "woolworth.de",
        "tedi": "tedi.de",
        "adidas": "adidas.de",
        "nike": "nike.com",
        "puma": "puma.com",
        "gucci": "gucci.com",
        "mango": "mango.com",
        "sheego": "sheego.de",
        "ulla popken": "ullapopken.de",
        "trigema": "trigema.de",
        "snipes": "snipes.com",
        "bonprix": "bonprix.de",
        "madeleine": "madeleine.de",
        "net-a-porter": "net-a-porter.com",
        "net a porter": "net-a-porter.com",
        "calida": "calida.com",

        // Online / E-Commerce
        "amazon": "amazon.de",
        "zalando": "zalando.de",
        "about you": "aboutyou.de",
        "aboutyou": "aboutyou.de",
        "otto": "otto.de",
        "baur": "baur.de",
        "flaconi": "flaconi.de",
        "spreadshirt": "spreadshirt.de",
        "swarovski": "swarovski.com",
        "hugendubel": "hugendubel.de",
        "yves rocher": "yves-rocher.de",
        "yves-rocher": "yves-rocher.de",
        "amorelie": "amorelie.de",
        "momox fashion": "momox-fashion.de",
        "momox": "momox-fashion.de",
        "contorion": "contorion.de",

        // Sport / Freizeit / Bücher
        "intersport": "intersport.de",
        "decathlon": "decathlon.de",
        "sport 2000": "sport2000.de",
        "fressnapf": "fressnapf.de",
        "das futterhaus": "das-futterhaus.de",
        "thalia": "thalia.de",
        "vedes": "vedes.de",
        "weight watchers": "weightwatchers.com",

        // Tankstellen
        "aral": "aral.de",
        "shell": "shell.de",
        "esso": "esso.de",
        "hem": "hem.de",
        "avia": "avia.de",
        "jet": "jet.de",
        "total energies": "totalenergies.de",
        "tamoil": "tamoil.de",

        // Zahlung / Fintech
        "paypal": "paypal.com",
        "klarna": "klarna.com",
        "wise": "wise.com",

        // Big Tech / SaaS
        "google": "google.com",
        "youtube": "youtube.com",
        "apple services": "apple.com",
        "anthropic": "anthropic.com",
        "claude": "claude.ai",
        "claude.ai": "claude.ai",
        "openai": "openai.com",
        "chatgpt": "openai.com",
        "formspree": "formspree.io",

        // Video-Streaming
        "netflix": "netflix.com",
        "disney+": "disneyplus.com",
        "disney plus": "disneyplus.com",
        "rtl+": "rtl.de",
        "rtl plus": "rtl.de",
        "dazn": "dazn.com",
        "wow": "wowtv.de",
        "wow / sky": "wowtv.de",
        "sky": "sky.de",
        "joyn": "joyn.de",
        "joyn plus+": "joyn.de",
        "paramount+": "paramountplus.com",
        "paramount plus": "paramountplus.com",
        "zattoo": "zattoo.com",
        "waipu.tv": "waipu.tv",
        "waipupro": "waipu.tv",
        "magentatv": "magentatv.de",
        "magenta tv": "magentatv.de",
        "viaplay": "viaplay.de",
        "max": "max.com",
        "hbo max": "max.com",
        "apple tv+": "apple.com",
        "apple tv": "apple.com",
        "crunchyroll": "crunchyroll.com",
        "discovery+": "discoveryplus.com",
        "discoveryplus": "discoveryplus.com",
        "curiositystream": "curiositystream.com",

        // Musik-Streaming
        "spotify": "spotify.com",
        "deezer": "deezer.com",
        "tidal": "tidal.com",
        "soundcloud": "soundcloud.com",
        "qobuz": "qobuz.com",
        "napster": "napster.com",
        "amazon music": "amazon.de",
        "youtube music": "youtube.com",
        "apple music": "apple.com",

        // Gaming
        "xbox": "xbox.com",
        "xbox game pass": "xbox.com",
        "playstation": "playstation.com",
        "playstation plus": "playstation.com",
        "nintendo": "nintendo.de",
        "nintendo switch online": "nintendo.de",
        "ubisoft": "ubisoft.com",
        "ubisoft+": "ubisoft.com",
        "ea play": "ea.com",
        "geforce now": "nvidia.de",
        "humble": "humblebundle.com",
        "humble choice": "humblebundle.com",
        "apple arcade": "apple.com",

        // Cloud / Software
        "microsoft 365": "microsoft.com",
        "adobe": "adobe.com",
        "adobe creative cloud": "adobe.com",
        "dropbox": "dropbox.com",
        "nordvpn": "nordvpn.com",
        "google one": "google.com",
        "icloud": "apple.com",
        "apple icloud": "apple.com",

        // Nachrichten
        "spiegel+": "spiegel.de",
        "spiegel plus": "spiegel.de",
        "bild+": "bild.de",
        "bild plus": "bild.de",
        "welt+": "welt.de",
        "faz+": "faz.net",
        "faz plus": "faz.net",

        // Fitness / Wellness
        "peloton": "onepeloton.de",
        "freeletics": "freeletics.com",
        "urban sports club": "urbansportsclub.com",
        "mcfit": "mcfit.com",
        "fitness first": "fitnessfirst.de",
        "clever fit": "clever-fit.com",
        "calm": "calm.com",
        "headspace": "headspace.com",

        // Bücher / Hörbücher / Bildung
        "audible": "audible.de",
        "kindle unlimited": "amazon.de",
        "kindle": "amazon.de",
        "storytel": "storytel.de",
        "scribd": "scribd.com",
        "duolingo": "duolingo.com",

        // Food / Delivery
        "lieferando": "lieferando.de",
        "hellofresh": "hellofresh.de",
        "hello fresh": "hellofresh.de",
        "wolt": "wolt.com",
        "mc donalds": "mcdonalds.de",
        "mcdonald's": "mcdonalds.de",
        "mcdonalds": "mcdonalds.de",
        "starbucks": "starbucks.de",
        "uber": "uber.com",
        "uber eats": "ubereats.com",

        // Retail-Boxen
        "glossybox": "glossybox.de",

        // Telko
        "telekom": "telekom.de",
        "vodafone": "vodafone.de",
        "o2": "o2online.de",
        "1&1": "1und1.de",
        "congstar": "congstar.de",
        "freenet": "freenet.de",
        "mobilcom": "mobilcom-debitel.de",

        // Logistik
        "dhl": "dhl.de",
        "dpd": "dpd.de",
        "hermes": "myhermes.de",
        "ups": "ups.com",
        "fedex": "fedex.de",

        // Sonstiges
        "deutsche bahn": "bahn.de",
        "bahn": "bahn.de",
        "db vertrieb": "bahn.de",
        "deutsche post": "deutschepost.de",
        "kleinanzeigen": "kleinanzeigen.de",
        "hd+": "hd-plus.de",
        "adac": "adac.de",
        "rundfunkbeitrag": "rundfunkbeitrag.de",
        "barmer": "barmer.de",
        "aok": "aok.de",
        "dak": "dak.de",
        "ebay": "ebay.de",
        "etsy": "etsy.com",
        "parship": "parship.de",

        // Versicherungen
        "allianz": "allianz.de",
        "axa": "axa.de",
        "debeka": "debeka.de",
        "devk": "devk.de",
        "ergo": "ergo.de",
        "generali": "generali.de",
        "gothaer": "gothaer.de",
        "hallesche": "hallesche.de",
        "hansemerkur": "hansemerkur.de",
        "hanse merkur": "hansemerkur.de",
        "hdi": "hdi.de",
        "huk-coburg": "huk.de",
        "huk coburg": "huk.de",
        "lvm": "lvm.de",
        "munich re": "munichre.com",
        "nurnberger versicherung": "nuernberger.de",
        "nuernberger versicherung": "nuernberger.de",
        "provinzial": "provinzial.com",
        "r+v versicherung": "ruv.de",
        "ruv versicherung": "ruv.de",
        "signal iduna": "signal-iduna.de",
        "signal-iduna": "signal-iduna.de",
        "sv sparkassenversicherung": "sv.de",
        "talanx": "talanx.com",
        "versicherungskammer": "vkb.de",
        "vgh": "vgh.de",
        "vhv": "vhv.de",
        "alte leipziger": "alte-leipziger.de",
        "arag": "arag.de",
        "die bayerische": "diebayerische.de",
        "continentale": "continentale.de",
        "wuestenrot": "wuestenrot.de",
        "württembergische": "ww-ag.com",
        "wurttembergische": "ww-ag.com",
        "zurich versicherung": "zurich.de",
    ]

    // Längste Schlüssel zuerst → spezifischere Treffer vor generischen ("apple music" vor "apple")
    private static let brandSearchNeedles: [String] = domainWhitelist.keys.sorted { $0.count > $1.count }

    /// Zahlungsintermediäre: Wenn der Empfänger einer dieser Brands ist, wird der eigentliche
    /// Händler aus dem Verwendungszweck gesucht.
    private static let paymentIntermediaries: Set<String> = [
        "klarna", "paypal", "wise", "stripe", "mollie",
        "apple pay", "google pay", "giropay"
    ]

    /// Logo-Key-Auflösung nach festem Ruleset:
    /// 1. Empfänger ist Zahlungsintermediär → suche echten Händler im Verwendungszweck
    /// 2. normalizedMerchant direkt in domainWhitelist → verwenden
    /// 3. Empfängertext nach Brand-Needle durchsuchen (z.B. "Amazon Payments Europe" → "amazon")
    /// 4. Verwendungszweck nach Brand-Needle durchsuchen (Intermediäre ausgeschlossen)
    /// 5. Kein Treffer → normalizedMerchant zurückgeben (kein Logo)
    func effectiveLogoKey(normalizedMerchant: String, empfaenger: String, verwendungszweck: String) -> String {
        let key = normalizedMerchant.lowercased()

        // Regel 1: Empfänger ist Zahlungsintermediär → echter Händler im Verwendungszweck suchen
        // hasPrefix-Check fängt auch abgeleitete Keys wie "paypal (intermediaer)" ab
        let isIntermediaryKey = Self.paymentIntermediaries.contains(key)
            || Self.paymentIntermediaries.contains(where: { key.hasPrefix($0) })
        if isIntermediaryKey {
            let vzweck = verwendungszweck.lowercased()
            for needle in Self.brandSearchNeedles {
                if !Self.paymentIntermediaries.contains(needle) && vzweck.contains(needle) {
                    return needle
                }
            }
            // Kein Händler gefunden → Intermediär-Logo als Fallback
            return key
        }

        // Regel 2: Direkt in domainWhitelist
        if Self.domainWhitelist[key] != nil { return key }

        // Regel 3: Empfängertext nach Brand-Needle durchsuchen (Intermediäre ausgeschlossen)
        let emp = empfaenger.lowercased()
        for needle in Self.brandSearchNeedles {
            if !Self.paymentIntermediaries.contains(needle) && emp.contains(needle) {
                return needle
            }
        }

        // Regel 4: Verwendungszweck durchsuchen (Intermediäre ausgeschlossen)
        let vzweck = verwendungszweck.lowercased()
        for needle in Self.brandSearchNeedles {
            if !Self.paymentIntermediaries.contains(needle) && vzweck.contains(needle) {
                return needle
            }
        }

        return key
    }

    private init() {
        loadMerchantCustomLogos()
    }

    func image(for normalizedMerchant: String) -> NSImage? {
        imageCache[normalizedMerchant.lowercased()]
    }

    func hasCustomLogo(forKey key: String) -> Bool {
        customLogoKeys.contains(key.lowercased())
    }

    /// Setzt ein Custom-Logo für einen Händler-Key (gilt für alle Buchungen desselben Händlers).
    func setCustomLogo(data: Data, forKey key: String) {
        let k = key.lowercased()
        guard let image = NSImage(data: data) else { return }
        imageCache[k] = image
        customLogoKeys.insert(k)
        Task.detached { TransactionsDatabase.saveMerchantCustomLogo(merchantKey: k, data: data) }
    }

    /// Entfernt das Custom-Logo für einen Händler-Key und stellt ggf. das gebündelte SVG wieder her.
    func removeCustomLogo(forKey key: String) {
        let k = key.lowercased()
        customLogoKeys.remove(k)
        imageCache.removeValue(forKey: k)
        Task.detached { TransactionsDatabase.deleteMerchantCustomLogo(merchantKey: k) }
        // Gebündeltes SVG wiederherstellen falls vorhanden
        loadBundledSVG(key: k)
    }

    /// Lädt Merchant-Custom-Logos beim Start — immer, unabhängig von Brandfetch-Einstellung.
    private func loadMerchantCustomLogos() {
        Task.detached {
            let entries = TransactionsDatabase.loadAllMerchantCustomLogos()
            await MainActor.run {
                for (key, data) in entries {
                    if let image = NSImage(data: data) {
                        self.imageCache[key] = image
                        self.customLogoKeys.insert(key)
                    }
                }
            }
        }
    }

    // Lädt alle gecachten Logos aus DB in den Speicher (einmalig beim ersten preload).
    // Brandfetch-aktiv: überspringen, damit Brandfetch immer frisch lädt.
    private func loadPersistedLogosIfNeeded() {
        guard !persistedLogosLoaded else { return }
        persistedLogosLoaded = true
        let brandfetchEnabled = UserDefaults.standard.bool(forKey: "brandfetchEnabled")
        let clientId = UserDefaults.standard.string(forKey: "brandfetchClientId") ?? ""
        guard !(brandfetchEnabled && !clientId.isEmpty) else { return }
        Task.detached {
            guard let entries = try? TransactionsDatabase.loadCachedLogoData() else { return }
            await MainActor.run {
                for (key, data) in entries where self.imageCache[key] == nil {
                    if let image = NSImage(data: data) {
                        self.imageCache[key] = image
                    }
                }
            }
        }
    }

    func preload(normalizedMerchant: String) {
        loadPersistedLogosIfNeeded()
        let key = normalizedMerchant.lowercased()
        guard imageCache[key] == nil, !inFlight.contains(key) else { return }
        guard let domain = Self.domainWhitelist[key] else { return }
        inFlight.insert(key)

        let brandfetchEnabled = UserDefaults.standard.bool(forKey: "brandfetchEnabled")
        let clientId = UserDefaults.standard.string(forKey: "brandfetchClientId") ?? ""

        Task {
            if brandfetchEnabled && !clientId.isEmpty {
                if await fetchBrandfetch(key: key, domain: domain, clientId: clientId) { return }
            }
            await fetchDuckDuckGo(key: key, domain: domain)
        }
    }

    @discardableResult
    private func loadBundledSVG(key: String) -> Bool {
        guard let svgName = Self.svgMap[key],
              let url = Bundle.main.url(forResource: svgName, withExtension: "svg", subdirectory: "merchant-logos"),
              let image = NSImage(contentsOf: url) else { return false }
        imageCache[key] = image
        inFlight.remove(key)
        return true
    }

    // Gibt .de + .com Varianten zurück, damit Brandfetch beide probiert.
    // Brandfetch ist brand-basiert, nicht länder-spezifisch — mal ist .de besser, mal .com.
    private static func brandfetchVariants(_ domain: String) -> [String] {
        var variants = [domain]
        if domain.hasSuffix(".de") {
            variants.append(String(domain.dropLast(3)) + ".com")
        } else if domain.hasSuffix(".com") {
            variants.append(String(domain.dropLast(4)) + ".de")
        }
        return variants
    }

    @discardableResult
    private func fetchBrandfetch(key: String, domain: String, clientId: String) async -> Bool {
        // Brandfetch-Platzhalter (Marke unbekannt) ist typischerweise < 5 KB.
        // Echte Logos sind größer → erster Treffer ≥ 5 KB gewinnt.
        let minBytes = 5_000

        for tryDomain in Self.brandfetchVariants(domain) {
            let urlString = "https://cdn.brandfetch.io/\(tryDomain)?c=\(clientId)"
            guard let url = URL(string: urlString) else { continue }
            // Explizites Timeout 15s — Logos sind kleine Assets, sollten schnell laden.
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count >= minBytes,
                  let image = NSImage(data: data) else { continue }
            let capturedData = data
            await MainActor.run {
                imageCache[key] = image
                inFlight.remove(key)
            }
            Task.detached { TransactionsDatabase.saveLogo(key: key, data: capturedData) }
            return true
        }
        return false
    }

    func clearCache() {
        imageCache = [:]
        inFlight = []
        persistedLogosLoaded = false
        Task.detached { TransactionsDatabase.clearLogoCache() }
    }

    private func fetchDuckDuckGo(key: String, domain: String) async {
        let urlString = "https://icons.duckduckgo.com/ip3/\(domain).ico"
        guard let url = URL(string: urlString) else {
            await MainActor.run { inFlight.remove(key) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              !data.isEmpty,
              let image = NSImage(data: data) else {
            await MainActor.run { inFlight.remove(key) }
            return
        }
        let capturedData = data
        await MainActor.run {
            imageCache[key] = image
            inFlight.remove(key)
        }
        Task.detached { TransactionsDatabase.saveLogo(key: key, data: capturedData) }
    }
}
