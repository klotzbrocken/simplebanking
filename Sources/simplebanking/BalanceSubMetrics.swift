import Foundation
import SwiftUI

/// „Ehrliche" Kontostand-Metriken unter dem großen Saldo:
/// • Wie viel bleibt bis zum Gehaltseingang (Saldo − erwartete Fixkosten)?
/// • Wie viel pro Tag steht dir davon zur Verfügung (÷ Resttage)?
///
/// Baut auf `LeftToPayCalculator.cycleEnd(...)` auf, damit der Zyklus konsistent
/// zum Rest der App definiert ist (Salary-Day + Toleranz).
struct BalanceSubMetrics: Equatable {
    let availableAmount: Double   // Saldo − leftToPay (kann negativ sein)
    let daysUntilSalary: Int      // Tage bis Gehaltseingang (≥ 1 außer im .unknown-State)
    let dailyBudget: Double       // availableAmount / daysUntilSalary
    let salaryDayOfMonth: Int     // Tag-des-Monats des nächsten Gehaltseingangs
    let state: State

    enum State: Equatable {
        case normal         // availableAmount >= 0, days > 0
        case overdrawn      // availableAmount < 0
        case unknown        // balance ODER leftToPay fehlen → Fallback auf Classic-Subtitle
    }

    /// - Parameters:
    ///   - balance: aktueller Kontostand (nil ⇒ .unknown)
    ///   - leftToPay: erwartete Fixkosten bis Gehaltseingang
    ///     (nil ⇒ .unknown — wichtig: ein nicht-berechneter Wert darf NICHT still als 0
    ///     interpretiert werden, sonst zeigt die App eine zu optimistische „verfügbare" Zahl)
    ///   - salaryDay: `BankSlotSettings.effectiveSalaryDay` (1/15/custom)
    ///   - toleranceBefore: `BankSlotSettings.salaryDayToleranceBefore` (0 oder 4)
    ///   - toleranceAfter:  `BankSlotSettings.salaryDayToleranceAfter` (0 oder 1)
    ///   - today: injectable für Tests
    static func compute(
        balance: Double?,
        leftToPay: Double?,
        salaryDay: Int,
        toleranceBefore: Int,
        toleranceAfter: Int,
        today: Date = Date()
    ) -> BalanceSubMetrics {
        guard let balance, let ltp = leftToPay else {
            return BalanceSubMetrics(availableAmount: 0, daysUntilSalary: 0,
                                     dailyBudget: 0, salaryDayOfMonth: salaryDay, state: .unknown)
        }

        let available = balance - ltp

        let cycleEnd = LeftToPayCalculator.cycleEnd(salaryDay: salaryDay,
                                                    toleranceBefore: toleranceBefore,
                                                    toleranceAfter: toleranceAfter,
                                                    today: today)
        let cal = Calendar.current
        let daysRaw = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: today),
            to: cal.startOfDay(for: cycleEnd)
        ).day ?? 0

        // Der angezeigte Tag ist immer der NOMINALE Gehaltstag, nicht das cycleEnd-Datum.
        // cycleEnd hat `+toleranceAfter` schon eingerechnet — würden wir das Day-Component
        // nehmen, käme bei salaryDay=15, toleranceAfter=1 fälschlicherweise „bis zum 16."
        // in der Anzeige. Der User hat „15." eingestellt, „15." soll er sehen.
        let salaryDom = salaryDay

        // `LeftToPayCalculator.cycleEnd()` liefert per Kontrakt einen Tag strikt nach heute.
        // Defensiv: falls das je anders sein sollte, Fallback auf .unknown statt divide-by-zero.
        guard daysRaw > 0 else {
            return BalanceSubMetrics(availableAmount: available, daysUntilSalary: daysRaw,
                                     dailyBudget: 0, salaryDayOfMonth: salaryDom, state: .unknown)
        }
        if available < 0 {
            return BalanceSubMetrics(availableAmount: available, daysUntilSalary: daysRaw,
                                     dailyBudget: 0, salaryDayOfMonth: salaryDom, state: .overdrawn)
        }

        let daily = available / Double(daysRaw)
        return BalanceSubMetrics(availableAmount: available, daysUntilSalary: daysRaw,
                                 dailyBudget: daily, salaryDayOfMonth: salaryDom, state: .normal)
    }
}

// MARK: - View

struct BalanceSubMetricsLabel: View {
    let metrics: BalanceSubMetrics
    /// `true` = nur die Tages-Budget-Zeile („€ Z/Tag verfügbar") zeigen, ohne „bis zum X.".
    /// Overdrawn-Warnung bleibt unverändert (kritisch), `.unknown` rendert nichts.
    var dayOnly: Bool = false

    private static let eurNoDecimals: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "de_DE")
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    private func euro(_ amount: Double) -> String {
        Self.eurNoDecimals.string(from: NSNumber(value: amount.rounded())) ?? "\(Int(amount.rounded())) €"
    }

    var body: some View {
        switch metrics.state {
        case .overdrawn:
            Text(L10n.t(
                "\(euro(-metrics.availableAmount)) überzogen bis \(metrics.salaryDayOfMonth).",
                "\(euro(-metrics.availableAmount)) overdrawn until \(metrics.salaryDayOfMonth)."
            ))
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(.sbRedStrong)
            .lineLimit(1)

        case .normal:
            if dayOnly {
                Text(L10n.t(
                    "\(euro(metrics.dailyBudget))/Tag verfügbar",
                    "\(euro(metrics.dailyBudget))/day available"
                ))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .lineLimit(1)
            } else {
                Text(L10n.t(
                    "\(euro(metrics.availableAmount)) bis zum \(metrics.salaryDayOfMonth). verfügbar",
                    "\(euro(metrics.availableAmount)) until \(metrics.salaryDayOfMonth). available"
                ))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .lineLimit(1)
                .truncationMode(.tail)
            }

        case .unknown:
            EmptyView()
        }
    }
}
