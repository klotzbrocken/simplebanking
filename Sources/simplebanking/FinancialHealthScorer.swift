import Foundation

// MARK: - Financial Health Score (Apple Watch Style)

struct FinancialHealthScore {
    let overall: Double
    let incomeCoverage: Double    // Grün: Einnahmen vs Fixkosten
    let savingsRate: Double       // Türkis: Sparrate
    let stability: Double         // Rot: Impulskontrolle
    
    // Dispo-Statistik
    let daysInDispo: Int          // Tage im Minus
    let avgDispoUsage: Double     // Durchschnittlicher negativer Saldo
    let maxDispoUsage: Double     // Tiefster Stand
    let dispoUtilization: Double  // Genutzter Dispo / Limit (0-1)
    
    // Sparinfo
    let savingsTransferAmount: Double  // Erkannte Sparüberweisungen
    
    // Fixkostenquote (50/30/20 Regel)
    let fixedCostRatio: Double        // Fixkosten / Einkommen (0-1)
    let variableExpenseRatio: Double  // Variable Ausgaben / Einkommen (0-1)
    let actualSavingsRatio: Double    // Tatsächliche Sparrate (0-1)
}

// MARK: - Savings Bookmarks Storage
enum SavingsBookmarks {
    private static let key = "savingsBookmarkedTransactions"
    
    static func isBookmarked(_ transactionId: String) -> Bool {
        let bookmarks = UserDefaults.standard.stringArray(forKey: key) ?? []
        return bookmarks.contains(transactionId)
    }
    
    static func toggle(_ transactionId: String) {
        var bookmarks = UserDefaults.standard.stringArray(forKey: key) ?? []
        if let index = bookmarks.firstIndex(of: transactionId) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(transactionId)
        }
        UserDefaults.standard.set(bookmarks, forKey: key)
    }
    
    static func allBookmarked() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}

