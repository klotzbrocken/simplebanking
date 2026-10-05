import Foundation
import SwiftUI

private enum FixedCostsFormatters {
    static let currencyEURFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static let currencyEURNoFractionFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Fixed Costs Analyzer

/// Recurring payment identified from transaction clustering
struct RecurringPayment: Identifiable {
    let id = UUID()
    let merchant: String           // Extracted/normalized merchant name (display)
    let groupKey: String           // Unique key used for exclusion: "merchant" or "merchant|ibanSuffix"
    let averageAmount: Double      // Average monthly amount (absolute)
    let occurrences: Int           // Number of occurrences found
    let months: Int                // Number of distinct months
    let frequency: PaymentFrequency
    let lastDate: String
    let category: PaymentCategory
    let confidence: Double         // 0..1, how confident we are this is a fixed cost
    
}

enum PaymentFrequency: String {
    case monthly = "Monatlich"
    case quarterly = "Vierteljährlich"
    case yearly = "Jährlich"
    case irregular = "Unregelmäßig"
}

enum PaymentCategory: String, CaseIterable {
    case streaming = "Streaming"
    case software = "Software/Apps"
    case telecom = "Telekommunikation"
    case insurance = "Versicherung"
    case utilities = "Versorger"
    case membership = "Mitgliedschaft"
    case finance = "Finanzen"
    /// Was die kontoführende Bank selbst abbucht — Kontoführung, Buchungsposten,
    /// Rechnungsabschluss. Eigene Kategorie und nicht `.finance`, weil es das Einzige
    /// ist, das man durch einen Kontowechsel loswird.
    case bankFees = "Bankgebühren"
    case transport = "Mobilität"
    case other = "Sonstiges"
    
    var icon: String {
        switch self {
        case .streaming: return "play.tv.fill"
        case .software: return "app.badge.fill"
        case .telecom: return "antenna.radiowaves.left.and.right"
        case .insurance: return "shield.fill"
        case .utilities: return "bolt.fill"
        case .membership: return "person.crop.circle.badge.checkmark"
        case .finance: return "creditcard.fill"
        case .bankFees: return "building.columns.fill"
        case .transport: return "car.fill"
        case .other: return "tag.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .streaming:   return .sbRedMid
        case .software:    return .sbBlueMid
        case .telecom:     return .sbOrangeMid
        case .insurance:   return .sbGreenMid
        case .utilities:   return .sbOrangeStrong
        case .membership:  return .sbRedStrong
        case .finance:     return .sbBlueStrong
        case .bankFees:    return .sbOrangeMid
        case .transport:   return .sbGreenStrong
        case .other:       return .sbNeutralMid
        }
    }
}

enum FixedCostsAnalyzer {
    
    // MARK: - Main Analysis
    
