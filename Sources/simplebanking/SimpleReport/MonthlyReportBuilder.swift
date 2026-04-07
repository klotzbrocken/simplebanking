import Foundation

struct MonthlyReportBuilder {

    func build(
        slot: BankSlot,
        month: ReportMonth,
        transactions: [TransactionsResponse.Transaction],
        previousMonth: [TransactionsResponse.Transaction],
        allTransactions: [TransactionsResponse.Transaction]
    ) -> MonthlyReport {
        let summary  = buildSummary(txs: transactions)
        let prevSum  = buildSummary(txs: previousMonth)
        let cats     = buildCategories(txs: transactions, prevTxs: previousMonth)
        let dedupedPrev = deduplicateBoundaryTxs(current: transactions, previous: previousMonth)

        return MonthlyReport(
            header:          buildHeader(slot: slot, month: month),
            summary:         summary,
            narrative:       buildNarrative(summary: summary, categories: cats, prevSummary: prevSum),
            cashflow:        buildCashflow(summary: summary),
            insights:        buildInsights(txs: transactions, prevTxs: previousMonth, summary: summary, categories: cats),
            categories:      cats,
            recurring:       buildRecurring(current: transactions, allHistory: allTransactions),
            highlights:      buildHighlights(txs: transactions),
            allTransactions: transactions.sorted { ($0.bookingDate ?? $0.valueDate ?? "") < ($1.bookingDate ?? $1.valueDate ?? "") }
        )
    }

    // MARK: - Header

    private func buildHeader(slot: BankSlot, month: ReportMonth) -> ReportHeaderData {
        ReportHeaderData(
            monthTitle:  month.longLabel,
            accountName: slot.nickname ?? slot.displayName,
            bankName:    slot.displayName,
            maskedIBAN:  maskIBAN(slot.iban)
        )
    }

    private func maskIBAN(_ raw: String) -> String {
        let clean = raw.replacingOccurrences(of: " ", with: "")
        guard clean.count >= 8 else { return raw }
        let prefix = String(clean.prefix(4))
        let suffix = String(clean.suffix(4))
        let mid = String(repeating: "•", count: 4) + " " +
                  String(repeating: "•", count: 4) + " " +
                  String(repeating: "•", count: 4)
        return prefix + " " + mid + " " + suffix
    }

    // MARK: - Summary

    private func buildSummary(txs: [TransactionsResponse.Transaction]) -> ReportSummaryData {
        var income:  Decimal = 0
        var expense: Decimal = 0
        for tx in txs {
            let val = Decimal(tx.parsedAmount)
            if val > 0 { income  += val }
            else       { expense += val }
        }
        return ReportSummaryData(
            incomeTotal:      income,
            expenseTotal:     expense,
            netTotal:         income + expense,
            transactionCount: txs.count
        )
    }

    // MARK: - Narrative

    private func buildNarrative(
        summary: ReportSummaryData,
        categories: [CategoryRow],
        prevSummary: ReportSummaryData
    ) -> NarrativeData {
        var lines: [String] = []
        let fmt = currencyFormatter()

        let incStr  = fmt.string(from: summary.incomeTotal as NSDecimalNumber) ?? "\(summary.incomeTotal)"
        let expStr  = fmt.string(from: abs(summary.expenseTotal) as NSDecimalNumber) ?? "\(summary.expenseTotal)"
        let netStr  = fmt.string(from: abs(summary.netTotal) as NSDecimalNumber) ?? "\(summary.netTotal)"

        lines.append("Du hast \(incStr) eingenommen und \(expStr) ausgegeben.")

        if summary.netTotal >= 0 {
            lines.append("Das ergibt ein Plus von \(netStr) für diesen Monat.")
        } else {
            lines.append("Das ergibt ein Minus von \(netStr) für diesen Monat.")
        }

        // Delta vs previous month
        if prevSummary.expenseTotal != 0 {
            let prevExp = abs(prevSummary.expenseTotal)
            let curExp  = abs(summary.expenseTotal)
            let delta   = prevExp > 0 ? Double(truncating: ((curExp - prevExp) / prevExp * 100) as NSDecimalNumber) : 0
            let absDelta = abs(delta)
            if absDelta >= 5 {
                let dir = delta > 0 ? "höher" : "niedriger"
                lines.append("Die Gesamtausgaben lagen \(Int(absDelta))% \(dir) als im Vormonat.")
            }
        }

        // Dominant category
        if let top = categories.first, top.share > 0.25 {
            let pct = Int(top.share * 100)
            lines.append("\(top.category) war mit \(pct)% deine größte Ausgabenkategorie.")
        }

        return NarrativeData(lines: lines)
    }

    // MARK: - Cashflow

    private func buildCashflow(summary: ReportSummaryData) -> CashflowData {
        CashflowData(
            incomeTotal:     summary.incomeTotal,
            expenseTotalAbs: abs(summary.expenseTotal),
            netTotal:        summary.netTotal
        )
    }

    // MARK: - Insights

