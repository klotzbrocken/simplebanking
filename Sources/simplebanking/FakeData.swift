import Foundation

enum FakeData {
    // MARK: - Standard Merchants (variable transactions)
    static let merchants = [
        "Bäckerei Morgenstern",
        "Supermarkt Nord",
        "Coffee Roasters",
        "Apotheke City",
        "OnlineShop",
        "Drogerie",
        "Restaurant",
        "Tankstelle"
    ]

    static let remittances = [
        "Kartenzahlung",
        "SEPA Lastschrift",
        "Überweisung",
        "Kontaktlos",
        "POS",
        "Rechnung",
        "Danke für Ihren Einkauf"
    ]
    
    // MARK: - Recurring Payments (for Fixkosten)
    
    struct RecurringTemplate {
        let merchant: String
        let remittance: String
        let amount: Double          // Base amount
        let variance: Double        // Amount variance (0-1, e.g. 0.02 = ±2%)
        let dayOfMonth: Int         // Typical day of month (1-28)
        let category: String        // For grouping
    }
    
    static let recurringPayments: [RecurringTemplate] = [
        // Streaming
        RecurringTemplate(merchant: "PayPal Europe S.a.r.l.", remittance: "PP . NETFLIX, Ihr Einkauf bei NETFLIX", amount: 17.99, variance: 0, dayOfMonth: 15, category: "streaming"),
        RecurringTemplate(merchant: "PayPal Europe S.a.r.l.", remittance: "PP . SPOTIFY AB, Ihr Einkauf bei SPOTIFY", amount: 10.99, variance: 0, dayOfMonth: 1, category: "streaming"),
        RecurringTemplate(merchant: "AMAZON EU S.A R.L.", remittance: "AMAZON PRIME MEMBERSHIP", amount: 8.99, variance: 0, dayOfMonth: 5, category: "streaming"),
        
        // Telecom
        RecurringTemplate(merchant: "Telekom Deutschland GmbH", remittance: "MOBILFUNK RECHNUNG", amount: 49.99, variance: 0.05, dayOfMonth: 20, category: "telecom"),
        
        // Insurance
        RecurringTemplate(merchant: "HUK-COBURG Versicherung", remittance: "KFZ-HAFTPFLICHT", amount: 38.50, variance: 0, dayOfMonth: 1, category: "insurance"),
        RecurringTemplate(merchant: "Debeka Krankenversicherung", remittance: "ZUSATZVERSICHERUNG", amount: 25.90, variance: 0, dayOfMonth: 1, category: "insurance"),
        
        // Utilities
        RecurringTemplate(merchant: "Stadtwerke Siegen", remittance: "STROM ABSCHLAG", amount: 85.00, variance: 0, dayOfMonth: 28, category: "utilities"),
        RecurringTemplate(merchant: "Stadtwerke Siegen", remittance: "GAS ABSCHLAG", amount: 65.00, variance: 0, dayOfMonth: 28, category: "utilities"),
        
        // Software/Subscriptions
        RecurringTemplate(merchant: "PayPal Europe S.a.r.l.", remittance: "PP . OPENAI, Ihr Einkauf bei OPENAI", amount: 20.00, variance: 0, dayOfMonth: 10, category: "software"),
        RecurringTemplate(merchant: "APPLE.COM/BILL", remittance: "APPLE ICLOUD+ 200GB", amount: 2.99, variance: 0, dayOfMonth: 8, category: "software"),
        
        // Membership
        RecurringTemplate(merchant: "McFit GmbH", remittance: "MITGLIEDSBEITRAG", amount: 24.90, variance: 0, dayOfMonth: 15, category: "membership"),
        
        // Transport
        RecurringTemplate(merchant: "DB Vertrieb GmbH", remittance: "DEUTSCHLANDTICKET", amount: 49.00, variance: 0, dayOfMonth: 1, category: "transport"),
        
        // Rent (large recurring)
        RecurringTemplate(merchant: "Wohnungsbaugesellschaft Siegen", remittance: "MIETE INKL. NK", amount: 850.00, variance: 0, dayOfMonth: 1, category: "housing"),
        
        // Salary (income)
        RecurringTemplate(merchant: "DSGV Sparkassenverband", remittance: "GEHALT", amount: -3450.00, variance: 0.02, dayOfMonth: 27, category: "income"),
    ]

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()
    
    // MARK: - Demo Transaction Generation (90 days with recurring)
    