    /// - Parameter bankname: Anzeigename des Kontos. Nur nötig, wenn eine Entgeltbuchung
    ///   doch einen Empfänger trägt — dann muss er zur Bank passen. Ohne Angabe bleiben
    ///   solche Buchungen draußen, was die vorsichtigere Annahme ist.
    static func analyze(transactions: [TransactionsResponse.Transaction],
                        bankname: String? = nil) -> [RecurringPayment] {
        // Only analyze expenses (negative amounts)
        let expenses = transactions.filter { amt($0) < 0 }
        
        // Group by effective merchant + IBAN (to separate same-name recipients with different accounts)
        var grouped: [String: [TransactionsResponse.Transaction]] = [:]
        
        for tx in expenses {
            // Entgelte der eigenen Bank tragen keinen Empfänger — der Händler-Auflöser
            // liefert dafür nichts Stabiles, und drei Monatsbuchungen landeten in drei
            // Gruppen. Deshalb ein fester Schlüssel, bevor überhaupt aufgelöst wird.
            if Bankgebuehren.istGebuehr(tx, bankname: bankname) {
                grouped[Bankgebuehren.bezeichnung, default: []].append(tx)
                continue
            }
            let merchant = extractEffectiveMerchant(tx)
            let iban = tx.creditor?.iban ?? tx.debtor?.iban ?? ""
            // For known services (Netflix, Telekom, etc.) the merchant name is the
            // unique identifier — drop the IBAN suffix so transactions that happen
            // to come via different sub-accounts (e.g. Telekom Inkasso rotation,
            // PayPal sub-IBANs) still land in the same cluster.
            let isKnown = categoryForMerchant(merchant) != .other
            let ibanSuffix = (iban.isEmpty || isKnown) ? "" : String(iban.suffix(8))
            let key = ibanSuffix.isEmpty ? merchant : "\(merchant)|\(ibanSuffix)"
            grouped[key, default: []].append(tx)
        }
        
        // Die Gebührengruppe muss ihren Beleg tragen: gleicher Betrag, regelmäßiger
        // Abstand. Sonst verschwindet sie hier, bevor irgendetwas sie auswertet.
        if let gebuehren = grouped[Bankgebuehren.bezeichnung],
           !Bankgebuehren.giltAlsWiederkehrend(gebuehren) {
            grouped.removeValue(forKey: Bankgebuehren.bezeichnung)
        }

        // Analyze each group for recurring patterns
        var recurring: [RecurringPayment] = []
        
        for (groupKey, txList) in grouped {
            // Remove IBAN suffix from display name
            let merchant = groupKey.contains("|") ? String(groupKey.split(separator: "|").first ?? "") : groupKey
            // Bleibt als Händler der Zahlungsdienstleister selbst übrig, ist aus dem
            // Verwendungszweck kein echter Empfänger zu holen gewesen. Dann liegen in
            // einer Gruppe beliebige fremde Einkäufe — verschiedene Shops, verschiedene
            // Beträge, verschiedene Termine. Daraus eine Fixkostenposition zu bilden
            // ist immer falsch, egal wie gleichmäßig die Beträge zufällig aussehen.
            if istDurchlaufposten(merchant) { continue }
            if let payment = analyzeRecurrence(merchant: merchant, groupKey: groupKey, transactions: txList) {
                recurring.append(payment)
            }
        }

        // Filter out merchants the user has excluded. Reads the UNIFIED RecurringAssignments store
        // (shared with SubscriptionsView) so an exclusion made anywhere applies everywhere —
        // HealthScorer, SimpleReport, AttentionInbox + the Abo-UI all honor the same corrections.
        let excluded = RecurringAssignments.current().excludedCanonicalKeys()

        return recurring
            .filter { excluded.isEmpty || !excluded.contains(RecurringAssignments.canonicalKey($0.groupKey)) }
            .sorted { $0.averageAmount > $1.averageAmount }
    }
    
    // MARK: - Fixed Cost Detection
    
    /// Returns merchant names that are identified as fixed costs
    static func getFixedCostMerchants(transactions: [TransactionsResponse.Transaction]) -> Set<String> {
        let recurring = analyze(transactions: transactions)
        return Set(recurring.map { $0.merchant })
    }
    
    /// Checks if a single transaction belongs to a fixed cost pattern
    static func isFixedCost(_ tx: TransactionsResponse.Transaction, fixedMerchants: Set<String>) -> Bool {
        let merchant = extractEffectiveMerchant(tx)
        return fixedMerchants.contains(merchant)
    }
    
    /// Get the effective merchant name for a transaction (public access)
    static func merchantName(for tx: TransactionsResponse.Transaction) -> String {
        return extractEffectiveMerchant(tx)
    }
    
    /// Calculate total monthly fixed costs
    static func totalMonthlyFixedCosts(transactions: [TransactionsResponse.Transaction]) -> Double {
        let recurring = analyze(transactions: transactions)
        return recurring.reduce(0.0) { total, payment in
            switch payment.frequency {
            case .monthly: return total + payment.averageAmount
            case .quarterly: return total + (payment.averageAmount / 3.0)
            case .yearly: return total + (payment.averageAmount / 12.0)
            case .irregular: return total + payment.averageAmount // assume monthly
            }
        }
    }
    
    // MARK: - Merchant Extraction (the crucial trick!)
    
    private static func extractEffectiveMerchant(_ tx: TransactionsResponse.Transaction) -> String {
        MerchantResolver.resolve(transaction: tx).effectiveMerchant
    }
    
    // MARK: - Payment Processor Detection
    
