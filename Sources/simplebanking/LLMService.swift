import Foundation

enum LLMServiceError: LocalizedError {
    case missingAPIKey
    case emptyQuestion
    case emptyModelResponse
    case invalidResultPayload

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Kein API-Key hinterlegt."
        case .emptyQuestion:
            return "Bitte eine Frage eingeben."
        case .emptyModelResponse:
            return "Das Modell hat keine Antwort geliefert."
        case .invalidResultPayload:
            return "Konnte das SQL-Ergebnis nicht serialisieren."
        }
    }
}

private struct DateScope {
    let sqlClause: String
    let description: String
}

private struct QueryPlan {
    let sql: String
    let renderAnswer: ([[String: String]]) -> String
}

enum LLMService {
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let groceryKeywords: [String] = [
        "rewe", "nahkauf", "edeka", "aldi", "lidl", "penny", "netto", "kaufland", "tegut", "globus", "norma", "denns", "supermarkt", "bio company",
    ]

    private static let insuranceKeywords: [String] = [
        "versicherung", "versicher", "huk", "huk-coburg", "allianz", "axa", "generali", "barmenia", "signal iduna", "provinzial", "hansemerkur", "devk", "lvm",
    ]

    private static let subscriptionKeywords: [String] = [
        "spotify", "netflix", "disney", "youtube", "youtube premium", "apple services", "apple.com/bill", "google", "google play", "amazon prime", "prime video", "adobe", "chatgpt", "openai", "anthropic", "claude", "figma", "notion", "dazn", "sky", "waipu",
    ]

    private static let merchantKeywordCandidates: [String] = [
        "rewe", "nahkauf", "edeka", "aldi", "lidl", "penny", "netto", "kaufland", "dm", "rossmann", "amazon", "amzn", "paypal", "klarna", "landesbank", "anthropic", "claude", "openai", "chatgpt", "google", "youtube", "apple", "spotify", "netflix", "disney", "adobe", "microsoft", "dropbox", "notion", "figma", "vodafone", "telekom", "o2", "huk", "allianz", "axa", "generali", "versicherung", "deutsche bahn", "db vertrieb", "ikea", "lieferando", "uber", "bolt", "shell", "aral",
    ]

    private static let monthTokens: [(tokens: [String], month: Int, label: String)] = [
        (["januar", "january", "jan"], 1, "Januar"),
        (["februar", "february", "feb"], 2, "Februar"),
        (["maerz", "marz", "march", "mrz", "mae"], 3, "März"),
        (["april", "apr"], 4, "April"),
        (["mai", "may"], 5, "Mai"),
        (["juni", "june", "jun"], 6, "Juni"),
        (["juli", "july", "jul"], 7, "Juli"),
        (["august", "aug"], 8, "August"),
        (["september", "sept", "sep"], 9, "September"),
        (["oktober", "october", "okt", "oct"], 10, "Oktober"),
        (["november", "nov"], 11, "November"),
        (["dezember", "december", "dez", "dec"], 12, "Dezember"),
    ]

    private static let effectiveMerchantExpression =
        "COALESCE(NULLIF(trim(effective_merchant), ''), COALESCE(NULLIF(trim(empfaenger), ''), NULLIF(trim(absender), ''), 'Unbekannt'))"

    private static var searchableTextExpression: String {
        """
        lower(COALESCE(NULLIF(search_text, ''),
        COALESCE(\(effectiveMerchantExpression), '') || ' ' ||
        COALESCE(normalized_merchant, '') || ' ' ||
        COALESCE(empfaenger, '') || ' ' ||
        COALESCE(absender, '') || ' ' ||
        COALESCE(verwendungszweck, '') || ' ' ||
        COALESCE(additional_information, '') || ' ' ||
        COALESCE(raw_json, '') || ' ' ||
        COALESCE(iban, '')))
        """
    }

    static func ask(question: String, apiKey: String) async throws -> LLMAnswer {
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuestion.isEmpty else { throw LLMServiceError.emptyQuestion }

        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw LLMServiceError.missingAPIKey }

        let plan = ruleBasedPlan(for: normalizedQuestion)
        let sql = if let plan {
            plan.sql
        } else {
            try await generateSQL(for: normalizedQuestion, apiKey: normalizedKey)
        }

