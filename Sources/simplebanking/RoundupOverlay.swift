import SwiftUI

/// Sticky-Banner oben am TransactionsPanel im Aufrunden-Modus.
/// Zeigt den aktiven Mode mit Step-Pills inline + Direkt-Übertrag-Button.
/// Mint/Sage-Tönung als Mode-Indikator. Schließen über den ¢-Toggle im
/// Filter-Header oder per Klick auf die aktive Step-Pile (Toggle).
struct RoundupOverlay: View {

    let slotId: String
    let bankId: String
    @ObservedObject private var state = RoundupViewState.shared

    let onClose: () -> Void

    /// Step-Optionen — von subtil (10 ct = 1. Nachkommastelle) bis aggressiv
    /// (10 € = Zehner-Sprung). Default 1 € liegt in der Mitte und ist
    /// Industry-Standard (Bank of America „Keep the Change", Acorns).
    static let stepOptions: [(label: String, cents: Int)] = [
        ("10 ct", 10),
        ("50 ct", 50),
        ("1 €",   100),
        ("2 €",   200),
        ("5 €",   500),
        ("10 €",  1000)
    ]

    /// Nur Lo-Fi (BTX): Fläche/Schrift/Blöcke statt Mint-Pillen — Farb-Themes
    /// behalten den Mint-Look.
    private var themed: Bool { !ThemeManager.shared.currentTheme.isDefault }
    private var lofi: Bool { themed && ThemeChrome.lofi }

    var body: some View {
        VStack(spacing: 8) {
            // Label + ¢-Toggle (Mode aus) in einer Zeile; die Step-Pills darunter in
            // EIGENER voller Zeile — sonst wird im schmalen Fenster die 5€-Pille beschnitten.
            HStack(spacing: 10) {
                Text(L10n.t("Aufrunden um:", "Round up to:"))
                    .font(ThemeFonts.rowBody(size: 12, weight: .semibold, lofiSize: 15))
                    .textCase(ThemeChrome.textCase)
                    .foregroundColor(themed ? .themedInk : .primary)
                    .fixedSize()
                Spacer(minLength: 4)
                Button(action: onClose) {
                    if lofi {
                        BTXTextControl(text: L10n.t("Aus", "Off"), active: true)
                    } else {
                        Image(systemName: "centsign.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color.roundupAccent)
                    }
                }
                .buttonStyle(.plain)
                .help(L10n.t("Sparmodus beenden", "Leave round-up mode"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                stepPills.padding(.vertical, 1)
            }

            payoutButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(themed ? Color.themedSurfaceOrClear : Color.roundupPanelBackground)
        .overlay(
            Rectangle()
                .fill(themed ? Color.themedInk.opacity(0.4) : Color.roundupAccent.opacity(0.25))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var payoutButton: some View {
        Button(action: openChoiceSheet) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if ThemeChrome.glyphControls {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(L10n.t("Aufgerundeten Betrag zur Seite legen",
                            "Set aside round-up amount"))
                    .font(ThemeFonts.rowBody(size: 13, weight: .semibold, lofiSize: 14))
                    .textCase(ThemeChrome.textCase)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(8))
                    .fill(themed ? Color.themedAccent : Color.roundupAccent)
            )
            .foregroundColor(themed ? Color.themedSurface : .white)
        }
        .buttonStyle(.plain)
        .help(L10n.t("Öffnet den Auswahl-Dialog (Heute / Gestern / Vorgestern / Monat).",
                     "Opens the picker (Today / Yesterday / Day before / Month)."))
    }

    private func openChoiceSheet() {
        NotificationCenter.default.post(
            name: Notification.Name("simplebanking.roundupOpenChoiceSheet"),
            object: nil,
            userInfo: ["slotId": slotId]
        )
    }

    /// Custom HStack mit Toggle-Verhalten: Klick auf inaktive Pile aktiviert sie,
    /// Klick auf bereits aktive Pile deaktiviert den ganzen Aufrunden-Mode.
    private var stepPills: some View {
        HStack(spacing: 4) {
            ForEach(Self.stepOptions, id: \.cents) { option in
                stepPill(label: option.label, cents: option.cents)
            }
        }
    }

    private func stepPill(label: String, cents: Int) -> some View {
        let selected = state.stepCents == cents
        return Button(action: {
            if selected {
                // Toggle: aktive Pile → Mode deaktivieren.
                onClose()
            } else {
                state.applyStepChange(slotId: slotId, bankId: bankId, stepCents: cents)
            }
        }) {
            // BTX: eckige Blöcke mit Tintenrahmen statt Mint-Kapseln; aktiv = gefüllt
            // in Leitfarbe (wie die Filter-Blöcke der Umsatzliste).
            Text(label)
                .font(ThemeFonts.rowBody(size: 11, weight: selected ? .semibold : .regular, lofiSize: 13))
                .textCase(ThemeChrome.textCase)
                .foregroundColor(lofi
                                 ? (selected ? Color.themedSurface : Color.themedInk.opacity(0.85))
                                 : (selected ? .white : Color.roundupAccent))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(999))
                        .fill(lofi
                              ? (selected ? Color.themedAccent : Color.clear)
                              : (selected ? Color.roundupAccent : Color.roundupAccent.opacity(0.10)))
                        .overlay(
                            (lofi && !selected)
                            ? RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(999))
                                .stroke(Color.themedInk.opacity(0.5), lineWidth: 1)
                            : nil
                        )
                )
        }
        .buttonStyle(.plain)
        .help(selected
            ? L10n.t("Klick: Aufrunden-Modus beenden",
                     "Click: leave round-up mode")
            : L10n.t("Schrittweite \(label) wählen",
                     "Set step \(label)"))
    }
}