    /// Namen, hinter denen **kein** Empfänger steht, sondern nur die Durchleitung.
    ///
    /// Geprüft wird der **aufgelöste** Händlername. Steht hier noch der Dienstleister,
    /// hat `MerchantResolver` im Verwendungszweck nichts gefunden — „PayPal Europe …
    /// Ihr Einkauf bei " ohne Namen dahinter ist der häufigste Fall. Der Shop selbst
    /// ist davon nicht betroffen: Wird er erkannt, heißt die Gruppe nach ihm („Google",
    /// „Anthropic") und zählt normal mit.
    private static let durchlaufpostenNamen: Set<String> = [
        "paypal", "paypal europe", "pp europe",
        "klarna", "klarna bank", "klarna ab", "sofort", "sofortueberweisung",
        "mollie", "stichting mollie",
        "adyen", "stripe", "sumup", "zettle", "izettle",
        "amazon payments", "amazon pay",
        "google pay", "apple pay",
        "concardis", "nexi", "unzer", "payone", "worldline", "six payment services",
        "shopify payments", "ratepay", "billpay", "paysafe", "skrill", "wirecard",
    ]

    /// Trifft auf „PayPal", „PayPal Europe" und „Stichting Mollie" zu, nicht auf
    /// „Paypalooza GmbH" oder „Apple" (ohne „Pay").
    static func istDurchlaufposten(_ merchant: String) -> Bool {
        let name = merchant.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return durchlaufpostenNamen.contains { needle in
            name == needle
                || name.hasPrefix(needle + " ")
                || name.hasSuffix(" " + needle)
                || name.contains(" " + needle + " ")
        }
    }

    // MARK: - Known Services Detection
    
    private static let knownServices: [(pattern: String, name: String, category: PaymentCategory)] = [
        // Streaming
        ("netflix", "Netflix", .streaming),
        ("spotify", "Spotify", .streaming),
        ("disney", "Disney+", .streaming),
        ("prime video", "Prime Video", .streaming),
        ("amazon prime", "Amazon Prime", .streaming),
        ("apple tv", "Apple TV+", .streaming),
        ("youtube premium", "YouTube Premium", .streaming),
        ("dazn", "DAZN", .streaming),
        ("sky", "Sky", .streaming),
        ("waipu", "Waipu.tv", .streaming),
        ("joyn", "Joyn", .streaming),
        ("wow ", "WOW", .streaming),
        ("crunchyroll", "Crunchyroll", .streaming),
        ("audible", "Audible", .streaming),
        ("deezer", "Deezer", .streaming),
        ("tidal", "Tidal", .streaming),
        
        // Software
        ("adobe", "Adobe", .software),
        ("microsoft 365", "Microsoft 365", .software),
        ("office 365", "Office 365", .software),
        ("dropbox", "Dropbox", .software),
        ("icloud", "iCloud", .software),
        ("google one", "Google One", .software),
        ("notion", "Notion", .software),
        ("1password", "1Password", .software),
        ("bitwarden", "Bitwarden", .software),
        ("github", "GitHub", .software),
        ("jetbrains", "JetBrains", .software),
        ("figma", "Figma", .software),
        ("canva", "Canva", .software),
        ("slack", "Slack", .software),
        ("zoom", "Zoom", .software),
        ("openai", "OpenAI", .software),
        ("chatgpt", "ChatGPT", .software),
        ("anthropic", "Anthropic", .software),
        ("midjourney", "Midjourney", .software),
        ("grammarly", "Grammarly", .software),
        
        // Telecom
        ("telekom", "Telekom", .telecom),
        ("vodafone", "Vodafone", .telecom),
        ("o2", "O2", .telecom),
        ("telefonica", "Telefónica", .telecom),
        ("1&1", "1&1", .telecom),
        ("congstar", "Congstar", .telecom),
        ("aldi talk", "ALDI TALK", .telecom),
        ("lidl connect", "Lidl Connect", .telecom),
        ("freenet", "Freenet", .telecom),
        ("mobilcom", "Mobilcom", .telecom),
        ("simplytel", "Simplytel", .telecom),
        
        // Insurance
        ("allianz", "Allianz", .insurance),
        ("huk", "HUK", .insurance),
        ("axa", "AXA", .insurance),
        ("ergo", "ERGO", .insurance),
        ("debeka", "Debeka", .insurance),
        ("generali", "Generali", .insurance),
        ("signal iduna", "Signal Iduna", .insurance),
        ("versicherung", "Versicherung", .insurance),
        ("barmer", "Barmer", .insurance),
        ("tk krankenkasse", "TK", .insurance),
        ("aok", "AOK", .insurance),
        ("dak", "DAK", .insurance),
        
        // Utilities
        ("stadtwerke", "Stadtwerke", .utilities),
        ("eon", "E.ON", .utilities),
        ("rwe", "RWE", .utilities),
        ("vattenfall", "Vattenfall", .utilities),
        ("enpal", "Enpal", .utilities),
        ("strom", "Stromanbieter", .utilities),
        ("gas", "Gasanbieter", .utilities),
        
        // Membership
        ("fitness", "Fitnessstudio", .membership),
        ("gym", "Gym", .membership),
        ("mcfit", "McFit", .membership),
        ("urban sports", "Urban Sports", .membership),
        ("adac", "ADAC", .membership),
        ("verein", "Vereinsbeitrag", .membership),
        ("bahncard", "BahnCard", .membership),
        
        // Finance
        ("depot", "Depot", .finance),
        ("trade republic", "Trade Republic", .finance),
        ("scalable", "Scalable", .finance),
        ("comdirect", "Comdirect", .finance),
        ("ing diba", "ING", .finance),
        ("dkb", "DKB", .finance),
        
        // Transport
        ("deutschlandticket", "Deutschlandticket", .transport),
        ("bahn", "Deutsche Bahn", .transport),
        ("nextbike", "Nextbike", .transport),
        ("miles", "MILES", .transport),
        ("share now", "ShareNow", .transport),
        ("tier", "TIER", .transport),
        ("bolt", "Bolt", .transport),
        
        // Podcasts/Media
        ("podigee", "Podigee", .software),
        ("anchor", "Anchor", .software),
        ("patreon", "Patreon", .membership),
        ("substack", "Substack", .membership),
        ("twitch", "Twitch", .streaming),
    ]
    
