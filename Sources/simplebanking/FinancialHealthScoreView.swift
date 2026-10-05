import SwiftUI

// MARK: - Financial Health Score View (MMI)
// Ersetzt den alten Financial Health Score — gleiche "Activity"-Optik, neue MMI-Logik.

struct FinancialHealthScoreView: View {
    let transactions: [TransactionsResponse.Transaction]
    let balance: Double
    var embedded: Bool = false
    /// Wechselt bei Slot-Wechsel/Refresh (Dashboard-`snapshotID`) → erzwingt Neuberechnung
    /// via `.task(id:)`. Default 0 für Standalone-Nutzung (feuert dann nur einmal).
    var reloadToken: Int = 0

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = MMIViewModel()
    @State private var animProgress: Double = 0

    private static let expenseColor = MMIColors.expense
    private static let savingsColor = MMIColors.savings
    private static let liquidColor  = MMIColors.liquid

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Einheitlicher Kopf mit Zeitraum-Steuerung rechts
            TabHeader("Financial Health", subtitle: "Money Mass Index (MMI)") {
                Picker("", selection: $vm.period) {
                    ForEach(MMIPeriod.allCases) { p in Text(p.label).tag(p) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .onChange(of: vm.period) { _ in
                    vm.load(transactions: transactions, balance: balance)
                    resetAnimation()
                }
            }
            Divider()

        // Drei Gruppen über die volle Höhe verteilt (space-evenly), kein Scrollen.
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            // Ring + Score LINKS, Erklärung im freien Platz rechts.
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 14) {
                    MMIRingView(components: vm.displayed, size: 168, lineWidth: 18, animProgress: animProgress)
                    VStack(alignment: .leading, spacing: 9) {
                        compactStat("Score", String(format: "%.2f", vm.displayed.score * animProgress), vm.displayed.rating.color)
                        compactStat("Sparrate", String(format: "%+.0f %%", vm.displayed.savingsRate * 100 * animProgress),
                                    vm.displayed.savingsRate >= 0 ? .sbBlueStrong : .sbRedStrong)
                        compactStat("Puffer", String(format: "%.1f Mon.", vm.displayed.bufferMonths), Self.liquidColor)
                    }
                }
                .fixedSize()
                mmiExplanation
            }
            .padding(.horizontal)

            Spacer(minLength: 16)

            // Ausgaben / Geparkt / Liquide als Karten-Band
            HStack(alignment: .top, spacing: 12) {
                metricColumn(color: Self.expenseColor, title: "Ausgegeben",
                             value: formatCurrency(vm.displayed.expenses),
                             desc: "Summe aller Ausgaben im Zeitraum.")
                metricColumn(color: Self.savingsColor, title: "Geparkt",
                             value: formatCurrency(vm.displayed.savings),
                             desc: "Abflüsse zu Spar-/Vorsorgekonten (Sparrate).")
                metricColumn(color: Self.liquidColor, title: "Liquide",
                             value: formatCurrency(vm.displayed.balance),
                             desc: String(format: "Kontostand — %.1f Mon. Ausgaben.", vm.displayed.bufferMonths))
            }
            .padding(.horizontal)

            Spacer(minLength: 10)

            Text("Zeitraum: \(vm.period.label) · Kontostand ≠ Notfallreserve")
                .font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: embedded ? nil : 420, height: embedded ? nil : 680)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Color.sbBackground.edgesIgnoringSafeArea(.all))
        // `.task(id:)` feuert beim Erscheinen UND bei jeder Token-Änderung (Slot-Wechsel/
        // Refresh) → MMI rechnet frisch, ohne die View neu aufzubauen.
        .task(id: reloadToken) {
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

    private func compactStat(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(value).font(.system(size: 22, weight: .bold)).foregroundColor(color).monospacedDigit()
            Text(title).font(.system(size: 12.5)).foregroundColor(.secondary)
        }
    }

    // MARK: - MMI-Erklärung (rechts neben Ring)

    private var mmiExplanation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("So entsteht dein MMI")
                .font(.system(size: 14, weight: .bold))
            explainRow(color: Self.liquidColor, title: "Pufferreichweite",
                       text: "Wie viele Monate dein Kontostand die ø-Ausgaben deckt — der Kern des Scores. ~3 Monate = gesund.")
            explainRow(color: Self.savingsColor, title: "Sparrate",
                       text: "Aktives Sparen (ETF, Sparplan, Depot, Tagesgeld) zählt positiv mit — bis +0,15 Bonus auf den Score.")
            Divider().padding(.vertical, 2)
            Text("So hebst du ihn")
                .font(.system(size: 14, weight: .bold))
            tipRow("Liquiden Puffer aufbauen — schon 1–3 Monatsausgaben heben den Score deutlich.")
            tipRow("Regelmäßig sparen — erkannte Sparabflüsse zählen positiv mit.")
            tipRow("Fixkosten senken — weniger Burn = längere Pufferreichweite.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func explainRow(color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundColor(.sbGreenStrong).padding(.top, 1)
            Text(text).font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metricColumn(color: Color, title: String, value: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(color).lineLimit(1)
            }
            Text(value).font(.system(size: 21, weight: .bold)).foregroundColor(color).monospacedDigit()
            Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .accentCard(color)
    }

    private func formatCurrency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value)) €"
    }

}
