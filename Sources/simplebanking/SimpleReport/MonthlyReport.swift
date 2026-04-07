import Foundation

// MARK: - ReportMonth

struct ReportMonth: Equatable, Hashable {
    let year: Int
    let month: Int

    var id: String { "\(year)-\(String(format: "%02d", month))" }

    static var current: ReportMonth {
        let c = Calendar.current
        let now = Date()
        return ReportMonth(year: c.component(.year, from: now), month: c.component(.month, from: now))
    }

    var previous: ReportMonth {
        var m = month - 1
        var y = year
        if m < 1 { m = 12; y -= 1 }
        return ReportMonth(year: y, month: m)
    }

    var shortLabel: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "de_DE")
        df.dateFormat = "MMM yyyy"
        return df.string(from: dateInMonth).uppercased()
    }

    var longLabel: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "de_DE")
        df.dateFormat = "MMMM yyyy"
        return df.string(from: dateInMonth).uppercased()
    }

    var fileLabel: String { id }

    private var dateInMonth: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    }

    func filter(_ txs: [TransactionsResponse.Transaction]) -> [TransactionsResponse.Transaction] {
        txs.filter { tx in
            guard tx.status?.lowercased() == "booked" || tx.status == nil else { return false }
            let dateStr = tx.bookingDate ?? tx.valueDate ?? ""
            guard dateStr.count >= 7 else { return false }
            let parts = dateStr.prefix(7).split(separator: "-")
            guard parts.count == 2,
                  let y = Int(parts[0]),
                  let m = Int(parts[1]) else { return false }
            return y == year && m == month
        }
    }
}

// MARK: - MonthlyReport

struct MonthlyReport {
    let header: ReportHeaderData
    let summary: ReportSummaryData
    let narrative: NarrativeData
    let cashflow: CashflowData
    let insights: [InsightItem]
    let categories: [CategoryRow]
    let recurring: [RecurringRow]
    let highlights: [TransactionHighlight]
    /// All booked transactions of the month, chronological — used for page 3+ full list
    let allTransactions: [TransactionsResponse.Transaction]
}

// MARK: - Header

struct ReportHeaderData {
    let monthTitle: String
    let accountName: String
    let bankName: String
    let maskedIBAN: String?
}

// MARK: - Summary

struct ReportSummaryData {
    let incomeTotal: Decimal
    let expenseTotal: Decimal
    let netTotal: Decimal
    let transactionCount: Int
}

// MARK: - Narrative

struct NarrativeData {
    let lines: [String]
}

// MARK: - Cashflow

struct CashflowData {
    let incomeTotal: Decimal
    let expenseTotalAbs: Decimal
    let netTotal: Decimal
}

// MARK: - Insight

enum InsightKind {
    case largestIncome
    case largestExpense
    case netSummary
    case dominantCategory
    case fixedCostsShare
}

struct InsightItem {
    let kind: InsightKind
    let text: String
    let priority: Int
}

// MARK: - Category

struct CategoryRow {
    let category: String
    let amount: Decimal
    let share: Double
    let deltaVsPreviousMonth: Decimal?
}

// MARK: - Recurring

struct RecurringRow {
    let merchant: String
    let amount: Decimal
    let category: String?
}

// MARK: - Highlight

enum TransactionDirection {
    case income
    case expense
}

struct TransactionHighlight {
    let date: String
    let title: String
    let subtitle: String?
    let amount: Decimal
    let direction: TransactionDirection
}