    static func categoryForMerchant(_ merchant: String) -> PaymentCategory {
        if merchant == Bankgebuehren.bezeichnung { return .bankFees }
        let lower = merchant.lowercased()
        for (pattern, _, category) in knownServices {
            if lower.contains(pattern) {
                return category
            }
        }
        return .other
    }
    
    private static func normalizeMerchant(_ name: String) -> String {
        // Clean up messy merchant names
        var cleaned = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove account numbers, references etc
        if let range = cleaned.range(of: #"\d{10,}"#, options: .regularExpression) {
            cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return cleaned.isEmpty ? "(Unbekannt)" : cleaned
    }
    
    private static func amt(_ t: TransactionsResponse.Transaction) -> Double {
        AmountParser.parse(t.amount?.amount)
    }
    
    private static func date(_ t: TransactionsResponse.Transaction) -> Date? {
        let s = t.bookingDate ?? t.valueDate
        guard let s else { return nil }
        return FixedCostsFormatters.isoDateFormatter.date(from: s)
    }
    
    // MARK: - Recurrence Analysis
    
    private static func analyzeRecurrence(merchant: String, groupKey: String, transactions: [TransactionsResponse.Transaction]) -> RecurringPayment? {
        // Known services (Netflix, Spotify, Telekom, etc.) dürfen nur die
        // Amplitudenschwelle lockern — die Recurrence-Evidenz (2 Buchungen in
        // 2 distinct months) gilt für alle, sonst landen Einmalkäufe bei
        // bekannten Marken fälschlich als Fixkosten in der Ansicht.
        let isKnownMerchant = categoryForMerchant(merchant) != .other

        // Dauerauftrag: die Bank hat die Wiederkehr bereits bestätigt. Damit
        // brauchen wir sie nicht mehr aus Beträgen und Abständen zu erraten —
        // genau daran scheiterten bisher Miete, Sparrate und Vereinsbeitrag, die
        // im 60-Tage-Fenster oft nur ein- oder zweimal auftauchen.
        let isStandingOrder = BookingType.containsStandingOrder(transactions)

        // Ein einzelner Dauerauftrag ist wiederkehrend, aber seine FREQUENZ lässt
        // sich aus einem Datum nicht ableiten. Wir nehmen die in Deutschland
        // übliche monatliche an — und drücken die Confidence bewusst auf 0.55:
        // das liegt ÜBER der Schwelle dieser Analyse (0.5), sodass der Posten in
        // Fixkosten und Abo-Liste erscheint, aber UNTER der Schwelle von
        // `LeftToPayCalculator` (0.6). Eine aus einer einzigen Beobachtung
        // geratene Frequenz verändert damit keine Geldsumme.
        if isStandingOrder && transactions.count == 1 {
            guard let only = transactions.first else { return nil }
            return RecurringPayment(
                merchant: merchant,
                groupKey: groupKey,
                averageAmount: abs(amt(only)),
                occurrences: 1,
                months: 1,
                frequency: .monthly,
                lastDate: only.bookingDate ?? only.valueDate ?? "",
                category: categoryForMerchant(merchant),
                confidence: 0.55
            )
        }

        // Require 2+ transactions
        guard transactions.count >= 2 else { return nil }

        let cal = Calendar(identifier: .gregorian)

        // Get amounts and dates
        let amounts = transactions.map { abs(amt($0)) }
        let dates = transactions.compactMap { date($0) }

        guard !amounts.isEmpty, !dates.isEmpty else { return nil }

        // Calculate average amount
        let avgAmount = amounts.reduce(0, +) / Double(amounts.count)

        // Check amount consistency. Bekannte Marken dürfen bis 0.50 schwanken
        // (Preiserhöhungen bei Streaming), unbekannte nur bis 0.35.
        let amountVariance = amounts.map { abs($0 - avgAmount) / avgAmount }.max() ?? 1.0
        // Beim Dauerauftrag dieselbe Toleranz wie bei bekannten Marken: eine
        // Mieterhöhung oder Nebenkostenanpassung darf die Erkennung nicht kippen,
        // wenn die Bank die Wiederkehr ohnehin bestätigt.
        var varianceLimit = (isKnownMerchant || isStandingOrder) ? 0.50 : 0.35
        // Bei genau zwei Buchungen ist dieses Maß fast blind. Für zwei Werte ist
        // `max |x - avg| / avg` identisch mit |a-b|/(a+b) — die Schranke 0,35 lässt
        // damit einen **Faktor 2,08** zwischen beiden Beträgen zu.
        //
        // Gemeldet am 01.10.2026: Zwei fremde PayPal-Einkäufe über 350,00 € und 609,59 €
        // ergaben so eine „monatliche Fixkostenposition" von 479,80 € — allein die
        // Hälfte der angezeigten Summe. Zwei Beträge belegen keine Regelmäßigkeit;
        // sie müssen dafür nahezu gleich sein.
        //
        // Bekannte Marken behalten etwas Luft, weil eine Preiserhöhung beim zweiten
        // Mal ein echter Fall ist (6,99 € → 7,99 € liegt bei 0,067).
        if transactions.count == 2 && !isStandingOrder {
            varianceLimit = isKnownMerchant ? 0.15 : 0.10
        }
        guard amountVariance < varianceLimit else { return nil }

        // Count distinct months and years
        let monthSet = Set(dates.map { cal.dateComponents([.year, .month], from: $0) })
        let distinctMonths = monthSet.count
        let yearSet = Set(dates.map { cal.component(.year, from: $0) })
        let distinctYears = yearSet.count

        // Require 2 distinct months — gilt für alle Händler AUSSER Daueraufträgen:
        // dort ist die Wiederkehr von der Bank bestätigt, und zwei Buchungen im
        // selben Monat (wöchentlich/14-täglich) sind ein gültiger Fall.
        guard distinctMonths >= 2 || isStandingOrder else { return nil }

        // Determine frequency
        var frequency = determineFrequency(dates: dates, cal: cal)

        // For yearly: can't confirm with < 2 distinct years of data.
        // Instead of hard-dropping, fall through as irregular so at least
        // known yearly merchants (Adobe, insurance) still appear.
        if frequency == .yearly && distinctYears < 2 {
            frequency = .irregular
        }
        
        // If frequency is irregular but we have consistent monthly data, treat as monthly
        if frequency == .irregular && distinctMonths >= 2 && transactions.count >= distinctMonths {
            frequency = .monthly
        }
        
        // Get last transaction date
        let lastDate = transactions
            .compactMap { $0.bookingDate ?? $0.valueDate }
            .sorted()
            .last ?? ""
        
        // Calculate confidence
        var confidence = calculateConfidence(
            occurrences: transactions.count,
            months: distinctMonths,
            amountVariance: amountVariance,
            frequency: frequency
        )
        // Bestätigte Wiederkehr durch die Bank ist mehr wert als jede Heuristik.
        if isStandingOrder { confidence = min(1.0, confidence + 0.2) }

        // Only include if confidence is decent
        guard confidence >= 0.5 else { return nil }
        
        return RecurringPayment(
            merchant: merchant,
            groupKey: groupKey,
            averageAmount: avgAmount,
            occurrences: transactions.count,
            months: distinctMonths,
            frequency: frequency,
            lastDate: lastDate,
            category: categoryForMerchant(merchant),
            confidence: confidence
        )
    }
    
    private static func determineFrequency(dates: [Date], cal: Calendar) -> PaymentFrequency {
        guard dates.count >= 2 else { return .irregular }
        
        let sorted = dates.sorted()
        var intervals: [Int] = []
        
        for i in 1..<sorted.count {
            let days = cal.dateComponents([.day], from: sorted[i-1], to: sorted[i]).day ?? 0
            intervals.append(days)
        }
        
        let avgInterval = Double(intervals.reduce(0, +)) / Double(intervals.count)
        
        if avgInterval >= 25 && avgInterval <= 35 {
            return .monthly
        } else if avgInterval >= 85 && avgInterval <= 100 {
            return .quarterly
        } else if avgInterval >= 350 && avgInterval <= 380 {
            return .yearly
        }
        
        return .irregular
    }
    
    private static func calculateConfidence(occurrences: Int, months: Int, amountVariance: Double, frequency: PaymentFrequency) -> Double {
        var conf = 0.5

        // More occurrences = higher confidence (clamped so single-occurrence known
        // merchants don't go negative; they stay at 0.5 base)
        conf += min(0.2, max(0.0, Double(occurrences - 2) * 0.05))

        // More months = higher confidence (same clamp)
        conf += min(0.15, max(0.0, Double(months - 2) * 0.05))

        // Lower amount variance = higher confidence
        conf += (1.0 - amountVariance) * 0.1

        // Regular frequency = higher confidence
        if frequency != .irregular {
            conf += 0.1
        }

        return min(1.0, max(0.0, conf))
    }
}

// MARK: - Fixed Costs View (Apple Activity Style)

struct FixedCostsView: View {
    let payments: [RecurringPayment]

