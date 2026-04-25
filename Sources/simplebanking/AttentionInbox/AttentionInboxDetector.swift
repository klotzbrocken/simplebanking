import Foundation

// MARK: - Card Types

enum AttentionCardType {
    case subscriptionPriceIncrease
    case unusuallyHighExpense
    case newMerchant
    case salaryMissing
    case newDirectDebit
    case possibleDuplicate
    case categorySpike
    case reminder

    var iconName: String {
        switch self {
        case .subscriptionPriceIncrease: return "arrow.up.circle.fill"
        case .unusuallyHighExpense:      return "exclamationmark.triangle.fill"
        case .newMerchant:               return "storefront.fill"
        case .salaryMissing:             return "clock.badge.exclamationmark.fill"
        case .newDirectDebit:            return "directcurrent"
        case .possibleDuplicate:         return "doc.on.doc.fill"
        case .categorySpike:             return "chart.line.uptrend.xyaxis"
        case .reminder:                  return "bell.fill"
        }
    }

    /// 1 = kritisch (rot), 2 = ungewöhnlich (orange), 3 = info (blau)
    var defaultPriority: Int {
        switch self {
        case .salaryMissing, .possibleDuplicate:      return 1
        case .subscriptionPriceIncrease,
             .unusuallyHighExpense, .newDirectDebit:  return 2
        case .newMerchant, .categorySpike, .reminder: return 3
        }
    }
}

struct AttentionCard: Identifiable {
    let id = UUID()
    let type: AttentionCardType
    let priority: Int
    let title: String
    let body: String
    let detail: String           // Betrag oder Datum als Anzeigetext
    let relatedTxId: String?     // fingerprint für "Ansehen"-Aktion
    let snoozeKey: String        // stabiler Key für Snooze-Persistenz (nicht der Titel)
}

// MARK: - Detector

enum AttentionInboxDetector {

    // MARK: Public Entry Point

    /// - recent:  Transaktionen der letzten ~60 Tage (vm.transactions)
    /// - history: Transaktionen der letzten 90 Tage (aus DB)
    static func analyze(
        recent: [TransactionsResponse.Transaction],
        history: [TransactionsResponse.Transaction],
        salaryDay: Int,
        salaryToleranceBefore: Int,
        salaryToleranceAfter: Int
    ) -> [AttentionCard] {
        var cards: [AttentionCard] = []

        // Nur Ausgaben (negative Beträge) aus den letzten 14 Tagen als "aktuell"
        let cutoff14  = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let cutoff7   = Calendar.current.date(byAdding: .day, value: -7,  to: Date()) ?? Date()
        let cutoff30  = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

        let recentExpenses14 = recent.filter { txDate($0) >= cutoff14 && txAmount($0) < 0 }
        let recentExpenses7  = recent.filter { txDate($0) >= cutoff7  && txAmount($0) < 0 }
        let historyExpenses  = history.filter { txAmount($0) < 0 }

        // Händler-Lookup aus History (älter als 14 Tage) als "bekannte" Händler
        let knownMerchants = Set(
            history.filter { txDate($0) < cutoff14 }.map { canonicalMerchant($0) }
        )

        cards += detectSalaryMissing(recent: recent, salaryDay: salaryDay,
                                     toleranceBefore: salaryToleranceBefore,
                                     toleranceAfter: salaryToleranceAfter)
        cards += detectDuplicates(recent: recentExpenses7)
        cards += detectSubscriptionIncrease(recent: recentExpenses14, history: historyExpenses)
        cards += detectUnusualExpense(recent: recentExpenses7, history: historyExpenses)
        cards += detectNewDirectDebit(recent: recentExpenses14, history: historyExpenses)
        cards += detectNewMerchant(recent: recentExpenses14, knownMerchants: knownMerchants)
        cards += detectCategorySpike(recent: recent.filter { txDate($0) >= cutoff30 && txAmount($0) < 0 }, history: historyExpenses)

        // Priorisieren + auf 5 begrenzen
        return Array(cards.sorted { $0.priority < $1.priority }.prefix(5))
    }

    // MARK: - Detection Algorithms

