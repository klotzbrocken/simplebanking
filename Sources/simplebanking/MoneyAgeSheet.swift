import SwiftUI

// MARK: - MoneyAgeSheet
//
// Auswertung „wie alt ist das Geld, das du gerade ausgibst?" — basiert auf
// dem FIFO-Algorithmus in `MoneyAge`. Wird aus dem „Mehr"-Menü des
// Umsatzpanels geöffnet.

struct MoneyAgeSheet: View {

    let transactions: [TransactionsResponse.Transaction]
    let onClose: () -> Void

    @State private var windowSize: Int = 10

    private var result: MoneyAge.Result {
        MoneyAge.calculate(
            entries: MoneyAge.entries(from: transactions),
            windowSize: windowSize
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            mainNumber
            bandLabel
            statsRow
            explainer
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 460, height: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Money Age", "Money Age"))
                    .font(.system(size: 18, weight: .semibold))
                Text(L10n.t(
                    "Durchschnittliches Alter des Geldes, das du gerade ausgibst.",
                    "Average age of the money you're currently spending."
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $windowSize) {
                Text(L10n.t("letzte 10", "last 10")).tag(10)
                Text(L10n.t("letzte 25", "last 25")).tag(25)
                Text(L10n.t("letzte 50", "last 50")).tag(50)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var mainNumber: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if result.band == .unknown {
                Text("—")
                    .font(.system(size: 56, weight: .bold).monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                Text(String(format: "%.0f", result.averageDays))
                    .font(.system(size: 56, weight: .bold).monospacedDigit())
                    .foregroundColor(bandColor)
                Text(L10n.t("Tage", "days"))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var bandLabel: some View {
        HStack(spacing: 8) {
            Circle().fill(bandColor).frame(width: 8, height: 8)
            Text(bandHeadline)
                .font(.system(size: 14, weight: .semibold))
            Text(bandSubtitle)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 24) {
            statTile(
                value: "\(result.sampleSize)",
                label: L10n.t("Ausgaben im Fenster", "expenses in window")
            )
            statTile(
                value: "\(result.totalExpenses)",
                label: L10n.t("Ausgaben gesamt", "total expenses")
            )
            statTile(
                value: "\(result.uncoveredExpenses)",
                label: L10n.t("davon nicht gedeckt", "of which uncovered"),
                emphasized: result.uncoveredExpenses > 0
            )
        }
    }

    private func statTile(value: String, label: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundColor(emphasized ? .sbOrangeStrong : .primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var explainer: some View {
        Text(L10n.t(
            "Annahme: das älteste Geld wird zuerst ausgegeben (FIFO). Pro Ausgabe wird das gewichtete Durchschnittsalter der verbrauchten Eingänge berechnet. Der gezeigte Wert ist der Durchschnitt über die letzten \(result.sampleSize) Ausgaben.",
            "Assumption: the oldest money is spent first (FIFO). For each expense, the weighted average age of the consumed inflows is calculated. The shown value is the average over the last \(result.sampleSize) expenses."
        ))
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.t("Schließen", "Close")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var bandColor: Color {
        switch result.band {
        case .sparse:     return .sbRedStrong
        case .ok:         return .sbOrangeStrong
        case .puffer:     return .sbGreenStrong
        case .monthAhead: return .sbBlueStrong
        case .unknown:    return .secondary
        }
    }

    private var bandHeadline: String {
        switch result.band {
        case .sparse:     return L10n.t("Eingang zu Ausgang", "Paycheck to paycheck")
        case .ok:         return L10n.t("Solide, aber eng", "Solid, but tight")
        case .puffer:     return L10n.t("Du hast Puffer", "You have a buffer")
        case .monthAhead: return L10n.t("Einen Monat voraus", "A month ahead")
        case .unknown:    return L10n.t("Zu wenig Daten", "Not enough data")
        }
    }

    private var bandSubtitle: String {
        switch result.band {
        case .sparse:     return L10n.t("< 15 Tage", "< 15 days")
        case .ok:         return L10n.t("15–30 Tage", "15–30 days")
        case .puffer:     return L10n.t("30–60 Tage", "30–60 days")
        case .monthAhead: return L10n.t("60+ Tage", "60+ days")
        case .unknown:    return ""
        }
    }
}
