import SwiftUI

enum BalanceSignalLevel {
    case overdraft
    case low
    case medium
    case good
    case unknown
}

struct BalanceSignalThresholds {
    let lowUpperBound: Double
    let mediumUpperBound: Double
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

enum BalanceSignal {
    // Color Harmony Palette — semantische Tokens, kein Hardcoded-Hex mehr.
    // Yellow gibt es in der neuen Palette nicht — "medium" verwendet Orange Mid.
    private static var red:    Color { .sbRedStrong }
    private static var orange: Color { .sbOrangeStrong }
    private static var yellow: Color { .sbOrangeMid }
    private static var green:  Color { .sbGreenStrong }
    private static var neutral: Color { .sbTextSecondary }

    static func normalizedThresholds(low: Int, medium: Int) -> BalanceSignalThresholds {
        let normalizedLow = max(0, low)
        let normalizedMedium = max(normalizedLow + 1, medium)
        return BalanceSignalThresholds(
            lowUpperBound: Double(normalizedLow),
            mediumUpperBound: Double(normalizedMedium)
        )
    }

    static func classify(balance: Double?, thresholds: BalanceSignalThresholds) -> BalanceSignalLevel {
        guard let balance else { return .unknown }
        if balance < 0 { return .overdraft }
        if balance < thresholds.lowUpperBound { return .low }
        if balance <= thresholds.mediumUpperBound { return .medium }
        return .good
    }

    static func style(for level: BalanceSignalLevel) -> BalanceSignalStyle {
        switch level {
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
