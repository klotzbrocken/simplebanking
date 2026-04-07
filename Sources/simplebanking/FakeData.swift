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

    // Profile 1: daily spending (coffee, food, fashion, delivery)
    private static let merchantsProfile1 = [
        "Starbucks Coffee",
        "Lieferando.de",
        "About You GmbH",
        "Zalando SE",
        "McDonald's",
        "Subway",
        "dm-drogerie markt",
        "Rewe To Go"
    ]

    // Profile 2: home & services (pharmacy, hardware, home)
    private static let merchantsProfile2 = [
        "Apotheke am Markt",
        "Bauhaus AG",
        "OBI Bau- und Heimwerkermarkt",
        "IKEA Deutschland",
        "MediaMarkt",
        "Rossmann",
        "Hornbach",
        "Saturn Electro"
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

    // Profile 0: main account — salary, rent, streaming, phone
    static let recurringPayments: [RecurringTemplate] = [
        RecurringTemplate(merchant: "Klotzbrocken AG", remittance: "GEHALT", amount: -3450.00, variance: 0.02, dayOfMonth: 1, category: "income"),
        RecurringTemplate(merchant: "Wohnungsbaugesellschaft Siegen", remittance: "MIETE INKL. NK", amount: 850.00, variance: 0, dayOfMonth: 1, category: "housing"),
        RecurringTemplate(merchant: "ING-DiBa AG", remittance: "KREDITKARTENABRECHNUNG", amount: 380.00, variance: 0.12, dayOfMonth: 3, category: "payment"),
        RecurringTemplate(merchant: "PayPal Europe S.a.r.l.", remittance: "PP . NETFLIX, Ihr Einkauf bei NETFLIX", amount: 17.99, variance: 0, dayOfMonth: 15, category: "streaming"),
        RecurringTemplate(merchant: "PayPal Europe S.a.r.l.", remittance: "PP . SPOTIFY AB, Ihr Einkauf bei SPOTIFY", amount: 10.99, variance: 0, dayOfMonth: 1, category: "streaming"),
        RecurringTemplate(merchant: "Telekom Deutschland GmbH", remittance: "MOBILFUNK RECHNUNG", amount: 49.99, variance: 0.05, dayOfMonth: 20, category: "telecom"),
        RecurringTemplate(merchant: "McFit GmbH", remittance: "MITGLIEDSBEITRAG", amount: 24.90, variance: 0, dayOfMonth: 15, category: "membership"),
    ]

    // Profile 1: daily/lifestyle account — subscriptions, online shopping, no salary
    private static let recurringPaymentsProfile1: [RecurringTemplate] = [
        RecurringTemplate(merchant: "AMAZON EU S.A R.L.", remittance: "AMAZON PRIME MEMBERSHIP", amount: 8.99, variance: 0, dayOfMonth: 5, category: "streaming"),
        RecurringTemplate(merchant: "PayPal Europe S.a.r.l.", remittance: "PP . DISNEY PLUS, Ihr Einkauf bei DISNEY", amount: 11.99, variance: 0, dayOfMonth: 3, category: "streaming"),
        RecurringTemplate(merchant: "APPLE.COM/BILL", remittance: "APPLE ONE SUBSCRIPTION", amount: 19.95, variance: 0, dayOfMonth: 12, category: "streaming"),
        RecurringTemplate(merchant: "O2 Online GmbH", remittance: "VERTRAGSRECHNUNG MOBILFUNK", amount: 34.99, variance: 0.03, dayOfMonth: 22, category: "telecom"),
        RecurringTemplate(merchant: "Urban Sports Club", remittance: "MITGLIEDSBEITRAG M-PAKET", amount: 59.90, variance: 0, dayOfMonth: 1, category: "membership"),
        RecurringTemplate(merchant: "Payment & Banking GmbH", remittance: "GEHALT", amount: -4200.00, variance: 0.02, dayOfMonth: 15, category: "income"),
    ]

    // Profile 2: bills/shared account — utilities, insurance, transport, software
    private static let recurringPaymentsProfile2: [RecurringTemplate] = [
        RecurringTemplate(merchant: "Stadtwerke München GmbH", remittance: "STROM ABSCHLAG", amount: 92.00, variance: 0, dayOfMonth: 28, category: "utilities"),
        RecurringTemplate(merchant: "Stadtwerke München GmbH", remittance: "GAS ABSCHLAG", amount: 71.00, variance: 0, dayOfMonth: 28, category: "utilities"),
        RecurringTemplate(merchant: "HUK-COBURG Versicherung", remittance: "KFZ-HAFTPFLICHT UND KASKO", amount: 52.30, variance: 0, dayOfMonth: 1, category: "insurance"),
        RecurringTemplate(merchant: "Debeka Krankenversicherung", remittance: "KRANKENZUSATZVERSICHERUNG", amount: 31.40, variance: 0, dayOfMonth: 1, category: "insurance"),
        RecurringTemplate(merchant: "DB Vertrieb GmbH", remittance: "DEUTSCHLANDTICKET", amount: 49.00, variance: 0, dayOfMonth: 1, category: "transport"),
        RecurringTemplate(merchant: "PayPal Europe S.a.r.l.", remittance: "PP . OPENAI, Ihr Einkauf bei OPENAI", amount: 20.00, variance: 0, dayOfMonth: 10, category: "software"),
        RecurringTemplate(merchant: "APPLE.COM/BILL", remittance: "APPLE ICLOUD+ 200GB", amount: 2.99, variance: 0, dayOfMonth: 8, category: "software"),
        RecurringTemplate(merchant: "Fliegenfranz GmbH", remittance: "GEHALT", amount: -2800.00, variance: 0.02, dayOfMonth: 1, category: "income"),
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
        generateDemoTransactions(seed: &seed, days: days, slotProfile: 0)
    }

    // slotProfile: 0 = main account, 1 = daily/lifestyle, 2 = bills/shared
    static func generateDemoTransactions(seed: inout UInt64, days: Int = 90, slotProfile: Int) -> [TransactionsResponse.Transaction] {
        let templates: [RecurringTemplate]
        let varMerchants: [String]
        switch slotProfile {
        case 1:
            templates = recurringPaymentsProfile1
            varMerchants = merchantsProfile1
        case 2:
            templates = recurringPaymentsProfile2
            varMerchants = merchantsProfile2
        default:
            templates = recurringPayments
            varMerchants = merchants
        }

        var transactions: [TransactionsResponse.Transaction] = []
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let boundedDays = max(1, days)

        guard let startDate = cal.date(byAdding: .day, value: -(boundedDays - 1), to: today) else {
            return []
        }

        // Generate each recurring template exactly once per month in the time range.
        for monthStart in monthsInRange(from: startDate, to: today, calendar: cal) {
            for template in templates {
                var comps = cal.dateComponents([.year, .month], from: monthStart)
                comps.day = min(template.dayOfMonth, daysInMonth(monthStart))
                guard let recurringDate = cal.date(from: comps) else { continue }
                guard recurringDate >= startDate && recurringDate <= today else { continue }

                // Always consume one seed step so per-slot amounts differ
                var amount = template.amount
                let effectiveVariance = template.variance > 0 ? template.variance : 0.03
                let varianceFactor = 1.0 + (nextDouble(&seed) * 2 - 1) * effectiveVariance
                amount *= varianceFactor

                let isIncome = amount < 0
                let txAmount = isIncome ? abs(amount) : -amount
                let amountStr = String(format: "%.2f", txAmount)
                let dateStr = formatDate(recurringDate)
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

        // Add random variable transactions
        // Profile 1 (daily spending) gets more frequent random transactions
        let chancePerDay: Double = slotProfile == 1 ? 0.7 : (slotProfile == 0 ? 0.55 : 0.4)
        for daysAgo in 0..<boundedDays {
            guard let date = cal.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let dateStr = formatDate(date)
            let numRandom = 1 + Int(nextDouble(&seed) * 2)
            for _ in 0..<numRandom {
                if nextDouble(&seed) > chancePerDay { continue }
                let sign = nextDouble(&seed) < 0.90 ? -1.0 : 1.0
                let value = randomEUR(seed: &seed, min: 3.50, max: 65.0)
                let amountStr = String(format: "%.2f", sign * value)
                let merchant = pick(varMerchants, seed: &seed)
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
        return randomEUR(seed: &seed, min: 500.0, max: 3500.0)
    }

    /// Like generateDemoTransactions but tags every transaction with slotId and uses a profile.
    static func generateDemoTransactions(seed: inout UInt64, days: Int = 90, slotId: String, slotProfile: Int = 0) -> [TransactionsResponse.Transaction] {
        var txs = generateDemoTransactions(seed: &seed, days: days, slotProfile: slotProfile)
        for i in txs.indices { txs[i].slotId = slotId }
        return txs
    }

    // Demo balance — profile-aware amount ranges
    static func demoBalance(seed: inout UInt64, slotProfile: Int) -> Double {
        switch slotProfile {
        case 1: return randomEUR(seed: &seed, min: 150.0, max: 900.0)    // daily spending
        case 2: return randomEUR(seed: &seed, min: -400.0, max: -50.0)   // in Dispo
        default: return randomEUR(seed: &seed, min: 1200.0, max: 4500.0) // main account
        }
    }

    /// Canonical salary day per demo profile — matches the recurring salary template.
    static func demoSalaryDay(slotProfile: Int) -> Int {
        switch slotProfile {
        case 1: return 15   // middle of month
        default: return 1   // beginning of month (profiles 0 and 2)
        }
    }

    /// Dispo limit for demo profiles — non-zero for profile 2 so the ring fills meaningfully.
    static func demoDispoLimit(slotProfile: Int) -> Int {
        slotProfile == 2 ? 500 : 0
    }
}
