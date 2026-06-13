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

    var body: some View {
        VStack(spacing: 8) {
            // Steuerzeile: „Aufrunden um" Steps · ¢-Toggle (Mode aus).
            // Konto-Picker liegt eine Zeile darüber (eigene Reihe), damit die Pills Platz haben.
            HStack(spacing: 10) {
                Text(L10n.t("Aufrunden um:", "Round up to:"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    stepPills.padding(.vertical, 1)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "centsign.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.roundupAccent)
                }
                .buttonStyle(.plain)
                .help(L10n.t("Sparmodus beenden", "Leave round-up mode"))
            }

            payoutButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.roundupPanelBackground)
        .overlay(
            Rectangle()
                .fill(Color.roundupAccent.opacity(0.25))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var payoutButton: some View {
        Button(action: openChoiceSheet) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(L10n.t("Aufgerundeten Betrag zur Seite legen",
                            "Set aside round-up amount"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.roundupAccent)
            )
            .foregroundColor(.white)
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
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : Color.roundupAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(selected ? Color.roundupAccent : Color.roundupAccent.opacity(0.10))
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