    /// D: Gehalt fehlt / verspätet
    /// - Parameter now: Current date — defaults to `Date()` in production, injectable for tests.
    ///
    /// Asymmetrische Toleranzen: `toleranceBefore` bestimmt wie früh das Gehalt akzeptiert
    /// wird (z.B. 28. bei nominalem 1., wenn 1. auf Sonntag fällt); `toleranceAfter` bestimmt
    /// die Grace-Period vor dem "Gehalt fehlt"-Alarm. Nur ein gemeinsamer Wert würde entweder
    /// früh gebuchtes Gehalt übersehen oder die Warnung zu spät feuern.
    internal static func detectSalaryMissing(
        recent: [TransactionsResponse.Transaction],
        salaryDay: Int,
        toleranceBefore: Int,
        toleranceAfter: Int,
        now: Date = Date()
    ) -> [AttentionCard] {
        guard salaryDay > 0 else { return [] }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // Clamp salaryDay to month length and build the expected salary date for a given month-anchor.
        func salaryDate(forMonthOf anchor: Date) -> Date? {
            let days = cal.range(of: .day, in: .month, for: anchor)?.count ?? 28
            var comps = cal.dateComponents([.year, .month], from: anchor)
            comps.day = min(salaryDay, days)
            return cal.date(from: comps)
        }

        // If today is before this month's salary day, the last due date was in the previous month.
        guard let thisMonthExpected = salaryDate(forMonthOf: today) else { return [] }
        let expectedDate: Date
        if thisMonthExpected <= today {
            expectedDate = thisMonthExpected
        } else {
            // Cross-month: salary day hasn't come yet this month → check last month
            let firstOfThisMonth = cal.date(from: DateComponents(
                year: cal.component(.year, from: today),
                month: cal.component(.month, from: today), day: 1))!
            let prevMonthAnchor = cal.date(byAdding: .month, value: -1, to: firstOfThisMonth)!
            guard let prev = salaryDate(forMonthOf: prevMonthAnchor) else { return [] }
            expectedDate = prev
        }

        // Only fire if today is strictly past the after-tolerance + 2 day grace period.
        guard today > (cal.date(byAdding: .day, value: toleranceAfter + 2, to: expectedDate) ?? expectedDate)
        else { return [] }

        // Detection window nutzt die *Before*-Toleranz, damit früh gebuchtes Gehalt (z.B. 28.
        // bei nominalem 1.) erkannt wird. Mit nur `toleranceAfter` würden solche Zahlungen
        // aus dem Fenster fallen und die Karte fälschlich feuern.
        // `now` wird durchgereicht, damit Tests deterministisch sind — sonst würde
        // `detectedIncome` intern `Date()` verwenden und ein für April geschriebener
        // Test im Mai einen anderen Monats-Anker liefern.
        let detected = SalaryProgressCalculator.detectedIncome(
            salaryDay: salaryDay, tolerance: toleranceBefore, transactions: recent, now: now
        )
        guard detected <= 0 else { return [] }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "de_DE")
        fmt.dateFormat = "d. MMMM"

