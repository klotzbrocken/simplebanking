import Foundation

// MARK: - TransferRecipientKind
//
// Heuristische Empfänger-Klassifikation für UI-Akzente:
// • Verwendungszweck-Suggestions (Versicherung → "Beitrag Mai" etc.)
// • Monthly-Badge-Default
// Wird ausschließlich aus dem Klartext-Namen geraten — bei Unsicherheit `.privat`.

enum TransferRecipientKind: String, Sendable, Equatable {
    case versicherung
    case online
    case abo
    case vermieter
    case privat

    var displayLabel: String {
        switch self {
        case .versicherung: return L10n.t("Versicherung",  "Insurance")
        case .online:       return L10n.t("Online",        "Online")
        case .abo:          return L10n.t("Abo",           "Subscription")
        case .vermieter:    return L10n.t("Vermieter",     "Landlord")
        case .privat:       return L10n.t("Privat",        "Private")
        }
    }

    /// Verwendungszweck-Vorschläge basierend auf dem Empfänger-Typ.
    var purposeSuggestions: [String] {
        switch self {
        case .versicherung:
            return [L10n.t("Beitrag Mai", "Premium May"),
                    L10n.t("Vertrag-Nr.", "Policy no."),
                    L10n.t("Rate",        "Installment")]
        case .online:
            return [L10n.t("Bestellung",  "Order"),
                    L10n.t("Rückzahlung", "Refund")]
        case .abo:
            return [L10n.t("Rechnung Mai", "Invoice May"),
                    L10n.t("Kunden-Nr.",   "Customer no.")]
        case .vermieter:
            return [L10n.t("Miete Mai",   "Rent May"),
                    L10n.t("Nebenkosten", "Utilities")]
        case .privat:
            return [L10n.t("Miete Mai",   "Rent May"),
                    L10n.t("Geburtstag",  "Birthday"),
                    L10n.t("Taschengeld", "Allowance"),
                    L10n.t("Ausgleich",   "Settlement"),
                    L10n.t("Sparen",      "Savings")]
        }
    }

    /// Klassifikation aus Namens-Patterns. Bewusst grob & deterministisch —
    /// für die UI-Akzente ist „grob richtig" gut genug.
    static func classify(name: String) -> TransferRecipientKind {
        let lower = name.lowercased()
        if matches(lower, any: ["versicherung", "vers.", " vers ",
                                "krankenkasse", "lebens", "haftpflicht",
                                "provinzial", "hansemerkur", "allianz", "huk",
                                "ergo", "axa", "barmer", "tk ", "techniker krankenkasse"]) {
            return .versicherung
        }
        if matches(lower, any: ["paypal", "klarna", "amazon", "stripe", "shopify",
                                "ebay", "etsy", "mollie", "paydirekt"]) {
            return .online
        }
        if matches(lower, any: ["telekom", "vodafone", "1&1", "1und1", "o2",
                                "spotify", "netflix", "apple", "amazon prime",
                                "disney", "youtube", "adobe", "microsoft",
                                "github", "openai", "anthropic", "claude",
                                "substack", "medium ", "wayback", "audible"]) {
            return .abo
        }
        if matches(lower, any: ["vermieter", "vermietung", "hausverwaltung",
                                "genossenschaft", "wohnungsbau", "immobilien"]) {
            return .vermieter
        }
        return .privat
    }

    private static func matches(_ haystack: String, any needles: [String]) -> Bool {
        for n in needles where haystack.contains(n) { return true }
        return false
    }
}

// MARK: - TransferRecipientCandidate
//
// Vorschlag aus der lokalen Buchungs-Historie für die Geld-senden-UI.
// `mostFrequentAmount` und `lastRemittance` sind Defaults für Betrag und
// Verwendungszweck — der User kann sie überschreiben.

struct TransferRecipientCandidate: Equatable, Sendable {
    let creditorName: String
    let creditorIban: String
    /// Betrag, der am häufigsten an diesen Empfänger ging (Mode statt Mean,
    /// damit Miete trotz einmaliger Sonderzahlung dominiert). Positiv (€).
    let mostFrequentAmount: Decimal?
    /// Letzter Verwendungszweck an diesen Empfänger.
    let lastRemittance: String?
    /// Anzahl ausgehender Transaktionen an dieses (Name, IBAN)-Paar.
    let frequency: Int
    /// ISO-Datum der letzten Buchung (yyyy-MM-dd).
    let lastBookingDate: String

