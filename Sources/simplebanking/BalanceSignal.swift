import SwiftUI

enum BalanceSignalLevel {
    case deepOverdraft
    case overdraft
    case low
    case medium
    case good
    case veryGood
    case unknown
}

struct BalanceSignalThresholds {
    let deepOverdraftThreshold: Double
    let lowUpperBound: Double
    let mediumUpperBound: Double
    let veryGoodLowerBound: Double
}

struct BalanceSignalStyle {
    let amountColor: Color
    let statusColor: Color
    let gradientBaseColor: Color
    let statusTextDE: String
    let statusTextEN: String

    var localizedStatusText: String {
        L10n.t(statusTextDE, statusTextEN)
    }
}

// MARK: - Live-Preview Skala (Settings)

/// Horizontale 6-Band-Skala die zeigt wie die User-Schwellen die Tier-Farben aufteilen.
/// Die Bänder werden proportional zum jeweiligen Range gerendert; ein kleiner Marker
/// zeigt den letzten gecachten Saldo des aktiven Slots, falls vorhanden.
struct BalanceMoodPreviewBar: View {
    let deepThr: Int
    let lowUB: Int
    let medUB: Int
    let veryGoodLB: Int

    /// Sichtbarer Range: links genug Luft unter deepThr, rechts genug über veryGoodLB.
    private var minVisible: Double { Double(deepThr) * 1.5 - 200 }
    private var maxVisible: Double { Double(veryGoodLB) * 1.5 + 200 }

    private var currentBalance: Double? {
        let slotId = UserDefaults.standard.string(forKey: "simplebanking.multibanking.activeSlotId")
            ?? UserDefaults.standard.string(forKey: "lastSelectedSlotId") ?? "legacy"
        let key = "simplebanking.cachedBalance.\(slotId)"
        guard let n = UserDefaults.standard.object(forKey: key) as? Double else { return nil }
        return n
    }

    private func position(_ value: Double, in width: CGFloat) -> CGFloat {
        let span = max(1, maxVisible - minVisible)
        let clamped = min(maxVisible, max(minVisible, value))
        return CGFloat((clamped - minVisible) / span) * width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let xDeep = position(Double(deepThr), in: w)
                let xZero = position(0, in: w)
                let xLow  = position(Double(lowUB), in: w)
                let xMed  = position(Double(medUB), in: w)
                let xVG   = position(Double(veryGoodLB), in: w)

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.sbBurgundyStrong).frame(width: xDeep)
                        Rectangle().fill(Color.sbRedStrong).frame(width: max(0, xZero - xDeep))
                        Rectangle().fill(Color.sbOrangeStrong).frame(width: max(0, xLow - xZero))
                        Rectangle().fill(Color.sbOrangeMid).frame(width: max(0, xMed - xLow))
                        Rectangle().fill(Color.sbGreenStrong).frame(width: max(0, xVG - xMed))
                        Rectangle().fill(Color.sbEmeraldStrong)  // Rest
                    }
                    .frame(height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    if let bal = currentBalance {
                        let x = position(bal, in: w)
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2, height: 16)
                            .offset(x: x - 1, y: -3)
                    }
                }
            }
            .frame(height: 16)

            HStack(spacing: 0) {
                Text(L10n.t("tief", "deep")).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("\(deepThr)").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("0").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("\(lowUB)").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("\(medUB)").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text("\(veryGoodLB)").font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Text(L10n.t("sehr gut", "very good")).font(.system(size: 9)).foregroundColor(.secondary)
            }
            if let bal = currentBalance {
                Text(L10n.t("Aktueller Saldo: \(Int(bal)) €", "Current balance: \(Int(bal)) €"))
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8))
            }
        }
    }
}

enum BalanceSignal {
    // Color Harmony Palette — semantische Tokens, kein Hardcoded-Hex mehr.
    // Yellow gibt es in der neuen Palette nicht — "medium" verwendet Orange Mid.
    private static var burgundy: Color { .sbBurgundyStrong }
    private static var red:      Color { .sbRedStrong }
    private static var orange:   Color { .sbOrangeStrong }
    private static var yellow:   Color { .sbOrangeMid }
    private static var green:    Color { .sbGreenStrong }
    private static var emerald:  Color { .sbEmeraldStrong }
    private static var neutral:  Color { .sbTextSecondary }

    /// Klemmt die User-Eingaben in eine konsistente Reihenfolge:
    /// `deepOverdraft < 0 < low < medium < veryGood`.
    /// Wenn der User unsinnige Werte einträgt (z.B. veryGood < medium), werden sie
    /// stillschweigend nach oben/unten korrigiert, statt Crashes oder leere Kategorien
    /// zuzulassen.
    static func normalizedThresholds(
        deepOverdraft: Int,
        low: Int,
        medium: Int,
        veryGood: Int
    ) -> BalanceSignalThresholds {
        let normalizedDeep = min(-1, deepOverdraft)             // strikt negativ
        let normalizedLow = max(0, low)
        let normalizedMedium = max(normalizedLow + 1, medium)
        let normalizedVeryGood = max(normalizedMedium + 1, veryGood)
        return BalanceSignalThresholds(
            deepOverdraftThreshold: Double(normalizedDeep),
            lowUpperBound: Double(normalizedLow),
            mediumUpperBound: Double(normalizedMedium),
            veryGoodLowerBound: Double(normalizedVeryGood)
        )
    }

    static func classify(balance: Double?, thresholds: BalanceSignalThresholds) -> BalanceSignalLevel {
        guard let balance else { return .unknown }
        if balance < thresholds.deepOverdraftThreshold { return .deepOverdraft }
        if balance < 0 { return .overdraft }
        if balance < thresholds.lowUpperBound { return .low }
        if balance <= thresholds.mediumUpperBound { return .medium }
        if balance <= thresholds.veryGoodLowerBound { return .good }
        return .veryGood
    }

    static func style(for level: BalanceSignalLevel) -> BalanceSignalStyle {
        switch level {
        case .deepOverdraft:
            return BalanceSignalStyle(
                amountColor: burgundy,
                statusColor: burgundy,
                gradientBaseColor: burgundy,
                statusTextDE: "Tief im Dispo",
                statusTextEN: "Deep overdraft"
            )
        case .overdraft:
            return BalanceSignalStyle(
                amountColor: red,
                statusColor: red,
                gradientBaseColor: red,
                statusTextDE: "Konto überzogen",
                statusTextEN: "Account overdrawn"
            )
        case .low:
            return BalanceSignalStyle(
                amountColor: orange,
                statusColor: orange,
                gradientBaseColor: orange,
                statusTextDE: "Niedriger Stand",
                statusTextEN: "Low balance"
            )
        case .medium:
            return BalanceSignalStyle(
                amountColor: yellow,
                statusColor: yellow,
                gradientBaseColor: yellow,
                statusTextDE: "Mittlerer Stand",
                statusTextEN: "Medium balance"
            )
        case .good:
            return BalanceSignalStyle(
                amountColor: green,
                statusColor: green,
                gradientBaseColor: green,
                statusTextDE: "Gutes Polster",
                statusTextEN: "Healthy buffer"
            )
        case .veryGood:
            return BalanceSignalStyle(
                amountColor: emerald,
                statusColor: emerald,
                gradientBaseColor: emerald,
                statusTextDE: "Sehr wohlhabend",
                statusTextEN: "Very wealthy"
            )
        case .unknown:
            return BalanceSignalStyle(
                amountColor: neutral,
                statusColor: neutral,
                gradientBaseColor: .clear,
                statusTextDE: "Kein Stand verfügbar",
                statusTextEN: "No balance available"
            )
        }
    }
}