        return [AttentionCard(
            type: .salaryMissing,
            priority: 1,
            title: "Gehaltseingang noch nicht erkannt",
            body: "Kein Gehaltseingang gefunden — erwartet um den \(fmt.string(from: expectedDate)).",
            detail: "Heute ist der \(cal.component(.day, from: today)).",
            relatedTxId: nil,
            snoozeKey: "salary-missing"
        )]
    }

    /// F: Doppelte Abbuchung
    private static func detectDuplicates(
        recent: [TransactionsResponse.Transaction]
    ) -> [AttentionCard] {
        var seen: [String: [TransactionsResponse.Transaction]] = [:]
        for tx in recent {
            let key = "\(canonicalMerchant(tx))|\(String(format: "%.2f", abs(txAmount(tx))))"
            seen[key, default: []].append(tx)
        }
        var cards: [AttentionCard] = []
        for (_, group) in seen where group.count >= 2 {
            let tx     = group[0]
            let name   = canonicalMerchant(tx)
            let amount = abs(txAmount(tx))
            // Bekannte monatliche Abos (spotify, netflix etc.) mit 2 Vorkommen in 7 Tagen ausschließen
            // Wenn Merchant ein Known-Service ist und Betrag < 30€ → kein Alert
            let isKnownSub = FixedCostsAnalyzer.categoryForMerchant(name) != .other && amount < 30
            guard !isKnownSub else { continue }
            cards.append(AttentionCard(
                type: .possibleDuplicate,
                priority: 1,
                title: "Möglicherweise doppelt: \(name)",
                body: "Zwei Abbuchungen mit gleichem Betrag innerhalb von 7 Tagen.",
                detail: formatAmount(amount) + " × \(group.count)",
                relatedTxId: TransactionRecord.fingerprint(for: tx),
                snoozeKey: "duplicate:\(name):\(String(format: "%.2f", amount))"
            ))
        }
        return cards
    }

    /// A: Abo / Fixkosten teurer geworden
    private static func detectSubscriptionIncrease(
        recent: [TransactionsResponse.Transaction],
        history: [TransactionsResponse.Transaction]
    ) -> [AttentionCard] {
        let recurring = FixedCostsAnalyzer.analyze(transactions: history)
        guard !recurring.isEmpty else { return [] }

        var cards: [AttentionCard] = []
        let recentByMerchant = Dictionary(grouping: recent, by: { canonicalMerchant($0) })

        for payment in recurring {
            guard let latestTxs = recentByMerchant[payment.merchant], let latestTx = latestTxs.first else { continue }
            let latestAmount = abs(txAmount(latestTx))
            let avg          = payment.averageAmount
            guard avg > 0 else { continue }
            let diff = latestAmount - avg
            // Trigger: mehr als 5% UND mehr als 1€ teurer
            guard diff > max(1.0, avg * 0.05) else { continue }
            cards.append(AttentionCard(
                type: .subscriptionPriceIncrease,
                priority: 2,
                title: "\(payment.merchant) kostet mehr als üblich",
                body: "Die Abbuchung liegt \(formatAmount(diff)) über deinem üblichen Betrag.",
                detail: "\(formatAmount(avg)) → \(formatAmount(latestAmount))",
                relatedTxId: TransactionRecord.fingerprint(for: latestTx),
                snoozeKey: "sub-increase:\(payment.merchant)"
            ))
        }
        return cards
    }

    /// B: Ungewöhnlich hohe Einzelausgabe
    private static func detectUnusualExpense(
        recent: [TransactionsResponse.Transaction],
        history: [TransactionsResponse.Transaction]
    ) -> [AttentionCard] {
        // Median-Betrag je Merchant aus History
        var medians: [String: Double] = [:]
        let byMerchant = Dictionary(grouping: history, by: { canonicalMerchant($0) })
        for (merchant, txs) in byMerchant where txs.count >= 3 {
            let amounts = txs.map { abs(txAmount($0)) }.sorted()
            let mid     = amounts.count / 2
            medians[merchant] = amounts.count % 2 == 0
                ? (amounts[mid - 1] + amounts[mid]) / 2
                : amounts[mid]
        }

        var cards: [AttentionCard] = []
        for tx in recent {
            let name   = canonicalMerchant(tx)
            let amount = abs(txAmount(tx))
            guard let median = medians[name], median > 5 else { continue }
            // Trigger: mehr als 2× Median UND mindestens 20€ absolut
            guard amount > median * 2.0 && amount - median > 20 else { continue }
            cards.append(AttentionCard(
                type: .unusuallyHighExpense,
                priority: 2,
                title: "Ungewöhnlich hohe Ausgabe bei \(name)",
                body: "Diese Abbuchung ist deutlich höher als dein üblicher Betrag dort.",
                detail: formatAmount(amount) + " (normal ~\(formatAmount(median)))",
                relatedTxId: TransactionRecord.fingerprint(for: tx),
                snoozeKey: "unusual-expense:\(name)"
            ))
        }
        return Array(cards.prefix(2)) // max 2 pro Durchlauf
    }

    /// E: Neue SEPA-Lastschrift
    private static func detectNewDirectDebit(
        recent: [TransactionsResponse.Transaction],
        history: [TransactionsResponse.Transaction]
    ) -> [AttentionCard] {
        let isDebit: (TransactionsResponse.Transaction) -> Bool = { tx in
            let addInfo = (tx.additionalInformation ?? "").uppercased()
            let purpose = (tx.remittanceInformation ?? []).joined().uppercased()
            return addInfo.contains("LASTSCHRIFT") || addInfo.contains("SEPA") ||
                   purpose.contains("LASTSCHRIFT") || tx.purposeCode == "DBIT"
        }

        // Bekannte Lastschrift-IBANs: nur aus History vor dem 14-Tage-Fenster (recent ⊆ history)
        let debitCutoff14 = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let knownIBANs = Set(
            history.filter { txDate($0) < debitCutoff14 }.compactMap { $0.creditor?.iban }.filter { !$0.isEmpty }
        )

        var cards: [AttentionCard] = []
        for tx in recent where isDebit(tx) {
            let iban   = tx.creditor?.iban ?? ""
            guard !iban.isEmpty, !knownIBANs.contains(iban) else { continue }
            let name   = canonicalMerchant(tx)
            let amount = abs(txAmount(tx))
            cards.append(AttentionCard(
                type: .newDirectDebit,
                priority: 2,
                title: "Neue Lastschrift: \(name)",
                body: "Diese IBAN hat bisher noch keine Lastschrift eingezogen.",
                detail: formatAmount(amount) + " · \(tx.bookingDate ?? "")",
                relatedTxId: TransactionRecord.fingerprint(for: tx),
                snoozeKey: "new-debit:\(iban)"
            ))
        }
        return Array(cards.prefix(2))
    }

    /// C: Neuer Händler
    private static func detectNewMerchant(
        recent: [TransactionsResponse.Transaction],
        knownMerchants: Set<String>
    ) -> [AttentionCard] {
        var seen  = Set<String>()
        var cards: [AttentionCard] = []
        for tx in recent {
            let name = canonicalMerchant(tx)
            guard !name.isEmpty, name != "Unbekannt", name != "Bargeldabhebung" else { continue }
            guard !knownMerchants.contains(name), !seen.contains(name) else { continue }
            seen.insert(name)
            let amount = abs(txAmount(tx))
            cards.append(AttentionCard(
                type: .newMerchant,
                priority: 3,
                title: "Erster Einkauf bei \(name)",
                body: "Dieser Händler ist in deiner bisherigen Transaktionshistorie neu.",
                detail: formatAmount(amount) + " · \(tx.bookingDate ?? "")",
                relatedTxId: TransactionRecord.fingerprint(for: tx),
                snoozeKey: "new-merchant:\(name)"
            ))
        }
        return Array(cards.prefix(2))
    }

    /// G: Kategorie-Spike (aktueller Monat vs. Vormonatsdurchschnitt)
    private static func detectCategorySpike(
        recent: [TransactionsResponse.Transaction],
        history: [TransactionsResponse.Transaction]
    ) -> [AttentionCard] {
        let cal = Calendar.current
        let now = Date()
        let currentMonth = cal.dateComponents([.year, .month], from: now)

        // Aktuelle Monatssummen je effektiver Kategorie
        let thisMonthTxs = recent.filter {
            guard let d = txDateOpt($0) else { return false }
            return cal.dateComponents([.year, .month], from: d) == currentMonth
        }

        var currentTotals: [String: Double] = [:]
        for tx in thisMonthTxs {
            let cat = effectiveCategory(tx)
            currentTotals[cat, default: 0] += abs(txAmount(tx))
        }

        // Vergangene Monate: Durchschnitt je Kategorie
        var monthlyTotals: [String: [Double]] = [:]
        let pastTxs = history.filter {
            guard let d = txDateOpt($0) else { return false }
            return cal.dateComponents([.year, .month], from: d) != currentMonth
        }
        let byMonth = Dictionary(grouping: pastTxs, by: {
            cal.dateComponents([.year, .month], from: txDate($0))
        })
        for (_, txs) in byMonth {
            var monthSums: [String: Double] = [:]
            for tx in txs { monthSums[effectiveCategory(tx), default: 0] += abs(txAmount(tx)) }
            for (cat, sum) in monthSums { monthlyTotals[cat, default: []].append(sum) }
        }

        var cards: [(card: AttentionCard, ratio: Double)] = []
        for (cat, currentTotal) in currentTotals where currentTotal > 20 {
            guard let pastAmounts = monthlyTotals[cat], pastAmounts.count >= 2 else { continue }
            let avg = pastAmounts.reduce(0, +) / Double(pastAmounts.count)
            guard avg > 20, currentTotal > avg * 1.6 else { continue }
            let ratio = currentTotal / avg
            let factor = Int((ratio * 10).rounded()) // z.B. 17 → "1,7×"
            let card = AttentionCard(
                type: .categorySpike,
                priority: 3,
                title: "\(cat) diesen Monat deutlich höher",
                body: "Du hast bisher \(formatAmount(currentTotal)) ausgegeben — etwa \(factor / 10),\(factor % 10)× mehr als üblich.",
                detail: "Ø \(formatAmount(avg)) / Monat",
                relatedTxId: nil,
                snoozeKey: "cat-spike:\(cat)"
            )
            cards.append((card, ratio))
        }
        // Stärkster Spike zuerst
        return cards.sorted { $0.ratio > $1.ratio }.prefix(1).map(\.card)
    }

    // MARK: - Helpers

    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let eurFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f
    }()

    static func txAmount(_ tx: TransactionsResponse.Transaction) -> Double {
        tx.parsedAmount  // handles German "1.200,50" format via AmountParser
    }

    private static func txDate(_ tx: TransactionsResponse.Transaction) -> Date {
        txDateOpt(tx) ?? .distantPast
    }

    private static func txDateOpt(_ tx: TransactionsResponse.Transaction) -> Date? {
        guard let s = tx.bookingDate ?? tx.valueDate else { return nil }
        return isoFmt.date(from: s)
    }

    static func canonicalMerchant(_ tx: TransactionsResponse.Transaction) -> String {
        MerchantResolver.resolve(transaction: tx).effectiveMerchant
    }

    private static func effectiveCategory(_ tx: TransactionsResponse.Transaction) -> String {
        let cat = FixedCostsAnalyzer.categoryForMerchant(canonicalMerchant(tx))
        return cat == .other ? "Sonstiges" : cat.rawValue
    }

    private static func formatAmount(_ amount: Double) -> String {
        eurFmt.string(from: NSNumber(value: amount)) ?? String(format: "%.2f €", amount)
    }
}
