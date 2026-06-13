import SwiftUI

// MARK: - QuickSendDrawerView
//
// Kompakter Schnellüberweisungs-Drawer, der unter der Flyout-Karte aufklappt.
// Reihe 1: Name + Betrag · Reihe 2: IBAN · Reihe 3: Betreff
// Reihe 4: bis zu 4 gepinnte Vorlagen + Senden.
//
// Bewusst eine Kurzform — die große `TransferSheet` (480 pt NSPanel) bleibt
// unberührt. Credentials/SCA werden vom Host (`BalanceBar.performQuickSend`)
// erledigt; diese View kennt nur `TransferRequest` + `TransferOutcome`.

struct QuickSendDrawerView: View {

    /// Gesamthöhe des Drawer-Blocks inkl. oberem Divider. Der Host (BalanceBar)
    /// addiert genau diesen Wert auf die Popover-/Overlay-Höhe.
    static let totalDrawerHeight: CGFloat = 168
    private static let contentHeight: CGFloat = 167

    /// Sendet die Überweisung. Rückgabe = Bank-Outcome. Wird vom Host gesetzt.
    var performSend: (@MainActor (TransferRequest) async -> TransferOutcome)? = nil
    /// Saldo + Dispo-Rahmen des aktiven Slots. Überweisungen darüber werden blockiert
    /// (dieselbe Hartgrenze wie in der großen `TransferSheet`). `nil` = unbekannt → keine Sperre.
    var availableLimit: Decimal? = nil
    /// Schließt den Drawer (Host fährt die Popover-Höhe zurück).
    var onClose: (() -> Void)? = nil
    /// „+“ im Vorlagen-Bereich → springt in die Einstellungen (Vorlagen-Editor).
    var onAddTemplate: (() -> Void)? = nil

    @ObservedObject private var favorites = QuickSendFavoritesStore.shared

    @State private var name: String = ""
    @State private var ibanText: String = ""
    @State private var amountInput: String = ""
    @State private var purpose: String = ""
    @State private var phase: Phase = .idle
    /// Der in der Confirm-Stufe geprüfte, fertig gebaute Request (rebuild-frei beim Senden).
    @State private var pendingRequest: TransferRequest? = nil

    /// Läuft gerade ein realer Versand (aus der Confirm-Stufe heraus)?
    @State private var isSending = false

    enum Phase: Equatable {
        case idle
        /// Zusammenfassung vor dem realen Versand: Name · gekürzte IBAN · Betrag.
        case confirm(amount: String, name: String, iban: String)
        case sent(amount: String, name: String)
        case failed(String)
    }

