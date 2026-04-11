import Foundation

enum FakeData {
    // MARK: - Standard Merchants (variable transactions)
    // Profile 0: Supermarkt, Tankstelle, Apotheke, Post
    static let merchants = [
        "REWE Markt GmbH",
        "EDEKA",
        "Lidl",
        "Aldi Süd",
        "Penny Markt",
        "Apotheke am Markt",
        "Aral Tankstelle",
        "Shell Tankstelle",
        "Deutsche Post AG",
        "Bäckerei Stadtbäcker"
    ]

    // Profile 1: City-Lifestyle, Delivery, Fashion
    private static let merchantsProfile1 = [
        "Starbucks Coffee",
        "Lieferando.de GmbH",
        "ABOUT YOU GmbH",
        "Zalando SE",
        "McDonald's Deutschland",
        "Subway",
        "dm-drogerie markt",
        "Rossmann GmbH",
        "Rewe City",
        "HelloFresh SE"
    ]

    // Profile 2: Heimwerken, Gesundheit, Fachhandel
    private static let merchantsProfile2 = [
        "Bauhaus AG",
        "OBI GmbH & Co. KG",
        "Hornbach",
        "MediaMarkt",
        "Saturn Electro",
        "IKEA Deutschland GmbH",
        "Fielmann AG",
        "DocMorris",
        "Vitalsana Apotheke",
        "Hagebaumarkt"
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
        // Einnahmen
        RecurringTemplate(merchant: "Klotzbrocken AG",               remittance: "GEHALT",                       amount: -3450.00, variance: 0.01, dayOfMonth: 1,  category: "income"),
        // Wohnen & Dauerzahlungen
        RecurringTemplate(merchant: "Wohnungsbaugesellschaft Siegen", remittance: "MIETE INKL. NK",              amount: 850.00,   variance: 0,    dayOfMonth: 1,  category: "housing"),
        RecurringTemplate(merchant: "Privat Überweisung",            remittance: "UNTERHALT",                    amount: 970.00,   variance: 0,    dayOfMonth: 1,  category: "other"),
        RecurringTemplate(merchant: "Privat Überweisung",            remittance: "HAUSHALTSGELD",                amount: 1200.00,  variance: 0,    dayOfMonth: 1,  category: "other"),
        // Kreditkarte (variable Abrechnung)
        RecurringTemplate(merchant: "Landesbank Hessen-Thüringen",   remittance: "KREDITKARTENABRECHNUNG",       amount: 480.00,   variance: 0.18, dayOfMonth: 3,  category: "payment"),
        // Streaming/Abo — direkte Creditor-Namen (kein PayPal-Routing, bessere Fixkosten-Erkennung)
        RecurringTemplate(merchant: "Netflix International B.V.",    remittance: "NETFLIX.COM",                  amount: 19.99,    variance: 0,    dayOfMonth: 15, category: "streaming"),
        RecurringTemplate(merchant: "Spotify AB",                    remittance: "SPOTIFY PREMIUM",              amount: 11.99,    variance: 0,    dayOfMonth: 1,  category: "streaming"),
        // Telecom
        RecurringTemplate(merchant: "Vodafone GmbH",                 remittance: "VERTRAGSRECHNUNG MOBILFUNK",  amount: 29.99,    variance: 0,    dayOfMonth: 20, category: "telecom"),
        RecurringTemplate(merchant: "freenet AG",                    remittance: "MOBILFUNK RECHNUNG",           amount: 20.98,    variance: 0,    dayOfMonth: 22, category: "telecom"),
        // Fitness
        RecurringTemplate(merchant: "McFit GmbH",                    remittance: "MITGLIEDSBEITRAG",             amount: 24.90,    variance: 0,    dayOfMonth: 15, category: "membership"),
    ]

