import AppKit
import Foundation

// MARK: - Merchant Logo Service
// Priority: 1) bundled SVG  2) Cache (30 Tage)  3) logo.dev (Tagesbudget, siehe LogoDev)

@MainActor
final class MerchantLogoService: ObservableObject {
    static let shared = MerchantLogoService()

    @Published private(set) var imageCache: [String: NSImage] = [:]
    /// Fertig gerechnete Anzeigegrößen, Schlüssel `"händler@punkte@pixel"`.
    /// Siehe `anzeigebild(for:kante:skala:)`.
    private var anzeigeCache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var persistedLogosLoaded = false
    /// @Published damit der X-Lösch-Button (hasCustomLogo) reaktiv erscheint
    /// /verschwindet wenn Custom-Logos gesetzt oder entfernt werden.
    @Published private(set) var customLogoKeys: Set<String> = []

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
        // "reformhaus": die gebündelte Datei zeichnet mit CoreSVG leer (geprüft am
        // 16.09.2026) — ohne Zuordnung läuft Reformhaus über den Netz-Fallback.
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

        // Ergänzt 17.09.2026: Dateien lagen im Bundle, waren aber nirgends zugeordnet.
        "action": "action",
        "tk maxx": "tk-maxx",
        "tkmaxx": "tk-maxx",
        "tk-maxx": "tk-maxx",
        "globus": "globus-sb-warenhaus",
        "globus sb-warenhaus": "globus-sb-warenhaus",
        "real": "real",
    ]

    // MARK: - Domain-Whitelist für Remote-Logos (logo.dev)
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

        // Ergänzt 17.09.2026 (siehe svgMap).
        "action": "action.com",
        "tk maxx": "tkmaxx.de",
        "tkmaxx": "tkmaxx.de",
        "tk-maxx": "tkmaxx.de",
        "globus": "globus.de",
        "globus sb-warenhaus": "globus.de",
        "real": "real.de",
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
    /// Substring-Treffer nur an Wortgrenzen: ein Buchstabe direkt vor oder nach dem
    /// Needle disqualifiziert den Treffer. Verhindert z.B., dass das Brand-Needle
    /// "otto" mitten in „Lotto24" matcht (Ziffern/Satzzeichen/Leerzeichen sind ok).
    nonisolated static func wordContains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var from = haystack.startIndex
        while let r = haystack.range(of: needle, range: from..<haystack.endIndex) {
            let beforeOK = r.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: r.lowerBound)].isLetter
            let afterOK = r.upperBound == haystack.endIndex
                || !haystack[r.upperBound].isLetter
            if beforeOK && afterOK { return true }
            from = haystack.index(after: r.lowerBound)
        }
        return false
    }

    func effectiveLogoKey(normalizedMerchant: String, empfaenger: String, verwendungszweck: String) -> String {
        let key = normalizedMerchant.lowercased()

        // Regel 1: Empfänger ist Zahlungsintermediär → echter Händler im Verwendungszweck suchen
        // hasPrefix-Check fängt auch abgeleitete Keys wie "paypal (intermediaer)" ab
        let isIntermediaryKey = Self.paymentIntermediaries.contains(key)
            || Self.paymentIntermediaries.contains(where: { key.hasPrefix($0) })
        if isIntermediaryKey {
            let vzweck = verwendungszweck.lowercased()
            for needle in Self.brandSearchNeedles {
                if !Self.paymentIntermediaries.contains(needle) && Self.wordContains(vzweck, needle) {
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
            if !Self.paymentIntermediaries.contains(needle) && Self.wordContains(emp, needle) {
                return needle
            }
        }

        // Regel 4: Verwendungszweck durchsuchen (Intermediäre ausgeschlossen)
        let vzweck = verwendungszweck.lowercased()
        for needle in Self.brandSearchNeedles {
            if !Self.paymentIntermediaries.contains(needle) && Self.wordContains(vzweck, needle) {
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

    /// Anzeigefertiges Logo: quadratisch, in genau der Pixelzahl, in der es gezeichnet
    /// wird. Siehe `Logoskalierung` — dort steht, warum das nicht SwiftUI übernimmt.
    ///
    /// `kante` in Punkten (20 in der Umsatzzeile, 48 in den Buchungsdetails), `skala`
    /// aus `\.displayScale`. Das Ergebnis wird je Kombination gemerkt; ein Bild kostet
    /// wenige Kilobyte, und der Wechsel zwischen internem und externem Bildschirm
    /// fragt einfach die andere Größe an.
    func anzeigebild(for normalizedMerchant: String, kante: CGFloat, skala: CGFloat) -> NSImage? {
        let key = normalizedMerchant.lowercased()
        guard let quelle = imageCache[key] else { return nil }
        let merkmal = "\(key)@\(Int(kante.rounded()))@\(Logoskalierung.zielPixel(kante: kante, skala: skala))"
        if let fertig = anzeigeCache[merkmal] { return fertig }
        guard let bild = Logoskalierung.anzeigebild(aus: quelle, kante: kante, skala: skala) else {
            return quelle
        }
        anzeigeCache[merkmal] = bild
        return bild
    }

    /// Verwirft die gerechneten Anzeigegrößen eines Händlers — nötig, sobald sich das
    /// Quellbild ändert (Netzabruf, eigenes Logo, Cache geleert).
    private func anzeigebilderVergessen(_ key: String? = nil) {
        guard let key else { anzeigeCache = [:]; return }
        let praefix = key.lowercased() + "@"
        anzeigeCache = anzeigeCache.filter { !$0.key.hasPrefix(praefix) }
    }

    func hasCustomLogo(forKey key: String) -> Bool {
        customLogoKeys.contains(key.lowercased())
    }

    /// Setzt ein Custom-Logo für einen Händler-Key (gilt für alle Buchungen desselben Händlers).
    func setCustomLogo(data: Data, forKey key: String) {
        let k = key.lowercased()
        guard let image = NSImage(data: data) else { return }
        imageCache[k] = image
        anzeigebilderVergessen(k)
        customLogoKeys.insert(k)
        Task.detached { TransactionsDatabase.saveMerchantCustomLogo(merchantKey: k, data: data) }
    }

    /// Entfernt das Custom-Logo für einen Händler-Key und stellt ggf. das gebündelte SVG wieder her.
    func removeCustomLogo(forKey key: String) {
        let k = key.lowercased()
        customLogoKeys.remove(k)
        imageCache.removeValue(forKey: k)
        anzeigebilderVergessen(k)
        Task.detached { TransactionsDatabase.deleteMerchantCustomLogo(merchantKey: k) }
        // Gebündeltes SVG wiederherstellen falls vorhanden
        loadBundledSVG(key: k)
    }

    /// Lädt Merchant-Custom-Logos beim Start — immer, unabhängig vom Internet-Schalter.
    private func loadMerchantCustomLogos() {
        Task.detached {
            let entries = TransactionsDatabase.loadAllMerchantCustomLogos()
            await MainActor.run {
                for (key, data) in entries {
                    if let image = NSImage(data: data) {
                        self.imageCache[key] = image
                        self.anzeigebilderVergessen(key)
                        self.customLogoKeys.insert(key)
                    }
                }
            }
        }
    }

    /// Einstellung „Händler-Logos aus dem Internet laden" (logo.dev).
    static let remoteLogosKey = "remoteMerchantLogosEnabled"
    static var remoteLogosEnabled: Bool {
        UserDefaults.standard.object(forKey: remoteLogosKey) as? Bool ?? true
    }

    /// Wie lange ein geladenes Logo aus dem Cache gilt — und wie lange ein „kein Logo"
    /// (404) gemerkt wird, damit unbekannte Händler nicht täglich neu kosten.
    nonisolated static let remoteCacheDays = 30

    /// Kürzeste Kante, die ein Logo aus dem Netz haben muss, um benutzt zu werden.
    ///
    /// Bis 2.0.2 kamen die Logos von DuckDuckGo, und das sind Favicons: 16, 32, manchmal
    /// 48 Pixel. In einer 20-Punkt-Zeile auf einem Retina-Bildschirm werden daraus 40 bis
    /// 60 Pixel — ein 16er Favicon wird dabei um das Zweieinhalbfache aufgeblasen und
    /// zerfällt sichtbar. Mit 2.0.3 liefert logo.dev saubere Bilder, aber die alten
    /// Favicons lagen weiter im Cache und galten dort noch 30 Tage. Sie sahen nicht
    /// „etwas schlechter" aus, sondern kaputt, und genau das war zu sehen.
    ///
    /// Die Grenze gilt auch für neue Abrufe: Lieber das Kategorie-Symbol als ein Bild,
    /// das man nicht erkennt.
    nonisolated static let mindestKante = 64

    /// Kürzeste Kante des Bildes in echten Pixeln — nicht `size`, das bei mehreren
    /// Auflösungen (.ico) die Punktgröße der ersten Repräsentation meldet.
    nonisolated static func kanteInPixeln(_ image: NSImage) -> Int {
        let kanten = image.representations.map { min($0.pixelsWide, $0.pixelsHigh) }
        return kanten.max() ?? Int(min(image.size.width, image.size.height))
    }

    // MARK: - logo.dev
    //
    // Ein Schlüssel für alle Installationen — logo.dev nennt ihn „publishable key", er
    // ist zum Einbetten gedacht (bei Brandfetch war genau das der Graubereich; die
    // Anbindung ist mit 2.0.3 entfallen). Das Kontingent des Free-Tarifs (500.000
    // Anfragen im Monat, harte Grenze) teilen sich damit alle Nutzer. Darum drei
    // Bremsen: gebündelte Logos zuerst, dann der 30-Tage-Cache, dann höchstens
    // `fetchesPerDay` Netzabrufe je Installation und Tag. Rechnung: 4.000 Nutzer ×
    // 3 × 30 = 360.000 im schlimmsten Fall; real liegt es nach der ersten Woche weit
    // darunter, weil nur neue Händler noch Abrufe auslösen.
    //
    // Free-Tarif und kommerzielle Nutzung verlangen einen Hinweis „Logos provided by
    // Logo.dev" auf der Website oder in der Store-Beschreibung.
    enum LogoDev {
        /// Publishable Key (`pk_…`). Leer oder Platzhalter ⇒ keine Netzabrufe.
        static let publishableKey = "pk_W66nkzL5RtG8bEEb3ZWNTg"
        static let fetchesPerDay = 3
        static var istKonfiguriert: Bool {
            publishableKey.hasPrefix("pk_") && publishableKey != "pk_PLACEHOLDER"
        }
        /// 256 statt 128 Pixel: Die Zeile zeigt das Logo 20 Punkte breit, auf einem
        /// Retina-Bildschirm sind das 40 bis 60 echte Pixel, die Detailansicht nimmt
        /// 30 Punkte. 128 reichte dafür, 256 kostet nur Bytes (keinen zusätzlichen
        /// Abruf) und hält auch eine größere Darstellung scharf.
        static func url(for domain: String) -> URL? {
            URL(string: "https://img.logo.dev/\(domain)?token=\(publishableKey)&size=256&format=png&fallback=404")
        }

        private static let zaehlerTagKey = "merchantLogoFetchDay"
        private static let zaehlerKey = "merchantLogoFetchCount"
        private static let fehltreffernKey = "merchantLogoMisses"
        private static let nachholKey = "merchantLogoNachholBudget"

        /// Obergrenze des einmaligen Nachhol-Kontingents. Es greift genau dann, wenn beim
        /// Start alte Favicons aus dem Cache fliegen (siehe `mindestKante`), und nur für
        /// so viele Abrufe, wie tatsächlich weggefallen sind. Rechnung für das Kontingent
        /// von logo.dev: 4.000 Installationen × höchstens 30 Abrufe = 120.000 — einmalig,
        /// neben den 500.000 im Monat des Free-Tarifs.
        static let nachholHoechstzahl = 30

        /// Meldet, dass `anzahl` gecachte Logos verworfen wurden und einmalig
        /// nachgeholt werden dürfen. Mehrfachaufrufe erhöhen nicht über die Grenze.
        static func nachholenErlauben(_ anzahl: Int) {
            let d = UserDefaults.standard
            let neu = min(d.integer(forKey: nachholKey) + anzahl, nachholHoechstzahl)
            d.set(neu, forKey: nachholKey)
        }

        private static func nachholenVerbrauchen() -> Bool {
            let d = UserDefaults.standard
            let rest = d.integer(forKey: nachholKey)
            guard rest > 0 else { return false }
            d.set(rest - 1, forKey: nachholKey)
            return true
        }

        private static var heute: String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }

        /// Reserviert einen Netzabruf für heute. `false`, wenn das Tagesbudget aufgebraucht ist.
        /// Das einmalige Nachhol-Kontingent geht vor, damit die beim Start verworfenen
        /// Logos nicht hinter dem Tagesbudget in der Schlange stehen.
        static func budgetVerbrauchen() -> Bool {
            if nachholenVerbrauchen() { return true }
            let d = UserDefaults.standard
            let tag = heute
            var count = d.string(forKey: zaehlerTagKey) == tag ? d.integer(forKey: zaehlerKey) : 0
            guard count < fetchesPerDay else { return false }
            count += 1
            d.set(tag, forKey: zaehlerTagKey)
            d.set(count, forKey: zaehlerKey)
            return true
        }

        /// „Kein Logo bekannt" — 30 Tage lang nicht erneut fragen.
        static func merkeFehltreffer(_ key: String) {
            var misses = UserDefaults.standard.dictionary(forKey: fehltreffernKey) as? [String: Double] ?? [:]
            misses[key] = Date().timeIntervalSince1970
            // Alte Einträge gleich mit ausmisten, damit das Dictionary nicht wächst.
            let grenze = Date().addingTimeInterval(-Double(remoteCacheDays) * 86_400).timeIntervalSince1970
            misses = misses.filter { $0.value >= grenze }
            UserDefaults.standard.set(misses, forKey: fehltreffernKey)
        }

        static func istFehltreffer(_ key: String) -> Bool {
            guard let ts = (UserDefaults.standard.dictionary(forKey: fehltreffernKey) as? [String: Double])?[key] else { return false }
            return Date().timeIntervalSince1970 - ts < Double(remoteCacheDays) * 86_400
        }

        static func vergissFehltreffer() {
            UserDefaults.standard.removeObject(forKey: fehltreffernKey)
        }
    }

    // MARK: - Rückfall: Googles Favicon-Dienst
    //
    // Kennt logo.dev einen Händler nicht (404), bleibt die Zeile beim Kategorie-Symbol.
    // Googles inoffizieller Favicon-Dienst nimmt, was die Website selbst hinterlegt hat,
    // und kennt dadurch manches, was in keiner Markendatenbank steht.
    //
    // **Wie viel das bringt, ist gemessen — heute nichts.** Am 23.09.2026 gegen alle 133
    // Domains der Whitelist ohne mitgeliefertes SVG geprüft: logo.dev liefert für 129 ein
    // brauchbares Bild, bei drei weiteren (storytel.de, tamoil.de, viaplay.de) hat auch
    // Google nur seine Ersatz-Weltkugel. Der Rückfall rettet also im Moment **keinen
    // einzigen** Händler.
    //
    // Er bleibt trotzdem drin, weil er nichts kostet, solange er nicht greift: kein
    // Schlüssel, kein Kontingent, und im Normalfall (logo.dev antwortet mit 200) wird er
    // gar nicht erst aufgerufen. Er ist das Netz für neue Whitelist-Einträge und für den
    // Fall, dass logo.dev einen Händler wieder verliert. Wer ihn später bewertet: Die
    // Messung oben lässt sich mit denselben zwei Abrufen je Domain wiederholen.
    //
    // Als *Ersatz* für logo.dev taugt Google ohnehin nicht — die Größe hängt daran, was
    // die Website hinterlegt hat: anthropic.com 256 px, dhl.de 192, uber.com 180, aber
    // apple.com nur 64, edeka.de 48, rossmann.de 16.
    //
    // Zwei Dinge, die man wissen muss:
    //
    //   * **Kein 404.** Für unbekannte Domains liefert Google ein festes Ersatzbild —
    //     eine 16×16 große Weltkugel (am 23.09.2026 für drei erfundene Domains byte-
    //     gleich). Die Mindestgröße fängt das ab; ein Abgleich auf genau dieses Bild
    //     wäre die brüchigere Prüfung, weil Google es jederzeit austauschen kann.
    //   * **Ohne Zusage.** Der Dienst ist inoffiziell und unmaintained — nach logo.dev's
    //     eigener Dokumentation. Er darf deshalb nie tragende Rolle spielen: fällt er
    //     aus, steht wie bisher das Kategorie-Symbol da.
    enum GoogleFavicon {
        /// Kein Schlüssel, kein Kontingent — nur die Domain geht raus, wie bei logo.dev.
        static func url(for domain: String) -> URL? {
            guard let kodiert = domain.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
            else { return nil }
            return URL(string: "https://www.google.com/s2/favicons?domain=\(kodiert)&sz=256")
        }
    }

    // Lädt die gecachten Logos aus der DB in den Speicher (einmalig beim ersten preload).
    // Logos, die älter als 30 Tage sind, fallen weg und werden beim nächsten Anzeigen
    // einmal neu geholt — innerhalb des Tagesbudgets.
    private func loadPersistedLogosIfNeeded() {
        guard !persistedLogosLoaded else { return }
        persistedLogosLoaded = true
        // Synchron, nicht im Hintergrund: `preload` prüft direkt danach den Speicher.
        // Lief das Laden asynchron, sah der erste Aufruf einen leeren Cache und holte
        // die beim Start sichtbaren Händler jedes Mal neu. Es ist ein einzelner
        // Blob-Read aus SQLite, wenige Millisekunden.
        guard let entries = try? TransactionsDatabase.loadCachedLogoData(maxAgeDays: Self.remoteCacheDays) else { return }
        // Zu kleine Bilder (Favicons aus der Zeit vor logo.dev) wandern nicht in den
        // Speicher, sondern aus dem Cache. Sonst blieben sie bis zu 30 Tage stehen und
        // verhinderten obendrein, dass für denselben Händler ein gutes Logo geholt wird.
        var zuKlein: [String] = []
        for (key, data) in entries where imageCache[key] == nil {
            guard let image = NSImage(data: data) else { continue }
            if Self.kanteInPixeln(image) < Self.mindestKante {
                zuKlein.append(key)
                continue
            }
            imageCache[key] = image
        }
        guard !zuKlein.isEmpty else { return }
        // Was hier wegfällt, hat der Nutzer vorher gesehen — deshalb ein einmaliges
        // Zusatzkontingent, damit die Lücken in Tagen statt Wochen wieder zuwachsen.
        LogoDev.nachholenErlauben(zuKlein.count)
        AppLogger.log("Logo-Cache: \(zuKlein.count) zu kleine Bilder verworfen (< \(Self.mindestKante)px)",
                      category: "Logos")
        Task.detached { TransactionsDatabase.deleteLogos(keys: zuKlein) }
    }

    func preload(normalizedMerchant: String) {
        loadPersistedLogosIfNeeded()
        let key = normalizedMerchant.lowercased()
        guard imageCache[key] == nil, !inFlight.contains(key) else { return }
        // Gebündeltes SVG zuerst — so stand es im Kopf dieser Datei, gerufen wurde es
        // aber nur beim Entfernen eines eigenen Logos. Für die mitgelieferten Händler
        // fiel deshalb jedes Mal ein Netzaufruf an, den niemand brauchte.
        if loadBundledSVG(key: key) { return }
        // Ohne diesen Schalter gab es keinen Weg, die Netzabrufe zu unterbinden. Default
        // an, damit sich für Bestandsnutzer nichts ändert; wer keine Händlerdomains an
        // Dritte schicken will, schaltet hier ab und behält die gebündelten Logos.
        guard Self.remoteLogosEnabled, LogoDev.istKonfiguriert else { return }
        guard let domain = Self.domainWhitelist[key] else { return }
        guard !LogoDev.istFehltreffer(key) else { return }
        guard LogoDev.budgetVerbrauchen() else { return }
        inFlight.insert(key)

        Task { await fetchLogoDev(key: key, domain: domain) }
    }

    @discardableResult
    private func loadBundledSVG(key: String) -> Bool {
        guard let svgName = Self.svgMap[key],
              let url = Bundle.main.url(forResource: svgName, withExtension: "svg", subdirectory: "merchant-logos"),
              let image = NSImage(contentsOf: url) else { return false }
        imageCache[key] = image
        anzeigebilderVergessen(key)
        inFlight.remove(key)
        return true
    }

    func clearCache() {
        imageCache = imageCache.filter { customLogoKeys.contains($0.key) }
        anzeigebilderVergessen()
        inFlight = []
        persistedLogosLoaded = false
        Self.LogoDev.vergissFehltreffer()
        Task.detached { TransactionsDatabase.clearLogoCache() }
    }

    private func fetchLogoDev(key: String, domain: String) async {
        defer { inFlight.remove(key) }
        guard let url = Self.LogoDev.url(for: domain) else { return }
        guard let (data, http) = await Self.holen(url) else { return }

        if http.statusCode == 404 {
            // logo.dev kennt den Händler nicht. Bevor die Zeile beim Kategorie-Symbol
            // bleibt, fragen wir Googles Favicon-Dienst — der kostet nichts und kennt
            // auch kleinere Läden. Siehe `GoogleFavicon`.
            await versucheGoogleFavicon(key: key, domain: domain)
            return
        }
        // 202 = noch nicht indiziert, 429 = Kontingent erschöpft: beides ohne Merker,
        // beim nächsten Tag klappt es vielleicht.
        guard http.statusCode == 200, !data.isEmpty, let image = NSImage(data: data) else { return }
        // Zu klein heißt: in der Zeile nicht erkennbar. Dann lieber erst Google fragen
        // und, wenn auch das nichts taugt, das Kategorie-Symbol zeigen.
        guard Self.kanteInPixeln(image) >= Self.mindestKante else {
            AppLogger.log("logo.dev: \(key) nur \(Self.kanteInPixeln(image))px — Rückfall auf Google",
                          category: "Logos")
            await versucheGoogleFavicon(key: key, domain: domain)
            return
        }
        uebernehmen(image, data: data, key: key)
    }

    /// Rückfall, wenn logo.dev nichts Brauchbares hat. Kein Fehler, wenn es misslingt —
    /// dann bleibt es beim Kategorie-Symbol, wie vor diesem Rückfall auch.
    ///
    /// Verbraucht **kein** logo.dev-Budget: Der Dienst hat keines, und der Abruf für
    /// diesen Händler ist oben schon bezahlt worden.
    private func versucheGoogleFavicon(key: String, domain: String) async {
        defer { Self.LogoDev.merkeFehltreffer(key) }   // in jedem Fall 30 Tage Ruhe
        guard let url = Self.GoogleFavicon.url(for: domain),
              let (data, http) = await Self.holen(url),
              http.statusCode == 200, !data.isEmpty,
              let image = NSImage(data: data)
        else {
            AppLogger.log("Kein Logo für \(key) — auch Google hat keins", category: "Logos")
            return
        }
        // Unbekannte Domains beantwortet Google mit einer 16×16-Weltkugel statt mit 404.
        // Die Mindestgröße sortiert sie zusammen mit allen anderen zu kleinen Favicons aus.
        guard Self.kanteInPixeln(image) >= Self.mindestKante else {
            AppLogger.log("Google-Favicon für \(key) nur \(Self.kanteInPixeln(image))px — verworfen",
                          category: "Logos")
            return
        }
        AppLogger.log("Logo für \(key) über Google (\(Self.kanteInPixeln(image))px)", category: "Logos")
        uebernehmen(image, data: data, key: key)
    }

    /// Ein geholtes Logo in Speicher- und Plattencache legen.
    private func uebernehmen(_ image: NSImage, data: Data, key: String) {
        imageCache[key] = image
        anzeigebilderVergessen(key)
        Task.detached { TransactionsDatabase.saveLogo(key: key, data: data) }
    }

    private static func holen(_ url: URL) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }
}
