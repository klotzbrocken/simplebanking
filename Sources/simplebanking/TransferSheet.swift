import SwiftUI
import AppKit

// MARK: - TransferSheet
//
// SwiftUI-Sheet für „Geld senden". Single-Input-Eingabe (Name oder IBAN),
// Live-Autocomplete aus Buchungs-Historie, Betrag- und Verwendungszweck-
// Felder, Confirm-Dialog vor dem eigentlichen Senden.
//
// Wird vom BalanceBar-Menü-Eintrag aufgerufen, NACHDEM die Lizenz-Prüfung
// (LicenseManager) erfolgreich war. Das Sheet selbst kennt die Lizenz-
// Logik nicht.

@MainActor
struct TransferSheet: View {
    /// Closure liefert das Master-Passwort (oder nil bei User-Cancel).
    /// Wird via BiometricStore-Cache erst stillschweigend versucht; nur bei
    /// Cache-Miss erscheint das modale Prompt.
    let requestMasterPassword: () -> String?
    let onClose: () -> Void

    @AppStorage("demoMode") private var demoMode: Bool = false

    // MARK: - Form state
    @State private var query: String = ""
    @State private var selectedCandidate: TransferRecipientCandidate? = nil
    @State private var rawIban: String = ""        // wenn User direkt IBAN tippt
    @State private var creditorName: String = ""
    @State private var amountInput: String = ""
    @State private var remittance: String = ""

    // MARK: - Async state
    @State private var recipients: [TransferRecipientCandidate] = []
    @State private var isSending: Bool = false
    @State private var phase: Phase = .idle
    @State private var showConfirm: Bool = false
    @State private var validationHint: String? = nil

    enum Phase: Equatable {
        case idle
        case sending
        case success
        case mayHaveBeenExecuted(String)
        case failed(String)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            switch phase {
            case .idle, .sending:
                form
                    .disabled(isSending)
            case .success:
                successView
            case .mayHaveBeenExecuted(let detail):
                mayHaveBeenExecutedView(detail)
            case .failed(let message):
                errorView(message)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .task { await loadRecipients() }
        .alert(isPresented: $showConfirm) {
            confirmAlert
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.right.square.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Geld senden", "Send money"))
                    .font(.system(size: 16, weight: .semibold))
                Text(senderInfo)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if demoMode {
                Text("🎭 Demo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
    }

    private var senderInfo: String {
        let slot = MultibankingStore.shared.activeSlot
        let name = slot?.nickname?.nilIfEmpty
            ?? slot?.displayName.nilIfEmpty
            ?? L10n.t("Aktives Konto", "Active account")
        let ibanShort = (slot?.iban).flatMap { iban -> String? in
            guard iban.count >= 8 else { return nil }
            return "\(iban.prefix(4))…\(iban.suffix(4))"
        } ?? ""
        if ibanShort.isEmpty {
            return L10n.t("Senden von: \(name)", "Sending from: \(name)")
        }
        return L10n.t("Senden von: \(name) · \(ibanShort)",
                      "Sending from: \(name) · \(ibanShort)")
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Single-Input Empfänger / IBAN
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Empfänger oder IBAN", "Recipient or IBAN"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(L10n.t("z.B. \"Max\" oder \"DE89…\"", "e.g. \"Max\" or \"DE89…\""),
                          text: $query, onEditingChanged: { _ in handleQueryChange() },
                          onCommit: { handleQueryCommit() })
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _ in handleQueryChange() }
            }

            // 2. Empfänger-Vorschläge (Top 5 nach Filter, sonst kein Frame)
            recipientList

