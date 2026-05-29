import SwiftUI
import AppKit

/// 3-Wege-Modal für den Tages-Spartopf: Verwerfen / Virtuell behalten /
/// Auf Sparkonto übertragen. Wird vom RoundupDayWatcher beim ersten App-Open
/// nach lokaler Mitternacht aufgerufen, oder manuell via Settings.
struct RoundupSheet: View {

    let slotId: String
    let potDate: String
    let pot: RoundupPot
    let savingsAccountName: String?
    let savingsAccountIban: String?

    /// Wird gerufen wenn der User „Verwerfen" oder „Virtuell behalten" wählt
    /// oder per Snooze schließt. Caller schließt das umgebende NSPanel.
    let onClose: () -> Void
    /// Wird gerufen wenn der User „Auf Sparkonto übertragen" wählt. Caller
    /// schließt das Sheet und öffnet TransferSheet mit dem Prefill.
    let onTransfer: (TransferRequest) -> Void

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    @State private var ibanInput: String = ""
    @State private var nameInput: String = ""
    @State private var showInlineIbanForm: Bool = false
    @State private var ibanError: String? = nil

    @ObservedObject private var bankingStore = MultibankingStore.shared

    private var slotDisplay: String {
        bankingStore.slots.first(where: { $0.id == slotId })?.displayName
            ?? L10n.t("Konto", "Account")
    }