    private func buildInsights(
        txs: [TransactionsResponse.Transaction],
        prevTxs: [TransactionsResponse.Transaction],
        summary: ReportSummaryData,
        categories: [CategoryRow]
    ) -> [InsightItem] {
        var items: [InsightItem] = []
        let fmt = currencyFormatter()

        // 1. Largest income
        if let top = txs.max(by: { amount($0) < amount($1) }), amount(top) > 0 {
            let name = partyName(top)
            let val  = fmt.string(from: amount(top) as NSDecimalNumber) ?? ""
            items.append(InsightItem(kind: .largestIncome,
                text: "Größte Einnahme: \(val) von \(name).",
                priority: 1))
        }

        // 2. Largest expense
        if let bot = txs.min(by: { amount($0) < amount($1) }), amount(bot) < 0 {
            let name = partyName(bot)
            let val  = fmt.string(from: abs(amount(bot)) as NSDecimalNumber) ?? ""
            items.append(InsightItem(kind: .largestExpense,
                text: "Größte Ausgabe: \(val) bei \(name).",
                priority: 2))
        }

        // 3. Net summary
        if summary.netTotal >= 0 {
            let val = fmt.string(from: summary.netTotal as NSDecimalNumber) ?? ""
            items.append(InsightItem(kind: .netSummary,
                text: "Du hast diesen Monat \(val) gespart – gut gemacht.",
                priority: 3))
        } else {
            let val = fmt.string(from: abs(summary.netTotal) as NSDecimalNumber) ?? ""
            items.append(InsightItem(kind: .netSummary,
                text: "Diesen Monat hast du \(val) mehr ausgegeben als eingenommen.",
                priority: 3))
        }

        // 4. Dominant category
        if let top = categories.first, top.share > 0.20 {
            let pct = Int(top.share * 100)
            items.append(InsightItem(kind: .dominantCategory,
                text: "\(top.category) war mit \(pct)% deine größte Ausgabenkategorie.",
                priority: 4))
        }

        // 5. Fixed costs share
        let recurring = buildRecurring(current: txs, allHistory: txs + prevTxs)
        if !recurring.isEmpty {
            let fixTotal = recurring.reduce(Decimal(0)) { $0 + $1.amount }
            let expTotal = abs(summary.expenseTotal)
            if expTotal > 0 {
                let share = Double(truncating: (fixTotal / expTotal * 100) as NSDecimalNumber)
                let fixStr = fmt.string(from: fixTotal as NSDecimalNumber) ?? ""
                items.append(InsightItem(kind: .fixedCostsShare,
                    text: "Fixkosten belaufen sich auf \(fixStr) – das sind \(Int(share))% deiner Ausgaben.",
                    priority: 5))
            }
        }

        return Array(items.sorted { $0.priority < $1.priority }.prefix(5))
    }

    // MARK: - Categories

    private func buildCategories(
        txs: [TransactionsResponse.Transaction],
        prevTxs: [TransactionsResponse.Transaction]
    ) -> [CategoryRow] {
        let expenses     = txs.filter    { amount($0) < 0 }
        let prevExpenses = prevTxs.filter { amount($0) < 0 }

        var sums:     [String: Decimal] = [:]
        var prevSums: [String: Decimal] = [:]

        for tx in expenses {
            let cat = tx.category ?? "Sonstiges"
            sums[cat, default: 0] += amount(tx)
        }
        for tx in prevExpenses {
            let cat = tx.category ?? "Sonstiges"
            prevSums[cat, default: 0] += amount(tx)
        }

        let total = sums.values.reduce(Decimal(0), +)

        return sums
            .sorted { $0.value < $1.value }  // most negative first
            .prefix(8)
            .map { (cat, val) in
                let absVal  = abs(val)
                let share   = total != 0 ? Double(truncating: (absVal / abs(total)) as NSDecimalNumber) : 0
                let prevVal = prevSums[cat]
                let delta   = prevVal.map { abs(val) - abs($0) }
                return CategoryRow(
                    category: cat,
                    amount:   absVal,
                    share:    share,
                    deltaVsPreviousMonth: delta
                )
            }
    }

    // MARK: - Boundary deduplication

    /// Removes transactions from `previous` that are cross-month duplicates of transactions
    /// in `current`. A duplicate is defined as: same normalized merchant name + same absolute
    /// amount (±0.01 €), where the previous-month tx falls in the last 6 days of its month
    /// (day ≥ 25) and the current-month tx falls in the first 5 days (day ≤ 5).
    private func deduplicateBoundaryTxs(
        current: [TransactionsResponse.Transaction],
        previous: [TransactionsResponse.Transaction]
    ) -> [TransactionsResponse.Transaction] {
        let currBoundary = current.filter  { dayOfMonth($0) <= 5 }
        let prevBoundary = previous.filter { dayOfMonth($0) >= 25 }
        guard !currBoundary.isEmpty, !prevBoundary.isEmpty else { return previous }

        var duplicateKeys: Set<String> = []
        for currTx in currBoundary {
            let currName = normalizedMerchant(currTx)
            let currAmt  = abs(amount(currTx))
            for prevTx in prevBoundary {
                guard normalizedMerchant(prevTx) == currName else { continue }
                guard abs(abs(amount(prevTx)) - currAmt) <= Decimal(string: "0.01")! else { continue }
                duplicateKeys.insert(txKey(prevTx))
            }
        }
        guard !duplicateKeys.isEmpty else { return previous }
        return previous.filter { !duplicateKeys.contains(txKey($0)) }
    }

