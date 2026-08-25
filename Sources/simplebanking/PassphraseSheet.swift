import SwiftUI

// MARK: - Passphrase-Eingabe
//
// Ersetzt die vorherige Lösung mit `NSAlert` und einem eingehängten Textfeld: In einem
// `NSStackView` ohne Breitenvorgabe fallen die Felder auf ihre Eigengröße zusammen und
// sind praktisch unsichtbar. Gemeldet am 25.08.2026 — die zweite Eingabe war zwar da,
// aber nicht zu sehen.

struct PassphraseSheet: View {

    enum Zweck: Identifiable {
        case erstellen
        case einspielen(merkhilfe: String?)

        var id: String {
            switch self {
            case .erstellen: return "erstellen"
            case .einspielen: return "einspielen"
            }
        }
    }

    let zweck: Zweck
    /// Passphrase und (nur beim Erstellen) die Merkhilfe.
    let fertig: (String, String?) -> Void
    let abbrechen: () -> Void

    @State private var passphrase = ""
    @State private var wiederholung = ""
    @State private var merkhilfe = ""
    @FocusState private var fokusAufErstem: Bool

    private var erstellt: Bool { if case .erstellen = zweck { return true }; return false }
    private var befund: PassphraseStaerke.Befund { PassphraseStaerke.pruefen(passphrase) }

    private var stimmenUeberein: Bool { !erstellt || passphrase == wiederholung }
    private var abschickbar: Bool {
        guard !passphrase.isEmpty else { return false }
        guard erstellt else { return true }
        return stimmenUeberein && befund.stufe > .zuKurz
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(erstellt
                 ? L10n.t("Passphrase für die Sicherung", "Passphrase for the backup")
                 : L10n.t("Passphrase der Sicherung", "Backup passphrase"))
                .font(.system(size: 15, weight: .semibold))

            if erstellt {
                Text(L10n.t(
                    "Ohne diese Passphrase lässt sich die Sicherung nicht wiederherstellen — auch von dir nicht. Es gibt keine Hintertür.",
                    "Without this passphrase the backup cannot be restored — not even by you. There is no back door."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .einspielen(let hilfe) = zweck, let hilfe {
                // Die Merkhilfe steht unverschlüsselt im Dateikopf — genau deshalb kann
                // sie hier stehen, bevor irgendetwas eingegeben wurde.
                Label(hilfe, systemImage: "lightbulb")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10)))
            }

            SecureField(L10n.t("Passphrase", "Passphrase"), text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .focused($fokusAufErstem)

            if erstellt {
                SecureField(L10n.t("Passphrase wiederholen", "Repeat passphrase"), text: $wiederholung)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)

                staerkeAnzeige

                if !wiederholung.isEmpty && !stimmenUeberein {
                    Label(L10n.t("Die beiden Eingaben stimmen nicht überein.",
                                 "The two entries do not match."),
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(.sbRedStrong)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Merkhilfe (optional)", "Memory aid (optional)"))
                        .font(.system(size: 11, weight: .medium))
                    TextField(L10n.t("z. B. „wie beim alten Router“", "e.g. „same as the old router“"),
                              text: $merkhilfe)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                    Text(L10n.t(
                        "Wird beim Einspielen angezeigt und ist deshalb NICHT verschlüsselt — wer die Datei hat, liest sie mit. Also ein Hinweis, keine halbe Passphrase.",
                        "Shown when restoring and therefore NOT encrypted — anyone holding the file can read it. So make it a hint, not half the passphrase."))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(L10n.t("Abbrechen", "Cancel"), action: abbrechen)
                    .keyboardShortcut(.cancelAction)
                Button(erstellt ? L10n.t("Weiter", "Continue") : L10n.t("Einspielen", "Restore")) {
                    fertig(passphrase, merkhilfe.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!abschickbar)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { fokusAufErstem = true }
    }

    /// Vier Balken statt einer Prozentzahl — siehe `PassphraseStaerke`.
    private var staerkeAnzeige: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < befund.stufe.rawValue ? farbe : Color.secondary.opacity(0.18))
                        .frame(height: 4)
                }
            }
            .frame(width: 360)
            Text(befund.text)
                .font(.system(size: 10.5))
                .foregroundColor(befund.stufe <= .schwach ? .sbRedStrong : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var farbe: Color {
        switch befund.stufe {
        case .zuKurz, .schwach: return .sbRedStrong
        case .brauchbar:        return .sbOrangeStrong
        case .gut:              return .sbGreenStrong
        }
    }
}
