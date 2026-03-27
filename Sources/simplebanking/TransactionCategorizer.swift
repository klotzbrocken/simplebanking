import Foundation

enum TransactionCategory: String, CaseIterable, Codable {
    // Existing
    case einkommen    = "Einkommen"
    case essenAlltag  = "Essen & Alltag"
    case abosDigital  = "Abos & Digital"
    case shopping     = "Shopping"
    case versicherungen = "Versicherungen"
    case mobilitaet   = "Mobilitaet"
    case wohnenKredit = "Wohnen & Kredit"
    case sonstiges    = "Sonstiges"
    // AI categories
    case gastronomie  = "Gastronomie"
    case sparen       = "Sparen"
    case freizeit     = "Freizeit"
    case gehalt       = "Gehalt"
    case gesundheit   = "Gesundheit"
    case umbuchung    = "Umbuchungen"

    var displayName: String {
        switch self {
        case .mobilitaet: return "Mobilität"
        default:          return rawValue
        }
    }

    var icon: String {
        switch self {
        case .einkommen:     return "briefcase"
        case .essenAlltag:   return "fork.knife"
        case .abosDigital:   return "play.rectangle"
        case .shopping:      return "cart"
        case .versicherungen: return "shield"
        case .mobilitaet:    return "car"
        case .wohnenKredit:  return "house"
        case .sonstiges:     return "square.grid.2x2"
        case .gastronomie:   return "fork.knife"
        case .sparen:        return "chart.line.uptrend.xyaxis"
        case .freizeit:      return "sportscourt"
        case .gehalt:        return "eurosign.circle"
        case .gesundheit:    return "cross.case"
        case .umbuchung:     return "arrow.triangle.2.circlepath"
        }
    }

    static func from(jsonKey: String) -> TransactionCategory? {
        switch jsonKey {
        // Existing keys
        case "versicherungen": return .versicherungen
        case "wohnen_kredit":  return .wohnenKredit
        case "mobilitaet":     return .mobilitaet
        case "abos_digital":   return .abosDigital
        case "shopping":       return .shopping
        case "essen_alltag":   return .essenAlltag
        // AI keys
        case "gastronomie":    return .gastronomie
        case "sparen":         return .sparen
        case "freizeit":       return .freizeit
        case "gehalt":         return .gehalt
        case "gesundheit":     return .gesundheit
        case "umbuchung":      return .umbuchung
        case "einkaufen":      return .shopping
        case "transport":      return .mobilitaet
        case "versicherung":   return .versicherungen
        case "sonstiges":      return .sonstiges
        default:               return nil
        }
    }

    static func from(displayName: String) -> TransactionCategory? {
        let normalized = normalize(displayName)
        for category in TransactionCategory.allCases {
            if normalize(category.rawValue) == normalized || normalize(category.displayName) == normalized {
                return category
            }
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
    }
}

enum TransactionCategorizer {
    static let overridesStorageKey = "transactionCategoryOverrides"

    private struct CategoriesFile: Decodable {
        let categories: [String: CategoryEntry]
    }

    private struct CategoryEntry: Decodable {
        let keywords: KeywordEntry
    }

    private struct KeywordEntry: Decodable {
        let generic: [String]?
        let merchants: [String]?
    }

    private struct Rule {
        let category: TransactionCategory
        let keywords: [String]

        func matches(haystack: String) -> Bool {
            for keyword in keywords where !keyword.isEmpty {
                if haystack.contains(keyword) {
                    return true
                }
            }
            return false
        }
    }

    private static let categoryOrder: [String] = [
        "versicherungen",
        "wohnen_kredit",
        "mobilitaet",
        "abos_digital",
        "shopping",
        "essen_alltag",
    ]

    private static let rules: [Rule] = loadRules()

    static func preload() {
        _ = rules
    }

    static func category(for transaction: TransactionsResponse.Transaction) -> TransactionCategory {
        let txID = TransactionRecord.fingerprint(for: transaction)
        if let override = overrideCategory(txID: txID) {
            return override
        }

        if let storedCategory = transaction.category,
           let parsedStored = TransactionCategory.from(displayName: storedCategory) {
            return parsedStored
        }

        return autoCategory(for: transaction)
    }

    static func autoCategory(for transaction: TransactionsResponse.Transaction) -> TransactionCategory {
        let amount = transaction.parsedAmount
        let empfaenger = transaction.creditor?.name
        let absender = transaction.debtor?.name
        let verwendungszweck = (transaction.remittanceInformation ?? []).joined(separator: " ")
        let additionalInformation = transaction.additionalInformation
        let merchant = MerchantResolver.resolve(transaction: transaction).effectiveMerchant

        return classify(
            amount: amount,
            empfaenger: empfaenger,
            absender: absender,
            verwendungszweck: verwendungszweck,
            additionalInformation: additionalInformation,
            effectiveMerchant: merchant
        )
    }

    static func category(
        txID: String,
        amount: Double,
        empfaenger: String?,
        absender: String?,
        verwendungszweck: String?,
        additionalInformation: String?,
        effectiveMerchant: String?
    ) -> TransactionCategory {
        if let override = overrideCategory(txID: txID) {
            return override
        }

        return classify(
            amount: amount,
            empfaenger: empfaenger,
            absender: absender,
            verwendungszweck: verwendungszweck,
            additionalInformation: additionalInformation,
            effectiveMerchant: effectiveMerchant
        )
    }

