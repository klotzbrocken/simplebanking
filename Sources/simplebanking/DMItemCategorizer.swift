import Foundation

/// Produktkategorien für dm-Einzelposten (Drogerie, nicht Lebensmittel wie REWE).
/// Heuristisch über Eigenmarken (Denkmit, Balea, …) + Stichwörter. Bewusst grob;
/// der Rest landet in `.sonstiges`.
enum DMCategory: String, CaseIterable {
    case koerperKosmetik = "Körper & Kosmetik"
    case zahnMund = "Zahn & Mund"
    case haareStyling = "Haare & Styling"
    case babyKind = "Baby & Kind"
    case gesundheit = "Gesundheit & Vitamine"
    case haushaltReinigung = "Haushalt & Reinigung"
    case ernaehrung = "Ernährung & Getränke"
    case tierbedarf = "Tierbedarf"
    case fotoSonstiges = "Foto & Schreibwaren"
    case sonstiges = "Sonstiges"

    var symbol: String {
        switch self {
        case .koerperKosmetik: return "sparkles"
        case .zahnMund: return "mouth.fill"
        case .haareStyling: return "comb.fill"
        case .babyKind: return "figure.and.child.holdinghands"
        case .gesundheit: return "cross.case.fill"
        case .haushaltReinigung: return "house.fill"
        case .ernaehrung: return "fork.knife"
        case .tierbedarf: return "pawprint.fill"
        case .fotoSonstiges: return "photo.fill"
        case .sonstiges: return "bag.fill"
        }
    }
}

enum DMItemCategorizer {
    // Reihenfolge = Priorität. Erste Liste mit Treffer gewinnt. Eigenmarken sind
    // starke Signale und stehen darum bei ihrer Kategorie.
    private static let rules: [(DMCategory, [String])] = [
        (.tierbedarf, ["dein bestes", "hundefutter", "katzenfutter", "tiernahrung", "tierbedarf"]),
        (.babyKind, ["babylove", "saubär", "saubaer", "windel", "feuchttücher", "feuchttuecher",
                     "babynahrung", "milupa", "schnuller", "fläschchen", "babypflege"]),
        (.zahnMund, ["dontodent", "zahnpasta", "zahncreme", "zahnbürste", "zahnbuerste", "zahnseide",
                     "mundspül", "mundspul", "mundwasser", "interdental"]),
        (.haareStyling, ["shampoo", "haarspülung", "haarspuelung", "spülung", "conditioner", "haarkur",
                         "haargel", "haarspray", "coloration", "tönung", "toenung", "balea men",
                         "haarfarbe", "föhn", "glätteisen"]),
        (.gesundheit, ["mivolis", "das gesunde plus", "vitamin", "magnesium", "kapseln", "tabletten",
                       "zink", "omega", "pflaster", "nasenspray", "halstabletten", "ibu", "paracetamol",
                       "desinfekt", "verband"]),
        (.koerperKosmetik, ["balea", "alverde", "ebelin", "sundance", "p2", "trend it up", "catrice",
                            "dusch", "bodylotion", "body lotion", "handcreme", "gesichtscreme", "creme",
                            "lotion", "deo", "deodorant", "seife", "rasier", "lippen", "nagel", "make-up",
                            "make up", "mascara", "puder", "lidschatten", "wattepads", "wattestäbchen",
                            "sonnenmilch", "sonnencreme", "parfum", "eau de"]),
        (.haushaltReinigung, ["denkmit", "profissimo", "spülmittel", "spuelmittel", "waschmittel",
                              "weichspüler", "weichspueler", "reiniger", "putz", "allzweck", "wc-",
                              "müllbeutel", "muellbeutel", "küchenrolle", "kuechenrolle", "toilettenpapier",
                              "taschentücher", "taschentuecher", "klarspüler", "klarspueler", "entkalker",
                              "schwamm", "alufolie", "frischhalte", "batterie", "glühbirne", "kerze"]),
        (.ernaehrung, ["dmbio", "dm bio", "tee", "kaffee", "müsli", "muesli", "riegel", "nuss", "schoko",
                       "snack", "getränk", "getraenk", "wasser", "saft", "limo", "reis", "nudel",
                       "haferflocken", "öl", "honig", "marmelade", "proteinpulver", "proteinriegel"]),
        (.fotoSonstiges, ["foto", "fotobuch", "abzüge", "abzuege", "kalender", "stift", "papier",
                          "notizbuch", "geschenkpapier", "klebe"]),
    ]

    static func category(forName name: String) -> DMCategory {
        let n = name.lowercased()
        for (cat, keys) in rules where keys.contains(where: { n.contains($0) }) {
            return cat
        }
        return .sonstiges
    }

    static func category(for item: ReweLineItem) -> DMCategory {
        category(forName: item.name)
    }

    /// Aggregiert die Einzelposten mehrerer Bons nach Kategorie (Summe Cent +
    /// Anzahl), absteigend nach Summe. Bei dm sind die Summen die AKTUELLEN
    /// Shop-Preise (dm liefert keinen historisch gezahlten Einzelpreis) — für die
    /// Verteilung „Was kaufst du ein?" ausreichend.
    static func breakdown(_ receipts: [ReweReceipt]) -> [(category: DMCategory, totalCents: Int, count: Int)] {
        var sums: [DMCategory: (Int, Int)] = [:]
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