            // 3. Betrag
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Betrag", "Amount"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    TextField(L10n.t("z.B. 49,99", "e.g. 49.99"), text: $amountInput)
                        .textFieldStyle(.roundedBorder)
                    Text("€").foregroundColor(.secondary)
                }
            }

            // 4. Verwendungszweck
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Verwendungszweck (optional)", "Purpose (optional)"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(L10n.t("z.B. Miete Mai", "e.g. May rent"), text: $remittance)
                    .textFieldStyle(.roundedBorder)
            }

            if let hint = validationHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(.sbRedStrong)
            }
        }
    }

    @ViewBuilder
    private var recipientList: some View {
        let filtered = TransferRecipientStore.filter(recipients, query: query).prefix(5)
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(filtered.indices, id: \.self) { i in
                    let c = filtered[i]
                    Button {
                        applyCandidate(c)
                    } label: {
                        recipientRow(c)
                    }
                    .buttonStyle(.plain)
                    if i < filtered.count - 1 {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    private func recipientRow(_ c: TransferRecipientCandidate) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.creditorName)
                    .font(.system(size: 13, weight: .medium))
                Text("\(formatIban(c.creditorIban)) · \(c.frequency)×")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let amt = c.mostFrequentAmount {
                Text(formatEUR(amt))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if phase == .idle {
                Button(L10n.t("Abbrechen", "Cancel")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: trySend) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.t("Senden…", "Send…"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSending || !canSend)
            } else {
                Spacer()
                Button(L10n.t("Schließen", "Close")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Result views

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundColor(.sbGreenStrong)
            Text(L10n.t("Überweisung wurde an die Bank übermittelt.",
                        "Transfer was submitted to the bank."))
                .multilineTextAlignment(.center)
            if demoMode {
                Text(L10n.t("(Demo-Mode — keine echte Bank-Aktion)",
                            "(Demo mode — no real bank action)"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func mayHaveBeenExecutedView(_ detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.sbOrangeStrong)
            Text(L10n.t("Status unklar — prüfe Banking-App",
                        "Status unclear — check banking app"))
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(L10n.t("Die Bank hat nicht eindeutig bestätigt. Es ist möglich, dass die Überweisung trotzdem ausgeführt wurde. Bitte prüfe deinen Kontostand und Buchungen.",
                        "The bank didn't confirm clearly. The transfer might still have been executed. Please verify in your banking app."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 44))
                .foregroundColor(.sbRedStrong)
            Text(L10n.t("Senden fehlgeschlagen", "Send failed"))
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Confirm alert

    private var confirmAlert: Alert {
        let amountText = formatEUR(parseAmount() ?? 0)
        let recipientText = creditorName.isEmpty
            ? formatIban(rawIban)
            : "\(creditorName) (\(formatIban(rawIban)))"
        return Alert(
            title: Text(L10n.t("Überweisung bestätigen", "Confirm transfer")),
            message: Text(L10n.t(
                "\(amountText) an \(recipientText) senden?",
                "Send \(amountText) to \(recipientText)?"
            )),
            primaryButton: .default(
                Text(L10n.t("Senden", "Send")),
                action: { Task { await performSend() } }
            ),
            secondaryButton: .cancel(Text(L10n.t("Abbrechen", "Cancel")))
        )
    }

    // MARK: - Logic

    private var canSend: Bool {
        validate() == nil
    }

    private func handleQueryChange() {
        // Wenn der Eingabe-String wie eine IBAN aussieht, behandle ihn als IBAN
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLikelyIban(raw) {
            rawIban = TransferRequest.normalizeIban(raw)
        } else if selectedCandidate == nil {
            // Wenn der User vom selektierten Empfänger weg-ändert, IBAN nicht überschreiben
            // bis er wirklich eine andere IBAN tippt.
        }
        validationHint = nil
    }

    private func handleQueryCommit() {
        // Enter im Empfänger-Feld → falls genau ein gefilterter Eintrag, übernehmen
        let filtered = TransferRecipientStore.filter(recipients, query: query)
        if filtered.count == 1 { applyCandidate(filtered[0]) }
    }

    private func applyCandidate(_ c: TransferRecipientCandidate) {
        selectedCandidate = c
        creditorName = c.creditorName
        rawIban = c.creditorIban
        query = c.creditorName
        if amountInput.isEmpty, let amt = c.mostFrequentAmount {
            amountInput = formatAmountForInput(amt)
        }
        if remittance.isEmpty, let r = c.lastRemittance, !r.isEmpty {
            remittance = r
        }
        validationHint = nil
    }

    private func loadRecipients() async {
        let slotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        let bankId = demoMode ? "demo" : "primary"
        let loaded = (try? TransferRecipientStore.loadCandidates(
            slotId: slotId, bankId: bankId
        )) ?? []
        await MainActor.run { self.recipients = loaded }
    }

    private func trySend() {
        if let hint = validate() {
            validationHint = hint
            return
        }
        showConfirm = true
    }

    /// Läuft Validierung gegen TransferRequest-Init und gibt ggf. einen
    /// User-facing Hint zurück. Nil = OK zu senden.
    private func validate() -> String? {
        // Wenn User über Liste ausgewählt hat ist creditorName + rawIban gesetzt;
        // sonst muss er eine IBAN getippt haben + Name in `query` (oder selektiert).
        let name = creditorName.isEmpty ? query : creditorName
        let iban = rawIban.isEmpty
            ? TransferRequest.normalizeIban(query)
            : rawIban
        guard let amt = parseAmount() else {
            return L10n.t("Betrag muss eine Zahl sein.", "Amount must be a number.")
        }
        do {
            _ = try TransferRequest(
                creditorName: name,
                creditorIban: iban,
                amountEUR: amt,
                remittance: remittance.isEmpty ? nil : remittance
            )
            return nil
        } catch let err as TransferRequestError {
            return err.localizedHint
        } catch {
            return error.localizedDescription
        }
    }

    private func performSend() async {
        guard let pw = requestMasterPassword() else { return }
        let name = creditorName.isEmpty ? query : creditorName
        let iban = rawIban.isEmpty
            ? TransferRequest.normalizeIban(query)
            : rawIban
        guard let amt = parseAmount() else { return }
        let request: TransferRequest
        do {
            request = try TransferRequest(
                creditorName: name,
                creditorIban: iban,
                amountEUR: amt,
                remittance: remittance.isEmpty ? nil : remittance
            )
        } catch let err as TransferRequestError {
            phase = .failed(err.localizedHint)
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let creds: StoredCredentials
        do {
            creds = try CredentialsStore.load(masterPassword: pw)
        } catch {
            phase = .failed(L10n.t("Falsches Master-Passwort.", "Wrong master password."))
            return
        }

        await MainActor.run {
            isSending = true
            phase = .sending
        }
        do {
            let outcome = try await YaxiService.sendTransfer(
                request: request, userId: creds.userId, password: creds.password
            )
            await MainActor.run {
                isSending = false
                if outcome.ok {
                    phase = .success
                    // Auto-close nach 1.5s damit der User die Bestätigung sieht
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if case .success = phase { onClose() }
                    }
                } else if outcome.mayHaveBeenExecuted {
                    phase = .mayHaveBeenExecuted(outcome.error ?? "")
                } else {
                    phase = .failed(outcome.userMessage ?? outcome.error
                                    ?? L10n.t("Unbekannter Fehler.", "Unknown error."))
                }
            }
        } catch {
            await MainActor.run {
                isSending = false
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Formatters

    private static let eurFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "de_DE")
        f.currencyCode = "EUR"
        return f
    }()

    private func formatEUR(_ amount: Decimal) -> String {
        Self.eurFormatter.string(from: NSDecimalNumber(decimal: amount))
            ?? "\(amount) €"
    }

    private func formatAmountForInput(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func parseAmount() -> Decimal? {
        let cleaned = amountInput
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned)
    }

    private func formatIban(_ iban: String) -> String {
        // 4er-Gruppen für Lesbarkeit
        let normalized = TransferRequest.normalizeIban(iban)
        var out = ""
        for (i, ch) in normalized.enumerated() {
            if i > 0 && i % 4 == 0 { out += " " }
            out.append(ch)
        }
        return out
    }

    private func isLikelyIban(_ raw: String) -> Bool {
        let normalized = TransferRequest.normalizeIban(raw)
        // Mindestens 4 Zeichen + erste 2 Buchstaben (Country Code)
        guard normalized.count >= 4 else { return false }
        let first = normalized.prefix(2)
        return first.allSatisfy { $0.isLetter && $0.isASCII }
            && normalized.dropFirst(2).contains(where: { $0.isNumber })
    }
}

// (String.nilIfEmpty wird global in BankingModels.swift definiert)
