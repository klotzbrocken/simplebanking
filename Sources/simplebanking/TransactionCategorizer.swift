import Foundation

/// Eine Kategorie: eine der 14 eingebauten oder eine selbst angelegte.
///
/// War bis 2.1.0 ein `enum` — und damit vom Nutzer nicht erweiterbar. Jetzt eine
/// Struktur, deren eingebaute Werte dieselben `rawValue`s tragen wie die alten Fälle.
/// Das ist kein Umbau, sondern die Öffnung eines geschlossenen Typs: Die Kategorie ist
/// an **jeder** Speicherstelle längst eine Zeichenkette (Datenbank-Spalte `kategorie`,
/// Override in den UserDefaults, `setCategory` einer Regel), nur im Programm war sie
/// geschlossen. Siehe `Eigenkategorien`.
///
/// Zwei Dinge, die beim Ändern hier zu beachten sind:
/// - `switch` über `.einkommen` funktioniert weiter (Ausdrucksmuster über `Equatable`),
///   braucht aber ein `default` — eine Struktur kennt keine Vollständigkeit. Genau das
///   ist der Preis: Wer eine neue eingebaute Kategorie ergänzt, bekommt **keinen**
///   Compilerfehler an den Stellen, die sie behandeln müssten. Die drei Stellen mit
///   fester Zuordnung sind `icon`, `BTXMosaic.style(for:)` und `categoryEmoji`.
/// - `Codable` ist von Hand geschrieben und kodiert **einen nackten String**, genau wie
///   das `enum` vorher. Eine synthetisierte Fassung schriebe `{"rawValue": …}` — und
///   damit wäre die Kategorie jeder gespeicherten Zuordnungsregel still verloren.
struct TransactionCategory: Hashable, Codable, CaseIterable, Sendable {

    /// Identität **und** Speicherform.
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    // MARK: - Die eingebauten

    static let einkommen      = TransactionCategory(rawValue: "Einkommen")
    static let essenAlltag    = TransactionCategory(rawValue: "Essen & Alltag")
    static let abosDigital    = TransactionCategory(rawValue: "Abos & Digital")
    static let shopping       = TransactionCategory(rawValue: "Shopping")
    static let versicherungen = TransactionCategory(rawValue: "Versicherungen")
    static let mobilitaet     = TransactionCategory(rawValue: "Mobilitaet")
    static let wohnenKredit   = TransactionCategory(rawValue: "Wohnen & Kredit")
    static let sonstiges      = TransactionCategory(rawValue: "Sonstiges")
    // Kategorien, die die KI-Zuordnung mitbringt
    static let gastronomie    = TransactionCategory(rawValue: "Gastronomie")
    static let sparen         = TransactionCategory(rawValue: "Sparen")
    static let freizeit       = TransactionCategory(rawValue: "Freizeit")
    static let gehalt         = TransactionCategory(rawValue: "Gehalt")
    static let gesundheit     = TransactionCategory(rawValue: "Gesundheit")
    static let umbuchung      = TransactionCategory(rawValue: "Umbuchungen")

    static let eingebaute: [TransactionCategory] = [
        .einkommen, .essenAlltag, .abosDigital, .shopping, .versicherungen,
        .mobilitaet, .wohnenKredit, .sonstiges, .gastronomie, .sparen,
        .freizeit, .gehalt, .gesundheit, .umbuchung
    ]

    /// Eingebaute zuerst, dann die eigenen — das ist die Reihenfolge jedes Auswahlmenüs.
    static var allCases: [TransactionCategory] {
        eingebaute + Eigenkategorien.alle.map { TransactionCategory(rawValue: $0.name) }
    }

    var istEigene: Bool { !Self.eingebaute.contains(self) }

    /// Gibt es diese Kategorie noch?
    ///
    /// Eine gelöschte eigene Kategorie kann in einer Zuordnungsregel oder in einem
    /// Override stehen bleiben. Zugeordnet werden darf sie dann nicht mehr — sonst
    /// zeigte die Umsatzliste eine Kategorie, die in keinem Auswahlmenü vorkommt.
    var istBekannt: Bool {
        !istEigene || Eigenkategorien.alle.contains { $0.name == rawValue }
    }

    /// Der Name ab Werk. Bleibt als Vergleichsform erhalten, auch wenn der Nutzer die
    /// Kategorie umbenennt — sonst fände `from(displayName:)` eine schon gespeicherte
    /// „Mobilität" nicht mehr.
    var werkseitigerName: String {
        self == .mobilitaet ? "Mobilität" : rawValue
    }

