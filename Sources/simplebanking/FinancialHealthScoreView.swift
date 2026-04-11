import SwiftUI

// MARK: - Financial Health Score View (MMI)
// Ersetzt den alten Financial Health Score — gleiche "Activity"-Optik, neue MMI-Logik.

struct FinancialHealthScoreView: View {
    let transactions: [TransactionsResponse.Transaction]
    let balance: Double

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = MMIViewModel()
    @State private var animProgress: Double = 0

    private static let expenseColor = MMIColors.expense
    private static let savingsColor = MMIColors.savings
    private static let liquidColor  = MMIColors.liquid

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header (pinned outside ScrollView)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Financial Health")
                        .font(.system(size: 24, weight: .bold))
                    Text("Money Mass Index (MMI)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 12)

        ScrollView {
            VStack(spacing: 24) {

                // MARK: Period Picker
                Picker("Zeitraum", selection: $vm.period) {
                    ForEach(MMIPeriod.allCases) { p in Text(p.label).tag(p) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: vm.period) { _ in
                    vm.load(transactions: transactions, balance: balance)
                    resetAnimation()
                }

                // MARK: Ring
                MMIRingView(
                    components: vm.displayed,
                    size: 220,
                    lineWidth: 22,
                    animProgress: animProgress
                )
                .padding(.vertical, 6)

                // MARK: Legende / Info-Rows
                VStack(alignment: .leading, spacing: 16) {
                    MMIInfoRow(
                        color: Self.expenseColor,
                        title: "Ausgegeben",
                        text: "Summe aller Ausgaben im Zeitraum.",
                        value: formatCurrency(vm.displayed.expenses)
                    )
                    MMIInfoRow(
                        color: Self.savingsColor,
                        title: "Geparkt",
                        text: "Erkannte Abflüsse zu Spar- und Vorsorgekonten.",
                        value: formatCurrency(vm.displayed.savings)
                    )
                    MMIInfoRow(
                        color: Self.liquidColor,
                        title: "Liquide",
                        text: String(format: "Kontostand — entspricht %.1f Monaten Ausgaben.", vm.displayed.bufferMonths),
                        value: formatCurrency(vm.displayed.balance)
                    )
                }
                .padding(.horizontal)

                // MARK: Score-Kacheln
                Divider()
                    .background(Color.secondary.opacity(0.3))
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    MMIStatBox(
                        title: "Score",
                        value: String(format: "%.2f", vm.displayed.score * animProgress),
                        color: vm.displayed.rating.color
                    )
                    MMIStatBox(
                        title: "Sparrate",
                        value: String(format: "%+.0f%%", vm.displayed.savingsRate * 100 * animProgress),
                        color: vm.displayed.savingsRate >= 0 ? .sbBlueStrong : .sbRedStrong
                    )
                    MMIStatBox(
                        title: "Puffer",
                        value: String(format: "%.1f Mon.", vm.displayed.bufferMonths),
                        color: Self.liquidColor
                    )
                }
                .padding(.horizontal)

                // MARK: Plan-Modus
                Divider()
                    .background(Color.secondary.opacity(0.3))
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.sbBlueStrong)
                        Text("Plan-Modus")
                            .font(.system(size: 18, weight: .bold))
                        Spacer()
                        Toggle("", isOn: $vm.planMode)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if vm.planMode {
                        VStack(spacing: 14) {
                            MMIDarkSlider(
                                label: "Einkommen",
                                color: Self.liquidColor,
                                value: $vm.planIncome,
                                range: 0...max(5000, vm.real.income * 2),
                                diff: vm.displayed.income - vm.real.income
                            )
                            MMIDarkSlider(
                                label: "Ausgaben",
                                color: Self.expenseColor,
                                value: $vm.planExpenses,
                                range: 0...max(2000, vm.real.expenses * 2),
                                diff: vm.displayed.expenses - vm.real.expenses
                            )
                            MMIDarkSlider(
                                label: "Geparkt",
                                color: Self.savingsColor,
                                value: $vm.planSavings,
                                range: 0...max(1000, max(vm.real.income, vm.real.savings) * 1.5),
                                diff: vm.displayed.savings - vm.real.savings
                            )
                            MMIDarkSlider(
                                label: "Liquide",
                                color: Self.liquidColor,
                                value: $vm.planBalance,
                                range: min(vm.real.balance, 0)...max(5000, max(vm.real.balance, 0) * 3),
                                diff: vm.displayed.balance - vm.real.balance
                            )

                            // Score-Diff
                            HStack(spacing: 16) {
                                diffKpi(label: "Score",   diff: vm.scoreDiff,
                                        format: { String(format: "%+.2f", $0) })
                                diffKpi(label: "Sparrate", diff: vm.savingsRateDiff,
                                        format: { String(format: "%+.0f%%", $0 * 100) })
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal)
                .animation(.easeInOut(duration: 0.22), value: vm.planMode)

                // MARK: Disclaimer
                Text("Zeitraum: \(vm.period.label) · Sparbewegungen = erkannte Abflüsse zu Spar-/Vorsorgekonten · Kontostand ≠ Notfallreserve")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer(minLength: 20)
            }
            .padding(.top, 12)
        }
        }
        .frame(width: 420, height: 680)
        .background(Color.sbBackground.edgesIgnoringSafeArea(.all))
        .onAppear {
            vm.load(transactions: transactions, balance: balance)
            resetAnimation()
        }
    }

    // MARK: - Helpers

    private func resetAnimation() {
        animProgress = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 1.5, dampingFraction: 0.7, blendDuration: 0)) {
                animProgress = 1.0
            }
        }
    }

    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    private func formatCurrency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value)) €"
    }

    @ViewBuilder
    private func diffKpi(label: String, diff: Double, format: (Double) -> String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if abs(diff) > 0.005 {
                Text(format(diff))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(diff > 0 ? Color.sbGreenSoft : Color.sbRedSoft)
                    )
                    .foregroundColor(diff > 0 ? .sbGreenStrong : .sbRedStrong)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Subviews (dark-mode styled)

private struct MMIInfoRow: View {
    let color: Color
    let title: String
    let text: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(color)
                    Spacer()
                    Text(value)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(color)
                }
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MMIStatBox: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.sbSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.sbBorder, lineWidth: 1)
        )
    }
}

private struct MMIDarkSlider: View {
    let label: String
    let color: Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    let diff: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f €", value))
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                if abs(diff) > 0.5 {
                    Text(String(format: "%+.0f €", diff))
                        .font(.system(size: 10))
                        .foregroundColor(diff > 0 ? .sbGreenStrong : .sbOrangeStrong)
                }
            }
            Slider(value: $value, in: range)
                .tint(color)
        }
    }
}
