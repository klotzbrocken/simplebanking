import Foundation

// MARK: - BankCountry
//
// Land einer Bank, abgeleitet aus dem Display-Namen (Routex/YAXI liefert
// bei der Suche kein Country-Feld, BIC erst nach Connection — daher
// Heuristik). Default ist DE (Hauptzielgruppe; deutsche Banken haben
// selten ein Land im Namen).

enum BankCountry: String, CaseIterable, Sendable, Equatable {
    case de, at, ch, be, nl, fr, es, it, lu, gb, other

    /// Unicode-Flag-Emoji oder Globus für `.other`.
    var flag: String {
        switch self {
        case .de:    return "🇩🇪"
        case .at:    return "🇦🇹"
        case .ch:    return "🇨🇭"
        case .be:    return "🇧🇪"
        case .nl:    return "🇳🇱"
        case .fr:    return "🇫🇷"
        case .es:    return "🇪🇸"
        case .it:    return "🇮🇹"
        case .lu:    return "🇱🇺"
        case .gb:    return "🇬🇧"
        case .other: return "🌐"
        }
    }

    var iso: String { rawValue.uppercased() }

    var displayName: String {
        switch self {
        case .de:    return L10n.t("Deutschland",  "Germany")
        case .at:    return L10n.t("Österreich",   "Austria")
        case .ch:    return L10n.t("Schweiz",      "Switzerland")
        case .be:    return L10n.t("Belgien",      "Belgium")
        case .nl:    return L10n.t("Niederlande",  "Netherlands")
        case .fr:    return L10n.t("Frankreich",   "France")
        case .es:    return L10n.t("Spanien",      "Spain")
        case .it:    return L10n.t("Italien",      "Italy")
        case .lu:    return L10n.t("Luxemburg",    "Luxembourg")
        case .gb:    return L10n.t("Vereinigtes Königreich", "United Kingdom")
        case .other: return L10n.t("Andere",       "Other")
        }
    }
}

// MARK: - BankCountryResolver

enum BankCountryResolver {

    /// Override-Map für Edge-Cases, in denen die Heuristik daneben liegt.
    /// Schlüssel = lowercase displayName-Substring (in der Reihenfolge
    /// geprüft), Wert = Country.
    private static let overrides: [(needle: String, country: BankCountry)] = [
        ("berenberg",            .de),    // „Berenberg Bank" hat keinen Country-Hint
        ("hypovereinsbank",      .de),    // HVB ist Teil von UniCredit, aber DE-Bank
        ("targobank",            .de),
        ("santander consumer",   .de),    // DE-Tochter
        ("santander privatkund", .de)
    ]

    /// Patterns pro Country. Reihenfolge zählt: Länder mit eindeutigen Namen
    /// (CH/BE/ES/IT/FR/NL/LU/GB) werden VOR AT geprüft, weil AT generische
    /// Patterns wie „raiffeisen " hat, die sonst „Raiffeisen Schweiz"
    /// fälschlich als AT klassifizieren würden. Lowercase-Substring-Matching.
    private static let countryPatterns: [(country: BankCountry, needles: [String])] = [
        (.ch, [
            "schweiz", "switzerland", "suisse", "svizzera",
            "zürich", "zuerich", "zürcher", "zuercher",
            "ubs", "postfinance", "kantonalbank"
        ]),
        (.be, [
            "belgium", "belgië", "belgique", "belgien"
        ]),
        (.es, [
            "españa", "espana", "spain", "spanien"
        ]),
        (.it, [
            "italia", "italy", "italien"
        ]),
        (.fr, [
            "france", "française", "francaise", "frankreich"
        ]),
        (.nl, [
            "netherlands", "nederland", "niederlande",
            "abn amro", "rabobank", "ing nederland", "ing netherlands"
        ]),
        (.lu, [
            "luxembourg", "luxemburg"
        ]),
        (.gb, [
            "united kingdom", " uk ", "england", "british",
            "barclays", "lloyds", "natwest", "hsbc"
        ]),
        (.at, [
            "austria", "österreich", "oesterreich",
            "wien", "tirol", "steiermark", "salzburg", "kärnten", "kaernten",
            "vorarlberg", "burgenland",
            "raiffeisen ", "raiffeisenlandesbank", "raiffeisenbank ",
            "sparkasse oberösterreich", "bawag", "easybank",
            "oberbank", "hypo oberösterreich", "hypo tirol",
            "alpen privatbank", "bks bank", "posojilnica",
            "volkskreditbank", "vkb"
        ])
    ]

    /// Liefert das Land der Bank anhand ihres `displayName`. Nicht zugeordnete
    /// Banken fallen auf `.de` zurück (deutsche Banken nennen ihr Land i.d.R.
    /// nicht im Namen → die unauffälligen Treffer sind statistisch DE).
    static func resolve(displayName: String) -> BankCountry {
        let name = " " + displayName.lowercased() + " "

        // 1) Override-Map zuerst (überschreibt Heuristik)
        for o in overrides where name.contains(o.needle) {
            return o.country
        }

        // 2) Substring-Heuristik
        for (country, needles) in countryPatterns {
            for n in needles where name.contains(n) {
                return country
            }
        }

        // 3) Fallback
        return .de
    }
}