    var displayName: String {
        if istEigene { return rawValue }
        return Eigenkategorien.umbenennungen[rawValue] ?? werkseitigerName
    }

    var istUmbenannt: Bool {
        !istEigene && Eigenkategorien.umbenennungen[rawValue] != nil
    }

    var icon: String {
        if istEigene { return Eigenkategorien.symbol(fuer: rawValue) ?? "tag" }
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
        default:             return "tag"
        }
    }

    // MARK: - Speicherform

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var behaelter = encoder.singleValueContainer()
        try behaelter.encode(rawValue)
    }

    // MARK: - Aus Text

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
        // Eine eigene Kategorie trägt keinen technischen Schlüssel — die KI bekommt
        // ihren Namen und schickt ihn zurück.
        default:               return from(displayName: jsonKey)
        }
    }

    /// Findet die Kategorie zu einer gespeicherten Bezeichnung.
    ///
    /// Geprüft werden `rawValue`, werkseitiger Name **und** der aktuelle Anzeigename:
    /// In der Datenbank können Bezeichnungen aus allen drei Zuständen liegen, weil sie
    /// beim Schreiben jeweils aktuell war.
    static func from(displayName: String) -> TransactionCategory? {
        let ziel = Kategorienamen.normalisiert(displayName)
        guard !ziel.isEmpty else { return nil }
        for kategorie in allCases {
            if Kategorienamen.normalisiert(kategorie.rawValue) == ziel
                || Kategorienamen.normalisiert(kategorie.werkseitigerName) == ziel
                || Kategorienamen.normalisiert(kategorie.displayName) == ziel {
                return kategorie
            }
        }
        return nil
    }
}


enum TransactionCategorizer {
    static let overridesStorageKey = "transactionCategoryOverrides"