    static func generateDemoTransactions(seed: inout UInt64, days: Int = 90) -> [TransactionsResponse.Transaction] {
        var transactions: [TransactionsResponse.Transaction] = []
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let boundedDays = max(1, days)

        guard let startDate = cal.date(byAdding: .day, value: -(boundedDays - 1), to: today) else {
            return []
        }

        // Generate each recurring template exactly once per month in the time range.
        for monthStart in monthsInRange(from: startDate, to: today, calendar: cal) {
            for template in recurringPayments {
                var comps = cal.dateComponents([.year, .month], from: monthStart)
                comps.day = min(template.dayOfMonth, daysInMonth(monthStart))
                guard let recurringDate = cal.date(from: comps) else { continue }
                guard recurringDate >= startDate && recurringDate <= today else { continue }

                // Apply variance
                var amount = template.amount
                if template.variance > 0 {
                    let varianceFactor = 1.0 + (nextDouble(&seed) * 2 - 1) * template.variance
                    amount *= varianceFactor
                }

                // Income = negative template amount (e.g. -3450 for salary)
                // Expenses = positive template amount → negate for transaction
                let isIncome = amount < 0
                let txAmount = isIncome ? abs(amount) : -amount  // Expenses are negative
                let amountStr = String(format: "%.2f", txAmount)
                let dateStr = formatDate(recurringDate)

                // Use consistent IBAN for recurring payments (same merchant = same IBAN)
                let merchantIBAN = consistentIBAN(for: template.merchant + template.remittance)

                let tx = TransactionsResponse.Transaction(
                    bookingDate: dateStr,
                    valueDate: dateStr,
                    status: "Booked",
                    endToEndId: UUID().uuidString,
                    amount: TransactionsResponse.Amount(currency: "EUR", amount: amountStr),
                    creditor: isIncome ? nil : TransactionsResponse.Party(name: template.merchant, iban: merchantIBAN, bic: "COBADEFFXXX"),
                    debtor: isIncome ? TransactionsResponse.Party(name: template.merchant, iban: merchantIBAN, bic: "COBADEFFXXX") : nil,
                    remittanceInformation: [template.remittance],
                    additionalInformation: isIncome ? "LOHN/GEHALT" : "DAUERAUFTRAG",
                    purposeCode: isIncome ? "SALA" : "RINP"
                )
                transactions.append(tx)
            }
        }

        // Add random variable transactions (1-3 per day, reduced)
        for daysAgo in 0..<boundedDays {
            guard let date = cal.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let dateStr = formatDate(date)

            let numRandom = 1 + Int(nextDouble(&seed) * 2)
            for _ in 0..<numRandom {
                // Skip most days randomly (only 40% chance)
                if nextDouble(&seed) > 0.4 { continue }

                let sign = nextDouble(&seed) < 0.90 ? -1.0 : 1.0  // 90% expenses
                let value = randomEUR(seed: &seed, min: 3.50, max: 65.0)  // Reduced max
                let amountStr = String(format: "%.2f", sign * value)

                let merchant = pick(merchants, seed: &seed)
                let rem = pick(remittances, seed: &seed)

                let tx = TransactionsResponse.Transaction(
                    bookingDate: dateStr,
                    valueDate: dateStr,
                    status: "Booked",
                    endToEndId: UUID().uuidString,
                    amount: TransactionsResponse.Amount(currency: "EUR", amount: amountStr),
                    creditor: sign < 0 ? TransactionsResponse.Party(name: merchant, iban: generateIBAN(&seed), bic: "COBADEFFXXX") : nil,
                    debtor: sign > 0 ? TransactionsResponse.Party(name: merchant, iban: generateIBAN(&seed), bic: "COBADEFFXXX") : nil,
                    remittanceInformation: [rem],
                    additionalInformation: pick(["ÜBERWEISUNG", "LASTSCHRIFT", "KARTENZAHLUNG"], seed: &seed),
                    purposeCode: pick(["RINP", "OTHR", "CCRD"], seed: &seed)
                )
                transactions.append(tx)
            }
        }
        
        // Sort by date (newest first)
        transactions.sort { ($0.bookingDate ?? "") > ($1.bookingDate ?? "") }
        
        return transactions
    }
    
    // MARK: - Helper Functions
    
    static func randomEUR(seed: inout UInt64, min: Double, max: Double) -> Double {
        let r = nextDouble(&seed)
        return min + (max - min) * r
    }

    static func nextDouble(_ seed: inout UInt64) -> Double {
        // xorshift64*
        seed &+= 0x9E3779B97F4A7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        let v = Double(z & 0xFFFFFFFFFFFF) / Double(0x1000000000000) // 48-bit
        return min(0.999999, max(0.0, v))
    }

    static func pick<T>(_ xs: [T], seed: inout UInt64) -> T {
        let i = Int(nextDouble(&seed) * Double(xs.count))
        return xs[max(0, min(xs.count - 1, i))]
    }

    static func maskedIban(_ iban: String) -> String {
        guard iban.count >= 8 else { return "DE**" }
        let prefix = iban.prefix(4)
        let suffix = iban.suffix(4)
        return "\(prefix)••••••••\(suffix)"
    }
    
    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func monthsInRange(from start: Date, to end: Date, calendar cal: Calendar) -> [Date] {
        guard let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: start)),
              let endMonth = cal.date(from: cal.dateComponents([.year, .month], from: end)) else {
            return []
        }

        var months: [Date] = []
        var current = startMonth
        while current <= endMonth {
            months.append(current)
            guard let next = cal.date(byAdding: .month, value: 1, to: current) else { break }
            current = next
        }
        return months
    }
    
    private static func daysInMonth(_ date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        return cal.range(of: .day, in: .month, for: date)?.count ?? 28
    }
    
    private static func generateIBAN(_ seed: inout UInt64) -> String {
        let bankCode = String(format: "%08d", Int(nextDouble(&seed) * 99999999))
        let accountNum = String(format: "%010d", Int(nextDouble(&seed) * 9999999999))
        return "DE89\(bankCode)\(accountNum)"
    }
    
    /// Generates a consistent IBAN for a given merchant name (deterministic hash-based)
    private static func consistentIBAN(for merchant: String) -> String {
        // Simple hash of merchant name to create consistent IBAN
        var hash: UInt64 = 5381
        for char in merchant.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        let bankCode = String(format: "%08d", Int(hash % 99999999))
        let accountNum = String(format: "%010d", Int((hash >> 32) % 9999999999))
        return "DE89\(bankCode)\(accountNum)"
    }
    
    // Demo balance based on seed
    static func demoBalance(seed: inout UInt64) -> Double {
        return randomEUR(seed: &seed, min: 1200.0, max: 4500.0)
    }
}