    private var amountText: String {
        let euros = Double(pot.amountCents) / 100.0
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: euros)) ?? "0,00") + " €"
    }

    private var stepLabel: String {
        // Step-Cents werden im roundup_entries gespeichert — wir holen den ersten
        // Step aus dem Pot via Settings-Fallback. Für UI reicht der aktuelle Setting.
        let settings = BankSlotSettingsStore.load(slotId: slotId)
        let step = settings.roundupStepCents
        switch step {
        case 100:  return L10n.t("je 1 € aufgerundet", "rounded up to 1 €")
        case 200:  return L10n.t("je 2 € aufgerundet", "rounded up to 2 €")
        case 500:  return L10n.t("je 5 € aufgerundet", "rounded up to 5 €")
        case 1000: return L10n.t("je 10 € aufgerundet", "rounded up to 10 €")
        default:   return L10n.t("aufgerundet", "rounded up")
        }
    }

    private var dateDisplay: String {
        if let date = dateFormatter.date(from: potDate) {
            return displayFormatter.string(from: date)
        }
        return potDate
    }

    private var hasSavingsIban: Bool {
        if let iban = savingsAccountIban, !iban.isEmpty { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Aufrunden vom \(dateDisplay)", "Round-up from \(dateDisplay)"))
                    .font(ThemeFonts.body(size: 16, weight: .semibold))
                HStack(spacing: 6) {
                    Image(systemName: "centsign.circle.fill")
                        .foregroundColor(.secondary)
                    Text(slotDisplay)
                        .font(ThemeFonts.body(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)

            // Pot amount card
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("Heute aufgerundet", "Rounded up today"))
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
                Text(amountText)
                    .font(ThemeFonts.body(size: 32, weight: .bold))
                    .monospacedDigit()
                Text(L10n.t("\(pot.entryCount) Buchungen, \(stepLabel)",
                            "\(pot.entryCount) bookings, \(stepLabel)"))
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.settingsCard))

            // Inline IBAN form (only shown if user clicked transfer but no IBAN saved)
            if showInlineIbanForm {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("Sparkonto-IBAN fehlt — einmalig eintragen:",
                                "Savings IBAN missing — set it once:"))
                        .font(ThemeFonts.body(size: 12, weight: .medium))
                    TextField(L10n.t("Name (z.B. Tagesgeld DKB)", "Name (e.g. DKB Savings)"),
                              text: $nameInput)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    TextField("DE...", text: $ibanInput)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    if let err = ibanError {
                        Text(err)
                            .font(ThemeFonts.body(size: 11))
                            .foregroundColor(.orange)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.settingsCard.opacity(0.5)))
            }

            // Action buttons
            VStack(spacing: 8) {
                Text(L10n.t("Was möchtest du tun?", "What would you like to do?"))
                    .font(ThemeFonts.body(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: discard) {
                    HStack {
                        Image(systemName: "trash")
                        Text(L10n.t("Verwerfen", "Discard"))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: keepVirtual) {
                    HStack {
                        Image(systemName: "tray.full")
                        Text(L10n.t("Virtuell behalten", "Keep virtual"))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: handleTransfer) {
                    HStack {
                        Image(systemName: "arrow.up.right.square.fill")
                        Text(showInlineIbanForm
                             ? L10n.t("Speichern und auf Sparkonto übertragen", "Save and transfer to savings")
                             : L10n.t("Auf Sparkonto übertragen", "Transfer to savings"))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.accentColor)
            }

            Spacer(minLength: 0)

            // Footer: snooze
            HStack(spacing: 8) {
                Text(L10n.t("Später erinnern", "Remind later"))
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
                Menu(L10n.t("Auswählen", "Choose")) {
                    Button(L10n.t("1 Stunde", "1 hour")) { snooze(hours: 1) }
                    Button(L10n.t("24 Stunden", "24 hours")) { snooze(hours: 24) }
                    Button(L10n.t("Nie mehr heute", "Not again today")) { snoozeUntilTomorrow() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
        .background(Color.panelBackground)
    }

    // MARK: - Actions

    private func discard() {
        try? RoundupStore.resolve(slotId: slotId, potDate: potDate, status: .discarded)
        onClose()
    }

    private func keepVirtual() {
        try? RoundupStore.resolve(slotId: slotId, potDate: potDate, status: .keptVirtual)
        onClose()
    }

    private func handleTransfer() {
        // Falls IBAN noch nicht in Settings, Inline-Form aufklappen + speichern.
        if !hasSavingsIban && !showInlineIbanForm {
            ibanInput = ""
            nameInput = savingsAccountName ?? ""
            showInlineIbanForm = true
            ibanError = nil
            return
        }

        let nameToUse: String
        let ibanToUse: String

        if showInlineIbanForm {
            let trimmedName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedIban = TransferRequest.normalizeIban(ibanInput)
            do {
                try TransferRequest.validateIban(normalizedIban)
            } catch {
                ibanError = L10n.t("Ungültige IBAN — bitte prüfen.",
                                   "Invalid IBAN — please check.")
                return
            }
            guard !trimmedName.isEmpty else {
                ibanError = L10n.t("Bitte Sparkonto-Name angeben.",
                                   "Please enter savings account name.")
                return
            }
            // Persist in Settings für künftige Auszahlungen.
            var settings = BankSlotSettingsStore.load(slotId: slotId)
            settings.savingsAccountName = trimmedName
            settings.savingsAccountIban = normalizedIban
            BankSlotSettingsStore.save(settings, slotId: slotId)
            NotificationCenter.default.post(name: .slotSettingsChanged, object: nil)
            nameToUse = trimmedName
            ibanToUse = normalizedIban
        } else {
            nameToUse = savingsAccountName ?? L10n.t("Sparkonto", "Savings")
            ibanToUse = savingsAccountIban ?? ""
        }

        let amount = Decimal(pot.amountCents) / 100
        guard let request = try? TransferRequest(
            creditorName: nameToUse,
            creditorIban: ibanToUse,
            amountEUR: amount,
            remittance: L10n.t("Aufgerundet \(potDate)", "Round-up \(potDate)")
        ) else {
            ibanError = L10n.t("Konnte Überweisung nicht vorbereiten — IBAN oder Betrag prüfen.",
                               "Couldn't prepare transfer — check IBAN or amount.")
            return
        }

        try? RoundupStore.resolve(slotId: slotId, potDate: potDate, status: .transferred)
        onTransfer(request)
    }

    private func snooze(hours: Int) {
        let until = Date().addingTimeInterval(TimeInterval(hours * 3600))
        UserDefaults.standard.set(until, forKey: snoozeKey)
        onClose()
    }

    private func snoozeUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        UserDefaults.standard.set(tomorrow, forKey: snoozeKey)
        onClose()
    }

    private var snoozeKey: String {
        "simplebanking.roundupSnoozeUntil.\(slotId).\(potDate)"
    }
}