    /// Im Testlauf eine Wegwerf-Domain statt der echten — dasselbe Muster wie bei
    /// `Eigenkategorien.defaults` und `MultibankingStore.defaults`. Bis hierher lief
    /// jeder Test, der einen Override schreibt, in die echten Zuordnungen des
    /// Nutzers; gemerkt hätte man es erst an einer Buchung, die plötzlich in der
    /// falschen Kategorie steht.
    /// `nonisolated(unsafe)`, weil dieser Laden aus jedem Faden gelesen wird und
    /// `UserDefaults` selbst fadensicher ist — nur der Compiler weiß das nicht.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let name = "simplebanking.tests.zuordnungen"
        if NSClassFromString("XCTestCase") != nil, let sandkasten = UserDefaults(suiteName: name) {
            sandkasten.removePersistentDomain(forName: name)
            return sandkasten
        }
        return .standard
    }()

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
        /// Deutsche Wortstämme — Treffer am Wortanfang genügt, damit Komposita greifen
        /// („versicherung" → „Versicherungsbeitrag", „miete" → „Mietvertrag").
        let generic: [String]
        /// Markennamen — nur als ganzes Wort. Marken stehen im Verwendungszweck
        /// immer als eigenes Token, nie als Wortbestandteil.
        let merchants: [String]

        init(category: TransactionCategory, generic: [String], merchants: [String] = []) {
            self.category = category
            self.generic = generic
            self.merchants = merchants
        }

        /// Fallback-Regeln (ohne generic/merchant-Trennung) behalten das Wortstamm-Verhalten.
        init(category: TransactionCategory, keywords: [String]) {
            self.init(category: category, generic: keywords)
        }

        func matches(haystack: String) -> Bool {
            for keyword in generic where !keyword.isEmpty {
                // Kurze Stämme sind Abkürzungen, keine Kompositum-Wurzeln („gas", „kfz",
                // „auto", „abo") — sie brauchen dieselbe volle Wortgrenze wie Marken,
                // sonst wird „Gaststätte" zu Energiekosten und „automatisch" zu Mobilität.
                let hit = keyword.count <= 4
                    ? TransactionCategorizer.matchesAsWord(haystack, keyword)
                    : TransactionCategorizer.matchesAtWordStart(haystack, keyword)
                if hit { return true }
            }
            for keyword in merchants where !keyword.isEmpty {
                if TransactionCategorizer.matchesAsWord(haystack, keyword) { return true }
            }
            return false
        }
    }

    /// Treffer nur am WORTANFANG — Wortende bleibt offen (Komposita).
    static func matchesAtWordStart(_ haystack: String, _ needle: String) -> Bool {
        WordMatch.atWordStart(haystack, needle)
    }

    /// Treffer nur als GANZES WORT.
    ///
    /// Ersetzt das frühere blanke `contains`, an dem kurze Tokens mitten in längeren
    /// Wörtern zündeten. Real beobachtet: eine PayPal-Lastschrift mit Verwendungszweck
    /// „J.P. Morgan Mobility Payments Solutions" wurde als Baumarkt-Einkauf verbucht,
    /// weil „obi" in „M-obi-lity" steckt. Weil `normalize()` zusätzlich Diakritika
    /// faltet, traf „uber" auch jedes „Überweisung".
    static func matchesAsWord(_ haystack: String, _ needle: String) -> Bool {
        WordMatch.asWord(haystack, needle)
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

    /// `cadenceMap` (optional): wenn gesetzt, wird die Intervall-Regel-Cadence EXPLIZIT aus
    /// dieser Karte berechnet (timing-unabhängig, z.B. beim Suchindex-Build) statt aus dem
    /// globalen Live-Cache. `nil` → bisheriges Verhalten (globaler `liveCadence`).
    static func category(for transaction: TransactionsResponse.Transaction,
                         cadenceMap: [String: PaymentFrequency]? = nil) -> TransactionCategory {
        let txID = TransactionRecord.fingerprint(for: transaction)
        // transaction.slotId ist von DB-load gesetzt (unified-mode), sonst nil
        // → fallback auf activeSlotId. Beide gibt slot-korrekten Override-Lookup —
        // sonst leakt activeSlot-Override auf identische Tx in anderen Slots.
        let slotId = transaction.slotId ?? TransactionsDatabase.activeSlotId
        if let override = overrideCategory(txID: txID, slotId: slotId) {
            return override
        }

        // Reusable user assignment rules win over the stored/auto category (explicit intent),
        // but not over the per-transaction override above. Cadence explizit (Index) oder global.
        let cadence = cadenceMap.map { AssignmentRules.cadence(for: transaction, map: $0) }
            ?? AssignmentRules.liveCadence(for: transaction)
        if let ruleCategory = AssignmentRules.firstCategory(for: RuleInput(transaction), cadence: cadence) {
            return ruleCategory
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
        slotId: String = TransactionsDatabase.activeSlotId,
        amount: Double,
        empfaenger: String?,
        absender: String?,
        verwendungszweck: String?,
        additionalInformation: String?,
        effectiveMerchant: String?
    ) -> TransactionCategory {
        // Slot-scoped Override-Lookup (Composite-Key seit v19) — sonst leakt
        // activeSlot-Override auf gleichfingerprint Tx in anderen Slots.
        if let override = overrideCategory(txID: txID, slotId: slotId) {
            return override
        }

        if let ruleCategory = AssignmentRules.firstCategory(for: RuleInput(
            amount: amount, empfaenger: empfaenger, absender: absender,
            verwendungszweck: verwendungszweck, additionalInformation: additionalInformation,
            endToEndId: nil, merchant: effectiveMerchant ?? ""
        )) {
            return ruleCategory
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

    /// Override-Storage seit Migration v19 mit Composite-Key `slotId|txID` —
    /// derselbe Fingerprint kann in mehreren Slots existieren (z.B. interne
    /// Transfers zwischen eigenen Konten), und ein Override in einem Slot darf
    /// nicht den anderen Slot überschreiben. Legacy-Einträge (nur txID-Key)
    /// werden im Read-Path noch unterstützt, neue Writes nur composite.
    ///
    /// `slotId` Default = `TransactionsDatabase.activeSlotId` für Convenience —
    /// entspricht dem Pattern in restlichem DB-Code. UI-callsites sollten
    /// explizit `slotId` durchreichen wenn der Kontext bekannt ist.
    static func saveOverride(txID: String, slotId: String = TransactionsDatabase.activeSlotId,
                             category: TransactionCategory) {
        let key = compositeOverrideKey(slotId: slotId, txID: txID)
        guard !key.isEmpty else { return }

        var overrides = transactionOverrides()
        overrides[key] = category.rawValue
        // Beim Schreiben den alten legacy-Key (nur txID) aufräumen, falls er
        // existierte — vermeidet Drift zwischen alter und neuer Speicherform.
        let legacy = legacyOverrideKey(txID: txID)
        if !legacy.isEmpty { overrides.removeValue(forKey: legacy) }
        persistOverrides(overrides)
    }

    /// Viele Overrides mit **einem** Lese- und einem Schreibvorgang.
    ///
    /// `saveOverride` liest und schreibt je Aufruf das ganze Wörterbuch; bei einem
    /// Umsteiger mit 50.000 Buchungen ist das quadratisch und dauert Minuten, in
    /// denen der Einrichtungsassistent steht. Gleiche Aufräumregel wie dort: der
    /// alte Nur-txID-Schlüssel fliegt mit raus, sonst driften alte und neue
    /// Speicherform auseinander.
    static func saveOverrides(_ zuordnungen: [(txID: String, slotId: String,
                                               category: TransactionCategory)]) {
        guard !zuordnungen.isEmpty else { return }
        var overrides = transactionOverrides()
        var geaendert = false
        for (txID, slotId, category) in zuordnungen {
            let key = compositeOverrideKey(slotId: slotId, txID: txID)
            guard !key.isEmpty else { continue }
            overrides[key] = category.rawValue
            let legacy = legacyOverrideKey(txID: txID)
            if !legacy.isEmpty { overrides.removeValue(forKey: legacy) }
            geaendert = true
        }
        if geaendert { persistOverrides(overrides) }
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

    static func hasOverride(txID: String,
                            slotId: String = TransactionsDatabase.activeSlotId) -> Bool {
        overrideCategory(txID: txID, slotId: slotId) != nil
    }

    static func overrideCategory(txID: String,
                                 slotId: String = TransactionsDatabase.activeSlotId) -> TransactionCategory? {
        let overrides = transactionOverrides()
        // Bevorzugt: composite-Key (slot-scoped, korrekt seit v19)
        let composite = compositeOverrideKey(slotId: slotId, txID: txID)
        if !composite.isEmpty, let rawValue = overrides[composite] {
            return TransactionCategory.from(displayName: rawValue)
        }
        // Legacy-Fallback: alter Key war nur txID. Wird beim nächsten saveOverride
        // automatisch zur composite-Form migriert.
        let legacy = legacyOverrideKey(txID: txID)
        if !legacy.isEmpty, let rawValue = overrides[legacy] {
            return TransactionCategory.from(displayName: rawValue)
        }
        return nil
    }

    /// Zieht alle Overrides von einem Kategorienamen auf einen anderen um — Gegenstück
    /// zu `TransactionsDatabase.kategorieUmbenennen`. Der Override ist die stärkste
    /// Zuordnung (er schlägt Regeln und gespeicherte Bezeichnung); ihn beim Umbenennen
    /// liegen zu lassen hieße, genau die Zuordnungen zu verlieren, die der Nutzer von
    /// Hand getroffen hat.
    static func overridesUmbenennen(von alt: String, nach neu: String) {
        let ziel = Kategorienamen.normalisiert(alt)
        guard !ziel.isEmpty, alt != neu else { return }
        var overrides = transactionOverrides()
        var geaendert = false
        for (schluessel, wert) in overrides where Kategorienamen.normalisiert(wert) == ziel {
            overrides[schluessel] = neu
            geaendert = true
        }
        if geaendert { persistOverrides(overrides) }
    }

    private static func compositeOverrideKey(slotId: String, txID: String) -> String {
        let sid = slotId.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tid = txID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty, !tid.isEmpty else { return "" }
        return "\(sid)|\(tid)"
    }

    private static func legacyOverrideKey(txID: String) -> String {
        txID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
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

        // SPM-Resource-Bundle. Im App-Bundle greift schon `Bundle.main`; hier zählt der
        // Testprozess, dessen `Bundle.main` der xctest-Runner ist — ohne diesen Zweig
        // fiele die Kategorisierung in Tests still auf `fallbackRules` zurück und
        // Regressionen im echten Keyword-Katalog blieben unentdeckt.
        return Bundle.module.url(forResource: "categories_de", withExtension: "json")
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

            // generic und merchants bleiben getrennt: Wortstämme dürfen in Komposita
            // greifen, Markennamen nur als ganzes Wort (siehe `Rule.matches`).
            let generic = (entry.keywords.generic ?? []).map(normalizeKeyword).filter { !$0.isEmpty }
            let merchants = (entry.keywords.merchants ?? []).map(normalizeKeyword).filter { !$0.isEmpty }

            guard !generic.isEmpty || !merchants.isEmpty else { continue }
            loadedRules.append(Rule(category: category,
                                    generic: Array(Set(generic)),
                                    merchants: Array(Set(merchants))))
        }

        return loadedRules.isEmpty ? nil : loadedRules
    }

    private static func persistOverrides(_ overrides: [String: String]) {
        let defaults = Self.defaults
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: overridesStorageKey)
        }
    }

    private static func transactionOverrides() -> [String: String] {
        let defaults = Self.defaults
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
