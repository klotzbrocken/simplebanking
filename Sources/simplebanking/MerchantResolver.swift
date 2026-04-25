import Foundation

struct MerchantResolution {
    let effectiveMerchant: String
    let normalizedMerchant: String
    let source: String
    let confidence: Double
}

struct MerchantUserRule: Codable, Identifiable {
    enum MatchScope: String, Codable, CaseIterable {
        case searchText = "search_text"
        case empfaenger
        case verwendungszweck
    }

    enum MatchType: String, Codable, CaseIterable {
        case contains
        case equals
        case regex
    }

    let id: UUID
    var enabled: Bool
    var priority: Int
    var matchScope: MatchScope
    var matchType: MatchType
    var pattern: String
    var merchant: String
    let createdAt: Date
    var updatedAt: Date
}

enum MerchantResolver {
    static let pipelineEnabledKey = "effectiveMerchantPipelineEnabled"
    static let rulesStorageKey = "merchantUserRules"
    static let overridesStorageKey = "merchantTxOverrides"

    private static let unknownMerchant = "Unbekannt"
    private static let cashMerchant = "Bargeldabhebung"
    private static let cardIntermediaryMerchant = "Kartenzahlung (Intermediaer)"

    private static let cardProcessorTokens: [String] = [
        "landesbank hessen-thuringen",
        "landesbank hessen-thueringen",
        "adyen",
        "nexi",
        "wirecard",
        "payone",
        "sumup",
        "fiserv",
        "worldline",
    ]