    @Environment(\.dismiss) private var dismiss
    @State private var animProgress: Double = 0
    @State private var sonstigeExpanded = false
    @State private var excludedExpanded = false
    // Unified correction store (shared with SubscriptionsView + FixedCostsAnalyzer.analyze) so an
    // exclusion here applies everywhere — Health Score, SimpleReport, Abo-Liste, Kalender.
    @AppStorage(RecurringAssignments.storageKey) private var assignmentsRaw: String = ""

    // MARK: Exclusion set helpers

    private var assignments: RecurringAssignments { RecurringAssignments.decode(assignmentsRaw) }

    /// Excluded canonical keys (merchant bases), shared across the app.
    private var excludedSet: Set<String> { assignments.excludedCanonicalKeys() }

    private func exclude(_ key: String) {
        assignmentsRaw = assignments.setting(key) { a in
            a.state = .excluded
            a.tab = nil
        }.jsonString
    }

    private func include(_ key: String) {
        assignmentsRaw = assignments.setting(key) { a in a.state = .neutral }.jsonString
    }

    private func resetExcluded() {
        var a = assignments
        for k in a.excludedCanonicalKeys() {
            a = a.setting(k) { $0.state = .neutral }
        }
        assignmentsRaw = a.jsonString
    }

    // MARK: Derived data (all excluding user-excluded)

