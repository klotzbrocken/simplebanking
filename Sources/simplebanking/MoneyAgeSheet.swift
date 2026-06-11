import SwiftUI

// MARK: - MoneyAgeSheet
//
// Auswertung „wie alt ist das Geld, das du gerade ausgibst?" — basiert auf
// dem FIFO-Algorithmus in `MoneyAge`. Wird aus dem „Mehr"-Menü des
// Umsatzpanels geöffnet.

struct MoneyAgeSheet: View {

    let transactions: [TransactionsResponse.Transaction]
    var onClose: () -> Void = {}
    var embedded: Bool = false

    @State private var windowSize: Int = 10

    private var result: MoneyAge.Result {
        MoneyAge.calculate(
            entries: MoneyAge.entries(from: transactions),
            windowSize: windowSize
        )
    }

    private var windowLabel: String { L10n.t("letzte \(windowSize)", "last \(windowSize)") }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(L10n.t("Money Age", "Money Age"),
                      subtitle: L10n.t("Wie alt ist das Geld, das du ausgibst?", "How old is the money you spend?")) {
                Menu {
                    ForEach([10, 25, 50], id: \.self) { n in
                        Button { windowSize = n } label: { menuCheckItem(L10n.t("letzte \(n)", "last \(n)"), selected: windowSize == n) }
                    }
                } label: { MenuTriggerLabel(text: windowLabel) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Divider()
            // Volle Höhe vertikal verteilt, kein Scrollen: Intro · Hero · Stat-Karten · Deckung · Erklärung.
            VStack(alignment: .leading, spacing: 0) {
                intro
                Spacer(minLength: 14)
                heroCard
                if result.band != .unknown {
                    Spacer(minLength: 14)
                    statCardsRow
                    Spacer(minLength: 14)
                    coverageCard
                }
                Spacer(minLength: 14)
                explainer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(width: embedded ? nil : 460, height: embedded ? nil : 560)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Color.panelBackground)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t(
                "Wie alt ist das Geld im Schnitt, das du gerade ausgibst — also wie viele Tage zwischen Eingang und Ausgabe liegen?",
                "How old, on average, is the money you're currently spending — i.e. how many days pass between inflow and spending?"
            ))
            .font(.system(size: 13))
            Text(L10n.t(
                "Hoher Wert = Puffer: du lebst aus Rücklagen statt vom Geld von gestern. Niedriger Wert = von der Hand in den Mund. Gut, um zu sehen, ob du dir Luft erarbeitet hast.",
                "High value = buffer: you live off reserves, not yesterday's income. Low value = paycheck to paycheck. Good for seeing whether you've built breathing room."
            ))
            .font(.system(size: 12)).foregroundColor(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.sbBlueSoft.opacity(0.5)))
    }

    // MARK: Hero-Karte

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 20) {
            mainNumber
            VStack(alignment: .leading, spacing: 10) {
                bandLabel
                if result.band != .unknown { bandGauge }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .dashboardCard()
    }

    private var mainNumber: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if result.band == .unknown {
                Text("—")
                    .font(.system(size: 60, weight: .bold).monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                Text(String(format: "%.0f", result.averageDays))
                    .font(.system(size: 60, weight: .bold).monospacedDigit())
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

    // MARK: 3 Stat-Karten (Spannweite · Trend · nicht gedeckt)

    private var statCardsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            statCard(
                value: "\(Int(result.minDays.rounded()))–\(Int(result.maxDays.rounded()))",
                label: L10n.t("Spannweite (Tage)", "Range (days)"),
                color: .primary
            )
            trendCard
            statCard(
                value: "\(result.uncoveredExpenses)",
                label: L10n.t("nicht gedeckt", "uncovered"),
                color: result.uncoveredExpenses > 0 ? .sbOrangeStrong : .primary
            )
        }
    }

    private func statCard(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 21, weight: .bold).monospacedDigit())
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dashboardCard()
    }

    private var trendCard: some View {
        let delta = result.previousAverageDays.map { result.averageDays - $0 }
        return VStack(alignment: .leading, spacing: 3) {
            if let d = delta {
                // Höheres Geldalter = größerer Puffer = positiv → steigend grün/▲, fallend orange/▼.
                HStack(spacing: 4) {
                    Image(systemName: d > 0 ? "arrow.up.right" : (d < 0 ? "arrow.down.right" : "arrow.right"))
                    Text(String(format: "%+.0f", d))
                }
                .font(.system(size: 21, weight: .bold).monospacedDigit())
                .foregroundColor(d >= 0 ? .sbGreenStrong : .sbOrangeStrong)
            } else {
                Text("—").font(.system(size: 21, weight: .bold)).foregroundColor(.secondary)
            }
            Text(L10n.t("Trend vs. vorher", "Trend vs. previous"))
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dashboardCard()
    }

    // MARK: Band-Skala (Gauge)

    private var bandGauge: some View {
        let maxScale: Double = 90
        let frac = min(1.0, max(0.0, result.averageDays / maxScale))
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Einordnung", "Where it sits"))
                .font(.system(size: 11)).foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.sbRedStrong.opacity(0.5)).frame(width: geo.size.width * (15.0/maxScale))
                        Rectangle().fill(Color.sbOrangeStrong.opacity(0.5)).frame(width: geo.size.width * (15.0/maxScale))
                        Rectangle().fill(Color.sbGreenStrong.opacity(0.5)).frame(width: geo.size.width * (30.0/maxScale))
                        Rectangle().fill(Color.sbBlueStrong.opacity(0.5))
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())

                    Capsule().fill(Color.primary)
                        .frame(width: 3, height: 16)
                        .offset(x: max(0, geo.size.width * frac - 1.5))
                }
            }
            .frame(height: 16)
            HStack {
                Text(L10n.t("frisch", "fresh")).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(L10n.t("alt (60+ Tage)", "old (60+ days)")).font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Deckungs-Karte

    private var coverageCard: some View {
        let total = max(1, result.totalExpenses)
        let coveredCount = max(0, result.totalExpenses - result.uncoveredExpenses)
        let coveredFrac = Double(coveredCount) / Double(total)
        let pct = Int((coveredFrac * 100).rounded())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("Deckung", "Coverage"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(pct) %")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundColor(.sbGreenStrong)
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.sbGreenStrong.opacity(0.6)).frame(width: geo.size.width * coveredFrac)
                    Rectangle().fill(Color.sbOrangeStrong.opacity(0.5))
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            Text(L10n.t(
                "\(coveredCount) von \(result.totalExpenses) Ausgaben durch frühere Eingänge gedeckt",
                "\(coveredCount) of \(result.totalExpenses) expenses covered by earlier inflows"
            ))
            .font(.system(size: 11)).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .dashboardCard()
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
