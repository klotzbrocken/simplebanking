import Foundation

// MARK: - Search v2 — Semantic Transaction Search

/// Parsed search query with structured dimensions.
struct TransactionSearchQuery {
    var textTerms: [String] = []
    var minAmount: Double?
    var maxAmount: Double?
    var exactAmount: Double?
    var exactAmountIsInteger: Bool = false
    var dateRange: DateInterval?
    var kinds: Set<SearchTransactionKind> = []
    var categories: Set<TransactionCategory> = []

    var isEmpty: Bool {
        textTerms.isEmpty && minAmount == nil && maxAmount == nil
            && exactAmount == nil && dateRange == nil
            && kinds.isEmpty && categories.isEmpty
    }
}

enum SearchTransactionKind {
    case income
    case expense
    case debit
    case subscription
    case salary
}

// MARK: - Tokenizer + Classifier

enum TransactionSearchEngine {

    /// Parse a raw search string into a structured query.
    static func parse(_ raw: String, now: Date = Date()) -> TransactionSearchQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TransactionSearchQuery() }

        var query = TransactionSearchQuery()
        let tokens = tokenize(trimmed)

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let lower = token.lowercased()

            // Try multi-word date patterns first ("letzter monat", "diese woche", "letzte woche")
            if i + 1 < tokens.count {
                let twoWord = "\(lower) \(tokens[i + 1].lowercased())"
                if let range = parseDateRange(twoWord, now: now) {
                    query.dateRange = merge(query.dateRange, range)
                    i += 2
                    continue
                }
            }

            // Amount operator: >100, <20, >=50, <=10
            if let (op, value) = parseAmountOperator(token) {
                switch op {
                case .gt:  query.minAmount = maxOpt(query.minAmount, value + 0.01)
                case .gte: query.minAmount = maxOpt(query.minAmount, value)
                case .lt:  query.maxAmount = minOpt(query.maxAmount, value - 0.01)
                case .lte: query.maxAmount = minOpt(query.maxAmount, value)
                }
                i += 1
                continue
            }

            // Exact amount: naked number like "49,99" or "32"
            if let value = parseGermanNumber(token), value > 0 {
                query.exactAmount = value
                query.exactAmountIsInteger = !token.contains(",") && !token.contains(".")
                i += 1
                continue
            }

            // Type keyword
            if let kind = parseKind(lower) {
                query.kinds.insert(kind)
                i += 1
                continue
            }

            // Category keyword
            if let cat = parseCategory(lower) {
                query.categories.insert(cat)
                i += 1
                continue
            }

            // Single-word date (month name, "heute", "gestern")
            if let range = parseDateRange(lower, now: now) {
                query.dateRange = merge(query.dateRange, range)
                i += 1
                continue
            }

            // Fallback: free text
            query.textTerms.append(lower)
            i += 1
        }

        return query
    }

    // MARK: - Execute

    /// Filter transactions by a parsed query. Uses the same in-memory list
    /// the ViewModel already holds — no extra DB round-trip needed for v1.
    static func execute(
        query: TransactionSearchQuery,
        transactions: [TransactionsResponse.Transaction],
        searchIndex: [String],
        subscriptionIDs: Set<String>
    ) -> [TransactionsResponse.Transaction] {
        guard !query.isEmpty else { return transactions }

        return transactions.enumerated().filter { index, tx in
            // Text terms — AND combination, each must match the search index
            if !query.textTerms.isEmpty {
                let haystack = index < searchIndex.count ? searchIndex[index] : ""
                for term in query.textTerms {
                    let dotVariant = term.replacingOccurrences(of: ",", with: ".")
                    if !haystack.contains(term) && !haystack.contains(dotVariant) {
                        return false
                    }
                }
            }

            // Amount filters
            let amt = abs(tx.parsedAmount)
            if let min = query.minAmount, amt < min { return false }
            if let max = query.maxAmount, amt > max { return false }
            if let exact = query.exactAmount {
                let amtMatches: Bool
                if query.exactAmountIsInteger {
                    // Integer input: match if floor(amt) == N or round(amt) == N
                    // "20" → 19.50–20.99, "32" → 31.50–32.99
                    let n = Int(exact)
                    amtMatches = Int(amt.rounded(.down)) == n || Int(amt.rounded()) == n
                } else {
                    // Decimal input: exact match with 2 cent tolerance
                    amtMatches = abs(amt - exact) < 0.02
                }
                if !amtMatches { return false }
            }

            // Date range
            if let range = query.dateRange {
                guard let txDate = txBookingDate(tx) else { return false }
                if txDate < range.start || txDate > range.end { return false }
            }

            // Kind filters — OR within kinds
            if !query.kinds.isEmpty {
                let matchesAny = query.kinds.contains { kind in
                    switch kind {
                    case .income:       return tx.parsedAmount > 0
                    case .expense:      return tx.parsedAmount < 0
                    case .debit:        return isDebitTx(tx)
                    case .subscription: return subscriptionIDs.contains(TransactionRecord.fingerprint(for: tx))
                    case .salary:       return isSalaryTx(tx)
                    }
                }
                if !matchesAny { return false }
            }

            // Category filters — OR within categories
            if !query.categories.isEmpty {
                let txCat = TransactionCategorizer.category(for: tx)
                if !query.categories.contains(txCat) { return false }
            }

            return true
        }.map(\.1)
    }

    // MARK: - Token Helpers

    private static func tokenize(_ input: String) -> [String] {
        // Split on whitespace, preserving operator-number combos like ">100"
        input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private enum AmountOp { case gt, gte, lt, lte }

    private static func parseAmountOperator(_ token: String) -> (AmountOp, Double)? {
        let s = token
        if s.hasPrefix(">="), let v = parseGermanNumber(String(s.dropFirst(2))) { return (.gte, v) }
        if s.hasPrefix("<="), let v = parseGermanNumber(String(s.dropFirst(2))) { return (.lte, v) }
        if s.hasPrefix(">"),  let v = parseGermanNumber(String(s.dropFirst(1))) { return (.gt, v)  }
        if s.hasPrefix("<"),  let v = parseGermanNumber(String(s.dropFirst(1))) { return (.lt, v)  }
        return nil
    }

    private static func parseGermanNumber(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        // German: "1.234,56" or "49,99" — also accept "49.99"
        let normalized: String
        if cleaned.contains(",") {
            // "1.234,56" → "1234.56"
            normalized = cleaned
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
        } else {
            normalized = cleaned
        }
        return Double(normalized)
    }

    private static func parseKind(_ lower: String) -> SearchTransactionKind? {
        switch lower {
        case "eingang", "eingänge", "einkommen", "income":  return .income
        case "ausgabe", "ausgaben", "expense", "expenses":   return .expense
        case "lastschrift", "lastschriften", "sepa", "debit": return .debit
        case "abo", "abos", "subscription", "subscriptions": return .subscription
        case "gehalt", "lohn", "salary":                      return .salary
        default: return nil
        }
    }

    private static func parseCategory(_ lower: String) -> TransactionCategory? {
        // Direct matches and common aliases
        let map: [String: TransactionCategory] = [
            // German display names (lowercased)
            "essen":          .essenAlltag,
            "essen & alltag": .essenAlltag,
            "alltag":         .essenAlltag,
            "lebensmittel":   .essenAlltag,
            "gastronomie":    .gastronomie,
            "restaurant":     .gastronomie,
            "shopping":       .shopping,
            "einkaufen":      .shopping,
            "versicherung":   .versicherungen,
            "versicherungen": .versicherungen,
            "mobilität":      .mobilitaet,
            "mobilitaet":     .mobilitaet,
            "transport":      .mobilitaet,
            "auto":           .mobilitaet,
            "wohnen":         .wohnenKredit,
            "miete":          .wohnenKredit,
            "kredit":         .wohnenKredit,
            "digital":        .abosDigital,
            "sparen":         .sparen,
            "freizeit":       .freizeit,
            "gesundheit":     .gesundheit,
            "umbuchung":      .umbuchung,
            "umbuchungen":    .umbuchung,
            "sonstiges":      .sonstiges,
        ]
        return map[lower]
    }

    // MARK: - Date Parsing

    private static let germanMonths: [(String, Int)] = [
        ("januar", 1), ("februar", 2), ("märz", 3), ("april", 4),
        ("mai", 5), ("juni", 6), ("juli", 7), ("august", 8),
        ("september", 9), ("oktober", 10), ("november", 11), ("dezember", 12),
        // Short forms
        ("jan", 1), ("feb", 2), ("mär", 3), ("apr", 4),
        ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9),
        ("okt", 10), ("nov", 11), ("dez", 12),
        // English
        ("january", 1), ("february", 2), ("march", 3), ("may", 5),
        ("june", 6), ("july", 7), ("october", 10), ("december", 12),
    ]

    private static func parseDateRange(_ text: String, now: Date) -> DateInterval? {
        let cal = Calendar.current

        switch text {
        case "heute", "today":
            let start = cal.startOfDay(for: now)
            return DateInterval(start: start, end: cal.date(byAdding: .day, value: 1, to: start)!)

        case "gestern", "yesterday":
            let todayStart = cal.startOfDay(for: now)
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
            return DateInterval(start: yesterdayStart, end: todayStart)

        case "diese woche", "this week":
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
            let end = cal.date(byAdding: .weekOfYear, value: 1, to: start)!
            return DateInterval(start: start, end: end)

        case "letzte woche", "last week":
            let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
            let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!
            return DateInterval(start: lastWeekStart, end: thisWeekStart)

        case "dieser monat", "this month":
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps)!
            let end = cal.date(byAdding: .month, value: 1, to: start)!
            return DateInterval(start: start, end: end)

        case "letzter monat", "last month":
            let comps = cal.dateComponents([.year, .month], from: now)
            let thisMonthStart = cal.date(from: comps)!
            let lastMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart)!
            return DateInterval(start: lastMonthStart, end: thisMonthStart)

        default:
            break
        }

        // Month name → range for that month (current or previous year)
        for (name, month) in germanMonths {
            if text == name {
                let year = cal.component(.year, from: now)
                let currentMonth = cal.component(.month, from: now)
                let targetYear = month > currentMonth ? year - 1 : year
                let start = cal.date(from: DateComponents(year: targetYear, month: month, day: 1))!
                let end = cal.date(byAdding: .month, value: 1, to: start)!
                return DateInterval(start: start, end: end)
            }
        }

        return nil
    }

    // MARK: - Transaction Helpers

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func txBookingDate(_ tx: TransactionsResponse.Transaction) -> Date? {
        guard let s = tx.bookingDate ?? tx.valueDate, s.count >= 10 else { return nil }
        return isoDateFormatter.date(from: String(s.prefix(10)))
    }

    private static func isDebitTx(_ tx: TransactionsResponse.Transaction) -> Bool {
        let purpose = tx.purposeCode?.uppercased() ?? ""
        if purpose == "DBIT" { return true }
        let text = ((tx.remittanceInformation ?? []).joined(separator: " ")
            + " " + (tx.additionalInformation ?? "")).uppercased()
        return text.contains("LASTSCHRIFT") || text.contains("SEPA-LASTSCHRIFT")
    }

    private static func isSalaryTx(_ tx: TransactionsResponse.Transaction) -> Bool {
        guard tx.parsedAmount > 0 else { return false }
        let purpose = tx.purposeCode?.uppercased() ?? ""
        if purpose == "SALA" { return true }
        let text = ((tx.remittanceInformation ?? []).joined(separator: " ")
            + " " + (tx.additionalInformation ?? "")).uppercased()
        return text.contains("GEHALT") || text.contains("LOHN")
    }

    // MARK: - Utility

    private static func merge(_ existing: DateInterval?, _ new: DateInterval) -> DateInterval {
        guard let e = existing else { return new }
        let start = max(e.start, new.start)
        let end = min(e.end, new.end)
        guard start < end else { return new }
        return DateInterval(start: start, end: end)
    }

    private static func maxOpt(_ a: Double?, _ b: Double) -> Double {
        guard let a else { return b }
        return max(a, b)
    }

    private static func minOpt(_ a: Double?, _ b: Double) -> Double {
        guard let a else { return b }
        return min(a, b)
    }
}