    private func dayOfMonth(_ tx: TransactionsResponse.Transaction) -> Int {
        let dateStr = tx.bookingDate ?? tx.valueDate ?? ""
        guard dateStr.count >= 10 else { return 0 }
        let parts = dateStr.prefix(10).split(separator: "-")
        guard parts.count == 3, let d = Int(parts[2]) else { return 0 }
        return d
    }

    private func normalizedMerchant(_ tx: TransactionsResponse.Transaction) -> String {
        partyName(tx).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func txKey(_ tx: TransactionsResponse.Transaction) -> String {
        let date = tx.bookingDate ?? tx.valueDate ?? ""
        let name = partyName(tx)
        let amt  = tx.amount?.amount ?? ""
        return "\(date)|\(name)|\(amt)"
    }

    // MARK: - Recurring

    private func buildRecurring(
        current: [TransactionsResponse.Transaction],
        allHistory: [TransactionsResponse.Transaction]
    ) -> [RecurringRow] {
        let payments = FixedCostsAnalyzer.analyze(transactions: allHistory)
        let currentMerchants = Set(current.map { FixedCostsAnalyzer.merchantName(for: $0) })
        return payments
            .filter { currentMerchants.contains($0.merchant) }
            .sorted { $0.averageAmount > $1.averageAmount }
            .prefix(10)
            .map { p in
                RecurringRow(
                    merchant: p.merchant,
                    amount:   Decimal(p.averageAmount),
                    category: p.category.rawValue
                )
            }
    }

    // MARK: - Highlights

    private func buildHighlights(txs: [TransactionsResponse.Transaction]) -> [TransactionHighlight] {
        var selected: [TransactionsResponse.Transaction] = []
        var usedIds: Set<String> = []

        func add(_ tx: TransactionsResponse.Transaction, label: String? = nil) {
            let key = tx.endToEndId ?? tx.bookingDate ?? partyName(tx)
            guard !usedIds.contains(key) else { return }
            usedIds.insert(key)
            selected.append(tx)
        }

        let expenses = txs.filter { amount($0) < 0 }.sorted { amount($0) < amount($1) }
        let incomes  = txs.filter { amount($0) > 0 }.sorted { amount($0) > amount($1) }

        // Top 3 expenses
        expenses.prefix(3).forEach { add($0) }
        // Top 2 incomes
        incomes.prefix(2).forEach { add($0) }
        // Refunds
        txs.filter { isRefund($0) }.prefix(2).forEach { add($0) }
        // Fill remaining slots (up to 12) with next biggest expenses
        expenses.dropFirst(3).forEach { if selected.count < 12 { add($0) } }

        let fmt = currencyFormatter()
        return selected.map { tx in
            let val = amount(tx)
            let absVal = abs(val)
            let dir: TransactionDirection = val >= 0 ? .income : .expense
            let dateStr = formatHighlightDate(tx.bookingDate ?? tx.valueDate ?? "")
            let sub = subtitleFor(tx)
            return TransactionHighlight(
                date:      dateStr,
                title:     partyName(tx),
                subtitle:  sub,
                amount:    absVal,
                direction: dir
            )
        }.sorted { dateSort($0.date, $1.date) }
    }

    // MARK: - Helpers

    private func amount(_ tx: TransactionsResponse.Transaction) -> Decimal {
        Decimal(tx.parsedAmount)
    }

    private func partyName(_ tx: TransactionsResponse.Transaction) -> String {
        if let name = tx.creditor?.name, !name.isEmpty { return name }
        if let name = tx.debtor?.name,  !name.isEmpty { return name }
        return tx.remittanceInformation?.first ?? "Unbekannt"
    }

    private func isRefund(_ tx: TransactionsResponse.Transaction) -> Bool {
        let refs = [tx.remittanceInformation?.joined(separator: " "),
                    tx.additionalInformation,
                    tx.purposeCode].compactMap { $0 }.joined(separator: " ").uppercased()
        return refs.contains("RETOURE") || refs.contains("ERSTATTUNG") || refs.contains("REFUND")
    }

    private func subtitleFor(_ tx: TransactionsResponse.Transaction) -> String? {
        if isRefund(tx) { return "Rückerstattung" }
        return tx.remittanceInformation?.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func formatHighlightDate(_ iso: String) -> String {
        guard iso.count >= 10 else { return iso }
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3, let d = Int(parts[2]), let m = Int(parts[1]) else { return iso }
        let months = ["", "Jan", "Feb", "Mär", "Apr", "Mai", "Jun",
                      "Jul", "Aug", "Sep", "Okt", "Nov", "Dez"]
        let mon = m < months.count ? months[m] : "\(m)"
        return String(format: "%02d. %@", d, mon)
    }

    private func dateSort(_ a: String, _ b: String) -> Bool { a < b }

    private func currencyFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f
    }
}