    // Profile 1: daily/lifestyle account — subscriptions, online shopping
    private static let recurringPaymentsProfile1: [RecurringTemplate] = [
        RecurringTemplate(merchant: "Payment & Banking GmbH",        remittance: "GEHALT",                       amount: -4200.00, variance: 0.01, dayOfMonth: 15, category: "income"),
        RecurringTemplate(merchant: "Amazon EU S.a.r.l.",            remittance: "AMAZON PRIME MEMBERSHIP",      amount: 8.99,     variance: 0,    dayOfMonth: 5,  category: "streaming"),
        RecurringTemplate(merchant: "Disney+ (The Walt Disney Co.)", remittance: "DISNEY PLUS ABONNEMENT",       amount: 13.99,    variance: 0,    dayOfMonth: 3,  category: "streaming"),
        RecurringTemplate(merchant: "Apple Services",                remittance: "APPLE ONE SUBSCRIPTION",       amount: 19.95,    variance: 0,    dayOfMonth: 12, category: "streaming"),
        RecurringTemplate(merchant: "YouTube Premium",               remittance: "YOUTUBE PREMIUM ABONNEMENT",   amount: 23.99,    variance: 0,    dayOfMonth: 8,  category: "streaming"),
        RecurringTemplate(merchant: "O2 Online GmbH",               remittance: "VERTRAGSRECHNUNG MOBILFUNK",   amount: 34.99,    variance: 0,    dayOfMonth: 22, category: "telecom"),
        RecurringTemplate(merchant: "Urban Sports Club",             remittance: "MITGLIEDSBEITRAG M-PAKET",     amount: 59.90,    variance: 0,    dayOfMonth: 1,  category: "membership"),
        RecurringTemplate(merchant: "Claude.ai (Anthropic)",         remittance: "ANTHROPIC SUBSCRIPTION",       amount: 20.00,    variance: 0,    dayOfMonth: 7,  category: "software"),
    ]

    // Profile 2: bills/shared account — utilities, insurance, credit, software
    private static let recurringPaymentsProfile2: [RecurringTemplate] = [
        RecurringTemplate(merchant: "Fliegenfranz GmbH",                  remittance: "GEHALT",                      amount: -2800.00, variance: 0.01, dayOfMonth: 1,  category: "income"),
        // Versicherungen — enthalten "Versicherung" im Namen → knownServices-Pattern "versicherung"
        RecurringTemplate(merchant: "Hannoversche Versicherung",          remittance: "UNFALLVERSICHERUNG BEITRAG",  amount: 19.73,    variance: 0,    dayOfMonth: 1,  category: "insurance"),
        RecurringTemplate(merchant: "Gothaer Versicherung AG",            remittance: "HAUSRATVERSICHERUNG",         amount: 34.81,    variance: 0,    dayOfMonth: 1,  category: "insurance"),
        RecurringTemplate(merchant: "HUK-COBURG Versicherung",           remittance: "KFZ-HAFTPFLICHT UND KASKO",   amount: 52.30,    variance: 0,    dayOfMonth: 1,  category: "insurance"),
        RecurringTemplate(merchant: "DKV Deutsche Krankenversicherung",   remittance: "KV-ZUSATZVERSICHERUNG",       amount: 31.47,    variance: 0,    dayOfMonth: 1,  category: "insurance"),
        RecurringTemplate(merchant: "BARMENIA Versicherungen",            remittance: "ZAHNZUSATZVERSICHERUNG",      amount: 5.99,     variance: 0,    dayOfMonth: 1,  category: "insurance"),
        // Kredit
        RecurringTemplate(merchant: "C24 Bank GmbH",                     remittance: "KREDITRATE",                  amount: 568.34,   variance: 0,    dayOfMonth: 15, category: "finance"),
        // Versorger
        RecurringTemplate(merchant: "Stadtwerke Siegen GmbH",            remittance: "STROM ABSCHLAG",              amount: 89.00,    variance: 0,    dayOfMonth: 28, category: "utilities"),
        RecurringTemplate(merchant: "Stadtwerke Siegen GmbH",            remittance: "GAS ABSCHLAG",                amount: 67.00,    variance: 0,    dayOfMonth: 28, category: "utilities"),
        // Transport
        RecurringTemplate(merchant: "DB Vertrieb GmbH",                  remittance: "DEUTSCHLANDTICKET",           amount: 49.00,    variance: 0,    dayOfMonth: 1,  category: "transport"),
        // Software/Medien
        RecurringTemplate(merchant: "Apple Services",                     remittance: "APPLE ICLOUD+ 200GB",         amount: 2.99,     variance: 0,    dayOfMonth: 8,  category: "software"),
        RecurringTemplate(merchant: "HD Plus GmbH",                       remittance: "HD PLUS ABONNEMENT",          amount: 6.99,     variance: 0,    dayOfMonth: 10, category: "streaming"),
        RecurringTemplate(merchant: "IONOS SE",                           remittance: "WEBHOSTING RECHNUNG",         amount: 22.62,    variance: 0,    dayOfMonth: 14, category: "software"),
    ]

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()
    