    private var visiblePayments: [RecurringPayment] {
        // analyze() already filters exclusions, but guard here too for
        // immediate visual feedback when user excludes within the open sheet.
        payments.filter { !assignments.isExcluded($0.groupKey) }
    }

    private func monthlyAmount(_ p: RecurringPayment) -> Double {
        switch p.frequency {
        case .monthly, .irregular: return p.averageAmount
        case .quarterly:           return p.averageAmount / 3
        case .yearly:              return p.averageAmount / 12
        }
    }

    private var totalMonthly: Double { visiblePayments.reduce(0) { $0 + monthlyAmount($1) } }
    private var totalYearly:  Double {
        visiblePayments.reduce(0) { result, p in
            switch p.frequency {
            case .monthly, .irregular: return result + p.averageAmount * 12
            case .quarterly:           return result + p.averageAmount * 4
            case .yearly:              return result + p.averageAmount
            }
        }
    }

    private typealias MerchantRow = (merchant: String, groupKey: String, amount: Double, category: PaymentCategory)

    private var sortedVisible: [MerchantRow] {
        visiblePayments
            .map { p -> MerchantRow in (p.merchant, p.groupKey, monthlyAmount(p), p.category) }
            .sorted { $0.amount > $1.amount }
    }

    private var topMerchants:   [MerchantRow] { Array(sortedVisible.prefix(5)) }
    private var otherMerchants: [MerchantRow] { sortedVisible.count > 5 ? Array(sortedVisible.dropFirst(5)) : [] }
    private var othersAmount:   Double        { otherMerchants.reduce(0) { $0 + $1.amount } }

