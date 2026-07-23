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

/// Temperatur-„Wash" nach Kontostand (Prototyp 4b/1c): 160°-Verlauf hinter dem
/// Header/Balance-Block. Geteilt von Flyout UND Umsatzlisten-Header, damit die
/// Farben nicht driften. 3 Zustände, gemappt aus 7 Signal-Leveln. Light-Mode =
/// exakte Prototyp-Hexes; Dark-Mode = dezente Hue-Tönung aus der Signal-Farbe.
enum BalanceWash {
    static func colors(level: BalanceSignalLevel, style: BalanceSignalStyle, dark: Bool)
        -> (top: Color, bottom: Color, balance: Color, detail: Color) {
        func hx(_ s: String) -> Color { Color(hex: s) ?? .gray }
        if dark {
            return (style.gradientBaseColor.opacity(0.20), style.gradientBaseColor.opacity(0.06),
                    style.amountColor, Color(NSColor.secondaryLabelColor))
        }
        switch level {
        case .deepOverdraft, .overdraft:
            return (hx("fbeeee"), hx("f5e2e2"), hx("b0242c"), hx("9a6060"))
        case .low, .medium:
            return (hx("f7f3e8"), hx("f1ece0"), hx("8a6d1e"), hx("8a7d5f"))
        case .good, .veryGood:
            return (hx("eef7f1"), hx("e3f1e9"), hx("177046"), hx("5f8974"))
        case .unknown:
            return (Color(white: 0.96), Color(white: 0.93),
                    Color(NSColor.secondaryLabelColor), Color(NSColor.secondaryLabelColor))
        }
    }
}

// MARK: - Merchant-Wash & Ausgaben-Heat (Händler-Slots)

/// Marken-„Wash" für Händler-/eBon-Slots (REWE/Amazon/dm) — analog zu
/// `BalanceWash`, aber aus der Markenfarbe gespeist statt aus einem Saldo-Level.
/// `top`/`bottom` = weiche Verlaufs-Stops (bottom dient als nahtlose Listenfarbe),
/// `accent` = kräftiger Markenton für die große Zahl. Auto light/dark.
enum MerchantWash {
    /// Markenfarbe je Quelle (ohne #). An EINER Stelle justierbar.
    static func brandHex(for source: SlotSource) -> String {
        switch source {
        case .rewe:   return "E30613"   // REWE-Rot
        case .amazon: return "FF9900"   // Amazon-Orange
        case .dm:     return "0A4EA2"   // dm-Blau
        case .yaxi:   return "8E8E93"   // Fallback (kein Receipt-Slot)
        }
    }

    /// Dynamische Karten-Farben (adaptieren automatisch an Light/Dark).
    static func colors(for source: SlotSource) -> (top: Color, bottom: Color, accent: Color) {
        let hex = brandHex(for: source)
        return (Color(nsColor: washNSColor(hex: hex, lightBlend: 0.16, darkBlend: 0.22)),
                Color(nsColor: washNSColor(hex: hex, lightBlend: 0.10, darkBlend: 0.10)),
                Color(nsColor: accentNSColor(hex: hex)))
    }

    /// Weicher Verlaufs-Stop: Basis-BG mit der Markenfarbe geblendet — gleiche
    /// Mathematik wie `BankTintProvider.softNSColor`.
    private static func washNSColor(hex: String, lightBlend: CGFloat, darkBlend: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let brand = AppTheme.color(from: hex, fallback: .controlBackgroundColor)
            let bg: NSColor = isDark
                ? NSColor(srgbRed: 0.090, green: 0.090, blue: 0.090, alpha: 1.0)
                : NSColor(srgbRed: 0.976, green: 0.976, blue: 0.976, alpha: 1.0)
            return bg.blended(withFraction: isDark ? darkBlend : lightBlend, of: brand) ?? brand
        }
    }

    /// Kräftiger Markenton für die große Zahl — Light abgedunkelt, Dark aufgehellt.
    private static func accentNSColor(hex: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let brand = AppTheme.color(from: hex, fallback: .labelColor)
            return isDark
                ? (brand.blended(withFraction: 0.25, of: .white) ?? brand)
                : (brand.blended(withFraction: 0.12, of: .black) ?? brand)
        }
    }
}

/// Ausgaben-„Temperatur" eines Händler-Slots relativ zum festen Monatsbudget.
enum SpendLevel: Equatable {
    case underBudget   // < 75 %
    case nearBudget    // 75 – <100 %
    case overBudget    // ≥ 100 %
    case noBudget      // kein Budget gesetzt → kein Heat
}

/// Analog zu `BalanceSignal`, aber für Händler-Ausgaben vs. Monatsbudget.
/// Reine Funktionen (testbar); Farben spiegeln die Money-Heat-Palette.
enum SpendSignal {
    static func classify(spentCents: Int, budgetCents: Int) -> SpendLevel {
        guard budgetCents > 0 else { return .noBudget }
        let ratio = Double(spentCents) / Double(budgetCents)
        if ratio < 0.75 { return .underBudget }
        if ratio < 1.0 { return .nearBudget }
        return .overBudget
    }

    /// Prozent des Budgets (gerundet). `nil` wenn kein Budget.
    static func percentOfBudget(spentCents: Int, budgetCents: Int) -> Int? {
        guard budgetCents > 0 else { return nil }
        return Int((Double(spentCents) / Double(budgetCents) * 100).rounded())
    }

    static func heatColor(_ level: SpendLevel) -> Color {
        switch level {
        case .underBudget: return dyn(light: "177046", dark: "67B487")   // grün
        case .nearBudget:  return dyn(light: "8a6d1e", dark: "E4BA78")   // amber
        case .overBudget:  return dyn(light: "b0242c", dark: "D77979")   // rot
        case .noBudget:    return Color(nsColor: .labelColor)
        }
    }

    /// Kompakte Budget-Pille — `nil` wenn kein Budget gesetzt.
    static func badge(spentCents: Int, budgetCents: Int, level: SpendLevel) -> String? {
        guard let pct = percentOfBudget(spentCents: spentCents, budgetCents: budgetCents) else { return nil }
        if level == .overBudget {
            let over = pct - 100
            return L10n.t("über Budget · +\(over) %", "over budget · +\(over)%")
        }
        return L10n.t("im Budget · \(pct) %", "on budget · \(pct)%")
    }

    private static func dyn(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return AppTheme.color(from: isDark ? dark : light, fallback: .labelColor)
        })
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

    /// Money-Mood-Emoticon pro Tier. Wird optional in der Menüleiste neben dem
    /// Bank-Icon angezeigt (Toggle `balanceMoodEmojiEnabled`).
    static func emoji(for level: BalanceSignalLevel) -> String? {
        switch level {
        case .deepOverdraft: return "💀"
        case .overdraft:     return "😟"
        case .low:           return "🥵"
        case .medium:        return "🙃"
        case .good:          return "🙂"
        case .veryGood:      return "😎"
        case .unknown:       return nil
        }
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
