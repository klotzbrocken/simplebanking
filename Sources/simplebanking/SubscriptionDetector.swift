import Foundation

// MARK: - Tab (shared between SubscriptionsView and FreezeAnalyzer)

enum SubscriptionTab: String, CaseIterable {
    case abos             = "Abos"
    case vertraege        = "Verträge"
    case sparen           = "Sparen"
    case verbindlichkeiten = "Verbindlichkeiten"
}

// MARK: - Candidate

struct SubscriptionCandidate: Identifiable {
    let id: String               // merchantKey (may contain |agg or |custId suffix)
    let displayName: String
    let averageAmount: Double
    let lastAmount: Double
    let lastDate: Date
    let cadence: PaymentFrequency
    let occurrences: Int
    let confidence: Int          // raw score; ≥10 = bestätigt, 7–9 = möglich
    let hasCancellationLink: Bool
    let cancellationEntry: CancellationLinks.Entry?
    let category: PaymentCategory
    let matchedTransactions: [TransactionsResponse.Transaction]

    var defaultTab: SubscriptionTab {
        switch category {
        case .finance:
            return .sparen
        case .streaming, .software:
            return .abos
        case .membership:
            let lower = displayName.lowercased()
            let isFitness = SubscriptionDetector.fitnessKeywords.contains { lower.contains($0) }
            return isFitness ? .vertraege : .abos
        case .telecom, .transport:
            return .vertraege
        case .insurance, .utilities:
            return .verbindlichkeiten
        default:
            let lower = displayName.lowercased()
            let verbindlichkeitenKeywords = [
                "versicherung", "krankenkasse", "aok", "barmer", "debeka",
                "stadtwerke", "eon ", "rwe", "vattenfall", "enpal",
                "wohnungsbau", "mietverwaltung", "hausverwaltung", "mietvertrag",
                "kreditrate", "kreditabrechnung", "miete",
            ]
            if verbindlichkeitenKeywords.contains(where: { lower.contains($0) }) {
                return .verbindlichkeiten
            }
            return .abos
        }
    }

    var isClassicAbo: Bool {
        [PaymentCategory.streaming, .software].contains(category)
    }
}

// MARK: - Detector

enum SubscriptionDetector {

    // Shared fitness keywords (used by defaultTab and FreezeAnalyzer)
    static let fitnessKeywords = [
        "mcfit", "clever fit", "cleverfit", "urban sports", "fitx", "fitness first",
        "kieser", "yoga", "pilates", "holmes place", "john reed",
        "sportstudio", "fitnessclub", "crossfit", "anytime fitness",
    ]

