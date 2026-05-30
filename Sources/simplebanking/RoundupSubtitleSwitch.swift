import SwiftUI

/// Subtitle-Toggle unter dem Kontostand im Aufrunden-Modus. Cycelt durch
/// vier Zeiträume — analog `BalanceSubtitleSwitch` für den Normal-Mode:
/// • `0` = Heute
/// • `1` = Gestern
/// • `2` = Vorgestern
/// • `3` = Diesen Monat
///
/// Style wird außen via `@Binding` gehalten (eigene AppStorage-Keys für
/// Flyout vs. Umsatzpanel), damit beide unabhängig wechseln können.
struct RoundupSubtitleSwitch: View {
    let todayCents: Int
    let yesterdayCents: Int
    let dayBeforeYesterdayCents: Int
    let monthToDateCents: Int
    @Binding var style: Int
    /// `true` rendert kompakter (kleinere Schrift, kürzere Labels) — z.B. im Flyout.
    var compact: Bool = false

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private func toggle() {
        style = (style + 1) % 4
    }

    private var currentLabel: String {
        switch style {
        case 1: return L10n.t("Gestern", "Yesterday")
        case 2: return L10n.t("Vorgestern", "Day before")
        case 3: return L10n.t("Diesen Monat", "This month")
        default: return L10n.t("Heute", "Today")
        }
    }

    var currentCentsValue: Int { currentCents }
    var currentLabelValue: String { currentLabel }

    private var nextLabel: String {
        switch (style + 1) % 4 {
        case 1: return L10n.t("Gestern", "Yesterday")
        case 2: return L10n.t("Vorgestern", "Day before")
        case 3: return L10n.t("Diesen Monat", "This month")
        default: return L10n.t("Heute", "Today")
        }
    }

    private var currentCents: Int {
        switch style {
        case 1: return yesterdayCents
        case 2: return dayBeforeYesterdayCents
        case 3: return monthToDateCents
        default: return todayCents
        }
    }

    private var currentIcon: String {
        switch style {
        case 1: return "clock.arrow.circlepath"
        case 2: return "clock.badge"
        case 3: return "calendar"
        default: return "sun.max.fill"
        }
    }

    private var formattedValue: String {
        let euros = Double(currentCents) / 100.0
        return (Self.formatter.string(from: NSNumber(value: euros)) ?? "0,00") + " €"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: currentIcon)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help(L10n.t(
                "Aktuell: \(currentLabel)\nKlick → \(nextLabel)",
                "Current: \(currentLabel)\nClick → \(nextLabel)"
            ))
            Text(L10n.t(
                "Aufgerundet (\(currentLabel)): \(formattedValue)",
                "Rounded up (\(currentLabel)): \(formattedValue)"
            ))
                .font(.system(size: compact ? 11 : 13))
                .foregroundColor(currentCents > 0 ? .primary : Color(NSColor.secondaryLabelColor))
                .lineLimit(1)
                .monospacedDigit()
        }
    }
}