    // MARK: Derived

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ibanValid: Bool { QuickSendFormatting.isValidIban(ibanText) }
    private var amount: Decimal? { QuickSendFormatting.amountDecimal(amountInput) }
    /// `true` wenn der Betrag den verfügbaren Rahmen (Saldo+Dispo) übersteigt.
    private var amountExceedsLimit: Bool {
        guard let amount, let limit = availableLimit else { return false }
        return amount > limit
    }
    /// `true` wenn der Betrag die absolute Quick-Send-Obergrenze übersteigt. Große
    /// Eingaben werden NICHT mehr gekürzt (Wert-Verfälschung), sondern hier invalidiert.
    private var amountTooLarge: Bool {
        guard let amount else { return false }
        return amount > QuickSendFormatting.maxAmount
    }
    private var canSubmit: Bool {
        !trimmedName.isEmpty && ibanValid && (amount ?? 0) > 0 && !amountExceedsLimit && !amountTooLarge
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.sbBorder)
            Group {
                switch phase {
                case .confirm(let amt, let nm, let ib):
                    confirmRow(amount: amt, name: nm, iban: ib)
                case .sent(let amt, let nm):
                    sentRow(amount: amt, name: nm)
                case .failed(let msg):
                    failedRow(msg)
                default:
                    form
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(height: Self.contentHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.totalDrawerHeight)
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 7) {
            // Reihe 1: Name + Betrag
            HStack(spacing: 7) {
                TextField(L10n.t("Name", "Name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(fieldBackground())

                HStack(spacing: 4) {
                    TextField(L10n.t("Betrag", "Amount"), text: $amountInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .onChange(of: amountInput) { newValue in
                            let s = QuickSendFormatting.sanitizeAmountInput(newValue)
                            if s != newValue { amountInput = s }
                        }
                    Text("€")
                        .font(.system(size: 12.5))
                        .foregroundColor(.sbTextSecondary)
                }
                .padding(.horizontal, 9)
                .frame(width: 122, height: 30)
                .background(fieldBackground(border: (amountExceedsLimit || amountTooLarge) ? .sbRedStrong : .sbBorder))
                .help(amountTooLarge
                      ? L10n.t("Betrag zu groß (max. 99.999,99 €)", "Amount too large (max. €99,999.99)")
                      : (amountExceedsLimit
                         ? L10n.t("Betrag übersteigt den verfügbaren Rahmen", "Amount exceeds available limit")
                         : ""))
            }

            // Reihe 2: IBAN + grüner Haken
            HStack(spacing: 8) {
                TextField(L10n.t("IBAN", "IBAN"), text: $ibanText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .onChange(of: ibanText) { newValue in
                        let grouped = QuickSendFormatting.groupIban(newValue)
                        if grouped != newValue { ibanText = grouped }
                    }
                if ibanValid {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.sbGreenStrong)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(fieldBackground(border: ibanValid ? .sbGreenStrong : .sbBorder))

            // Reihe 3: Betreff
            TextField(L10n.t("Betreff", "Reference"), text: $purpose)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .background(fieldBackground())

            // Reihe 4: Vorlagen + Senden
            HStack(spacing: 6) {
                if favorites.items.isEmpty {
                    // Leerzustand: zwei inaktive Platzhalter + „+“ zum Anlegen.
                    inactiveTemplate
                    inactiveTemplate
                    addTemplateButton
                } else {
                    ForEach(favorites.items) { fav in
                        Button { apply(fav) } label: {
                            Text(fav.emoji)
                                .font(.system(size: 15))
                                .frame(width: 30, height: 30)
                                .background(fieldBackground())
                        }
                        .buttonStyle(.plain)
                        .help(fav.name)
                        .contextMenu {
                            Button(role: .destructive) {
                                favorites.remove(id: fav.id)
                            } label: {
                                Label(L10n.t("Vorlage entfernen", "Remove template"), systemImage: "trash")
                            }
                        }
                    }
                    if favorites.canAddMore { addTemplateButton }
                }
                Spacer(minLength: 0)
                sendButton
            }
        }
    }

    /// Inaktiver Emoji-Platzhalter (Leerzustand „noch keine Vorlage").
    private var inactiveTemplate: some View {
        Image(systemName: "face.smiling")
            .font(.system(size: 14))
            .foregroundColor(Color.sbTextSecondary.opacity(0.35))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.sbSurfaceSoft)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.sbBorder, lineWidth: 1))
            )
    }

    /// „+“ → öffnet die Einstellungen am Vorlagen-Editor.
    private var addTemplateButton: some View {
        Button { onAddTemplate?() } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.sbTextSecondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundColor(.sbBorder)
                )
        }
        .buttonStyle(.plain)
        .help(L10n.t("Vorlage in den Einstellungen anlegen", "Create template in Settings"))
    }

    private var sendButton: some View {
        // Führt NICHT direkt zum Versand, sondern zur Bestätigungs-Stufe (`review`).
        Button { review() } label: {
            HStack(spacing: 5) {
                Text(L10n.t("Weiter", "Next"))
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(canSubmit ? Color.sbRedStrong : Color.sbSurfaceSoft)
            )
            .foregroundColor(canSubmit ? .white : .sbTextSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    // MARK: Confirm-Stufe

    private func confirmRow(amount: String, name: String, iban: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.t("Wirklich senden?", "Send for real?"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.sbTextPrimary)
            VStack(spacing: 5) {
                confirmLine(label: L10n.t("An", "To"), value: name)
                confirmLine(label: "IBAN", value: iban, mono: true)
                confirmLine(label: L10n.t("Betrag", "Amount"), value: amount, strong: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(fieldBackground())
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { phase = .idle } label: {
                    Text(L10n.t("Zurück", "Back"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(height: 30).padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 7).fill(Color.sbSurfaceSoft)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.sbBorder, lineWidth: 1))
                        )
                        .foregroundColor(.sbTextPrimary)
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                Spacer(minLength: 0)
                Button { performConfirmedSend() } label: {
                    HStack(spacing: 5) {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .semibold))
                        }
                        Text(L10n.t("Jetzt senden", "Send now")).font(.system(size: 12, weight: .semibold))
                    }
                    .frame(height: 30).padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.sbRedStrong))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
        }
    }

    private func confirmLine(label: String, value: String, mono: Bool = false, strong: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundColor(.sbTextSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: strong ? 13 : 12,
                              weight: strong ? .bold : .medium,
                              design: mono ? .monospaced : .default))
                .foregroundColor(.sbTextPrimary)
                .lineLimit(1)
        }
    }

    // MARK: Result states

    private func sentRow(amount: String, name: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.sbGreenStrong.opacity(0.15)).frame(width: 30, height: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.sbGreenStrong)
            }
            (Text(amount).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
             + Text(L10n.t(" an \(name) gesendet", " sent to \(name)")).font(.system(size: 12.5)))
                .foregroundColor(.sbTextPrimary)
            Spacer(minLength: 0)
        }
    }

    private func failedRow(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.sbRedStrong.opacity(0.15)).frame(width: 30, height: 30)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.sbRedStrong)
                }
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.sbTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button { phase = .idle } label: {
                Text(L10n.t("Zurück", "Back"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.sbBlueStrong)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Helpers

    private func fieldBackground(border: Color = .sbBorder) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.sbSurfaceSoft)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(border, lineWidth: 1))
    }

    private func apply(_ fav: QuickSendFavorite) {
        name = fav.name
        ibanText = QuickSendFormatting.groupIban(fav.iban)
        amountInput = fav.amount
        purpose = fav.purpose
    }

    /// Schritt 1: Eingabe validieren + in die Bestätigungs-Stufe wechseln (KEIN Versand).
    private func review() {
        guard canSubmit, let amt = amount else { return }
        let request: TransferRequest
        do {
            request = try TransferRequest(
                creditorName: trimmedName,
                creditorIban: TransferRequest.normalizeIban(ibanText),
                amountEUR: amt,
                remittance: purpose.isEmpty ? nil : purpose
            )
        } catch {
            phase = .failed((error as? TransferRequestError)?.localizedHint ?? error.localizedDescription)
            return
        }
        pendingRequest = request
        phase = .confirm(
            amount: QuickSendFormatting.displayEUR(amt),
            name: trimmedName,
            iban: QuickSendFormatting.maskedIban(ibanText)
        )
    }

    /// Schritt 2: erst hier wird real überwiesen — ausgelöst durch „Jetzt senden".
    private func performConfirmedSend() {
        guard let request = pendingRequest, !isSending else { return }
        let amountDisplay = QuickSendFormatting.displayEUR(request.amountEUR)
        let recipient = request.creditorName
        isSending = true
        Task { @MainActor in
            let outcome = await performSend?(request)
                ?? TransferOutcome(ok: false, scaRequired: false, error: "no-handler",
                                   userMessage: nil, mayHaveBeenExecuted: false)
            isSending = false
            if outcome.ok {
                phase = .sent(amount: amountDisplay, name: recipient)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                onClose?()
            } else if outcome.mayHaveBeenExecuted {
                phase = .failed(outcome.userMessage
                                ?? L10n.t("Status unklar — bitte Umsätze prüfen.",
                                          "Status unclear — please check transactions."))
            } else {
                phase = .failed(outcome.userMessage ?? outcome.error
                                ?? L10n.t("Senden fehlgeschlagen.", "Send failed."))
            }
        }
    }
}
