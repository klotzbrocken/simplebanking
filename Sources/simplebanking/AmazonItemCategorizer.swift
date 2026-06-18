import Foundation

/// Produktkategorien für Amazon-Bestellpositionen. Amazon verkauft quer durch
/// alle Sortimente — daher breite Handelskategorien, heuristisch über Stichwörter
/// in den (oft langen) Produkttiteln. Rest → `.sonstiges`.
enum AmazonCategory: String, CaseIterable {
    case elektronik = "Elektronik & Technik"
    case haushaltKueche = "Haushalt & Küche"
    case buecherMedien = "Bücher & Medien"
    case kleidungMode = "Kleidung & Mode"
    case drogerieBeauty = "Drogerie & Beauty"
    case lebensmittel = "Lebensmittel"
    case spielzeugHobby = "Spielzeug & Hobby"
    case sportOutdoor = "Sport & Outdoor"
    case bueroSchreib = "Büro & Schreibwaren"
    case heimwerkerGarten = "Heimwerker & Garten"
    case sonstiges = "Sonstiges"

    var symbol: String {
        switch self {
        case .elektronik: return "cpu"
        case .haushaltKueche: return "house.fill"
        case .buecherMedien: return "book.fill"
        case .kleidungMode: return "tshirt.fill"
        case .drogerieBeauty: return "sparkles"
        case .lebensmittel: return "fork.knife"
        case .spielzeugHobby: return "teddybear.fill"
        case .sportOutdoor: return "figure.run"
        case .bueroSchreib: return "pencil.and.ruler.fill"
        case .heimwerkerGarten: return "wrench.and.screwdriver.fill"
        case .sonstiges: return "shippingbox.fill"
        }
    }
}

enum AmazonItemCategorizer {
    // Reihenfolge = Priorität. Erste Liste mit Treffer gewinnt.
    private static let rules: [(AmazonCategory, [String])] = [
        (.elektronik, ["kabel", "usb", "hdmi", "ladegerät", "ladegerat", "akku", "batterie", "kopfhörer",
                       "kopfhorer", "headset", "lautsprecher", "ssd", "festplatte", "monitor", "tastatur",
                       "maus ", "router", "smart", "echo", "kindle", "fire tv", "ipad", "iphone", "samsung",
                       "anker", "powerbank", "adapter", "webcam", "drucker", "toner", "speicherkarte",
                       "bluetooth", "wlan", "netzteil", "controller", "konsole", "grafikkarte"]),
        (.buecherMedien, ["buch", "roman", "taschenbuch", "gebundene", "hörbuch", "horbuch", "blu-ray",
                          "dvd", "vinyl", "schallplatte", "zeitschrift", "comic", "manga", "kalender 202"]),
        (.drogerieBeauty, ["shampoo", "duschgel", "creme", "lotion", "deo", "parfum", "rasier", "zahnpasta",
                           "zahnbürste", "make-up", "make up", "nagellack", "windel", "feuchttücher",
                           "feuchttucher", "vitamin", "tabletten", "nahrungsergänz", "pflaster", "seife"]),
        (.lebensmittel, ["kaffee", "tee", "schokolade", "müsli", "muesli", "nudeln", "reis", "olivenöl",
                         "rapsöl", "speiseöl", "sonnenblumenöl", "snack",
                         "riegel", "protein", "getränk", "getrank", "wasser", "kapseln nespresso", "honig",
                         "gewürz", "gewurz", "bonbon", "chips", "nüsse", "nusse"]),
        (.kleidungMode, ["t-shirt", "tshirt", "hemd", "hose", "jeans", "jacke", "mantel", "pullover", "schuhe",
                         "sneaker", "socken", "unterwäsche", "unterwasche", "bh ", "kleid", "rock", "gürtel",
                         "gurtel", "mütze", "mutze", "handschuhe", "schal", "tasche", "rucksack", "geldbörse"]),
        (.sportOutdoor, ["fitness", "yoga", "hantel", "fahrrad", "laufschuh", "wandern", "zelt", "schlafsack",
                         "trinkflasche", "sport", "training", "ball", "outdoor", "camping"]),
        (.spielzeugHobby, ["lego", "puzzle", "spielzeug", "brettspiel", "kartenspiel", "playmobil", "puppe",
                           "modellbau", "bastel", "stricken", "wolle", "malen", "lego ", "figur", "plüsch", "plusch"]),
        (.bueroSchreib, ["stift", "kugelschreiber", "notizbuch", "ordner", "papier", "drucker­papier",
                         "umschlag", "etiketten", "locher", "tacker", "marker", "tinte", "klebe"]),
        (.heimwerkerGarten, ["bohr", "schraub", "akkuschrauber", "werkzeug", "zange", "hammer", "farbe",
                             "lack", "dübel", "dubel", "garten", "rasen", "pflanze", "blumen", "dünger",
                             "dunger", "schlauch", "leiter", "silikon", "klebeband"]),
        (.haushaltKueche, ["pfanne", "topf", "messer", "geschirr", "teller", "tasse", "besteck", "küche",
                           "kuche", "staubsauger", "wäsche", "wasche", "reiniger", "müllbeutel", "muellbeutel",
                           "handtuch", "bettwäsche", "bettwasche", "kissen", "lampe", "regal", "box ", "behälter",
                           "behalter", "vorhang", "mixer", "wasserkocher", "kaffeemaschine", "toaster"]),
    ]

    static func category(forName name: String) -> AmazonCategory {
        let n = name.lowercased()
        for (cat, keys) in rules where keys.contains(where: { n.contains($0) }) {
            return cat
        }
        return .sonstiges
    }

    static func category(for item: ReweLineItem) -> AmazonCategory {
        category(forName: item.name)
    }

    /// Aggregiert die Positionen mehrerer Bestellungen nach Kategorie (Summe Cent +
    /// Anzahl), absteigend nach Summe.
    static func breakdown(_ receipts: [ReweReceipt]) -> [(category: AmazonCategory, totalCents: Int, count: Int)] {
        var sums: [AmazonCategory: (Int, Int)] = [:]
        for r in receipts where !r.cancelled {
            for item in r.items {
                let cat = category(for: item)
                let cur = sums[cat] ?? (0, 0)
                sums[cat] = (cur.0 + item.totalCents, cur.1 + 1)
            }
        }
        return sums.map { (category: $0.key, totalCents: $0.value.0, count: $0.value.1) }
            .sorted { $0.totalCents > $1.totalCents }
    }
}
