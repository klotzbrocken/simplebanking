import Foundation

/// Produktkategorien für REWE-Einzelposten. Heuristisch (Stichwort-Wörterbuch),
/// bewusst grob — der Rest landet in `.sonstiges`. Später ggf. LLM-gestützt.
enum ReweCategory: String, CaseIterable {
    case obstGemuese = "Obst & Gemüse"
    case fleischWurst = "Fleisch & Wurst"
    case milchKaese = "Milch & Käse"
    case brotBack = "Brot & Backwaren"
    case getraenke = "Getränke"
    case alkohol = "Alkohol"
    case snacksSuesses = "Snacks & Süßes"
    case tiefkuehl = "Tiefkühl"
    case haushaltDrogerie = "Haushalt & Drogerie"
    case pfand = "Pfand"
    case sonstiges = "Sonstiges"

    var symbol: String {
        switch self {
        case .obstGemuese: return "carrot.fill"
        case .fleischWurst: return "fork.knife"
        case .milchKaese: return "drop.fill"
        case .brotBack: return "birthday.cake.fill"
        case .getraenke: return "cup.and.saucer.fill"
        case .alkohol: return "wineglass.fill"
        case .snacksSuesses: return "popcorn.fill"
        case .tiefkuehl: return "snowflake"
        case .haushaltDrogerie: return "house.fill"
        case .pfand: return "arrow.uturn.left"
        case .sonstiges: return "bag.fill"
        }
    }
}

enum ReweItemCategorizer {
    // Reihenfolge = Priorität. Erste Liste mit Treffer gewinnt.
    private static let rules: [(ReweCategory, [String])] = [
        (.pfand, ["pfand", "leergut"]),
        (.alkohol, ["bier", "pils", "helles", "weizen", "radler", "wein", "prosec", "sekt", "schnaps",
                    "vodka", "wodka", "whisky", "rum", "aperol", "gin", "likör", "paulaner", "becks",
                    "krombach", "jever", "veltins", "warstein"]),
        (.getraenke, ["saft", "cola", "limo", "wasser", "schorle", "eistee", "kaffee", "energy",
                      "brause", "smoothie", "spezi", "fanta", "sprite", "tonic", "r.bete saft"]),
        (.milchKaese, ["milch", "käse", "kaese", "joghurt", "jogh", "quark", "butter", "sahne", "skyr",
                       "frischkäse", "gouda", "camembert", "mozzarella", "feta", "edamer", "hummus"]),
        (.fleischWurst, ["schinken", "wurst", "salami", "hack", "schnitzel", "steak", "jerky",
                         "leberwurst", "bratwurst", "mett", "aufschnitt", "speck", "hähnchen",
                         "haehnchen", "pute", "rind", "schwein", "spicker", "pommersche"]),
        (.obstGemuese, ["apfel", "äpfel", "banane", "nektarine", "kiwi", "avocado", "zucchini",
                        "paprika", "tomate", "gurke", "salat", "zwiebel", "kartoffel", "kart.",
                        "möhre", "karotte", "orange", "zitrone", "beere", "heidelb", "erdbeer",
                        "himbeer", "traube", "melone", "wassermel", "mango", "birne", "brokkoli",
                        "spinat", "pilz", "lauch", "kohl", "san lucar"]),
        (.brotBack, ["brot", "brötchen", "broetchen", "semmel", "pretzel", "brezel", "croissant",
                     "baguette", "toast", "kuchen", "gebäck", "backwaren"]),
        (.tiefkuehl, ["tiefkühl", "pizza", "eis ", "frosta", "gelato", " tk", "tk "]),
        (.snacksSuesses, ["chips", "popco", "popcorn", "snyders", "schoko", "keks", "riegel",
                          "gummi", "bonbon", "nuss", "cracker", "hot & spicy", "pieces",
                          "fruchtg", "haribo", "salzstang"]),
        (.haushaltDrogerie, ["tragetasche", "tasche", "spül", "putz", "papier", "tücher", "shampoo",
                             "zahn", "seife", "windel", "müllbeutel", "alufolie", "frischhalt",
                             "batterie", "kerze"]),
    ]

    static func category(forName name: String, taxCategory: String?) -> ReweCategory {
        let n = name.lowercased()
        for (cat, keys) in rules where keys.contains(where: { n.contains($0) }) {
            return cat
        }
        return .sonstiges
    }

    static func category(for item: ReweLineItem) -> ReweCategory {
        category(forName: item.name, taxCategory: item.taxCategory)
    }

    /// Aggregiert die Einzelposten mehrerer Bons nach Kategorie (Summe Cent +
    /// Anzahl), absteigend nach Summe.
    static func breakdown(_ receipts: [ReweReceipt]) -> [(category: ReweCategory, totalCents: Int, count: Int)] {
        var sums: [ReweCategory: (Int, Int)] = [:]
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