    private static let aggregatorPatterns = [
        "paypal europe", "klarna bank", "amazon payments",
        "google payment", "apple pay",
    ]

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Extracts a stable customer/contract reference from remittance info.
    private static func customerKey(from remittance: String) -> String? {
        let patterns = [
            #"Kd\.(\d{6,12})"#,
            #"KdNr\.?\s*(\d{6,12})"#,
            #"Kundennr\.?\s*(\d{6,12})"#,
            #"Vertragsnr\.?\s*(\d{6,12})"#,
        ]
        for pat in patterns {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            let range = NSRange(remittance.startIndex..., in: remittance)
            guard let m = re.firstMatch(in: remittance, range: range),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: remittance) else { continue }
            return String(remittance[r])
        }
        return nil
    }

    static func detect(in transactions: [TransactionsResponse.Transaction]) -> [SubscriptionCandidate] {
        let expenses = transactions.filter { tx in
            guard tx.parsedAmount < 0 else { return false }
            let rem = (tx.remittanceInformation ?? []).joined(separator: " ").lowercased()
            // Refunds and returns are never candidates
            if rem.contains("erstattung") || rem.contains("rückzahlung") || rem.contains("retoure") { return false }
            // Intra-account transfers are not obligations
            if rem.contains("umbuchung") || rem.contains("übertrag auf konto") { return false }
            return true
        }

        var grouped: [String: [TransactionsResponse.Transaction]] = [:]
        for tx in expenses {
            let merchant = FixedCostsAnalyzer.merchantName(for: tx)
            let creditorLower = (tx.creditor?.name ?? "").lowercased()
            let isAggregator = creditorLower.contains("paypal") || creditorLower.contains("klarna")
            let remittance = (tx.remittanceInformation ?? []).joined(separator: " ")

            let key: String
            if isAggregator {
                key = "\(merchant)|agg"
            } else {
                let category = FixedCostsAnalyzer.categoryForMerchant(merchant)
                if category == .telecom, let custId = customerKey(from: remittance) {
                    key = "\(merchant)|\(custId)"
                } else {
                    let isKnown = category != .other
                    let iban = tx.creditor?.iban ?? tx.debtor?.iban ?? ""
                    let suffix = (iban.isEmpty || isKnown) ? "" : String(iban.suffix(8))
                    key = suffix.isEmpty ? merchant : "\(merchant)|\(suffix)"
                }
            }
            grouped[key, default: []].append(tx)
        }

        return grouped
            .compactMap { scoreGroup(merchantKey: $0.key, transactions: $0.value) }
            .filter { $0.confidence >= 7 }
            .sorted { $0.averageAmount > $1.averageAmount }
    }

    private static func scoreGroup(merchantKey: String, transactions: [TransactionsResponse.Transaction]) -> SubscriptionCandidate? {
        guard transactions.count >= 2 else { return nil }

        let merchantName = merchantKey.contains("|")
            ? String(merchantKey.split(separator: "|", maxSplits: 1).first ?? Substring(merchantKey))
            : merchantKey
        let lowerKey = merchantName.lowercased()

        // Aggregators are never candidates on their own
        for p in aggregatorPatterns where lowerKey.contains(p) { return nil }

        let cal = Calendar(identifier: .gregorian)
        let amounts = transactions.map { abs($0.parsedAmount) }
        let dates: [Date] = transactions
            .compactMap { tx -> Date? in
                guard let s = tx.bookingDate ?? tx.valueDate else { return nil }
                return isoFormatter.date(from: s)
            }
            .sorted()

        guard !dates.isEmpty else { return nil }

        let avgAmount = amounts.reduce(0, +) / Double(amounts.count)
        let category = FixedCostsAnalyzer.categoryForMerchant(merchantName)

        // Amount ceiling — higher for obligations and savings
        let amountLimit: Double = {
            switch category {
            case .finance:               return 5000.0
            case .insurance, .utilities: return 2000.0
            default:
                let isHousing = ["wohnungsbau", "mietverwaltung", "hausverwaltung"].contains { lowerKey.contains($0) }
                return isHousing ? 3000.0 : 600.0
            }
        }()
        guard avgAmount <= amountLimit else { return nil }

        let maxDev = amounts.map { abs($0 - avgAmount) }.max() ?? 0
        let relVar = avgAmount > 0 ? maxDev / avgAmount : 1.0

        // Wider tolerance for categories with variable billing
        let varianceTol: Double = {
            switch category {
            case .telecom, .transport, .finance, .insurance, .utilities: return 0.30
            default: return 0.15
            }
        }()
        let amountOK = relVar <= varianceTol || maxDev <= 2.0

        var intervals: [Int] = []
        for i in 1..<dates.count {
            intervals.append(cal.dateComponents([.day], from: dates[i - 1], to: dates[i]).day ?? 0)
        }
        let avgInterval = intervals.isEmpty ? 0.0 : Double(intervals.reduce(0, +)) / Double(intervals.count)
        let isMonthly = avgInterval >= 25 && avgInterval <= 35

        let daysOfMonth = dates.map { cal.component(.day, from: $0) }
        let daySpread = (daysOfMonth.max() ?? 0) - (daysOfMonth.min() ?? 0)

        let remittanceSample = (transactions.first?.remittanceInformation ?? []).joined(separator: " ")
        let cancellationEntry = CancellationLinks.find(merchant: merchantName, remittance: remittanceSample)
        let isKnownSubCategory = [PaymentCategory.streaming, .software, .membership,
                                   .telecom, .finance, .insurance, .utilities].contains(category)

        let firstTokens = transactions.compactMap {
            ($0.remittanceInformation ?? []).first?
                .lowercased().components(separatedBy: .whitespaces).first
        }.filter { !$0.isEmpty }
        let remittanceSimilar = Set(firstTokens).count <= 2

        var s = 3
        if transactions.count >= 3 { s += 3 }
        if isMonthly              { s += 3 }
        if amountOK               { s += 2 }
        if remittanceSimilar      { s += 2 }
        if cancellationEntry != nil || isKnownSubCategory { s += 2 }
        if daySpread <= 5         { s += 1 }
        if !amountOK              { s -= 3 }
        if !isMonthly && !intervals.isEmpty { s -= 2 }

        guard s >= 7 else { return nil }

        let lastTx = transactions.max { ($0.bookingDate ?? "") < ($1.bookingDate ?? "") }
        let lastAmount = abs(lastTx?.parsedAmount ?? avgAmount)
        let displayName = cancellationEntry?.displayName ?? merchantName

        return SubscriptionCandidate(
            id: merchantKey,
            displayName: displayName,
            averageAmount: avgAmount,
            lastAmount: lastAmount,
            lastDate: dates.last ?? Date(),
            cadence: isMonthly ? .monthly : .irregular,
            occurrences: transactions.count,
            confidence: s,
            hasCancellationLink: cancellationEntry != nil,
            cancellationEntry: cancellationEntry,
            category: category,
            matchedTransactions: transactions.sorted { ($0.bookingDate ?? "") > ($1.bookingDate ?? "") }
        )
    }
}