    private static let merchantAliases: [(needle: String, canonical: String)] = [
        // Lebensmittel
        ("rewe", "Rewe"),
        ("nahkauf", "Nahkauf"),
        ("edeka", "Edeka"),
        ("marktkauf", "Marktkauf"),
        ("aldi", "Aldi"),
        ("lidl", "Lidl"),
        ("netto", "Netto"),
        ("kaufland", "Kaufland"),
        ("penny", "Penny"),
        ("norma", "Norma"),
        ("np discount", "NP Discount"),
        ("tegut", "Tegut"),
        ("alnatura", "Alnatura"),
        ("famila", "Famila"),
        ("combi markt", "Combi"),
        ("combi verbrauchermarkt", "Combi"),
        ("v-markt", "V-Markt"),
        ("mix markt", "Mix Markt"),
        ("trinkgut", "Trinkgut"),
        ("getraenke hoffmann", "Getraenke Hoffmann"),
        ("getränke hoffmann", "Getraenke Hoffmann"),
        ("reformhaus", "Reformhaus"),
        ("denns biomarkt", "Denns Biomarkt"),
        ("denn's biomarkt", "Denns Biomarkt"),
        ("tchibo", "Tchibo"),

        // Drogerie / Gesundheit / Optik
        ("dm", "dm"),
        ("rossmann", "Rossmann"),
        ("müller drogerie", "Müller"),
        ("mueller drogerie", "Müller"),
        ("müller markt", "Müller"),
        ("mueller markt", "Müller"),
        ("müller", "Müller"),
        ("mueller", "Müller"),
        ("fielmann", "Fielmann"),
        ("apollo-optik", "Apollo-Optik"),
        ("apollo optik", "Apollo-Optik"),
        ("budnikowsky", "Budnikowsky"),
        ("douglas", "Douglas"),

        // Elektronik / Technik
        ("saturn", "Saturn"),
        ("mediamarkt", "MediaMarkt"),
        ("media markt", "MediaMarkt"),
        ("euronics", "Euronics"),
        ("mediamax", "Mediamax"),
        ("hercules", "Hercules"),
        ("thomann", "Thomann"),
        ("notebooksbilliger", "Notebooksbilliger"),
        ("gamestop", "Gamestop"),
        ("game stop", "Gamestop"),
        ("microsoft 365", "Microsoft 365"),
        ("microsoft", "Microsoft"),
        ("garmin", "Garmin"),
        ("lenovo", "Lenovo"),
        ("acer", "Acer"),
        ("expert", "Expert"),

        // DIY / Baumarkt
        ("ikea", "IKEA"),
        ("hornbach", "Hornbach"),
        ("bauhaus", "Bauhaus"),
        ("hagebaumarkt", "Hagebaumarkt"),
        ("hellweg", "Hellweg"),
        ("toom", "Toom"),
        ("tedox", "Tedox"),
        ("thomas philipps", "Thomas Philipps"),
        ("obi", "OBI"),

        // Möbel / Wohnen (oe spellings as canonical so normalizeForSearch matches svgMap)
        ("xxxlutz", "XXXLutz"),
        ("höffner", "Höffner"),
        ("hoeffner", "Höffner"),
        ("hoffner", "Höffner"),
        ("segmüller", "Segmüller"),
        ("segmueller", "Segmüller"),
        ("segmuller", "Segmüller"),
        ("poco", "Poco"),
        ("roller", "Roller"),
        ("jysk", "JYSK"),
        ("daenisches bettenlager", "Daenisches Bettenlager"),
        ("dänisches bettenlager", "Daenisches Bettenlager"),
        ("danisches bettenlager", "Daenisches Bettenlager"),
        ("sb-moebel boss", "SB-Moebel Boss"),
        ("sb-möbel boss", "SB-Moebel Boss"),
        ("sb-mobel boss", "SB-Moebel Boss"),
        ("moebel hardeck", "Moebel Hardeck"),
        ("möbel hardeck", "Moebel Hardeck"),
        ("moebel kraft", "Moebel Kraft"),
        ("möbel kraft", "Moebel Kraft"),
        ("moebel martin", "Moebel Martin"),
        ("möbel martin", "Moebel Martin"),
        ("moemax", "Moemax"),
        ("mömax", "Moemax"),
        ("porta moebel", "Porta Moebel"),
        ("porta möbel", "Porta Moebel"),
        ("porta mobel", "Porta Moebel"),
        ("dehner", "Dehner"),
        ("westwing", "Westwing"),
        ("maisons du monde", "Maisons du Monde"),

        // Mode / Schuhe / Accessoires
        ("h&m", "H&M"),
        ("zara", "Zara"),
        ("primark", "Primark"),
        ("deichmann", "Deichmann"),
        ("c&a", "C&A"),
        ("kik", "KiK"),
        ("new yorker", "New Yorker"),
        ("nkd", "NKD"),
        ("takko fashion", "Takko Fashion"),
        ("takko", "Takko Fashion"),
        ("ernstings family", "Ernstings Family"),
        ("ernsting's family", "Ernstings Family"),
        ("peek & cloppenburg", "Peek & Cloppenburg"),
        ("peek und cloppenburg", "Peek & Cloppenburg"),
        ("breuninger", "Breuninger"),
        ("galeria karstadt", "Galeria"),
        ("galeria", "Galeria"),
        ("woolworth", "Woolworth"),
        ("tedi", "Tedi"),
        ("adidas", "Adidas"),
        ("nike", "Nike"),
        ("puma", "Puma"),
        ("gucci", "Gucci"),
        ("mango", "Mango"),
        ("sheego", "Sheego"),
        ("ulla popken", "Ulla Popken"),
        ("trigema", "Trigema"),
        ("snipes", "Snipes"),
        ("bonprix", "Bonprix"),
        ("madeleine", "Madeleine"),
        ("net-a-porter", "Net-a-Porter"),
        ("net a porter", "Net-a-Porter"),
        ("calida", "Calida"),

        // Online / E-Commerce
        ("kindle unlimited", "Kindle Unlimited"),
        ("kindle", "Kindle"),
        ("amazon music", "Amazon Music"),
        ("amazon", "Amazon"),
        ("zalando", "Zalando"),
        ("about you", "About You"),
        ("aboutyou", "About You"),
        ("otto", "Otto"),
        ("baur", "Baur"),
        ("flaconi", "Flaconi"),
        ("spreadshirt", "Spreadshirt"),
        ("swarovski", "Swarovski"),
        ("hugendubel", "Hugendubel"),
        ("yves rocher", "Yves Rocher"),
        ("yves-rocher", "Yves Rocher"),
        ("amorelie", "Amorelie"),
        ("momox fashion", "Momox Fashion"),
        ("momox", "Momox"),
        ("contorion", "Contorion"),
        ("ebay", "eBay"),
        ("etsy", "Etsy"),

        // Sport / Freizeit
        ("intersport", "Intersport"),
        ("decathlon", "Decathlon"),
        ("sport 2000", "Sport 2000"),
        ("fressnapf", "Fressnapf"),
        ("das futterhaus", "Das Futterhaus"),
        ("thalia", "Thalia"),
        ("vedes", "Vedes"),
        ("weight watchers", "Weight Watchers"),

        // Streaming / Video (spezifisch vor generisch)
        ("apple music", "Apple Music"),
        ("apple tv+", "Apple TV+"),
        ("apple tv", "Apple TV"),
        ("apple arcade", "Apple Arcade"),
        ("apple icloud", "iCloud"),
        ("icloud", "iCloud"),
        ("apple services", "Apple Services"),
        ("apple", "Apple"),
        ("netflix", "Netflix"),
        ("disney+", "Disney+"),
        ("disney plus", "Disney+"),
        ("rtl+", "RTL+"),
        ("rtl plus", "RTL+"),
        ("dazn", "DAZN"),
        ("wow / sky", "WOW"),
        ("wowtv", "WOW"),
        ("waipu", "Waipu.tv"),
        ("magentatv", "MagentaTV"),
        ("magenta tv", "MagentaTV"),
        ("joyn plus", "Joyn"),
        ("joyn", "Joyn"),
        ("paramount+", "Paramount+"),
        ("paramount plus", "Paramount+"),
        ("zattoo", "Zattoo"),
        ("viaplay", "Viaplay"),
        ("hbo max", "Max"),
        ("crunchyroll", "Crunchyroll"),
        ("discovery+", "Discovery+"),
        ("curiositystream", "CuriosityStream"),
        ("sky", "Sky"),

        // Musik-Streaming
        ("spotify", "Spotify"),
        ("deezer", "Deezer"),
        ("tidal", "Tidal"),
        ("soundcloud", "SoundCloud"),
        ("qobuz", "Qobuz"),
        ("napster", "Napster"),
        ("youtube music", "YouTube Music"),
        ("youtube", "YouTube"),

        // Gaming
        ("xbox game pass", "Xbox Game Pass"),
        ("xbox", "Xbox"),
        ("playstation plus", "PlayStation Plus"),
        ("playstation", "PlayStation"),
        ("nintendo switch online", "Nintendo Switch Online"),
        ("nintendo", "Nintendo"),
        ("ubisoft+", "Ubisoft+"),
        ("ubisoft", "Ubisoft"),
        ("ea play", "EA Play"),
        ("geforce now", "GeForce Now"),
        ("humble choice", "Humble Choice"),
        ("humble", "Humble"),

        // Cloud / Software
        ("adobe creative cloud", "Adobe"),
        ("adobe", "Adobe"),
        ("dropbox", "Dropbox"),
        ("nordvpn", "NordVPN"),
        ("google one", "Google One"),
        ("google", "Google"),

        // Nachrichten
        ("spiegel+", "Spiegel+"),
        ("spiegel plus", "Spiegel+"),
        ("bild+", "Bild+"),
        ("bild plus", "Bild+"),
        ("welt+", "Welt+"),
        ("faz+", "FAZ+"),
        ("faz plus", "FAZ+"),

        // Fitness / Wellness
        ("peloton", "Peloton"),
        ("freeletics", "Freeletics"),
        ("urban sports club", "Urban Sports Club"),
        ("mcfit", "McFit"),
        ("fitness first", "Fitness First"),
        ("clever fit", "Clever Fit"),
        ("calm", "Calm"),
        ("headspace", "Headspace"),

        // Bücher / Bildung
        ("audible", "Audible"),
        ("storytel", "Storytel"),
        ("scribd", "Scribd"),
        ("duolingo", "Duolingo"),

        // Food / Delivery
        ("lieferando", "Lieferando"),
        ("hellofresh", "HelloFresh"),
        ("hello fresh", "HelloFresh"),
        ("wolt", "Wolt"),
        ("mcdonald", "McDonalds"),
        ("starbucks", "Starbucks"),
        ("uber eats", "Uber Eats"),
        ("uber", "Uber"),
        ("glossybox", "Glossybox"),

        // Telko
        ("telekom", "Telekom"),
        ("vodafone", "Vodafone"),
        ("o2", "O2"),
        ("1&1", "1&1"),
        ("congstar", "Congstar"),
        ("freenet", "Freenet"),
        ("mobilcom", "Mobilcom"),

        // Logistik / Transport
        ("deutsche bahn", "Deutsche Bahn"),
        ("db vertrieb", "Deutsche Bahn"),
        ("db fernverkehr", "Deutsche Bahn"),
        ("bahn.de", "Deutsche Bahn"),
        ("deutsche post", "Deutsche Post"),
        ("dhl", "DHL"),
        ("dpd", "DPD"),
        ("fedex", "FedEx"),
        ("hermes", "Hermes"),
        ("ups", "UPS"),

        // Marktplätze / Anzeigen
        ("kleinanzeigen", "Kleinanzeigen"),
        ("ebay kleinanzeigen", "Kleinanzeigen"),
        ("ebay-kleinanzeigen", "Kleinanzeigen"),

        // Medien / TV
        ("hd plus", "HD+"),
        ("hd+", "HD+"),
        ("hdplus", "HD+"),

        // Fintech / Zahlung
        ("paypal", "PayPal"),
        ("klarna", "Klarna"),
        ("wise", "Wise"),

        // Big Tech / SaaS
        ("anthropic", "Anthropic"),
        ("claude.ai", "Claude"),
        ("claude", "Claude"),
        ("openai", "OpenAI"),
        ("chatgpt", "OpenAI"),
        ("formspree", "Formspree"),

        // Gesundheit / Kassen
        ("barmer", "Barmer"),
        ("aok", "AOK"),
        ("dak", "DAK"),
        ("rundfunkbeitrag", "Rundfunkbeitrag"),
        ("adac", "ADAC"),

        // Versicherungen
        ("allianz", "Allianz"),
        ("axa", "AXA"),
        ("debeka", "Debeka"),
        ("devk", "DEVK"),
        ("ergo versicherung", "Ergo"),
        ("ergo direkt", "Ergo"),
        ("ergo", "Ergo"),
        ("generali", "Generali"),
        ("gothaer", "Gothaer"),
        ("hallesche", "Hallesche"),
        ("hanse merkur", "HanseMerkur"),
        ("hansemerkur", "HanseMerkur"),
        ("hdi versicherung", "HDI"),
        ("hdi lebensversicherung", "HDI"),
        ("hdi", "HDI"),
        ("huk-coburg", "HUK-Coburg"),
        ("huk coburg", "HUK-Coburg"),
        ("huk ", "HUK-Coburg"),
        ("lvm versicherung", "LVM"),
        ("lvm ", "LVM"),
        ("munichener ruck", "Munich Re"),
        ("munich re", "Munich Re"),
        ("nurnberger versicherung", "Nürnberger"),
        ("nuernberger versicherung", "Nürnberger"),
        ("nürnberger versicherung", "Nürnberger"),
        ("provinzial", "Provinzial"),
        ("r+v versicherung", "R+V"),
        ("r+v lebensversicherung", "R+V"),
        ("ruv versicherung", "R+V"),
        ("signal iduna", "Signal Iduna"),
        ("signal-iduna", "Signal Iduna"),
        ("sv sparkassenversicherung", "SV SparkassenVersicherung"),
        ("sv versicherung", "SV SparkassenVersicherung"),
        ("talanx", "Talanx"),
        ("versicherungskammer", "Versicherungskammer Bayern"),
        ("vgh versicherungen", "VGH"),
        ("vgh ", "VGH"),
        ("vhv versicherung", "VHV"),
        ("vhv allgemeine", "VHV"),
        ("vhv ", "VHV"),
        ("alte leipziger", "Alte Leipziger"),
        ("alte-leipziger", "Alte Leipziger"),
        ("arag versicherung", "ARAG"),
        ("arag", "ARAG"),
        ("bayerische versicherung", "Die Bayerische"),
        ("die bayerische", "Die Bayerische"),
        ("continentale", "Continentale"),
        ("wuestenrot", "Wüstenrot"),
        ("wüstenrot", "Wüstenrot"),
        ("württembergische", "Württembergische"),
        ("wurttembergische", "Württembergische"),
        ("zurich versicherung", "Zurich"),
        ("zurich insurance", "Zurich"),
        ("zurich gruppe", "Zurich"),

        // Tankstellen
        ("aral", "Aral"),
        ("shell", "Shell"),
        ("esso", "Esso"),
        ("hem tankstell", "HEM"),
        ("hem ", "HEM"),
        ("avia tankstell", "Avia"),
        ("avia ", "Avia"),
        ("jet tankstell", "JET"),
        ("jet ", "JET"),
        ("totalenergies", "Total Energies"),
        ("total tankstell", "Total Energies"),
        ("tamoil", "Tamoil"),

        // Sonstiges
        ("parship", "Parship"),
    ]

