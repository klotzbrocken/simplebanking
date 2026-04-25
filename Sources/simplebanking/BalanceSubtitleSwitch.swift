import SwiftUI

/// Subtitle unter dem großen Kontostand mit Toggle zwischen drei Modi:
/// • `0` = Classic: „Noch offen: X €" / „Alles gebucht für diesen Zyklus"
/// • `1` = Sub-Metrics: „€ 847 bis zum 1. verfügbar"
/// • `2` = Day-only: „€ 34/Tag verfügbar"
///
/// Der Toggle-Style wird außen via `@Binding` gehalten, damit Caller
/// (Flyout vs. Umsatzpanel) eigene `@AppStorage`-Keys nutzen können und
/// die beiden Views unabhängig gewechselt werden.
struct BalanceSubtitleSwitch: View {
    let balance: Double?
    let leftToPayAmount: Double?
    let salaryDay: Int
    let salaryToleranceBefore: Int
    let salaryToleranceAfter: Int
    @Binding var style: Int
    /// Wenn `true`, wird zwingend der Classic-Mode angezeigt und der Toggle-Button
    /// ausgeblendet. Nutzung: im Unified-Mode, wo Sub-Metrics mit aggregiertem
    /// `leftToPayAmount` gegen einen einzelnen Slot-Gehaltstag rechnen würden
    /// und damit fachlich inkonsistent wären.
    var forceClassic: Bool = false

    private static let classicFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "de_DE")
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    private func classicLabel(_ amount: Double) -> String {
        let formatted = Self.classicFormatter.string(from: NSNumber(value: amount)) ?? "\(Int(amount)) €"
        return L10n.t("Noch offen: \(formatted)", "Still to pay: \(formatted)")
    }

    private func toggle() {
        // Cycle: Classic (0) → Sub-Metrics (1) → Day-only (2) → Classic
        style = (style + 1) % 3
    }

    private var currentModeLabel: String {
        switch style {
        case 1: return L10n.t("Sub-Metrics", "Sub-metrics")
        case 2: return L10n.t("Tagesbudget", "Daily budget")
        default: return L10n.t("Klassisch", "Classic")
        }
    }

    private var nextModeLabel: String {
        switch (style + 1) % 3 {
        case 1: return L10n.t("Sub-Metrics", "Sub-metrics")
        case 2: return L10n.t("Tagesbudget", "Daily budget")
        default: return L10n.t("Klassisch", "Classic")
        }
    }

    private var currentModeIcon: String {
        switch style {
        case 1: return "chart.bar.fill"
        case 2: return "sun.max.fill"
        default: return "text.alignleft"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if !forceClassic {
                Button(action: toggle) {
                    Image(systemName: currentModeIcon)
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .help(L10n.t(
                    "Aktuell: \(currentModeLabel)\nKlick → \(nextModeLabel)",
                    "Current: \(currentModeLabel)\nClick → \(nextModeLabel)"
                ))
            }
            subtitleContent
        }
    }

    @ViewBuilder
    private var subtitleContent: some View {
        if forceClassic {
            classicContent
        } else {
            switch style {
            case 1:
                subMetricsWithFallback(dayOnly: false)
            case 2:
                subMetricsWithFallback(dayOnly: true)
            default:
                classicContent
            }
        }
    }

    // MARK: - Sub-Metrics Mode (mit Classic-Fallback bei .unknown)

    @ViewBuilder
    private func subMetricsWithFallback(dayOnly: Bool) -> some View {
        let metrics = BalanceSubMetrics.compute(
            balance: balance,
            leftToPay: leftToPayAmount,
            salaryDay: salaryDay,
            toleranceBefore: salaryToleranceBefore,
            toleranceAfter: salaryToleranceAfter
        )
        switch metrics.state {
        case .normal, .overdrawn:
            BalanceSubMetricsLabel(metrics: metrics, dayOnly: dayOnly)
        case .unknown:
            classicContent
        }
    }

    // MARK: - Classic Mode

    @ViewBuilder
    private var classicContent: some View {
        if let amount = leftToPayAmount {
            let text = amount > 0.5
                ? classicLabel(amount)
                : L10n.t("Alles gebucht für diesen Zyklus", "All paid for this cycle")
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .lineLimit(1)
        } else {
            // Placeholder reserves vertical space while value is computing
            Text(" ")
                .font(.system(size: 13, weight: .regular))
                .hidden()
        }
    }
}
