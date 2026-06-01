import SwiftUI
import AppKit

/// Auswahl-Dialog für den Banner-„Aufgerundeten Betrag zur Seite legen"-Button.
///
/// UX-Aufbau (top → bottom):
/// 1. Header — Icon + Title + ausführlicher Untertitel (was passiert nach „Jetzt sparen")
/// 2. Schrittweite — Segmented Picker (10ct/50ct/1€/2€/5€/10€), persistiert sofort
///    in BankSlotSettings; Beträge im Zeitraum-Grid recompute live.
/// 3. Zeitraum — 2×2-Grid mit Karten (Label oben, Betrag groß) und Highlight.
/// 4. Empfänger-Editor — Name + IBAN editierbar (Default aus Settings; User
///    kann für diese Auszahlung einen anderen Empfänger eingeben). IBAN
///    wird live über `TransferRequest.validateIban` geprüft.
/// 5. Action-Bar — Abbrechen (links), „Jetzt sparen — X,XX €" (rechts,
///    prominent, disabled bei 0 € oder ungültiger IBAN).
struct RoundupChoiceSheet: View {

    enum TimeRange: Int, CaseIterable {
        case today, yesterday, dayBeforeYesterday, monthToDate
    }

    let slotId: String
    let bankId: String
    @ObservedObject private var state = RoundupViewState.shared

    let onCancel: () -> Void
    /// `(amountCents, rangeLabel, recipientName, recipientIban)` — Caller baut den TransferRequest.
    let onTransfer: (Int, String, String, String) -> Void

    @State private var selectedRange: TimeRange = .today
    @State private var recipientName: String = ""
    @State private var recipientIban: String = ""
    @State private var didInitFromSettings: Bool = false

    // MARK: - Computed inputs

    private func cents(for r: TimeRange) -> Int {
        switch r {
        case .today: return state.todayPotCents
        case .yesterday: return state.yesterdayPotCents
        case .dayBeforeYesterday: return state.dayBeforeYesterdayPotCents
        case .monthToDate: return state.monthToDateCents
        }
    }

    private func label(for r: TimeRange) -> String {
        switch r {
        case .today: return L10n.t("Heute", "Today")
        case .yesterday: return L10n.t("Gestern", "Yesterday")
        case .dayBeforeYesterday: return L10n.t("Vorgestern", "Day before")
        case .monthToDate: return L10n.t("Diesen Monat", "This month")
        }
    }

    private var selectedCents: Int { cents(for: selectedRange) }
    private var selectedLabel: String { label(for: selectedRange) }

    private var trimmedName: String {
        recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var normalizedIban: String {
        TransferRequest.normalizeIban(recipientIban)
    }
    private var ibanIsValid: Bool {
        (try? TransferRequest.validateIban(normalizedIban)) != nil
    }
    private var canTransfer: Bool {
        selectedCents > 0 && !trimmedName.isEmpty && ibanIsValid
    }

    // MARK: - Formatter

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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            stepSection
            rangeSection
            recipientEditor
            Spacer(minLength: 0)
            actionBar
        }
        .padding(20)
        .frame(width: 460, height: 600)
        .background(Color.panelBackground)
        .onAppear {
            guard !didInitFromSettings else { return }
            didInitFromSettings = true
            let settings = BankSlotSettingsStore.load(slotId: slotId)
            recipientName = settings.savingsAccountName ?? ""
            recipientIban = settings.savingsAccountIban ?? ""
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.roundupAccent.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "centsign.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.roundupAccent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("Aufrunden", "Round-up"))
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.t(
                    "Wähle Schrittweite und Zeitraum. Nach Klick auf 'Jetzt sparen' öffnet sich das Überweisungsfenster mit Betrag und Empfänger vorausgefüllt — du bestätigst es wie immer manuell (PIN/SCA bleiben bei dir).",
                    "Pick step size and period. After clicking 'Save now' the transfer sheet opens with amount and recipient pre-filled — you confirm it manually as always (PIN/SCA stays with you)."
                ))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Step

    private var stepSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Schrittweite", "Step size"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Picker("", selection: Binding(
                get: { state.stepCents },
                set: { state.applyStepChange(slotId: slotId, bankId: bankId, stepCents: $0) }
            )) {
                ForEach(RoundupOverlay.stepOptions, id: \.cents) { option in
                    Text(option.label).tag(option.cents)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Time-Range Grid

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Zeitraum", "Period"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    rangeCard(range)
                }
            }
        }
    }

    private func rangeCard(_ range: TimeRange) -> some View {
        let selected = range == selectedRange
        let c = cents(for: range)
        let hasAmount = c > 0
        return Button(action: { selectedRange = range }) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label(for: range))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(selected ? Color.roundupAccent : .secondary)
                    Text(formatEuros(c))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(hasAmount ? .primary : Color(NSColor.tertiaryLabelColor))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color.roundupAccent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.roundupAccent.opacity(0.10) : Color.gray.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.roundupAccent : Color.gray.opacity(0.18),
                            lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recipient editor

    private var recipientEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Empfänger", "Recipient"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(spacing: 6) {
                TextField(L10n.t("Name (z.B. Tagesgeld DKB)", "Name (e.g. DKB Savings)"),
                          text: $recipientName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 3) {
                    TextField("DE...", text: Binding(
                        get: { recipientIban },
                        set: { recipientIban = TransferRequest.normalizeIban($0) }
                    ))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 12, design: .monospaced))

                    if !recipientIban.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: ibanIsValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            Text(ibanIsValid
                                ? L10n.t("IBAN gültig", "IBAN valid")
                                : L10n.t("IBAN ungültig — bitte prüfen", "Invalid IBAN — please check"))
                        }
                        .font(.system(size: 10))
                        .foregroundColor(ibanIsValid ? .green : .orange)
                    }
                }
            }

            Text(L10n.t(
                "Default aus den Slot-Einstellungen — du kannst hier für diese Überweisung einen anderen Empfänger eingeben.",
                "Default is taken from slot settings — you can enter a different recipient just for this transfer."
            ))
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(L10n.t("Abbrechen", "Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

            Spacer()

            Button(action: {
                onTransfer(selectedCents, selectedLabel, trimmedName, normalizedIban)
            }) {
                if selectedCents > 0 {
                    Text(L10n.t("Jetzt sparen · \(formatEuros(selectedCents))",
                                "Save now · \(formatEuros(selectedCents))"))
                        .frame(minWidth: 150)
                } else {
                    Text(L10n.t("Jetzt sparen", "Save now"))
                        .frame(minWidth: 150)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canTransfer)
            .help(canTransfer
                ? L10n.t("Öffnet das Überweisungsfenster mit Empfänger und Betrag vorbereitet.",
                         "Opens the transfer sheet with recipient and amount pre-filled.")
                : (selectedCents == 0
                    ? L10n.t("Wähle einen Zeitraum mit Betrag > 0.", "Pick a period with amount > 0.")
                    : (trimmedName.isEmpty
                        ? L10n.t("Empfänger-Name fehlt.", "Recipient name missing.")
                        : L10n.t("IBAN ist ungültig oder leer.", "IBAN is invalid or empty."))))
        }
    }
}
