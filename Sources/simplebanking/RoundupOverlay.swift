import SwiftUI

/// Sticky-Banner oben am TransactionsPanel im Aufrunden-Modus.
/// Zeigt den aktiven Mode mit Step-Picker inline + Direkt-Übertrag-Button,
/// Schnell-Off (✕). Mint/Sage-Tönung als Mode-Indikator. Die heutige Pot-
/// Summe steht im BalanceBar-Subtitle — hier nicht redundant wiederholt.
struct RoundupOverlay: View {

    let slotId: String
    let bankId: String
    @ObservedObject private var state = RoundupViewState.shared

    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "centsign.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.roundupAccent)
                Text(L10n.t("Aufrunden aktiv", "Round-up active"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                stepPicker
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("Aufrunden-Ansicht schließen", "Close round-up view"))
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
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(L10n.t("Jetzt sparen — Betrag wählen",
                            "Save now — choose amount"))
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.roundupAccent.opacity(0.18))
            )
            .foregroundColor(Color.roundupAccent)
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

    private var stepPicker: some View {
        Picker("", selection: Binding(
            get: { state.stepCents },
            set: { newValue in
                state.applyStepChange(slotId: slotId, bankId: bankId, stepCents: newValue)
            }
        )) {
            Text("1 €").tag(100)
            Text("2 €").tag(200)
            Text("5 €").tag(500)
            Text("10 €").tag(1000)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
    }

    private func formatEuros(_ cents: Int) -> String {
        let euros = Double(cents) / 100.0
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: euros)) ?? "0,00") + " €"
    }
}