    static func saveOverride(txID: String, category: TransactionCategory) {
        let key = txID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        var overrides = transactionOverrides()
        overrides[key] = category.rawValue
        persistOverrides(overrides)
    }

    @discardableResult
    static func removeOverride(txID: String) -> Bool {
        let key = txID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }

        var overrides = transactionOverrides()
        let removed = overrides.removeValue(forKey: key) != nil
        persistOverrides(overrides)
        return removed
    }

    static func hasOverride(txID: String) -> Bool {
        overrideCategory(txID: txID) != nil
    }

    static func overrideCategory(txID: String) -> TransactionCategory? {
        let key = txID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        guard let rawValue = transactionOverrides()[key] else { return nil }
        return TransactionCategory.from(displayName: rawValue)
    }

    private static func classify(
        amount: Double,
        empfaenger: String?,
        absender: String?,
        verwendungszweck: String?,
        additionalInformation: String?,
        effectiveMerchant: String?
    ) -> TransactionCategory {
        if amount > 0 {
            return .einkommen
        }

        let haystack = normalizedHaystack(
            empfaenger: empfaenger,
            absender: absender,
            verwendungszweck: verwendungszweck,
            additionalInformation: additionalInformation,
            effectiveMerchant: effectiveMerchant
        )

        for rule in rules where rule.matches(haystack: haystack) {
            return rule.category
        }

        return .sonstiges
    }

    private static func normalizedHaystack(
        empfaenger: String?,
        absender: String?,
        verwendungszweck: String?,
        additionalInformation: String?,
        effectiveMerchant: String?
    ) -> String {
        let values: [String] = [
            empfaenger ?? "",
            absender ?? "",
            verwendungszweck ?? "",
            additionalInformation ?? "",
            effectiveMerchant ?? "",
        ]

        let combined = values
            .map(normalizeKeyword)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return combined
    }

    private static func loadRules() -> [Rule] {
        if let bundleURL = bundleCategoriesURL(),
           let loaded = loadRulesFromJSON(at: bundleURL) {
            AppLogger.log("Loaded category keywords from bundle categories_de.json", category: "Category")
            return loaded
        }

        if let appSupportURL = applicationSupportCategoriesURL(),
           let loaded = loadRulesFromJSON(at: appSupportURL) {
            AppLogger.log("Loaded category keywords from Application Support categories_de.json", category: "Category")
            return loaded
        }

        AppLogger.log("Category keywords fallback active", category: "Category", level: "WARN")
        return fallbackRules
    }

    private static func applicationSupportCategoriesURL() -> URL? {
        guard let credentialsURL = try? CredentialsStore.defaultURL() else { return nil }
        return credentialsURL.deletingLastPathComponent().appendingPathComponent("categories_de.json")
    }

    private static func bundleCategoriesURL() -> URL? {
        if let mainURL = Bundle.main.url(forResource: "categories_de", withExtension: "json") {
            return mainURL
        }

        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("categories_de.json"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        return nil
    }

    private static func loadRulesFromJSON(at url: URL) -> [Rule]? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CategoriesFile.self, from: data)
        else {
            return nil
        }

        var loadedRules: [Rule] = []

        for key in categoryOrder {
            guard let category = TransactionCategory.from(jsonKey: key),
                  let entry = decoded.categories[key]
            else {
                continue
            }

            let words = ((entry.keywords.generic ?? []) + (entry.keywords.merchants ?? []))
                .map(normalizeKeyword)
                .filter { !$0.isEmpty }

            guard !words.isEmpty else { continue }
            loadedRules.append(Rule(category: category, keywords: Array(Set(words))))
        }

        return loadedRules.isEmpty ? nil : loadedRules
    }

    private static func persistOverrides(_ overrides: [String: String]) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: overridesStorageKey)
        }
    }

    private static func transactionOverrides() -> [String: String] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: overridesStorageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private static func normalizeKeyword(_ keyword: String) -> String {
        keyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
    }

    private static let fallbackRules: [Rule] = [
        Rule(category: .versicherungen, keywords: [
            "versicherung", "krankenvers", "haftpflicht", "huk-coburg", "allianz", "ergo", "axa", "debeka",
        ]),
        Rule(category: .wohnenKredit, keywords: [
            "miete", "hausgeld", "nebenkosten", "stadtwerke", "strom", "gas", "rundfunkbeitrag", "kreditrate", "sofortkredit",
        ]),
        Rule(category: .mobilitaet, keywords: [
            "tankstelle", "tanken", "aral", "shell", "deutsche bahn", "db vertrieb", "park", "maut", "uber",
        ]),
        Rule(category: .abosDigital, keywords: [
            "netflix", "spotify", "apple services", "youtube", "prime", "adobe", "vodafone", "o2", "telekom", "chatgpt", "anthropic",
        ]),
        Rule(category: .shopping, keywords: [
            "amazon", "zalando", "ebay", "ikea", "mediamarkt", "saturn", "klarna",
        ]),
        Rule(category: .essenAlltag, keywords: [
            "rewe", "edeka", "aldi", "lidl", "dm", "rossmann", "mcdonald", "burger king", "restaurant", "lieferando", "apotheke",
        ]),
    ]
}