enum FinancialHealthScorer {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func score(
        transactions: [TransactionsResponse.Transaction],
        salaryDay: Int = 1,
        dispoLimit: Int = 0,
        targetBuffer: Int = 500,
        targetSavingsRate: Int = 20,
        stabilityOutlierMultiplier: Double = 3.0,
        coverageRatioWeight: Double = 0.6,
        fixedCostWarningRatio: Double = 0.70
    ) -> FinancialHealthScore {
        func amt(_ t: TransactionsResponse.Transaction) -> Double {
            t.parsedAmount
        }
        
        func dateOf(_ t: TransactionsResponse.Transaction) -> Date? {
            let dateStr = t.bookingDate ?? t.valueDate ?? ""
            return dateFormatter.date(from: dateStr)
        }

        // Pending-Umsätze raus — noch nicht final, verzerren den Score
        let transactions = transactions.filter { $0.status != "pending" }

        // Sortiere Transaktionen nach Datum
        let sortedTx = transactions.sorted { (dateOf($0) ?? .distantPast) < (dateOf($1) ?? .distantPast) }
        
        let incomes = transactions.map(amt).filter { $0 > 0 }
        let expenseTransactions = transactions.filter { amt($0) < 0 }
        
        // Erkenne Sparüberweisungen (bookmarkiert oder automatisch erkannt)
        let bookmarked = SavingsBookmarks.allBookmarked()
        let savingsTransfers = expenseTransactions.filter { tx in
            // Manuell bookmarkiert
            if bookmarked.contains(tx.stableIdentifier) { return true }
            // Automatische Erkennung anhand von Keywords
            return isSavingsTransfer(tx)
        }

        let savingsTransferAmount = savingsTransfers.map { abs(amt($0)) }.reduce(0, +)
        let regularExpenses = expenseTransactions.filter { tx in
            if bookmarked.contains(tx.stableIdentifier) { return false }
            return !isSavingsTransfer(tx)
        }

        let totalIncome = incomes.reduce(0, +)
        let totalExpense = regularExpenses.map { abs(amt($0)) }.reduce(0, +)
        let totalExpenseWithSavings = totalExpense + savingsTransferAmount
        
        // === Fixkosten-Analyse für 50/30/20 Regel ===
        let fixedMerchants = FixedCostsAnalyzer.getFixedCostMerchants(transactions: transactions)
        let fixedCostTransactions = regularExpenses.filter { 
            FixedCostsAnalyzer.isFixedCost($0, fixedMerchants: fixedMerchants) 
        }
        let variableExpenseTransactions = regularExpenses.filter { 
            !FixedCostsAnalyzer.isFixedCost($0, fixedMerchants: fixedMerchants) 
        }
        
        let totalFixedCosts = fixedCostTransactions.map { abs(amt($0)) }.reduce(0, +)
        let totalVariableExpenses = variableExpenseTransactions.map { abs(amt($0)) }.reduce(0, +)
        
        // Fixkostenquote berechnen (als Anteil am Einkommen)
        let fixedCostRatio = totalIncome > 0 ? totalFixedCosts / totalIncome : 0
        let variableExpenseRatio = totalIncome > 0 ? totalVariableExpenses / totalIncome : 0
        let actualSavingsRatio = totalIncome > 0 ? max(0, (totalIncome - totalExpense) / totalIncome) : 0
        
        // 1. Income Coverage (Grün) - Gewichteter Ansatz
        // Basiert auf allen Ausgaben inkl. Sparen (Cashflow-Perspektive)
        let coverageRatio = clamp01(totalIncome / max(totalExpenseWithSavings, 1000.0))
        let bufferTarget = max(Double(targetBuffer), 100.0)  // Mindestens 100€
        let margin = totalIncome - totalExpenseWithSavings
        let absoluteMargin = clamp01(margin / bufferTarget)
        let incomeCoverage = clamp01(coverageRatio * coverageRatioWeight + absoluteMargin * (1.0 - coverageRatioWeight))

        // 2. Savings Rate (Türkis) - Sparüberweisungen zählen als Sparen!
        let effectiveSavings = (totalIncome - totalExpense)  // Ohne Sparüberweisungen
        let targetRate = max(Double(targetSavingsRate), 1.0) / 100.0  // z.B. 20% = 0.20
        let savingsRate = clamp01((effectiveSavings / max(totalIncome, 1.0)) / targetRate)

        // 3. Stability (Rot) - NUR variable Ausgaben (Fixkosten rausfiltern!)
        // Fixkosten wie Miete sollen nicht als "Ausreißer" gewertet werden
        let variableAmounts = variableExpenseTransactions.map { abs(amt($0)) }
        let avgVariable = variableAmounts.isEmpty ? 0 : variableAmounts.reduce(0, +) / Double(variableAmounts.count)
        let highOutliers = variableAmounts.filter { $0 > avgVariable * stabilityOutlierMultiplier }.count
        let stability = clamp01(1.0 - (Double(highOutliers) / 5.0))

        // 4. Dispo-Statistik: Berechne täglichen Kontostand
        var runningBalance: Double = 0
        var dailyBalances: [Date: Double] = [:]
        
        for tx in sortedTx {
            runningBalance += amt(tx)
            if let date = dateOf(tx) {
                dailyBalances[date] = runningBalance
            }
        }
        
        // Berechne Dispo-Metriken
        let negativeBalances = dailyBalances.values.filter { $0 < 0 }
        let daysInDispo = negativeBalances.count
        let avgDispoUsage = negativeBalances.isEmpty ? 0 : abs(negativeBalances.reduce(0, +) / Double(negativeBalances.count))
        let maxDispoUsage = abs(negativeBalances.min() ?? 0)
        let dispoUtilization = dispoLimit > 0 ? clamp01(maxDispoUsage / Double(dispoLimit)) : 0

        // Overall: 4 Metriken wenn Dispo konfiguriert, sonst 3
        let dispoScore = dispoLimit > 0 ? clamp01(1.0 - dispoUtilization) : 1.0
        let overall = dispoLimit > 0 
            ? (incomeCoverage + savingsRate + stability + dispoScore) / 4.0
            : (incomeCoverage + savingsRate + stability) / 3.0

        return FinancialHealthScore(
            overall: overall,
            incomeCoverage: incomeCoverage,
            savingsRate: savingsRate,
            stability: stability,
            daysInDispo: daysInDispo,
            avgDispoUsage: avgDispoUsage,
            maxDispoUsage: maxDispoUsage,
            dispoUtilization: dispoUtilization,
            savingsTransferAmount: savingsTransferAmount,
            fixedCostRatio: fixedCostRatio,
            variableExpenseRatio: variableExpenseRatio,
            actualSavingsRatio: actualSavingsRatio
        )
    }

    private static func clamp01(_ x: Double) -> Double { min(1.0, max(0.0, x)) }
    
    /// Erkennt automatisch Sparüberweisungen anhand von Keywords
    private static func isSavingsTransfer(_ tx: TransactionsResponse.Transaction) -> Bool {
        let creditor = (tx.creditor?.name ?? "").lowercased()
        let remittance = (tx.remittanceInformation ?? []).joined(separator: " ").lowercased()
        let additionalInfo = (tx.additionalInformation ?? "").lowercased()
        let combined = "\(creditor) \(remittance) \(additionalInfo)"
        
        // Keywords für Spar-/Anlagekonten
        let savingsKeywords = [
            "sparplan", "sparen", "depot", "anlage", "etf", "fonds",
            "tagesgeld", "festgeld", "wertpapier", "aktien",
            "trade republic", "scalable", "comdirect depot", "dkb depot",
            "ing depot", "consorsbank depot", "flatex", "smartbroker",
            "vermögensaufbau", "altersvorsorge", "riester", "rürup",
            "bausparen", "bauspar", "vl-sparen", "vermögenswirksam"
        ]
        
        for keyword in savingsKeywords {
            if combined.contains(keyword) { return true }
        }
        
        return false
    }
}