        let safeSQL = try SQLGuard.validatedReadOnlySQL(sql, defaultLimit: 200)
        let rows = try TransactionsDatabase.executeReadOnlyQuery(sql: safeSQL)

        let answer: String
        if let plan, !rows.isEmpty {
            answer = plan.renderAnswer(rows)
        } else {
            answer = try await generateAnswer(
                question: normalizedQuestion,
                sql: safeSQL,
                rows: rows,
                apiKey: normalizedKey
            )
        }

        return LLMAnswer(sql: safeSQL, resultRows: rows, answerText: answer)
    }

    // MARK: - Rule-based SQL for frequent intents

    private static func ruleBasedPlan(for question: String) -> QueryPlan? {
        let normalized = normalize(question)
        let scope = dateScope(for: normalized)

        let asksCount = containsAny(normalized, needles: ["wie viele", "wieviele", "anzahl", "wie oft"])
        let asksIncome = containsAny(normalized, needles: ["einnahm", "gehalt", "lohn", "eingang", "eingange", "einkommen", "verdien"])
        let asksExpense = containsAny(normalized, needles: ["ausgab", "ausgegeben", "kosten", "spend", "zahlung", "bezahlt", "gezahlt", "gebe ich aus"])
        let asksTop = containsAny(normalized, needles: ["wofur", "wofuer", "grosste", "groesste", "hochste", "meiste", "top", "teuerste", "am meisten"])
        let asksGrocery = containsAny(normalized, needles: ["lebensmittel", "supermarkt", "einkaufen", "groceries"])
        let asksInsurance = containsAny(normalized, needles: ["versicherung", "versicherungen", "insurance"])
        let asksSubscriptions = containsAny(normalized, needles: ["abo", "abonnement", "subscription", "subscriptions"])
        let asksFixedCosts = containsAny(normalized, needles: ["fixkosten", "feste kosten", "wiederkehrend", "recurring"])
        let asksCash = containsAny(normalized, needles: ["bargeld", "abhebung", "geldautomat", "cash"])
        let asksSummary = containsAny(normalized, needles: ["zusammenfassung", "uberblick", "ueberblick", "ubersicht", "overview", "summary", "stand"])

        if asksSummary {
            return summaryPlan(scope: scope)
        }
        if asksCash {
            return cashPlan(scope: scope)
        }
        if asksInsurance {
            return insurancePlan(scope: scope)
        }
        if asksSubscriptions {
            return subscriptionsPlan(scope: scope)
        }
        if asksFixedCosts {
            return fixedCostsPlan(scope: scope)
        }
        if asksGrocery {
            return groceryPlan(scope: scope)
        }
        if asksTop && !asksIncome {
            return topExpensesPlan(scope: scope)
        }
        if let merchant = extractMerchant(from: normalized) {
            return merchantPlan(merchant: merchant, scope: scope)
        }
        if asksIncome {
            return incomePlan(scope: scope, preferCount: asksCount)
        }
        if asksExpense {
            return expensePlan(scope: scope, preferCount: asksCount)
        }

        return nil
    }

    private static func incomePlan(scope: DateScope, preferCount: Bool) -> QueryPlan {
        let sql = """
        SELECT
            COUNT(*) AS anzahl_einnahmen,
            ROUND(COALESCE(SUM(betrag), 0), 2) AS summe_einnahmen
        FROM transactions
        WHERE betrag > 0\(scope.sqlClause)
        """

        return QueryPlan(sql: sql) { rows in
            let count = intValue(from: rows, key: "anzahl_einnahmen")
            let total = doubleValue(from: rows, key: "summe_einnahmen")

            if count == 0 || total <= 0 {
                return "Ich konnte \(scope.description) keine Einnahmen finden."
            }

            if preferCount {
                return "Du hast \(scope.description) \(count) Einnahmen mit zusammen \(formatEUR(total))."
            }
            return "Du hast \(scope.description) \(formatEUR(total)) eingenommen, verteilt auf \(count) Buchungen."
        }
    }

    private static func expensePlan(scope: DateScope, preferCount: Bool) -> QueryPlan {
        let sql = """
        SELECT
            COUNT(*) AS anzahl_ausgaben,
            ROUND(COALESCE(SUM(-betrag), 0), 2) AS summe_ausgaben
        FROM transactions
        WHERE betrag < 0\(scope.sqlClause)
        """

        return QueryPlan(sql: sql) { rows in
            let count = intValue(from: rows, key: "anzahl_ausgaben")
            let total = doubleValue(from: rows, key: "summe_ausgaben")

            if count == 0 || total <= 0 {
                return "Ich konnte \(scope.description) keine Ausgaben finden."
            }

            if preferCount {
                return "Du hast \(scope.description) \(count) Ausgaben mit zusammen \(formatEUR(total))."
            }
            return "Du hast \(scope.description) \(formatEUR(total)) ausgegeben, verteilt auf \(count) Buchungen."
        }
    }

    private static func merchantPlan(merchant: String, scope: DateScope) -> QueryPlan {
        let terms = merchantSearchTerms(for: merchant)
        let displayMerchant = merchant.uppercased()
        let whereClause = containsAnyTermsClause(terms)

        let sql = """
        SELECT
            COUNT(*) AS anzahl_buchungen,
            ROUND(COALESCE(SUM(CASE WHEN betrag < 0 THEN -betrag ELSE 0 END), 0), 2) AS summe_ausgaben,
            ROUND(COALESCE(SUM(CASE WHEN betrag > 0 THEN betrag ELSE 0 END), 0), 2) AS summe_einnahmen
        FROM transactions
        WHERE (\(whereClause))\(scope.sqlClause)
        """

        return QueryPlan(sql: sql) { rows in
            let count = intValue(from: rows, key: "anzahl_buchungen")
            let expenses = doubleValue(from: rows, key: "summe_ausgaben")
            let incomes = doubleValue(from: rows, key: "summe_einnahmen")

            if count == 0 {
                return "Ich konnte für \(displayMerchant) \(scope.description) keine passenden Buchungen finden."
            }

            var text = "Bei \(displayMerchant) hast du \(scope.description) \(formatEUR(expenses)) ausgegeben"
            if incomes > 0 {
                text += " und \(formatEUR(incomes)) eingenommen"
            }
            text += " (\(count) Buchungen insgesamt)."
            return text
        }
    }

    private static func groceryPlan(scope: DateScope) -> QueryPlan {
        let sql = """
        SELECT
            COUNT(*) AS anzahl_buchungen,
            ROUND(COALESCE(SUM(-betrag), 0), 2) AS summe_lebensmittel
        FROM transactions
        WHERE betrag < 0
          AND (\(containsAnyTermsClause(groceryKeywords)))\(scope.sqlClause)
        """

        return QueryPlan(sql: sql) { rows in
            let count = intValue(from: rows, key: "anzahl_buchungen")
            let total = doubleValue(from: rows, key: "summe_lebensmittel")

            if count == 0 || total <= 0 {
                return "Ich konnte \(scope.description) keine Lebensmittel-Ausgaben finden."
            }
            return "Für Lebensmittel hast du \(scope.description) \(formatEUR(total)) ausgegeben, aufgeteilt auf \(count) Buchungen."
        }
    }

    private static func topExpensesPlan(scope: DateScope) -> QueryPlan {
        let sql = """
        SELECT merchant,
               COUNT(*) AS anzahl_buchungen,
               ROUND(SUM(-betrag), 2) AS summe_ausgaben
        FROM (
            SELECT betrag,
                   \(effectiveMerchantExpression) AS merchant
            FROM transactions
            WHERE betrag < 0\(scope.sqlClause)
        )
        GROUP BY merchant
        ORDER BY summe_ausgaben DESC
        LIMIT 10
        """

        return QueryPlan(sql: sql) { rows in
            guard !rows.isEmpty else {
                return "Ich konnte \(scope.description) keine Ausgaben finden."
            }

            let topRows = Array(rows.prefix(3))
            let restRows = Array(rows.dropFirst(3))

            var parts: [String] = ["Deine größten Ausgabeposten \(scope.description):"]

            for (index, row) in topRows.enumerated() {
                let merchant = stringValue(in: row, key: "merchant", fallback: "Unbekannt")
                let total = doubleValue(in: row, key: "summe_ausgaben")
                let count = intValue(in: row, key: "anzahl_buchungen")
                if index == 0 {
                    parts.append("Am meisten ging an \(merchant) mit \(formatEUR(total)) (\(count) Buchungen).")
                } else if index == 1 {
                    parts.append("Danach kommt \(merchant) mit \(formatEUR(total)) (\(count) Buchungen).")
                } else {
                    parts.append("Auf Platz 3 liegt \(merchant) mit \(formatEUR(total)) (\(count) Buchungen).")
                }
            }

            if !restRows.isEmpty {
                let restTotal = restRows.reduce(0.0) { partial, row in
                    partial + doubleValue(in: row, key: "summe_ausgaben")
                }
                let restNames = restRows
                    .prefix(4)
                    .map { stringValue(in: $0, key: "merchant", fallback: "Unbekannt") }
                    .joined(separator: ", ")
                parts.append("Dahinter folgen unter anderem \(restNames) mit zusammen \(formatEUR(restTotal)).")
            }

            return parts.joined(separator: "\n")
        }
    }

    private static func insurancePlan(scope: DateScope) -> QueryPlan {
        let sql = """
        SELECT merchant,
               COUNT(*) AS anzahl_buchungen,
               ROUND(SUM(-betrag), 2) AS summe_ausgaben
        FROM (
            SELECT betrag,
                   \(effectiveMerchantExpression) AS merchant
            FROM transactions
            WHERE betrag < 0
              AND (\(containsAnyTermsClause(insuranceKeywords)))\(scope.sqlClause)
        )
        GROUP BY merchant
        ORDER BY summe_ausgaben DESC
        LIMIT 10
        """

        return QueryPlan(sql: sql) { rows in
            guard !rows.isEmpty else {
                return "Ich konnte \(scope.description) keine Versicherungsausgaben finden."
            }

            let total = rows.reduce(0.0) { partial, row in
                partial + doubleValue(in: row, key: "summe_ausgaben")
            }
            let bookingCount = rows.reduce(0) { partial, row in
                partial + intValue(in: row, key: "anzahl_buchungen")
            }

            var lines: [String] = ["Für Versicherungen hast du \(scope.description) insgesamt \(formatEUR(total)) ausgegeben (\(bookingCount) Buchungen)."]
            for row in rows.prefix(5) {
                let merchant = stringValue(in: row, key: "merchant", fallback: "Unbekannt")
                let sum = doubleValue(in: row, key: "summe_ausgaben")
                lines.append("Davon \(merchant): \(formatEUR(sum)).")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func subscriptionsPlan(scope: DateScope) -> QueryPlan {
        let sql = """
        SELECT merchant,
               COUNT(*) AS anzahl_buchungen,
               ROUND(SUM(-betrag), 2) AS summe_ausgaben
        FROM (
            SELECT betrag,
                   \(effectiveMerchantExpression) AS merchant
            FROM transactions
            WHERE betrag < 0
              AND (\(containsAnyTermsClause(subscriptionKeywords)))\(scope.sqlClause)
        )
        GROUP BY merchant
        ORDER BY summe_ausgaben DESC
        LIMIT 20
        """

        return QueryPlan(sql: sql) { rows in
            guard !rows.isEmpty else {
                return "Ich konnte \(scope.description) keine Abo-Ausgaben finden."
            }

            let total = rows.reduce(0.0) { partial, row in
                partial + doubleValue(in: row, key: "summe_ausgaben")
            }
            var lines: [String] = ["Deine Abo-Ausgaben \(scope.description) liegen bei \(formatEUR(total))."]
            for row in rows.prefix(5) {
                let merchant = stringValue(in: row, key: "merchant", fallback: "Unbekannt")
                let sum = doubleValue(in: row, key: "summe_ausgaben")
                let count = intValue(in: row, key: "anzahl_buchungen")
                lines.append("\(merchant): \(formatEUR(sum)) (\(count) Buchungen).")
            }

            if rows.count > 5 {
                let restTotal = rows.dropFirst(5).reduce(0.0) { partial, row in
                    partial + doubleValue(in: row, key: "summe_ausgaben")
                }
                lines.append("Der Rest macht zusammen nochmal \(formatEUR(restTotal)) aus.")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func fixedCostsPlan(scope: DateScope) -> QueryPlan {
        let sql = """
        SELECT merchant,
               COUNT(*) AS anzahl_buchungen,
               ROUND(SUM(-betrag), 2) AS summe_ausgaben
        FROM (
            SELECT betrag,
                   \(effectiveMerchantExpression) AS merchant
            FROM transactions
            WHERE betrag < 0\(scope.sqlClause)
        )
        GROUP BY merchant
        HAVING anzahl_buchungen >= 2
        ORDER BY anzahl_buchungen DESC, summe_ausgaben DESC
        LIMIT 15
        """

        return QueryPlan(sql: sql) { rows in
            guard !rows.isEmpty else {
                return "Ich konnte \(scope.description) keine klaren Fixkosten erkennen."
            }

            var lines: [String] = ["Das sieht \(scope.description) nach deinen wahrscheinlichsten Fixkosten aus:"]
            for row in rows.prefix(6) {
                let merchant = stringValue(in: row, key: "merchant", fallback: "Unbekannt")
                let count = intValue(in: row, key: "anzahl_buchungen")
                let sum = doubleValue(in: row, key: "summe_ausgaben")
                lines.append("\(merchant): \(formatEUR(sum)) (\(count) Buchungen).")
            }

            if rows.count > 6 {
                lines.append("Ich sehe außerdem noch weitere wiederkehrende Posten in deinen Umsätzen.")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static func cashPlan(scope: DateScope) -> QueryPlan {
        let sql = """
        SELECT
            COUNT(*) AS anzahl_abhebungen,
            ROUND(COALESCE(SUM(-betrag), 0), 2) AS summe_bargeld
        FROM transactions
        WHERE betrag < 0
          AND (
            lower(COALESCE(verwendungszweck, '')) LIKE '%bargeldausz%'
            OR lower(COALESCE(additional_information, '')) LIKE '%barauszahl%'
            OR lower(COALESCE(empfaenger, '')) LIKE 'ga nr%'
            OR lower(COALESCE(empfaenger, '')) LIKE 'f0%'
            OR lower(\(effectiveMerchantExpression)) LIKE '%bargeld%'
          )\(scope.sqlClause)
        """

        return QueryPlan(sql: sql) { rows in
            let count = intValue(from: rows, key: "anzahl_abhebungen")
            let total = doubleValue(from: rows, key: "summe_bargeld")

            if count == 0 || total <= 0 {
                return "Ich konnte \(scope.description) keine Bargeldabhebungen finden."
            }
            return "Du hast \(scope.description) \(formatEUR(total)) Bargeld abgehoben (\(count) Buchungen)."
        }
    }

    private static func summaryPlan(scope: DateScope) -> QueryPlan {
        let sql = """
        SELECT
            COUNT(*) AS anzahl_buchungen,
            ROUND(COALESCE(SUM(CASE WHEN betrag > 0 THEN betrag ELSE 0 END), 0), 2) AS summe_einnahmen,
            ROUND(COALESCE(SUM(CASE WHEN betrag < 0 THEN -betrag ELSE 0 END), 0), 2) AS summe_ausgaben,
            ROUND(COALESCE(SUM(betrag), 0), 2) AS saldo
        FROM transactions
        WHERE 1 = 1\(scope.sqlClause)
        """

        return QueryPlan(sql: sql) { rows in
            let count = intValue(from: rows, key: "anzahl_buchungen")
            let incomes = doubleValue(from: rows, key: "summe_einnahmen")
            let expenses = doubleValue(from: rows, key: "summe_ausgaben")
            let saldo = doubleValue(from: rows, key: "saldo")

            if count == 0 {
                return "Ich konnte \(scope.description) keine Buchungen finden."
            }

            return "Kurzüberblick \(scope.description): Du hattest \(formatEUR(incomes)) Einnahmen und \(formatEUR(expenses)) Ausgaben. Unterm Strich liegt dein Saldo bei \(formatEUR(saldo)) (\(count) Buchungen)."
        }
    }

    private static func containsTermClause(_ rawTerm: String) -> String {
        let escaped = rawTerm.lowercased().replacingOccurrences(of: "'", with: "''")
        return searchableTextExpression + " LIKE '%" + escaped + "%'"
    }

    private static func containsAnyTermsClause(_ terms: [String]) -> String {
        terms.map(containsTermClause).joined(separator: " OR ")
    }

    private static func extractMerchant(from normalizedQuestion: String) -> String? {
        for keyword in merchantKeywordCandidates where normalizedQuestion.contains(keyword) {
            return keyword
        }

        let patterns = [
            "\\b(?:bei|fuer|fur|für|an|von)\\s+([a-z0-9äöüß&+\\-.]{2,})",
            "\\b(?:zu)\\s+([a-z0-9äöüß&+\\-.]{2,})",
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let nsRange = NSRange(normalizedQuestion.startIndex..<normalizedQuestion.endIndex, in: normalizedQuestion)
            guard let match = regex.firstMatch(in: normalizedQuestion, options: [], range: nsRange), match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: normalizedQuestion)
            else {
                continue
            }

            let raw = String(normalizedQuestion[range])
            if let cleaned = cleanMerchantCandidate(raw) {
                return cleaned
            }
        }

        return nil
    }

    private static func cleanMerchantCandidate(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,;:!?\"'()[]{}"))
            .replacingOccurrences(of: "  ", with: " ")

        guard trimmed.count >= 2 else { return nil }

        let lower = trimmed.lowercased()
        let blocklist: Set<String> = [
            "den", "dem", "der", "die", "das", "ein", "eine", "einem", "einer",
            "mir", "dir", "ihm", "ihr", "uns", "euch",
            "aus", "ein", "ab", "auf", "raus", "hoch", "runter", "weg",
        ]
        if blocklist.contains(lower) {
            return nil
        }

        return lower
    }

    private static func merchantSearchTerms(for merchant: String) -> [String] {
        switch merchant {
        case "rewe":
            return ["rewe", "rewe markt", "rewe city", "rewe center", "nahkauf"]
        case "aldi":
            return ["aldi", "aldi sud", "aldi nord"]
        case "netto":
            return ["netto", "netto marken-discount"]
        case "amazon", "amzn":
            return ["amazon", "amzn", "amazon marketplace", "amazon payments"]
        case "anthropic", "claude":
            return ["anthropic", "claude", "purchase at anthropic"]
        case "openai", "chatgpt":
            return ["openai", "chatgpt"]
        case "paypal":
            return ["paypal", "einkauf bei", "purchase at"]
        default:
            return [merchant]
        }
    }

    private static func dateScope(for normalizedQuestion: String) -> DateScope {
        if containsAny(normalizedQuestion, needles: ["letzte 30 tage", "letzten 30 tage", "in den letzten 30 tagen", "30 tage"]) {
            return DateScope(sqlClause: " AND buchungsdatum >= date('now', '-30 days')", description: "in den letzten 30 Tagen")
        }

        if containsAny(normalizedQuestion, needles: ["letzte 7 tage", "letzten 7 tage", "7 tage"]) {
            return DateScope(sqlClause: " AND buchungsdatum >= date('now', '-7 days')", description: "in den letzten 7 Tagen")
        }

        if containsAny(normalizedQuestion, needles: ["letzten monat", "vorherigen monat"]) {
            return DateScope(
                sqlClause: " AND strftime('%Y-%m', buchungsdatum) = strftime('%Y-%m', date('now', '-1 month'))",
                description: "im letzten Monat"
            )
        }

        if containsAny(normalizedQuestion, needles: ["diesen monat", "aktuellen monat", "this month"]) {
            return DateScope(
                sqlClause: " AND strftime('%Y-%m', buchungsdatum) = strftime('%Y-%m', 'now')",
                description: "im aktuellen Monat"
            )
        }

        if let monthInfo = monthTokens.first(where: { entry in entry.tokens.contains(where: normalizedQuestion.contains) }) {
            let year = inferYear(forMonth: monthInfo.month, in: normalizedQuestion)
            let month = String(format: "%02d", monthInfo.month)
            return DateScope(
                sqlClause: " AND strftime('%Y-%m', buchungsdatum) = '\(year)-\(month)'",
                description: "im \(monthInfo.label) \(year)"
            )
        }

        return DateScope(sqlClause: "", description: "insgesamt in deinen Umsätzen")
    }

    private static func detectYear(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "\\b(20\\d{2})\\b") else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange), match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
    }

    private static func inferYear(forMonth targetMonth: Int, in normalizedQuestion: String) -> Int {
        if let explicitYear = detectYear(in: normalizedQuestion) {
            return explicitYear
        }

        let now = Date()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)

        if targetMonth > currentMonth {
            return currentYear - 1
        }
        return currentYear
    }

    private static func normalize(_ input: String) -> String {
        input
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ text: String, needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func intValue(from rows: [[String: String]], key: String) -> Int {
        guard let raw = rows.first?[key] else { return 0 }
        return intValue(raw)
    }

    private static func intValue(in row: [String: String], key: String) -> Int {
        intValue(row[key] ?? "0")
    }

    private static func intValue(_ raw: String) -> Int {
        if let int = Int(raw) {
            return int
        }
        let asDouble = parseLooseDouble(raw)
        return Int(asDouble.rounded())
    }

    private static func doubleValue(from rows: [[String: String]], key: String) -> Double {
        guard let raw = rows.first?[key] else { return 0 }
        return parseLooseDouble(raw)
    }

    private static func doubleValue(in row: [String: String], key: String) -> Double {
        parseLooseDouble(row[key] ?? "0")
    }

    private static func stringValue(in row: [String: String], key: String, fallback: String = "") -> String {
        let raw = (row[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? fallback : raw
    }

    private static func parseLooseDouble(_ raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return 0 }

        let normalized = trimmed
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")

        return Double(normalized) ?? 0
    }

    private static func formatEUR(_ value: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f €", value)
    }

    // MARK: - Anthropic Calls

    private static func generateSQL(for question: String, apiKey: String) async throws -> String {
        let systemPrompt = """
        Du bist ein SQL-Generator für eine lokale SQLite-Datenbank.
        Gib ausschließlich EIN SQL-Statement zurück, ohne Markdown, ohne Erklärungen.
        Erlaubt ist nur SELECT (oder WITH ... SELECT), keine Writes.
        Bevorzuge aussagekräftige Aggregationen für Finanzfragen.

        Wichtige Datenrealität:
        - Viele Buchungen laufen über Intermediäre (PayPal, Klarna, Landesbank).
        - Der eigentliche Händler steckt oft in `verwendungszweck`.
        - Für Händlerfragen NICHT nur auf `empfaenger` filtern.

        Verfügbares Schema:
        CREATE TABLE transactions (
            tx_id TEXT PRIMARY KEY,
            end_to_end_id TEXT,
            datum TEXT NOT NULL,
            buchungsdatum TEXT NOT NULL,
            betrag REAL NOT NULL,
            waehrung TEXT NOT NULL DEFAULT 'EUR',
            empfaenger TEXT,
            absender TEXT,
            iban TEXT,
            verwendungszweck TEXT,
            kategorie TEXT,
            additional_information TEXT,
            effective_merchant TEXT,
            normalized_merchant TEXT,
            merchant_source TEXT,
            merchant_confidence REAL,
            search_text TEXT,
            raw_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        Nutze bei Händlerfragen primär `effective_merchant` und ergänzend `normalized_merchant`/`search_text`.
        """

        let userPrompt = """
        Nutzerfrage: \(question)

        Anforderungen:
        - Verwende vorzugsweise `buchungsdatum` für zeitliche Gruppierung.
        - Beträge < 0 sind Ausgaben, Beträge > 0 Einnahmen.
        - Für Summen von Ausgaben nutze `SUM(-betrag)` mit `WHERE betrag < 0`.
        - Bei "wie viel"-Fragen nutze Aggregation (SUM/COUNT) statt Einzelzeilen.
        - Für Textsuche bevorzugt `search_text` verwenden (Fallback: `effective_merchant`, `empfaenger`, `verwendungszweck`).
        - Wenn sinnvoll: Monatsaggregation über `strftime('%Y-%m', buchungsdatum)`.
        - Gib nur SQL zurück.
        """

        return try await AIProviderService.complete(
            provider: AIProvider.active,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userMessage: userPrompt,
            maxTokens: 520,
            temperature: 0.0
        )
    }

    private static func generateAnswer(question: String, sql: String, rows: [[String: String]], apiKey: String) async throws -> String {
        guard JSONSerialization.isValidJSONObject(rows) else {
            throw LLMServiceError.invalidResultPayload
        }
        let jsonData = try JSONSerialization.data(withJSONObject: rows, options: [])
        guard let jsonText = String(data: jsonData, encoding: .utf8) else {
            throw LLMServiceError.invalidResultPayload
        }

        let userPrompt = """
        Frage: \(question)
        Ausgeführtes SQL:
        \(sql)

        SQL-Ergebnis (JSON):
        \(jsonText)
        """

        return try await AIProviderService.complete(
            provider: AIProvider.active,
            apiKey: apiKey,
            systemPrompt: AIProviderService.QUERY_SYSTEM_PROMPT,
            userMessage: userPrompt,
            maxTokens: 500,
            temperature: 0.2
        )
    }
}