    /// Heuristische Klassifikation für UI-Akzente.
    var kind: TransferRecipientKind {
        TransferRecipientKind.classify(name: creditorName)
    }

    /// Heuristik: regelmäßiger/monatlicher Empfänger? `frequency >= 3`
    /// UND letzte Aktivität innerhalb 60 Tagen ⇒ wahrscheinlich Dauerauftrag/Abo.
    /// Das vermeidet, dass alte „häufige" Empfänger fälschlich monatl.-Badge bekommen.
    func isMonthly(today: Date = Date()) -> Bool {
        guard frequency >= 3 else { return false }
        return TransferRecipientStore.daysSince(lastBookingDate, today: today) <= 60
    }

    /// Human-readable letzte Aktivität: "Heute" / "Gestern" / "Mo." /
    /// "Letzte Wo." / "01. Mai".
    func lastDateLabel(today: Date = Date()) -> String {
        let days = TransferRecipientStore.daysSince(lastBookingDate, today: today)
        if days == 0 { return L10n.t("Heute",  "Today") }
        if days == 1 { return L10n.t("Gestern","Yesterday") }
        if days < 7 {
            return TransferRecipientStore.weekdayShort(lastBookingDate)
                ?? TransferRecipientStore.dayMonthShort(lastBookingDate)
                ?? lastBookingDate
        }
        if days < 14 { return L10n.t("Letzte Wo.", "Last week") }
        return TransferRecipientStore.dayMonthShort(lastBookingDate) ?? lastBookingDate
    }
}

// MARK: - TransferRecipientStore

enum TransferRecipientStore {

    /// Lädt die Empfänger-Kandidaten für den aktiven Slot, sortiert nach
    /// `frequency × recencyBoost`. Default-Limit ist großzügig gewählt
    /// (1000), damit auch selten benutzte Empfänger noch in der Suche
    /// auffindbar sind — die UI rendert nur die Top-3, aber die volle
    /// Liste liegt in-memory für die Filter-Suche zur Verfügung.
    ///
    /// `today` ist injizierbar für deterministische Tests.
    static func loadCandidates(
        slotId: String,
        limit: Int = 1000,
        today: Date = Date(),
        bankId: String = "primary"
    ) throws -> [TransferRecipientCandidate] {
        let raw = try TransactionsDatabase.loadOutgoingRecipientCandidates(
            slotId: slotId,
            limit: limit,
            bankId: bankId
        )
        let sorted = raw.sorted { score($0, today: today) > score($1, today: today) }
        return Array(sorted.prefix(limit))
    }

    /// Substring-Match auf Name oder IBAN. Case-insensitive.
    static func filter(
        _ candidates: [TransferRecipientCandidate],
        query: String
    ) -> [TransferRecipientCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { c in
            c.creditorName.lowercased().contains(q)
                || c.creditorIban.lowercased().contains(q.replacingOccurrences(of: " ", with: ""))
        }
    }

    /// Ranking-Score = `frequency × recencyBoost`.
    /// `recencyBoost = max(0.1, 1 − daysSinceLast / 365)`. 0.1-Floor damit alte
    /// Empfänger nicht komplett verschwinden, sondern nur abgewertet werden.
    static func score(_ c: TransferRecipientCandidate, today: Date) -> Double {
        let days = daysSince(c.lastBookingDate, today: today)
        let recency = max(0.1, 1.0 - Double(days) / 365.0)
        return Double(c.frequency) * recency
    }

    // MARK: - Helpers

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd. MMM"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EE."
        return f
    }()

    /// Tage zwischen `iso` und `today`. Gibt einen großen Wert zurück bei
    /// unparseable Datum (alter Empfänger fällt ans Ende).
    static func daysSince(_ iso: String, today: Date) -> Int {
        guard let date = isoFormatter.date(from: iso) else { return 9999 }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.day], from: date, to: today)
        return max(0, comps.day ?? 9999)
    }

    static func dayMonthShort(_ iso: String) -> String? {
        guard let date = isoFormatter.date(from: iso) else { return nil }
        return dayMonthFormatter.string(from: date)
    }

    static func weekdayShort(_ iso: String) -> String? {
        guard let date = isoFormatter.date(from: iso) else { return nil }
        return weekdayFormatter.string(from: date)
    }
}
