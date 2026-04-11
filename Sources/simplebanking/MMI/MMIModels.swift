import SwiftUI

// MARK: - MMI Color Palette
// Mapped auf die Color Harmony Palette — keine MMI-eigenen Akzentfarben mehr.
// expense → Red, savings → Blue, liquid → Green (Strong-Variante für Ringe/Numbers)

enum MMIColors {
    static var expense: Color { .sbRedStrong }
    static var savings: Color { .sbBlueStrong }
    static var liquid:  Color { .sbGreenStrong }
}

// MARK: - Period

enum MMIPeriod: Int, CaseIterable, Identifiable {
    case month = 1, quarter = 3, year = 12

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .month:   return "Dieser Monat"
        case .quarter: return "3 Monate"
        case .year:    return "12 Monate"
        }
    }

    var days: Int { rawValue * 30 }
}

// MARK: - Transaction Classification

enum MMITransactionKind {
    case income, expense, savings, transfer, refund
}

extension TransactionsResponse.Transaction {
    var mmiKind: MMITransactionKind {
        let amount = parsedAmount
        let rem    = (remittanceInformation ?? []).joined(separator: " ").lowercased()
        let add    = (additionalInformation ?? "").lowercased()
        let cred   = (creditor?.name ?? "").lowercased()
        let combined = rem + " " + add + " " + cred

        if amount > 0 {
            // Own-account transfers / Umbuchungen
            if purposeCode == "XBND" || combined.contains("umbuchung") || combined.contains("übertrag") {
                return .transfer
            }
            // Refunds — keywords or tiny amounts
            let refundWords = ["erstattung", "rücküberweisung", "rückbuchung",
                               "gutschrift", "refund", "storno", "cashback", "korrektur", "retoure"]
            if refundWords.contains(where: { combined.contains($0) }) || amount < 5 {
                return .refund
            }
            return .income
        } else {
            // Own-account / Umbuchungen
            if purposeCode == "XBND" || combined.contains("umbuchung") || combined.contains("übertrag") {
                return .transfer
            }
            // Savings / Vorsorge / Depot movements
            let savingsWords = ["sparplan", "etf", "depot", "vorsorge",
                                "riester", "rürup", "fondssparplan", "invest",
                                "tagesgeld", "festgeld", "wertpapier"]
            if savingsWords.contains(where: { combined.contains($0) }) {
                return .savings
            }
            return .expense
        }
    }
}

// MARK: - MMI Components

struct MMIComponents {
    let income:   Double
    let expenses: Double
    let savings:  Double    // Abflüsse zu Spar-/Vorsorgekonten
    let balance:  Double    // Aktueller Kontostand (Girokonto)
    let period:   MMIPeriod

    /// Sparrate: kann negativ sein (wenn Ausgaben > Einkommen),
    /// wird aber auf [-1, 1] geclampt damit die Kennzahl semantisch haltbar bleibt.
    /// Aktives Sparen (Depot, Sparplan) zählt mit rein.
    var savingsRate: Double {
        guard income > 0 else { return 0 }
        let raw = (income - expenses + savings) / income
        return min(max(raw, -1), 1)
    }

    /// BF = Kontostand normiert gegen 3-Monats-Reserve, geclampt [0, 1]
    /// (für Ring-Visuals; der Score nutzt die Funktion `bufferScore` direkt)
    var bufferFactor: Double {
        guard bufferMonths > 0 else { return 0 }
        return min(bufferMonths / 3.0, 1.0)
    }

    /// Reichweite des Kontostands in Monaten gegen den durchschnittlichen Burn.
    var bufferMonths: Double {
        let monthlyExp = expenses / Double(period.rawValue)
        guard monthlyExp > 0 else { return balance > 0 ? .infinity : 0 }
        return max(balance / monthlyExp, 0)
    }

    /// MMI Score [0,1]
    /// - Hauptkomponente: Pufferreichweite (paycheck-to-paycheck-tauglich)
    /// - Bonus: positive Sparrate
    /// Additiv, nicht multiplikativ — eine Null killt nicht alles.
    var score: Double {
        let base = Self.bufferScore(bufferMonths)
        let bonus = max(savingsRate, 0) * 0.15   // bis +0.15 bei 100% SR
        return min(base + bonus, 1.0)
    }

    /// Mappt Pufferreichweite (Monate) auf [0,1] mit sinnvollen Ankerpunkten:
    /// 0d→0 · 1 Wo→0.15 · 2 Wo→0.30 · 1 Mo→0.55 · 3 Mo→0.85 · 6+ Mo→1.0
    private static func bufferScore(_ months: Double) -> Double {
        guard months > 0 else { return 0 }
        if months >= 6 { return 1.0 }
        let pts: [(Double, Double)] = [
            (0.0,  0.00),
            (0.25, 0.15),
            (0.5,  0.30),
            (1.0,  0.55),
            (3.0,  0.85),
            (6.0,  1.00),
        ]
        for i in 0..<(pts.count - 1) {
            let (x0, y0) = pts[i]
            let (x1, y1) = pts[i + 1]
            if months <= x1 {
                let t = (months - x0) / (x1 - x0)
                return y0 + t * (y1 - y0)
            }
        }
        return 1.0
    }

    var rating: MMIRating { MMIRating(score: score) }

    /// Ringanteile (Rot / Blau / Grün) als Anteil an der Gesamtsumme
    /// Ausgaben + Sparbewegungen + aktueller Kontostand.
    /// → Liquidität ist immer sichtbar, auch wenn expenses ≥ income.
    var ringProportions: (expenses: Double, savings: Double, liquid: Double) {
        let liquid = max(balance, 0)
        let total = expenses + savings + liquid
        guard total > 0 else { return (0, 0, 0) }
        return (expenses / total, savings / total, liquid / total)
    }

    static let zero = MMIComponents(income: 0, expenses: 0, savings: 0, balance: 0, period: .quarter)
}

// MARK: - Rating

enum MMIRating: String {
    case critical  = "Kritisch"
    case weak      = "Angeschlagen"
    case solid     = "Solide"
    case healthy   = "Gesund"
    case excellent = "Exzellent"

    init(score: Double) {
        switch score {
        case ..<0.15: self = .critical   // < ~1 Woche Puffer
        case ..<0.30: self = .weak       // ~1–2 Wochen
        case ..<0.55: self = .solid      // ~2 Wochen – 1 Monat
        case ..<0.85: self = .healthy    // 1–3 Monate
        default:      self = .excellent  // 3+ Monate
        }
    }

    var color: Color {
        // Color Harmony Palette — Strong-Variante für Status-Indikatoren.
        switch self {
        case .critical:  return .sbRedStrong
        case .weak:      return .sbOrangeStrong
        case .solid:     return .sbOrangeMid
        case .healthy:   return .sbGreenMid
        case .excellent: return .sbGreenStrong
        }
    }
}