    // MARK: Formatting

    private func fmt(_ v: Double) -> String {
        FixedCostsFormatters.currencyEURNoFractionFormatter.string(from: NSNumber(value: v)) ?? "\(Int(v)) €"
    }

    // Color Harmony Palette — kategoriale Variation aus den 4 Hue-Familien (kein Cyan/Pink/Purple mehr).
    private let merchantColors: [Color] = [
        .sbBlueStrong, .sbGreenStrong, .sbOrangeStrong, .sbRedStrong, .sbBlueMid
    ]

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fixkosten")
                            .font(.system(size: 24, weight: .bold))
                        Text("Wiederkehrende Zahlungen")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal)

                // Summary Boxes — Blue für die analytischen Zahlen, Orange für die größere Jahres-Summe.
                HStack(spacing: 16) {
                    FixedCostsSummaryBox(title: "Monatlich", value: fmt(totalMonthly), color: .sbBlueStrong,   icon: "calendar")
                    FixedCostsSummaryBox(title: "Jährlich",  value: fmt(totalYearly),  color: .sbOrangeStrong, icon: "calendar.badge.clock")
                }
                .padding(.horizontal)

                // Merchant breakdown
                if !visiblePayments.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Nach Empfänger")
                                .font(.system(size: 18, weight: .bold))
                            Spacer()
                            Text("\(visiblePayments.count) Posten")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)

                        // Top 5
                        ForEach(Array(topMerchants.enumerated()), id: \.offset) { index, item in
                            FixedCostsMerchantRow(
                                merchant: item.merchant,
                                amount: item.amount,
                                category: item.category,
                                total: totalMonthly,
                                progress: animProgress,
                                color: merchantColors[index % merchantColors.count]
                            )
                            .contextMenu {
                                Button { exclude(item.groupKey) } label: {
                                    Label("Keine Fixkosten (gilt auch für Abos & Verträge)", systemImage: "hand.raised.slash")
                                }
                            }
                        }