    // MARK: - Demo Transaction Generation (90 days with recurring)

    static func generateDemoTransactions(seed: inout UInt64, days: Int = 365) -> [TransactionsResponse.Transaction] {
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
                let varianceFactor = template.variance > 0
                    ? 1.0 + (nextDouble(&seed) * 2 - 1) * template.variance
                    : { let _ = nextDouble(&seed); return 1.0 }()
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

        // Inject demo anomalies for Attention Inbox testing (only main account)
        if slotProfile == 0 {
            transactions += demoAnomalyTransactions()
        }

        transactions.sort { ($0.bookingDate ?? "") > ($1.bookingDate ?? "") }
        return transactions
    }

    // MARK: - Demo Anomalies (Attention Inbox test data)

    /// Injects realistic anomalies so the Attention Inbox has something to show in demo mode.
    /// - Abo teurer:          Netflix at €25.99 (was €19.99 all year)
    /// - Neuer Händler:       Decathlon, first time ever
    /// - Doppelte Abbuchung:  Aral Tankstelle, identical €78.50 twice within 4 days
    private static func demoAnomalyTransactions() -> [TransactionsResponse.Transaction] {
        let cal  = Calendar.current
        let now  = Date()
        func daysAgo(_ n: Int) -> String {
            formatDate(cal.date(byAdding: .day, value: -n, to: now) ?? now)
        }
        func expenseTx(merchant: String, iban: String, remittance: String, amount: Double, date: String, addInfo: String = "LASTSCHRIFT") -> TransactionsResponse.Transaction {
            TransactionsResponse.Transaction(
                bookingDate: date, valueDate: date, status: "Booked",
                endToEndId: UUID().uuidString,
                amount: TransactionsResponse.Amount(currency: "EUR", amount: String(format: "-%.2f", amount)),
                creditor: TransactionsResponse.Party(name: merchant, iban: iban, bic: "COBADEFFXXX"),
                debtor: nil,
                remittanceInformation: [remittance],
                additionalInformation: addInfo,
                purposeCode: "RINP"
            )
        }

        return [
            // 1. Abo teurer: Netflix hat Preis erhöht (war €19.99, jetzt €25.99)
            expenseTx(merchant: "Netflix International B.V.",
                      iban: "DE89200400600000099901",
                      remittance: "NETFLIX.COM",
                      amount: 25.99,
                      date: daysAgo(3)),

            // 2. Neuer Händler: Decathlon — bisher nie aufgetaucht
            expenseTx(merchant: "Decathlon GmbH",
                      iban: "DE89370400440000123456",
                      remittance: "Kartenzahlung DECATHLON",
                      amount: 89.95,
                      date: daysAgo(2),
                      addInfo: "KARTENZAHLUNG"),

            // 3. Doppelte Abbuchung: Aral, gleicher Betrag, 4 Tage auseinander
            expenseTx(merchant: "Aral Tankstelle",
                      iban: "DE89500400600000044401",
                      remittance: "Kartenzahlung ARAL",
                      amount: 78.50,
                      date: daysAgo(5),
                      addInfo: "KARTENZAHLUNG"),
            expenseTx(merchant: "Aral Tankstelle",
                      iban: "DE89500400600000044401",
                      remittance: "Kartenzahlung ARAL",
                      amount: 78.50,
                      date: daysAgo(2),
                      addInfo: "KARTENZAHLUNG"),
        ]
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
