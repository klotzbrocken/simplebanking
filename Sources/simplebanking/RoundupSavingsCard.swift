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

    // Bei aktivem Theme trägt die Karte die Theme-Fläche/-Schrift; BTX bekommt statt
    // Mint + rundem Euro-Symbol die grüne Leitfarbe und einen Mosaik-Block.
    private var themed: Bool { !ThemeManager.shared.currentTheme.isDefault }
    private var heroColor: Color { themed ? .themedIncome : Color.roundupAccent }
    private var eyebrowColor: Color { themed ? Color.themedInk.opacity(0.75) : .secondary }

    var body: some View {
        VStack(spacing: 6) {
            if themed && !ThemeChrome.glyphControls {
                BTXMosaicIcon(category: .sparen, side: iconSize)
                    .padding(.bottom, 2)
            } else {
                Image(systemName: "eurosign.circle.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(Color.roundupAccent)
                    .padding(.bottom, 2)
            }

            Text("+ \(formatEuros(state.monthToDateCents))")
                .font(themed ? ThemeFonts.flyoutHeading(size: heroFontSize, weight: .bold)
                             : .system(size: heroFontSize, weight: .bold, design: .rounded))
                .foregroundColor(heroColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(L10n.t("hättest Du diesen Monat durch Aufrunden zur Seite legen können",
                        "you could have set this aside through round-up this month"))
                .font(themed ? ThemeFonts.flyoutBody(size: eyebrowFontSize + 3) : .system(size: eyebrowFontSize))
                .textCase(themed ? .uppercase : nil)
                .foregroundColor(eyebrowColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            HStack(spacing: 6) {
                Text(L10n.t("Heute +\(formatEuros(state.todayPotCents))",
                            "Today +\(formatEuros(state.todayPotCents))"))
                if state.streakDays > 0 {
                    Text("·").foregroundColor(eyebrowColor.opacity(0.6))
                    Text(streakLabel)
                }
            }
            .font(themed ? ThemeFonts.flyoutBody(size: subFontSize + 3) : .system(size: subFontSize))
            .textCase(themed ? .uppercase : nil)
            .foregroundColor(eyebrowColor)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: themed ? 0 : 12, style: .continuous)
                .fill(themed ? Color.themedSurface : Color.roundupPanelBackground)
        )
    }
}