                        // Sonstige — aufklappbar
                        if !otherMerchants.isEmpty {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    sonstigeExpanded.toggle()
                                }
                            } label: {
                                FixedCostsMerchantRow(
                                    merchant: "Sonstige",
                                    amount: othersAmount,
                                    category: .other,
                                    total: totalMonthly,
                                    progress: animProgress,
                                    color: .sbTextSecondary,
                                    subtitle: "\(otherMerchants.count) weitere Empfänger",
                                    disclosure: sonstigeExpanded
                                )
                            }
                            .buttonStyle(PlainButtonStyle())

                            if sonstigeExpanded {
                                ForEach(Array(otherMerchants.enumerated()), id: \.offset) { _, item in
                                    FixedCostsMerchantRow(
                                        merchant: item.merchant,
                                        amount: item.amount,
                                        category: item.category,
                                        total: totalMonthly,
                                        progress: animProgress,
                                        color: .sbTextSecondary,
                                        isSubRow: true
                                    )
                                    .contextMenu {
                                        Button { exclude(item.groupKey) } label: {
                                            Label("Keine Fixkosten (gilt auch für Abos & Verträge)", systemImage: "hand.raised.slash")
                                        }
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                    }
                }

                // Ausgeschlossene Händler — aufklappbar am Ende
                if !excludedSet.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                excludedExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.raised.slash")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text("Ausgeblendet (\(excludedSet.count))")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: excludedExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(PlainButtonStyle())

                        if excludedExpanded {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Spacer()
                                    Button("Alle einschließen") { resetExcluded() }
                                        .font(.system(size: 12))
                                        .buttonStyle(PlainButtonStyle())
                                        .foregroundColor(.sbBlueStrong)
                                }
                                .padding(.horizontal, 12)
                                ForEach(excludedSet.sorted(), id: \.self) { key in
                                    let displayName = key.isEmpty ? key : key.prefix(1).uppercased() + key.dropFirst()
                                    HStack {
                                        Text(displayName)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary.opacity(0.7))
                                            .strikethrough(true, color: .secondary.opacity(0.4))
                                        Spacer()
                                        Button("Einschließen") { include(key) }
                                            .font(.system(size: 11))
                                            .buttonStyle(PlainButtonStyle())
                                            .foregroundColor(.sbBlueMid)
                                    }
                                    .padding(.horizontal, 12)
                                }
                            }
                            .padding(.vertical, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.sbSurfaceSoft))
                    .padding(.horizontal)
                }

                Spacer(minLength: 20)
            }
            .padding(.top, 24)
        }
        .frame(width: 420, height: 680)
        .background(Color.sbBackground.edgesIgnoringSafeArea(.all))
        .onAppear {
            withAnimation(.spring(response: 1.2, dampingFraction: 0.8, blendDuration: 0)) {
                animProgress = 1.0
            }
        }
    }
}

private struct FixedCostsSummaryBox: View {
    let title: String
    let value: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.sbTextSecondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // Soft-Variante als Karten-Fill — bleibt im Palette-System statt color.opacity().
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.sbSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.sbBorder, lineWidth: 1))
    }
}

private struct FixedCostsMerchantRow: View {
    let merchant: String
    let amount: Double
    let category: PaymentCategory
    let total: Double
    let progress: Double
    let color: Color
    var subtitle: String? = nil
    var disclosure: Bool? = nil   // nil = kein Chevron, Bool = Richtung
    var isSubRow: Bool = false

    private func fmt(_ v: Double) -> String {
        FixedCostsFormatters.currencyEURNoFractionFormatter.string(from: NSNumber(value: v)) ?? "\(Int(v)) €"
    }

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: isSubRow ? 26 : 32, height: isSubRow ? 26 : 32)
                Image(systemName: category.icon)
                    .font(.system(size: isSubRow ? 11 : 13))
                    .foregroundColor(color)
            }
            .padding(.leading, isSubRow ? 16 : 0)

            // Name + optional progress bar
            VStack(alignment: .leading, spacing: 3) {
                Text(merchant)
                    .font(.system(size: isSubRow ? 12 : 13, weight: .medium))
                    .foregroundColor(isSubRow ? .secondary : .primary)
                    .lineLimit(1)

                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                if !isSubRow {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.sbBorder)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color)
                                .frame(width: geo.size.width * CGFloat((amount / max(total, 1)) * progress))
                        }
                    }
                    .frame(height: 5)
                }
            }

            Spacer()

            Text(fmt(amount))
                .font(.system(size: isSubRow ? 12 : 13, weight: .semibold))
                .foregroundColor(isSubRow ? .secondary : color)

            if let expanded = disclosure {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, isSubRow ? 4 : 6)
    }
}