    private static let legalFormCanonical: [String: String] = [
        "AG": "AG",
        "GMBH": "GmbH",
        "SE": "SE",
        "KG": "KG",
        "UG": "UG",
        "OHG": "OHG",
        "NV": "N.V.",
        "AB": "AB",
        "SARL": "S.A.R.L.",
        "SCA": "S.C.A.",
        "SA": "S.A.",
    ]

    private static var isPipelineEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: pipelineEnabledKey) == nil {
            return true
        }
        return defaults.bool(forKey: pipelineEnabledKey)
    }

    // MARK: - Public Rule API

    static func userRules() -> [MerchantUserRule] {
        loadRules()
    }

    @discardableResult
    static func saveRule(
        pattern: String,
        merchant: String,
        scope: MerchantUserRule.MatchScope = .searchText,
        matchType: MerchantUserRule.MatchType = .contains,
        priority: Int = 100
    ) -> MerchantUserRule? {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMerchant = (cleanMerchantName(merchant) ?? merchant).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty, !normalizedMerchant.isEmpty else {
            return nil
        }

        var rules = userRules()
        let now = Date()
        let rule = MerchantUserRule(
            id: UUID(),
            enabled: true,
            priority: priority,
            matchScope: scope,
            matchType: matchType,
            pattern: normalizedPattern,
            merchant: normalizedMerchant,
            createdAt: now,
            updatedAt: now
        )
        rules.append(rule)
        persistRules(rules)
        return rule
    }

    /// Override-Storage seit Migration v19 mit Composite-Key `slotId|txID` —
    /// derselbe Fingerprint kann in mehreren Slots existieren, manueller
    /// Merchant-Override darf nicht slot-übergreifend leaken. Legacy-Einträge
    /// (nur txID) werden im Read-Path noch gefunden, beim nächsten Save
    /// migriert.
    static func saveOverride(txID: String, slotId: String = TransactionsDatabase.activeSlotId,
                             merchant: String) {
        let key = compositeOverrideKey(slotId: slotId, txID: txID)
        let normalizedMerchant = (cleanMerchantName(merchant) ?? merchant).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        var overrides = transactionOverrides()
        let legacy = legacyOverrideKey(txID: txID)
        if normalizedMerchant.isEmpty {
            overrides.removeValue(forKey: key)
            if !legacy.isEmpty { overrides.removeValue(forKey: legacy) }
        } else {
            overrides[key] = normalizedMerchant
            // Legacy-Eintrag aufräumen, falls vorhanden — vermeidet Drift.
            if !legacy.isEmpty { overrides.removeValue(forKey: legacy) }
        }
        persistOverrides(overrides)
    }

    static func hasOverride(txID: String,
                            slotId: String = TransactionsDatabase.activeSlotId) -> Bool {
        overrideForTransaction(txID: txID, slotId: slotId) != nil
    }

    @discardableResult
    static func removeOverride(txID: String,
                               slotId: String = TransactionsDatabase.activeSlotId) -> Bool {
        let composite = compositeOverrideKey(slotId: slotId, txID: txID)
        let legacy = legacyOverrideKey(txID: txID)
        guard !composite.isEmpty || !legacy.isEmpty else { return false }
        var overrides = transactionOverrides()
        var removed = false
        if !composite.isEmpty, overrides.removeValue(forKey: composite) != nil { removed = true }
        if !legacy.isEmpty, overrides.removeValue(forKey: legacy) != nil { removed = true }
        persistOverrides(overrides)
        return removed
    }

    /// Internal lookup helper — composite-Key bevorzugt, legacy-Key fallback.
    static func overrideForTransaction(txID: String,
                                       slotId: String = TransactionsDatabase.activeSlotId) -> String? {
        let overrides = transactionOverrides()
        let composite = compositeOverrideKey(slotId: slotId, txID: txID)
        if !composite.isEmpty,
           let merchant = overrides[composite],
           !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return merchant
        }
        let legacy = legacyOverrideKey(txID: txID)
        if !legacy.isEmpty,
           let merchant = overrides[legacy],
           !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return merchant
        }
        return nil
    }

    private static func compositeOverrideKey(slotId: String, txID: String) -> String {
        let sid = slotId.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tid = txID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty, !tid.isEmpty else { return "" }
        return "\(sid)|\(tid)"
    }

    private static func legacyOverrideKey(txID: String) -> String {
        txID.lowercased()
    }

    @discardableResult
    static func removeRule(id: UUID) -> Bool {
        var rules = userRules()
        let before = rules.count
        rules.removeAll { $0.id == id }
        guard rules.count != before else { return false }
        persistRules(rules)
        return true
    }

    static func firstMatchingRule(
        empfaenger: String?,
        absender: String?,
        verwendungszweck: String?,
        additionalInformation: String?
    ) -> MerchantUserRule? {
        firstMatchingEnabledUserRule(
            empfaenger: empfaenger,
            verwendungszweck: verwendungszweck,
            additionalInformation: additionalInformation,
            absender: absender
        )
    }

    static func transactionOverrides() -> [String: String] {
        loadOverrides()
    }

    static func suggestedRulePattern(for transaction: TransactionsResponse.Transaction) -> String {
        let remittance = clean((transaction.remittanceInformation ?? []).joined(separator: " ")) ?? ""
        if let merchant = firstCapture(in: remittance, pattern: "(?i)ihr\\s+einkauf\\s+bei\\s+(.+)$") {
            return normalizeForSearch(merchant)
        }
        if let merchant = firstCapture(in: remittance, pattern: "(?i)purchase\\s+at\\s+(.+)$") {
            return normalizeForSearch(merchant)
        }
        return ""
    }

    // MARK: - Resolution

    static func resolve(transaction: TransactionsResponse.Transaction) -> MerchantResolution {
        let remittance = (transaction.remittanceInformation ?? []).joined(separator: " ")
        let txID = TransactionRecord.fingerprint(for: transaction)
        return resolve(
            txID: txID,
            // transaction.slotId ist von DB-load gesetzt (unified-mode), sonst nil
            // → fallback auf activeSlotId. Beides gibt slot-korrekten Override-Lookup.
            slotId: transaction.slotId ?? TransactionsDatabase.activeSlotId,
            empfaenger: transaction.creditor?.name,
            absender: transaction.debtor?.name,
            verwendungszweck: remittance,
            additionalInformation: transaction.additionalInformation
        )
    }

    static func resolve(
        txID: String? = nil,
        slotId: String = TransactionsDatabase.activeSlotId,
        empfaenger: String?,
        absender: String?,
        verwendungszweck: String?,
        additionalInformation: String?
    ) -> MerchantResolution {
        let payee = clean(empfaenger)
        let payer = clean(absender)
        let purpose = clean(verwendungszweck)
        let additional = clean(additionalInformation)
        let payeeLower = payee?.lowercased() ?? ""

        if let txID,
           let overrideMerchant = overrideForTransaction(txID: txID, slotId: slotId) {
            return makeResolution(merchant: overrideMerchant, source: "tx_override", confidence: 1.0)
        }

        if !isPipelineEnabled {
            if let payee, !payee.isEmpty {
                return makeResolution(merchant: payee, source: "pipeline_disabled_empfaenger", confidence: 0.85)
            }
            if let payer, !payer.isEmpty {
                return makeResolution(merchant: payer, source: "pipeline_disabled_absender", confidence: 0.7)
            }
            return makeResolution(merchant: unknownMerchant, source: "pipeline_disabled_unknown", confidence: 0.1)
        }

        if let userRule = firstMatchingEnabledUserRule(
            empfaenger: payee,
            verwendungszweck: purpose,
            additionalInformation: additional,
            absender: payer
        ) {
            return makeResolution(merchant: userRule.merchant, source: "user_rule", confidence: 0.99)
        }

        if isCashWithdrawal(payee: payeeLower, purpose: purpose, additionalInformation: additional) {
            return makeResolution(merchant: cashMerchant, source: "cash_pattern", confidence: 0.98)
        }

        if payeeLower.contains("paypal") {
            if let extracted = extractPayPalMerchant(from: purpose) ?? extractPayPalMerchant(from: additional) {
                return makeResolution(merchant: extracted, source: "paypal_purpose", confidence: 0.95)
            }
            return makeResolution(merchant: "PayPal (Intermediaer)", source: "paypal_intermediary", confidence: 0.45)
        }

        if payeeLower.contains("klarna") {
            if let extracted = extractKlarnaMerchant(from: purpose) ?? extractKlarnaMerchant(from: additional) {
                return makeResolution(merchant: extracted, source: "klarna_purpose", confidence: 0.95)
            }
            return makeResolution(merchant: "Klarna (Intermediaer)", source: "klarna_intermediary", confidence: 0.45)
        }

        if cardProcessorTokens.contains(where: payeeLower.contains) {
            if let extracted = extractCardProcessorMerchant(from: purpose) ?? extractCardProcessorMerchant(from: additional) {
                return makeResolution(merchant: extracted, source: "card_processor_purpose", confidence: 0.75)
            }
            return makeResolution(merchant: cardIntermediaryMerchant, source: "card_processor_intermediary", confidence: 0.35)
        }

        // ABWA structured format — check remittance before falling back to raw payee name,
        // because some banks use terminal IDs (e.g. "Debitk.1 2028-12") as the creditor name.
        if let abwaMerchant = extractABWAMerchant(from: purpose) ?? extractABWAMerchant(from: additional) {
            return makeResolution(merchant: abwaMerchant, source: "abwa_format", confidence: 0.88)
        }

        if let payee, !payee.isEmpty {
            return makeResolution(merchant: payee, source: "empfaenger", confidence: 0.9)
        }

        if let payer, !payer.isEmpty {
            return makeResolution(merchant: payer, source: "absender", confidence: 0.75)
        }

        if let inferred = extractGenericMerchant(from: purpose) ?? extractGenericMerchant(from: additional) {
            return makeResolution(merchant: inferred, source: "purpose_inferred", confidence: 0.6)
        }

        return makeResolution(merchant: unknownMerchant, source: "unknown", confidence: 0.1)
    }

    static func buildSearchText(
        effectiveMerchant: String,
        normalizedMerchant: String,
        empfaenger: String?,
        absender: String?,
        verwendungszweck: String?,
        additionalInformation: String?,
        iban: String?
    ) -> String {
        let values: [String] = [
            effectiveMerchant,
            normalizedMerchant,
            clean(empfaenger) ?? "",
            clean(absender) ?? "",
            clean(verwendungszweck) ?? "",
            clean(additionalInformation) ?? "",
            clean(iban) ?? "",
        ]

        return values
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    // MARK: - Internal

    private static func persistRules(_ rules: [MerchantUserRule]) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: rulesStorageKey)
        }
    }

    private static func persistOverrides(_ overrides: [String: String]) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: overridesStorageKey)
        }
    }

    private static func loadRules() -> [MerchantUserRule] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: rulesStorageKey),
              let decoded = try? JSONDecoder().decode([MerchantUserRule].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private static func loadOverrides() -> [String: String] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: overridesStorageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private static func firstMatchingEnabledUserRule(
        empfaenger: String?,
        verwendungszweck: String?,
        additionalInformation: String?,
        absender: String?
    ) -> MerchantUserRule? {
        let rules = userRules()
            .filter { $0.enabled }
            .sorted {
                if $0.priority == $1.priority {
                    return $0.createdAt < $1.createdAt
                }
                return $0.priority < $1.priority
            }

        guard !rules.isEmpty else { return nil }

        let searchRaw = [empfaenger, absender, verwendungszweck, additionalInformation]
            .compactMap(clean)
            .joined(separator: " ")
        let searchNormalized = normalizeForSearch(searchRaw)
        let payeeRaw = empfaenger ?? ""
        let payeeNormalized = normalizeForSearch(payeeRaw)
        let purposeRaw = [verwendungszweck, additionalInformation].compactMap(clean).joined(separator: " ")
        let purposeNormalized = normalizeForSearch(purposeRaw)

        for rule in rules {
            let targetRaw: String
            let targetNormalized: String
            switch rule.matchScope {
            case .searchText:
                targetRaw = searchRaw
                targetNormalized = searchNormalized
            case .empfaenger:
                targetRaw = payeeRaw
                targetNormalized = payeeNormalized
            case .verwendungszweck:
                targetRaw = purposeRaw
                targetNormalized = purposeNormalized
            }

            if ruleMatches(rule: rule, normalizedTarget: targetNormalized, rawTarget: targetRaw) {
                return rule
            }
        }

        return nil
    }

    private static func ruleMatches(rule: MerchantUserRule, normalizedTarget: String, rawTarget: String) -> Bool {
        let trimmedPattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return false }

        switch rule.matchType {
        case .contains:
            let p = normalizeForSearch(trimmedPattern)
            return !p.isEmpty && normalizedTarget.contains(p)
        case .equals:
            let p = normalizeForSearch(trimmedPattern)
            return !p.isEmpty && normalizedTarget == p
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: trimmedPattern, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(rawTarget.startIndex..<rawTarget.endIndex, in: rawTarget)
            return regex.firstMatch(in: rawTarget, options: [], range: range) != nil
        }
    }

    private static func makeResolution(merchant: String, source: String, confidence: Double) -> MerchantResolution {
        let cleaned = cleanMerchantName(merchant) ?? unknownMerchant
        let canonical = canonicalMerchant(for: cleaned)
        return MerchantResolution(
            effectiveMerchant: canonical,
            normalizedMerchant: normalizeForSearch(canonical),
            source: source,
            confidence: confidence
        )
    }

    private static func extractPayPalMerchant(from text: String?) -> String? {
        guard let text else { return nil }

        if let merchant = firstCapture(in: text, pattern: "(?i)ihr\\s+einkauf\\s+bei\\s+(.+)$") {
            return cleanMerchantName(merchant)
        }
        if let merchant = firstCapture(in: text, pattern: "(?i)/\\.\\s*([^,;/]{2,120})\\s*,\\s*ihr\\s+einkauf\\s+bei") {
            return cleanMerchantName(merchant)
        }
        if let merchant = firstCapture(in: text, pattern: "(?i)purchase\\s+at\\s+(.+)$") {
            return cleanMerchantName(merchant)
        }
        if let merchant = firstCapture(in: text, pattern: "(?i)paypal\\s*[\\*:\\-]?\\s*([^,;/]{2,100})") {
            return cleanMerchantName(merchant)
        }
        return nil
    }

    private static func extractKlarnaMerchant(from text: String?) -> String? {
        guard let text else { return nil }

        if let merchant = firstCapture(in: text, pattern: "(?i)purchase\\s+at\\s+(.+)$") {
            return cleanMerchantName(merchant)
        }
        if let merchant = firstCapture(in: text, pattern: "(?i)klarna\\s*[\\*:\\-]?\\s*([^,;/]{2,100})") {
            return cleanMerchantName(merchant)
        }
        return nil
    }

    private static func extractCardProcessorMerchant(from text: String?) -> String? {
        guard let text else { return nil }

        if text.lowercased().contains("zahl.system") || text.lowercased().contains("debitmastercard") {
            return nil
        }
        if let merchant = firstCapture(in: text, pattern: "(?i)purchase\\s+at\\s+(.+)$") {
            return cleanMerchantName(merchant)
        }
        if let merchant = firstCapture(in: text, pattern: "(?i)ihr\\s+einkauf\\s+bei\\s+(.+)$") {
            return cleanMerchantName(merchant)
        }
        return nil
    }

    private static func extractABWAMerchant(from text: String?) -> String? {
        guard let text else { return nil }
        // ISO 20022 ABWA structured format used in card transactions by some German banks:
        // e.g. "ABWA+CRV.Cafeteria Jung Sti/Street/City/Country/PostalCode"
        // Captures the merchant name between the dot and the first slash.
        if let merchant = firstCapture(in: text, pattern: "ABWA\\+[A-Z0-9]+\\.([^/\\n]{2,80})/") {
            return cleanMerchantName(merchant)
        }
        return nil
    }

    private static func extractGenericMerchant(from text: String?) -> String? {
        guard let text else { return nil }
        if let merchant = firstCapture(in: text, pattern: "(?i)(?:purchase\\s+at|einkauf\\s+bei|zahlung\\s+an)\\s+(.+)$") {
            return cleanMerchantName(merchant)
        }
        return nil
    }

    private static func isCashWithdrawal(payee: String, purpose: String?, additionalInformation: String?) -> Bool {
        if payee.contains("ga nr") || payee.hasPrefix("f0") {
            return true
        }
        let purposeLower = (purpose ?? "").lowercased()
        let additionalLower = (additionalInformation ?? "").lowercased()
        return purposeLower.contains("bargeldausz")
            || purposeLower.contains("geldautomat")
            || additionalLower.contains("barauszahl")
    }

    private static func canonicalMerchant(for merchant: String) -> String {
        let lower = merchant.lowercased()
        for alias in merchantAliases where lower.contains(alias.needle) {
            return alias.canonical
        }
        return merchant
    }

    private static func cleanMerchantName(_ value: String?) -> String? {
        guard let value else { return nil }

        var result = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r,.;:!?/\\|-_()[]{}"))
        let originalLower = result.lowercased()

        let stripLeadingPatterns = [
            "^(?i)crv\\*\\s*",
            "^(?i)pp\\.\\d+\\.pp/\\.\\s*",
            "^(?i)paypal\\*\\s*",
            "^(?i)klarna\\*\\s*",
        ]
        for pattern in stripLeadingPatterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        if let merchant = firstCapture(in: result, pattern: "(?i)ihr\\s+einkauf\\s+bei\\s+(.+)$") {
            result = merchant
        } else if let merchant = firstCapture(in: result, pattern: "(?i)purchase\\s+at\\s+(.+)$") {
            result = merchant
        }

        let cutMarkers = [
            " zahl.system",
            " debitmastercard",
            " debitk.",
            " pp.",
            " /pp",
        ]
        let lower = result.lowercased()
        for marker in cutMarkers {
            if let range = lower.range(of: marker) {
                result = String(result[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r,.;:!?/\\|-_()[]{}"))
                break
            }
        }

        if originalLower.contains("crv*"),
           let merchantOnly = firstCapture(in: result, pattern: "^(?i)(.+?)(?:\\s+\\d{4,}.*)$") {
            result = merchantOnly
        }

        if result.isEmpty {
            return nil
        }
        if result == "...................." ||
            result.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        result = normalizeDisplayCasing(result)
        return result.isEmpty ? nil : result
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalizeForSearch(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeDisplayCasing(_ value: String) -> String {
        let parts = value
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { normalizeWordCasing(String($0)) }

        return parts.joined(separator: " ")
    }

    private static func normalizeWordCasing(_ word: String) -> String {
        guard !word.isEmpty else { return word }

        let simplified = word.uppercased().replacingOccurrences(of: ".", with: "")
        if let legal = legalFormCanonical[simplified] {
            return legal
        }

        if word.contains(where: \.isNumber) {
            return word
        }

        let isUpper = word == word.uppercased()
        let isLower = word == word.lowercased()
        guard isUpper || isLower else {
            return word
        }

        let lower = word.lowercased()
        guard let first = lower.first else { return lower }
        return String(first).uppercased() + lower.dropFirst()
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }
}
