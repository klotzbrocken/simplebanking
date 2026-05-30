import SwiftUI
import AppKit

/// Auswahl-Dialog für den Banner-„Jetzt sparen"-Button.
///
/// UX-Aufbau (top → bottom):
/// 1. Header — Icon + Title + Untertitel
/// 2. Schrittweite — Segmented Picker (1/2/5/10 €), persistiert sofort in
///    BankSlotSettings; Beträge im Zeitraum-Grid recompute live.
/// 3. Zeitraum — 2×2-Grid mit Karten (Label oben, Betrag groß) und
///    Highlight-State für die Auswahl. Karten mit 0 € bleiben klickbar,
///    aber visuell zurückgenommen.
/// 4. Empfänger-Vorschau — kompakte Zeile mit Name + maskierter IBAN
///    (oder Hinweis wenn Settings unvollständig).
/// 5. Action-Bar — Abbrechen (links), „Jetzt sparen — X,XX €" (rechts,
///    prominent, disabled bei 0 € oder fehlender IBAN).
struct RoundupChoiceSheet: View {

    enum TimeRange: Int, CaseIterable {
        case today, yesterday, dayBeforeYesterday, monthToDate
    }

    let slotId: String
    let bankId: String
    @ObservedObject private var state = RoundupViewState.shared

    let onCancel: () -> Void
    /// `(amountCents, rangeLabel)` — Caller baut den TransferRequest.
    let onTransfer: (Int, String) -> Void

    @State private var selectedRange: TimeRange = .today

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

    private var savingsName: String {
        BankSlotSettingsStore.load(slotId: slotId).savingsAccountName ?? L10n.t("Sparkonto", "Savings")
    }
    private var savingsIban: String {
        BankSlotSettingsStore.load(slotId: slotId).savingsAccountIban ?? ""
    }

    private var maskedIban: String {
        let iban = savingsIban
        guard iban.count > 12 else { return iban }
        return "\(iban.prefix(8))…\(iban.suffix(4))"
    }

    private var canTransfer: Bool {
        selectedCents > 0 && !savingsIban.isEmpty
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
        VStack(alignment: .leading, spacing: 18) {
            header
            stepSection
            rangeSection
            recipientPreview
            Spacer(minLength: 0)
            actionBar
        }
        .padding(20)
        .frame(width: 440, height: 530)
        .background(Color.panelBackground)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Aufrunden", "Round-up"))
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.t("Wähle Schrittweite und Zeitraum, dann übertrage.",
                            "Pick step size and period, then transfer."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
                Text("1 €").tag(100)
                Text("2 €").tag(200)
                Text("5 €").tag(500)
                Text("10 €").tag(1000)
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

    // MARK: - Recipient preview

    private var recipientPreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Empfänger", "Recipient"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                if savingsIban.isEmpty {
                    Text(L10n.t("Erst Sparkonto in Einstellungen hinterlegen",
                                "First add savings account in Settings"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                } else {
                    Text("\(savingsName) · \(maskedIban)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.06))
        )
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(L10n.t("Abbrechen", "Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

            Spacer()

            Button(action: { onTransfer(selectedCents, selectedLabel) }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square.fill")
                    if selectedCents > 0 {
                        Text(L10n.t("Jetzt sparen · \(formatEuros(selectedCents))",
                                    "Save now · \(formatEuros(selectedCents))"))
                    } else {
                        Text(L10n.t("Jetzt sparen", "Save now"))
                    }
                }
                .frame(minWidth: 150)
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
                    : L10n.t("Hinterlege erst eine Sparkonto-IBAN in den Einstellungen.",
                             "First set the savings IBAN in Settings.")))
        }
    }
}
