import SwiftUI

/// Motivational Hero-Card im Aufrunden-Modus. Ersetzt im aktivierten Mode
/// die Bank-Header + Kontostand-Card in BalanceBar-Flyout und Umsatzpanel-
/// Header. Botschaft: was du gerade sparst, nicht was du auf dem Konto hast.
///
/// Layout (top → bottom):
///   ▸ Centsign-Icon prominent (Mint-Akzent)
///   ▸ Hero-Zahl „+ X,XX €" — monthToDate in Mint
///   ▸ Eyebrow „diesen Monat zur Seite gelegt"
///   ▸ Sub-Info „Heute +X,XX € · Tag N in Folge"
///
/// `compact: true` für den Flyout (kleinere Schrift, schmaleres Padding),
/// `compact: false` für den großen Panel-Header.
struct RoundupSavingsCard: View {
    var compact: Bool = false
    @ObservedObject private var state = RoundupViewState.shared

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private func formatEuros(_ cents: Int) -> String {
        let euros = Double(cents) / 100.0
        return (Self.formatter.string(from: NSNumber(value: euros)) ?? "0,00") + " €"
    }

    private var iconSize: CGFloat { compact ? 22 : 28 }
    private var heroFontSize: CGFloat { compact ? 28 : 34 }
    private var eyebrowFontSize: CGFloat { compact ? 10 : 11 }
    private var subFontSize: CGFloat { compact ? 11 : 12 }
    private var verticalPadding: CGFloat { compact ? 14 : 18 }

    private var streakLabel: String {
        if state.streakDays <= 0 {
            return L10n.t("Noch kein Streak", "No streak yet")
        }
        return L10n.t("Tag \(state.streakDays) in Folge", "Day \(state.streakDays) streak")
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "eurosign.circle.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(Color.roundupAccent)
                .padding(.bottom, 2)

            Text("+ \(formatEuros(state.monthToDateCents))")
                .font(.system(size: heroFontSize, weight: .bold, design: .rounded))
                .foregroundColor(Color.roundupAccent)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(L10n.t("hättest Du diesen Monat durch Aufrunden zur Seite legen können",
                        "you could have set this aside through round-up this month"))
                .font(.system(size: eyebrowFontSize))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            HStack(spacing: 6) {
                Text(L10n.t("Heute +\(formatEuros(state.todayPotCents))",
                            "Today +\(formatEuros(state.todayPotCents))"))
                if state.streakDays > 0 {
                    Text("·").foregroundColor(.secondary.opacity(0.5))
                    Text(streakLabel)
                }
            }
            .font(.system(size: subFontSize))
            .foregroundColor(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.roundupPanelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.roundupAccent.opacity(0.30), lineWidth: 1)
        )
    }
}
