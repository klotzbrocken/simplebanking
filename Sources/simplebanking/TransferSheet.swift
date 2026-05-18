import SwiftUI
import AppKit

// MARK: - TransferSheet (v3 — linearer Flow, kein Picker)
//
// Spec-Referenz: ~/Downloads/design_handoff_geld_senden_v3 / dialog-v3.jsx,
// recipient-v3.jsx. Kernprinzipien aus dem Handoff:
//
//  1. Ein Modell, kein Switch: Name + IBAN sind IMMER beide Felder, kein
//     Mode-Toggle, kein Selected-Card-State.
//  2. Historie ist still: Empfänger-Historie nur als Autocomplete am Namens-
//     feld. Keine Listen, Chips, Tabs, Favoriten-UI.
//  3. Linearer Fluss: Source → Empfänger → Betrag → Zweck → Senden.
//     Nachgelagerte Felder sind disabled bis Vorbedingung erfüllt.
//  4. Keine Schritte/Wizard. Bestätigung nur als finaler Sicherheitsschritt
//     im Footer (idle → confirm → sent).
//
// Public API unverändert (`requestMasterPassword`, `onClose`).
//
// Phase-Enum behält weiter `.sending`, `.failed`, `.mayHaveBeenExecuted`
// für den echten Bank-Flow — sind im Spec nicht aufgeführt, aber notwendig
// um YaxiService-Outcomes zu rendern.

@MainActor
struct TransferSheet: View {
    let requestMasterPassword: () -> String?
    let onClose: () -> Void
    /// Optional — wird vom Source-Picker bei Multibanking gerufen, damit
    /// der globale Bank-Switch (Refresh + Slot-Kontext) korrekt durchläuft.
    /// nil = no-op (Single-Bank-Setup).
    var onSwitchSlot: ((Int) -> Void)? = nil

    @ObservedObject private var bankingStore = MultibankingStore.shared

    @AppStorage("demoMode") private var demoMode: Bool = false
    /// Sendeverzögerung in Sekunden (0 = aus). Setting in `behaviorSettings`.
    @AppStorage("transferDelaySeconds") private var transferDelaySeconds: Int = 5

    // MARK: - State

    @State private var name: String = ""
    @State private var iban: String = ""
    @State private var ibanTouched: Bool = false
    @State private var amountInput: String = ""
    @State private var purpose: String = ""
    @State private var phase: Phase = .idle
    @State private var bodyError: String? = nil

    // Clipboard-IBAN-Hinweis: erkannte IBAN aus Pasteboard, wird als
    // dismissable Banner gezeigt solange iban-Feld leer ist.
    @State private var clipboardIbanCandidate: String? = nil

    // Sendeverzögerung
    @State private var delayRemaining: Int = 0
    @State private var delayTask: Task<Void, Never>? = nil

    // Empfänger informieren (Mail-Quittung)
    @State private var informRecipient: Bool = false
    @State private var recipientEmail: String = ""

    // Scheduling
    @State private var scheduledDate: Date? = nil
    @State private var showSchedulePicker: Bool = false
    @State private var customDateValue: Date = Date()

    // Autocomplete
    @State private var allRecipients: [TransferRecipientCandidate] = []
    @State private var acHighlightIndex: Int = 0
    /// Form-Felder mit Tab-Reihenfolge. Wird von `@FocusState` für
    /// automatisches Tab-Cycling genutzt — SwiftUI navigiert in der
    /// Reihenfolge der `equals:`-Bindings durch die TextFields.
    private enum TransferField: Hashable {
        case name, iban, amount, purpose, email
    }
    @FocusState private var focusField: TransferField?

    // Bool-Bridges für bestehende Lese-/Schreibstellen — vermeidet 20+ Diff-
    // Hunks. Read = Vergleich, Write = setzen/clearen des Enum-Slots.
    private var nameFocused: Bool {
        get { focusField == .name }
        nonmutating set { focusField = newValue ? .name : (focusField == .name ? nil : focusField) }
    }
    private var ibanFocused: Bool {
        get { focusField == .iban }
        nonmutating set { focusField = newValue ? .iban : (focusField == .iban ? nil : focusField) }
    }
    private var amountFocused: Bool {
        get { focusField == .amount }
        nonmutating set { focusField = newValue ? .amount : (focusField == .amount ? nil : focusField) }
    }

    // Async Bank-Preview (Routex/YAXI-Lookup für IBANs, die nicht in der
    // statischen BLZ-Tabelle stehen). Sync `BankLogoAssets.find(byIBAN:)`
    // gewinnt wenn vorhanden — sonst debounced async via previewBank().
    @State private var previewedRecipientBank: DiscoveredBank? = nil
    @State private var isPreviewingBank: Bool = false
    @State private var previewBankTask: Task<Void, Never>? = nil
    @State private var previewedForIban: String = ""

    enum Phase: Equatable {
        case idle
        case confirm
        /// Countdown-Phase: User hat „Bestätigen" geklickt, aber Send wird
        /// erst nach `transferDelaySeconds` ausgelöst. User kann während
        /// der Delay abbrechen → zurück zu `.confirm`. 0s setzt direkt zu
        /// `.sending` ohne diese Phase zu durchlaufen.
        case delaying
        case sending
        case sent
        case mayHaveBeenExecuted(String)
        case failed(String)
    }

    // MARK: - Derived

    private var slot: BankSlot? { MultibankingStore.shared.activeSlot }
    private var slotId: String { slot?.id ?? "legacy" }

    private var availableBalance: Decimal {
        let raw = UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slotId)") as? Double
        guard let raw else { return 0 }
        return Decimal(raw)
    }

    /// Per-Slot-Dispolimit aus den BankSlotSettings. 0 = kein Dispo
    /// konfiguriert, dann wird die Dispo-Zeile im Saldo-Block ausgeblendet.
    private var dispoLimit: Decimal {
        let cfg = BankSlotSettingsStore.load(slotId: slotId)
        return Decimal(cfg.dispoLimit)
    }

    /// Maximal mögliche Überweisung inklusive Dispo. Saldo + Dispo.
    private var availableInclDispo: Decimal {
        availableBalance + dispoLimit
    }

    private var amountValue: Decimal {
        let cleaned = amountInput
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned) ?? 0
    }

    /// Überschreitet das normale Guthaben (ohne Dispo) — User-feedback
    /// für den Hinweis "geht nur über Dispo".
    private var amountExceedsBalance: Bool {
        amountValue > availableBalance && availableBalance > 0
    }

    /// Echte Hard-Limit-Überschreitung — auch der Dispo reicht nicht.
    /// Sperrt den Senden-Button.
    private var amountExceedsDispoLimit: Bool {
        amountValue > availableInclDispo && availableInclDispo > 0
    }

    private var ibanClean: String {
        iban.replacingOccurrences(of: " ", with: "").uppercased()
    }

    private var ibanIsValid: Bool {
        guard !ibanClean.isEmpty else { return false }
        return (try? TransferRequest.validateIban(ibanClean)) != nil
    }

    private var ibanShowError: Bool {
        ibanTouched && ibanClean.count >= 6 && !ibanIsValid
    }

    private var ibanExpectedLength: Int {
        ibanLengthFor(country: String(ibanClean.prefix(2)))
    }

    private var ibanProgress: CGFloat {
        guard ibanExpectedLength > 0 else { return 0 }
        return min(1, CGFloat(ibanClean.count) / CGFloat(ibanExpectedLength))
    }

    private var ibanBrand: BankLogoAssets.BankBrand? {
        guard ibanClean.count >= 12 else { return nil }
        return BankLogoAssets.find(byIBAN: ibanClean)
    }

    /// Sync wins, sonst der async-Preview als Brand-Mapping. Brauchen wir
    /// fürs IBAN-Feld-Icon und die rechte FlowCard-Seite.
    private var recipientBrand: BankLogoAssets.BankBrand? {
        if let sync = ibanBrand { return sync }
        return BankLogoAssets.resolve(
            displayName: previewedRecipientBank?.displayName,
            logoID: previewedRecipientBank?.logoId,
            iban: ibanClean
        )
    }

    /// Vier Zustände: sync aufgelöst → async aufgelöst → noch lookup → Unbekannt.
    private var bankLabelText: String {
        if let name = ibanBrand?.displayName { return name }
        if let preview = previewedRecipientBank?.displayName { return preview }
        if ibanClean.isEmpty { return " " }
        if isPreviewingBank { return L10n.t("Bank wird erkannt …", "Detecting bank…") }
        if ibanClean.count >= ibanExpectedLength {
            return L10n.t("Unbekannte Bank", "Unknown bank")
        }
        return L10n.t("Bank wird erkannt …", "Detecting bank…")
    }

    private var nameReady: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2
    }

    private var recipientReady: Bool {
        nameReady && ibanIsValid
    }

    /// Enable-Flag fürs IBAN-Feld: laut Spec wird es aktivierbar sobald der
    /// Name ≥ 2 Zeichen hat. Vorher disabled.
    private var ibanFieldEnabled: Bool {
        nameReady && phase == .idle
    }

    private var amountFieldEnabled: Bool {
        recipientReady && phase == .idle
    }

    private var purposeFieldEnabled: Bool {
        recipientReady && amountValue > 0 && phase == .idle
    }

    private var canSubmit: Bool {
        // Hard limit ist Saldo + Dispo. Innerhalb dessen darf gesendet werden;
        // optisch warnen wir trotzdem wenn der reine Saldo überschritten wird
        // (siehe `amountExceedsBalance` in saldoLine).
        guard recipientReady, amountValue > 0, !amountExceedsDispoLimit else { return false }
        do {
            _ = try TransferRequest(
                creditorName: name.trimmingCharacters(in: .whitespaces),
                creditorIban: ibanClean,
                amountEUR: amountValue,
                remittance: purpose.nilIfEmpty
            )
            return true
        } catch {
            return false
        }
    }

    /// Autocomplete-Treffer: Substring-Match auf Name, sortiert nach
    /// Häufigkeit, max. 4. Liefert `[]` wenn Feld nicht fokussiert oder
    /// noch nichts getippt.
    private var acMatches: [TransferRecipientCandidate] {
        guard nameFocused, !name.isEmpty else { return [] }
        let q = name.lowercased()
        return allRecipients
            .filter { $0.creditorName.lowercased().contains(q) }
            .sorted { $0.frequency > $1.frequency }
            .prefix(4)
            .map { $0 }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            bodyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider().opacity(0.6)
            footer
        }
        // Höhe flexibel — das umgebende NSPanel wird in BalanceBar auf die
        // exakte Frame-Höhe des Umsatzfensters gesetzt, damit beide Fenster
        // nebeneinander gleich hoch sind.
        .frame(width: 480)
        .frame(maxHeight: .infinity)
        .background(Color.panelBackground)
        .task { await loadInitial() }
        .onChange(of: ibanClean) { _, _ in
            schedulePreviewBank()
        }
        .onDisappear {
            previewBankTask?.cancel()
            delayTask?.cancel()
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch phase {
        case .mayHaveBeenExecuted(let detail):
            terminalView(
                icon: "questionmark.circle.fill",
                tint: .sbOrangeStrong,
                title: L10n.t("Status unklar — prüfe Banking-App",
                              "Status unclear — check banking app"),
                message: L10n.t(
                    "Die Bank hat nicht eindeutig bestätigt. Es ist möglich, dass die Überweisung trotzdem ausgeführt wurde.",
                    "The bank didn't confirm clearly. The transfer might still have been executed."
                ),
                detail: detail
            )
        case .failed(let message):
            terminalView(
                icon: "xmark.octagon.fill",
                tint: .sbRedStrong,
                title: L10n.t("Senden fehlgeschlagen", "Send failed"),
                message: message,
                detail: nil
            )
        default:
            VStack(alignment: .leading, spacing: 10) {
                metaRow
                if let candidate = clipboardIbanCandidate, ibanClean.isEmpty {
                    clipboardIbanBanner(candidate: candidate)
                }
                empfaengerSection
                betragSection
                verwendungszweckSection
                flowCardSection
                informRecipientSection
                if let err = bodyError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.sbRedStrong)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 14)
        }
    }

    private func clipboardIbanBanner(candidate: String) -> some View {
        let formatted = formatIbanGroups(candidate)
        return HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.sbBlueStrong)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("IBAN aus Zwischenablage erkannt",
                            "IBAN detected on clipboard"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.sbTextPrimary)
                Text(shortIbanFormatted(formatted))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(.sbTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: {
                iban = formatted
                ibanTouched = true
                clipboardIbanCandidate = nil
            }) {
                Text(L10n.t("Einfügen", "Paste"))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundColor(.white)
                    .background(Capsule().fill(Color.sbBlueStrong))
            }
            .buttonStyle(.plain)
            Button(action: { clipboardIbanCandidate = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.sbTextSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.sbBlueSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.sbBlueStrong.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func shortIbanFormatted(_ formatted: String) -> String {
        let c = formatted.replacingOccurrences(of: " ", with: "")
        guard c.count > 8 else { return formatted }
        return "\(c.prefix(4)) … \(c.suffix(4))"
    }

    // MARK: - Meta row

    private var metaRow: some View {
        HStack(spacing: 10) {
            timingInlineControl
            Spacer()
            if demoMode { DemoBadge() }
            SourcePill(
                slot: slot,
                allSlots: bankingStore.slots,
                onSelect: onSwitchSlot
            )
        }
    }

    /// Inline Sofort/Termin-Picker — ersetzt den ehemaligen „SEPA · in Sekunden"-
    /// Badge. Wenn kein Termin: „[bolt] Sofort [▾]" (▾ öffnet Datepicker-Popover).
    /// Wenn Termin gewählt: „[calendar] [Datum] [✕]" (X resetted auf Sofort).
    @ViewBuilder
    private var timingInlineControl: some View {
        if let d = scheduledDate {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.sbTextSecondary)
                Text(TransferScheduleHelpers.formatDateDisplay(d))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.sbTextPrimary)
                Button(action: { scheduledDate = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.sbTextSecondary.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(L10n.t("Sofort senden", "Send now"))
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.sbBlueStrong)
                Text(L10n.t("Sofort", "Now"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.sbTextPrimary)
                Button(action: {
                    customDateValue = TransferScheduleHelpers.tomorrow()
                    showSchedulePicker = true
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.sbBlueStrong)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.sbBlueSoft))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSchedulePicker, arrowEdge: .top) {
                    schedulePickerPopover
                }
                .help(L10n.t("Termin wählen", "Pick date"))
            }
        }
    }

    // MARK: - Empfänger

    private var empfaengerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel(L10n.t("Empfänger", "Recipient"))

            // Name + Autocomplete-Overlay
            ZStack(alignment: .topLeading) {
                nameField
                if !acMatches.isEmpty {
                    autocompleteList
                        .offset(y: 38)
                        .zIndex(2)
                }
            }
            .zIndex(1)

            ibanField

            // Bank-Name + Counter unter dem IBAN-Feld
            HStack {
                Text(bankLabelText)
                    .font(.system(size: 10.5))
                    .foregroundColor(.sbTextSecondary)
                    .lineLimit(1)
                Spacer()
                if !ibanClean.isEmpty {
                    Text("\(ibanClean.count)/\(ibanExpectedLength)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.sbTextSecondary.opacity(0.6))
                }
            }
            .frame(height: 14)

            // Progress-Bar
            ProgressBar(
                progress: ibanProgress,
                accent: ibanIsValid ? .sbGreenStrong
                       : ibanShowError ? .sbRedStrong
                       : .sbBlueStrong
            )
            .frame(height: 1.5)
            .opacity(ibanClean.isEmpty ? 0 : 1)
        }
    }

    private var nameField: some View {
        HStack(spacing: 8) {
            MerchantOrPersonIcon(
                name: name.trimmingCharacters(in: .whitespaces),
                kind: recipientKindGuess,
                size: 16
            )
            TextField(L10n.t("Empfänger-Name", "Recipient name"), text: $name)
                .textFieldStyle(.plain)
                .focused($focusField, equals: .name)
                .font(.system(size: 13))
                .onChange(of: name) { _, _ in
                    acHighlightIndex = 0
                }
                .onSubmit { acceptHighlightedAC() }
            if !name.isEmpty {
                Button(action: { name = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.sbTextSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.sbSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.sbBorder, lineWidth: 0.5)
        )
        .background(KeyHandlingView(
            onUp: { stepHighlight(by: -1) },
            onDown: { stepHighlight(by: 1) },
            onEnter: { acceptHighlightedAC() },
            onEscape: { nameFocused = false },
            isActive: !acMatches.isEmpty && nameFocused
        ))
        .onAppear {
            // Initial-Fokus: Namensfeld
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                nameFocused = true
            }
        }
    }

    private var autocompleteList: some View {
        VStack(spacing: 2) {
            ForEach(Array(acMatches.enumerated()), id: \.element.creditorIban) { idx, c in
                AutocompleteRow(
                    candidate: c,
                    highlighted: idx == acHighlightIndex,
                    onPick: { pickAC(c) },
                    onHover: { acHighlightIndex = idx }
                )
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.sbBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
    }

    private var ibanField: some View {
        HStack(spacing: 8) {
            Group {
                if let brand = recipientBrand {
                    BankBrandIcon(brand: brand, size: 20)
                } else {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.sbTextSecondary)
                        .frame(width: 20, height: 20)
                }
            }
            TextField(L10n.t("IBAN, z.B. DE …", "IBAN, e.g. DE …"),
                      text: Binding(
                        get: { iban },
                        set: { newValue in
                            iban = sanitizeIban(newValue)
                            if !ibanTouched && !iban.isEmpty { ibanTouched = true }
                        }))
                .textFieldStyle(.plain)
                .focused($focusField, equals: .iban)
                .font(.system(size: 13).monospacedDigit())
                .tracking(0.5)
                .disabled(!ibanFieldEnabled)
            if ibanIsValid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.sbGreenStrong)
                    .font(.system(size: 14, weight: .semibold))
                    .transition(.scale.combined(with: .opacity))
            } else if ibanShowError {
                Text(L10n.t("ungültig", "invalid"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.sbRedStrong)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.sbSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(ibanBorderColor, lineWidth: ibanIsValid || ibanShowError ? 1 : 0.5)
        )
        .opacity(ibanFieldEnabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.15), value: ibanIsValid)
        .animation(.easeInOut(duration: 0.15), value: ibanShowError)
    }

    private var ibanBorderColor: Color {
        if ibanIsValid    { return .sbGreenStrong.opacity(0.7) }
        if ibanShowError  { return .sbRedStrong.opacity(0.7) }
        return .sbBorder
    }

    // MARK: - Betrag

    private var betragSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(L10n.t("Betrag", "Amount"))

            // Hero
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("€")
                    .font(.system(size: 22, weight: .regular).monospacedDigit())
                    .foregroundColor(.sbTextSecondary)
                ZStack(alignment: .leading) {
                    if amountInput.isEmpty {
                        Text("0,00")
                            .font(.system(size: 30, weight: .bold).monospacedDigit())
                            .foregroundColor(.sbTextSecondary.opacity(0.45))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    TextField("", text: $amountInput)
                        .textFieldStyle(.plain)
                        .focused($focusField, equals: .amount)
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .foregroundColor(amountExceedsDispoLimit
                                         ? .sbRedStrong
                                         : amountInput.isEmpty
                                            ? .sbTextPrimary
                                            : moneyMoodStyle.amountColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .onChange(of: amountInput) { _, newValue in
                            amountInput = sanitizeDecimal(newValue)
                        }
                }
            }

            // Saldo-Zeile
            saldoLine

            // Piles
            pilesRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cardBackground)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [moneyMoodStyle.gradientBaseColor.opacity(0.10), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(amountExceedsBalance
                        ? Color.sbRedStrong.opacity(0.6)
                        : moneyMoodStyle.gradientBaseColor.opacity(0.4),
                        lineWidth: 1)
        )
        .opacity(amountFieldEnabled ? 1 : 0.4)
        .allowsHitTesting(amountFieldEnabled)
        .animation(.easeInOut(duration: 0.15), value: amountFieldEnabled)
        .onTapGesture { if amountFieldEnabled { amountFocused = true } }
    }

    /// MoneyMood-Style — gleiche Klassifikation wie in der Umsatzliste,
    /// aber gegen den PROJIZIERTEN Saldo (verfügbar − eingegebener Betrag).
    /// Tippt der User einen großen Betrag, kippt der Mood live z.B. von
    /// Grün auf Orange/Rot — visuelles Live-Feedback fürs Überweisen.
    /// Bei leerem Eingabefeld: aktueller verfügbarer Saldo.
    private var moneyMoodStyle: BalanceSignalStyle {
        let s = BankSlotSettingsStore.load(slotId: slotId)
        let thresholds = BalanceSignalThresholds(
            deepOverdraftThreshold: Double(s.balanceSignalDeepOverdraftThreshold),
            lowUpperBound: Double(s.balanceSignalLowUpperBound),
            mediumUpperBound: Double(s.balanceSignalMediumUpperBound),
            veryGoodLowerBound: Double(s.balanceSignalVeryGoodLowerBound)
        )
        let projected = availableBalance - amountValue
        let level = BalanceSignal.classify(
            balance: NSDecimalNumber(decimal: projected).doubleValue,
            thresholds: thresholds
        )
        return BalanceSignal.style(for: level)
    }

    private var saldoLine: some View {
        // Eine Zeile: links Saldo (oder alt→neu), rechts Status-Badge,
        // ganz rechts der Dispo-Hint (falls konfiguriert).
        HStack(spacing: 6) {
            if amountValue > 0 {
                // Alt durchgestrichen → Pfeil → neu (visuell zusammenhängend)
                Text("€ \(formatEUR(availableBalance))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.sbTextSecondary.opacity(0.6))
                    .strikethrough(true, color: .sbTextSecondary.opacity(0.6))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.sbTextSecondary.opacity(0.7))
                Text("€ \(formatEUR(availableBalance - amountValue))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(amountExceedsDispoLimit ? .sbRedStrong : .sbTextPrimary)
                if amountExceedsDispoLimit {
                    Text(L10n.t("überschreitet Limit", "exceeds limit"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.sbRedStrong)
                } else if amountExceedsBalance {
                    Text(L10n.t("nutzt Dispo", "uses overdraft"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.sbOrangeStrong)
                }
                Spacer(minLength: 6)
                dispoHintInline
            } else {
                Text(L10n.t("verfügbar", "available"))
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
                Text("€ \(formatEUR(availableBalance))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(availableBalance < 0 ? .sbRedStrong : .sbGreenStrong)
                Spacer(minLength: 6)
                dispoHintInline
            }
        }
    }

    /// Inline-Variante des Dispo-Hints — passt in die Saldo-Zeile rechts neben
    /// das verfügbare Guthaben. Wird ausgeblendet wenn kein Dispo konfiguriert.
    @ViewBuilder
    private var dispoHintInline: some View {
        if dispoLimit > 0 {
            HStack(spacing: 4) {
                Image(systemName: "creditcard.and.123")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.sbTextSecondary.opacity(0.7))
                Text(L10n.t(
                    "inkl. Dispo bis € \(formatEUR(availableInclDispo))",
                    "incl. overdraft up to € \(formatEUR(availableInclDispo))"
                ))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(.sbTextSecondary.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }

    private var pilesRow: some View {
        HStack(spacing: 6) {
            ForEach([10, 20, 50, 100], id: \.self) { value in
                pile(value: value)
            }
            Spacer()
        }
    }

    private func pile(value: Int) -> some View {
        let active = amountValue == Decimal(value)
        return Button(action: { setAmount(Decimal(value)) }) {
            Text("\(value)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(active ? .sbBlueStrong : .sbTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Color.sbBlueSoft : Color.clear)
                )
                .overlay(
                    Capsule().stroke(active ? Color.sbBlueStrong.opacity(0.5) : Color.sbBorder,
                                     lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Verwendungszweck

    private var verwendungszweckSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CapsLabel(L10n.t("Verwendungszweck", "Purpose"))
                Text(L10n.t("optional", "optional"))
                    .font(.system(size: 10))
                    .foregroundColor(.sbTextSecondary)
                Spacer()
                if !purpose.isEmpty {
                    Text("\(purpose.count)/140")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(purpose.count >= 140 ? .sbRedStrong
                                       : purpose.count >= 126 ? .sbOrangeStrong
                                       : .sbTextSecondary.opacity(0.7))
                }
            }
            TextField(L10n.t("z.B. Miete Mai", "e.g. Rent May"),
                      text: Binding(
                        get: { purpose },
                        set: { purpose = sanitizePurpose($0) }))
                .textFieldStyle(.plain)
                .focused($focusField, equals: .purpose)
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.sbSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.sbBorder, lineWidth: 0.5)
                )
                .disabled(!purposeFieldEnabled)
        }
        .opacity(purposeFieldEnabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.15), value: purposeFieldEnabled)
    }

    // MARK: - Empfänger informieren

    /// Optional: Empfänger bekommt nach erfolgreichem Send eine E-Mail mit
    /// PDF-Quittung. Mail-Compose öffnet im System-Mail-Client; nichts wird
    /// ohne explizite Bestätigung versendet.
    @ViewBuilder
    private var informRecipientSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $informRecipient) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!informRecipientFieldEnabled)
                .onChange(of: scheduledDate) { _, newDate in
                    // Bei Termin-Überweisung Toggle zurücksetzen — die
                    // „ist raus"-Mail soll nicht für Future-Dated rausgehen.
                    if newDate != nil { informRecipient = false }
                }
                Text(L10n.t("Empfänger per E-Mail informieren",
                            "Notify recipient by email"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.sbTextPrimary)
                Spacer()
                if scheduledDate != nil {
                    Text(L10n.t("nur bei Sofort-Überweisung", "only for instant transfer"))
                        .font(.system(size: 10.5))
                        .foregroundColor(.sbTextSecondary)
                } else if informRecipient && !recipientEmailIsValid && !recipientEmail.isEmpty {
                    Text(L10n.t("ungültige E-Mail", "invalid email"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.sbRedStrong)
                }
            }
            if informRecipient {
                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .font(.system(size: 12))
                        .foregroundColor(.sbTextSecondary)
                        .frame(width: 16, height: 16)
                    TextField(L10n.t("E-Mail-Adresse", "Email address"),
                              text: $recipientEmail)
                        .textFieldStyle(.plain)
                        .focused($focusField, equals: .email)
                        .font(.system(size: 12.5))
                        .disableAutocorrection(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.sbSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.sbBorder, lineWidth: 0.5)
                )
            }
        }
        .opacity(informRecipientFieldEnabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.15), value: informRecipient)
    }

    private var informRecipientFieldEnabled: Bool {
        // Termin-Überweisungen werden ggf. erst Tage später ausgeführt — eine
        // sofortige „ist raus"-Mail wäre da irreführend. Daher nur bei Sofort.
        recipientReady && amountValue > 0 && phase == .idle && scheduledDate == nil
    }

    private var recipientEmailIsValid: Bool {
        let trimmed = recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Pragmatisch: ein @ + ein . danach. Mail.app validiert beim Compose nochmal.
        guard let atIdx = trimmed.firstIndex(of: "@") else { return false }
        let local = trimmed[..<atIdx]
        let domain = trimmed[trimmed.index(after: atIdx)...]
        return !local.isEmpty && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    // MARK: - FlowCard (Sender → Betrag → Empfänger + Timing-Strip)

    @ViewBuilder
    private var flowCardSection: some View {
        if recipientReady && amountValue > 0 {
            // timingStrip ist nach oben in den metaRow (timingInlineControl)
            // gewandert — die FlowCard zeigt nur noch die Sender→Empfänger-Übersicht.
            flowRow
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.sbSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(Color.sbBorder, lineWidth: 0.5)
            )
            .allowsHitTesting(phase == .idle)
            .opacity(phase == .idle ? 1 : 0.7)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeInOut(duration: 0.15), value: recipientReady && amountValue > 0)
        }
    }

    private var flowRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // Links: Sender — Logo VOR Bank-Name (konsistent zur SourcePill).
            HStack(spacing: 6) {
                SenderLogo(slot: slot, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(senderBankName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.sbTextPrimary)
                        .lineLimit(1)
                    Text(senderAccountLabel)
                        .font(.system(size: 10.5))
                        .foregroundColor(.sbTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Mitte: Betrag + Pfeil — unverändert
            VStack(spacing: 2) {
                Text("€ \(formatEUR(amountValue))")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundColor(.sbTextPrimary)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.sbBlueStrong.opacity(0.7))
            }
            .layoutPriority(1)

            // Rechts: Empfänger — gleiches Pattern wie links: Logo VOR Name.
            // Block ist rechts-anchored, Texte aber innerhalb leading-aligned
            // damit Logo + Name visuell zusammenbleiben (kein leerer Spalt).
            HStack(spacing: 6) {
                if let brand = recipientBrand {
                    BankBrandIcon(brand: brand, size: 16)
                } else {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.sbTextSecondary)
                        .frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(recipientBankName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.sbTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(name.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 10.5))
                        .foregroundColor(.sbTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var senderBankName: String {
        // Spezifischer Bank-Name (z.B. „Sparkasse Siegen") gewinnt vor dem
        // generischen Brand-Namen aus BankLogoAssets („Sparkasse").
        slot?.displayName.nilIfEmpty
            ?? BankLogoAssets.resolve(
                displayName: slot?.displayName,
                logoID: slot?.logoId,
                iban: slot?.iban
            )?.displayName
            ?? L10n.t("Konto", "Account")
    }

    private var senderAccountLabel: String {
        if let nick = slot?.nickname?.nilIfEmpty { return nick }
        if let iban = slot?.iban.nilIfEmpty { return shortIban(iban) }
        return ""
    }

    private var recipientBankName: String {
        // YAXI liefert spezifische Namen wie „Sparkasse Siegen"; das
        // gewinnt vor dem generischen BankLogoAssets-Brand-Namen.
        previewedRecipientBank?.displayName
            ?? ibanBrand?.displayName
            ?? L10n.t("Empfänger-Bank", "Recipient bank")
    }

    /// Triggert async Bank-Preview wenn IBAN nach Sync-Resolver nicht
    /// auflöst. Debounced 350ms, cancelt vorheriges Task. Lookup nur wenn
    /// IBAN ≥ 15 Zeichen (siehe YaxiService.previewBank-Gate).
    private func schedulePreviewBank() {
        previewBankTask?.cancel()
        let target = ibanClean

        // Sync-Resolver hat schon einen Treffer → kein async-Lookup nötig.
        if BankLogoAssets.find(byIBAN: target) != nil {
            previewedRecipientBank = nil
            isPreviewingBank = false
            previewedForIban = target
            return
        }

        // Zu kurz → reset.
        guard target.count >= 15 else {
            previewedRecipientBank = nil
            isPreviewingBank = false
            previewedForIban = ""
            return
        }

        // Schon für genau diese IBAN gequeried → nichts tun.
        if target == previewedForIban { return }

        // Demo-Mode: kein Routex-Call.
        if demoMode {
            previewedRecipientBank = nil
            isPreviewingBank = false
            previewedForIban = target
            return
        }

        isPreviewingBank = true
        previewBankTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let result = await YaxiService.previewBank(iban: target)
            if Task.isCancelled { return }
            await MainActor.run {
                // Nur committen wenn IBAN sich nicht zwischenzeitlich geändert hat.
                guard target == ibanClean else { return }
                self.previewedRecipientBank = result
                self.previewedForIban = target
                self.isPreviewingBank = false
            }
        }
    }

    /// Versucht, einen passenden TransferRecipientKind aus den geladenen
    /// Kandidaten zu finden. Sonst Fallback auf `.privat` für die
    /// Avatar-SF-Symbol-Auswahl.
    private var recipientKindGuess: TransferRecipientKind {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = allRecipients.first(where: {
            $0.creditorIban == ibanClean
                || $0.creditorName.lowercased() == trimmed
        }) {
            return match.kind
        }
        return .privat
    }

    private var schedulePickerPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("TERMIN WÄHLEN", "PICK DATE"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.sbTextSecondary.opacity(0.85))
                .padding(.bottom, 4)

            quickPickRow(L10n.t("Morgen", "Tomorrow"),
                         date: TransferScheduleHelpers.tomorrow())
            quickPickRow(L10n.t("In 7 Tagen", "In 7 days"),
                         date: TransferScheduleHelpers.in7Days())
            quickPickRow(L10n.t("1. nächsten Monat", "1st of next month"),
                         date: TransferScheduleHelpers.firstOfNextMonth())

            Divider().padding(.vertical, 4)

            HStack(spacing: 8) {
                DatePicker("",
                           selection: $customDateValue,
                           in: TransferScheduleHelpers.today()...,
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Button(L10n.t("OK", "OK")) {
                    scheduledDate = customDateValue
                    showSchedulePicker = false
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func quickPickRow(_ label: String, date: Date) -> some View {
        Button(action: {
            scheduledDate = date
            showSchedulePicker = false
        }) {
            HStack {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundColor(.sbTextPrimary)
                Spacer()
                Text(TransferScheduleHelpers.formatDateDisplay(date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.sbTextSecondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortIban(_ iban: String) -> String {
        let c = iban.replacingOccurrences(of: " ", with: "")
        guard c.count > 8 else { return iban }
        return "\(c.prefix(4)) … \(c.suffix(4))"
    }

    // MARK: - Footer (3 Phasen + sending/terminal)

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .idle:                     footerIdle
        case .confirm:                  footerConfirm
        case .delaying:                 footerDelaying
        case .sending:                  footerSending
        case .sent:                     footerSent
        case .mayHaveBeenExecuted,
             .failed:                   footerTerminal
        }
    }

    private var footerIdle: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: {
                guard canSubmit else { return }
                phase = .confirm
                bodyError = nil
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .semibold))
                    if canSubmit {
                        Text(L10n.t("€ \(formatEUR(amountValue)) senden",
                                    "Send € \(formatEUR(amountValue))"))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    } else {
                        Text(L10n.t("Senden", "Send"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .frame(minWidth: 130)
                .foregroundColor(canSubmit ? .white : .sbTextSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canSubmit ? Color.sbRedStrong : Color.sbSurfaceSoft)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private var footerConfirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            (
                Text("€ \(formatEUR(amountValue))").font(.system(size: 12, weight: .semibold).monospacedDigit())
                + Text(" " + L10n.t("an", "to") + " ")
                + Text(name.trimmingCharacters(in: .whitespaces)).font(.system(size: 12, weight: .semibold))
                + Text(purpose.nilIfEmpty.map { " · \u{201E}\($0)\u{201C}" } ?? "")
                + Text(" · ")
                + Text(scheduleSuffix)
            )
            .font(.system(size: 12))
            .foregroundColor(.sbTextSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(L10n.t("Zurück", "Back")) { phase = .idle }
                    .buttonStyle(SecondaryActionStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: {
                    // Race-Schutz: phase synchron umstellen, BEVOR der Task
                    // startet. Zweiter Klick / Enter findet phase != .confirm
                    // vor und fällt durch das guard.
                    guard phase == .confirm else { return }
                    if transferDelaySeconds > 0 {
                        startSendDelay()
                    } else {
                        phase = .sending
                        Task { await performSend() }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .semibold))
                        Text(L10n.t("Bestätigen", "Confirm"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color.sbRedStrong)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(phase != .confirm)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private var footerDelaying: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.sbBlueStrong)
                Text(L10n.t(
                    "Sende in \(delayRemaining)s — du kannst noch abbrechen.",
                    "Sending in \(delayRemaining)s — you can still cancel."
                ))
                    .font(.system(size: 12))
                    .foregroundColor(.sbTextSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

            // Countdown-Bar (visueller Fortschritt)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.sbBorder)
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.sbBlueStrong)
                        .frame(width: geo.size.width * delayProgress)
                        .animation(.linear(duration: 0.5), value: delayRemaining)
                }
            }
            .frame(height: 3)

            HStack(spacing: 8) {
                Spacer()
                Button(action: { cancelSendDelay() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L10n.t("Abbrechen (\(delayRemaining)s)",
                                    "Cancel (\(delayRemaining)s)"))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color.sbBlueStrong)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private var delayProgress: CGFloat {
        guard transferDelaySeconds > 0 else { return 0 }
        let total = CGFloat(transferDelaySeconds)
        let remaining = CGFloat(delayRemaining)
        return max(0, min(1, (total - remaining) / total))
    }

    private func startSendDelay() {
        let total = transferDelaySeconds
        delayRemaining = total
        phase = .delaying
        delayTask?.cancel()
        delayTask = Task { @MainActor in
            for tick in stride(from: total, through: 1, by: -1) {
                self.delayRemaining = tick
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            // Countdown abgelaufen → senden
            self.delayRemaining = 0
            self.phase = .sending
            await self.performSend()
        }
    }

    private func cancelSendDelay() {
        delayTask?.cancel()
        delayTask = nil
        delayRemaining = 0
        phase = .confirm
    }

    private var footerSending: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L10n.t("Übertrage an Bank…", "Submitting to bank…"))
                .font(.system(size: 12))
                .foregroundColor(.sbTextSecondary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private var footerSent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.sbGreenStrong).frame(width: 28, height: 28)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(sentTitle)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                Text(sentSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
            }
            Spacer()
            Button(L10n.t("Neue Überweisung", "New transfer")) { resetForNext() }
                .buttonStyle(SecondaryActionStyle())
            Button(L10n.t("Schließen", "Close")) { onClose() }
                .buttonStyle(SecondaryActionStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private var footerTerminal: some View {
        HStack {
            Spacer()
            Button(L10n.t("Schließen", "Close")) { onClose() }
                .buttonStyle(SecondaryActionStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    // MARK: - Terminal view

    private func terminalView(icon: String, tint: Color, title: String, message: String, detail: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.sbTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            if let d = detail, !d.isEmpty {
                Text(d)
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
                    .padding(.horizontal, 8)
                    .multilineTextAlignment(.center)
            }
            if demoMode {
                Text(L10n.t("(Demo-Mode — keine echte Bank-Aktion)",
                            "(Demo mode — no real bank action)"))
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 22)
    }

    // MARK: - Confirm/Sent helper texts

    private var scheduleSuffix: String {
        if let d = scheduledDate {
            return L10n.t("am \(TransferScheduleHelpers.formatDateDisplay(d))",
                          "on \(TransferScheduleHelpers.formatDateDisplay(d))")
        }
        return L10n.t("sofort", "now")
    }

    private var sentTitle: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if scheduledDate == nil {
            return L10n.t("€ \(formatEUR(amountValue)) an \(n) gesendet",
                          "€ \(formatEUR(amountValue)) sent to \(n)")
        }
        return L10n.t("€ \(formatEUR(amountValue)) an \(n) terminiert",
                      "€ \(formatEUR(amountValue)) scheduled to \(n)")
    }

    private var sentSubtitle: String {
        if let d = scheduledDate {
            return L10n.t("Ausführung am \(TransferScheduleHelpers.formatDateDisplay(d))",
                          "executes on \(TransferScheduleHelpers.formatDateDisplay(d))")
        }
        return L10n.t("in 1–2 Sekunden auf seinem Konto",
                      "arrives in 1–2 seconds")
    }

    // MARK: - Autocomplete actions

    private func pickAC(_ c: TransferRecipientCandidate) {
        name = c.creditorName
        iban = formatIbanGroups(c.creditorIban)
        ibanTouched = true     // gefüllter Wert ist per Definition gültig
        nameFocused = false    // blurrt; User kann zum Betrag tabben
        // Spec: nach Pick darauf folgender Tab geht zu IBAN, das bereits
        // gefüllt ist; User tabbt erneut zu Amount. Wir lassen die
        // Browser-Default-Tab-Order so wie sie ist.
    }

    private func stepHighlight(by delta: Int) {
        guard !acMatches.isEmpty else { return }
        let n = acMatches.count
        acHighlightIndex = (acHighlightIndex + delta + n) % n
    }

    private func acceptHighlightedAC() {
        guard !acMatches.isEmpty else { return }
        let idx = max(0, min(acHighlightIndex, acMatches.count - 1))
        pickAC(acMatches[idx])
    }

    // MARK: - Actions

    private func loadInitial() async {
        let bankId = demoMode ? "demo" : "primary"
        let loaded = (try? TransferRecipientStore.loadCandidates(
            slotId: slotId, bankId: bankId
        )) ?? []
        let detectedIban = IbanClipboardScanner.detectIban()
        await MainActor.run {
            self.allRecipients = loaded
            // Banner nur einblenden wenn der User noch nichts ins IBAN-Feld
            // getippt hat — sonst nervig. detectedIban ist syntaktisch valide.
            if self.ibanClean.isEmpty {
                self.clipboardIbanCandidate = detectedIban
            }
        }
    }

    private func setAmount(_ amount: Decimal) {
        guard amountFieldEnabled else { return }
        amountInput = formatAmountForInput(amount)
    }

    private func resetForNext() {
        name = ""
        iban = ""
        ibanTouched = false
        amountInput = ""
        purpose = ""
        scheduledDate = nil
        showSchedulePicker = false
        bodyError = nil
        informRecipient = false
        recipientEmail = ""
        delayTask?.cancel()
        delayTask = nil
        delayRemaining = 0
        phase = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            nameFocused = true
        }
    }

    private func performSend() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let request: TransferRequest
        do {
            request = try TransferRequest(
                creditorName: trimmedName,
                creditorIban: ibanClean,
                amountEUR: amountValue,
                remittance: purpose.nilIfEmpty
            )
        } catch let err as TransferRequestError {
            await MainActor.run { bodyError = err.localizedHint; phase = .idle }
            return
        } catch {
            await MainActor.run { bodyError = error.localizedDescription; phase = .idle }
            return
        }

        // Demo-Mode: kein Master-Passwort, keine Credentials — `YaxiService.sendTransfer`
        // short-circuited zu `.demoSuccess`. PDF/Mail-Quittung läuft normal.
        let userId: String
        let password: String
        if demoMode {
            userId = ""
            password = ""
        } else {
            guard let pw = requestMasterPassword() else {
                await MainActor.run { phase = .idle }
                return
            }
            do {
                let creds = try CredentialsStore.load(masterPassword: pw)
                userId = creds.userId
                password = creds.password
            } catch {
                await MainActor.run {
                    bodyError = L10n.t("Falsches Master-Passwort.", "Wrong master password.")
                    phase = .idle
                }
                return
            }
        }

        do {
            let outcome = try await YaxiService.sendTransfer(
                request: request,
                userId: userId,
                password: password,
                requestedExecutionDate: scheduledDate
            )
            await MainActor.run {
                if outcome.ok {
                    phase = .sent
                    triggerRecipientEmailIfRequested(request: request)
                } else if outcome.mayHaveBeenExecuted {
                    phase = .mayHaveBeenExecuted(outcome.error ?? "")
                } else {
                    phase = .failed(outcome.userMessage
                                    ?? outcome.error
                                    ?? L10n.t("Unbekannter Fehler.", "Unknown error."))
                }
            }
        } catch {
            await MainActor.run { phase = .failed(error.localizedDescription) }
        }
    }

    /// Generiert PDF-Quittung + öffnet Mail-Compose-Fenster, wenn der User
    /// Empfänger informieren aktiviert hat. Best-effort — Fehler hier dürfen
    /// die erfolgreiche Überweisung nicht überschreiben.
    private func triggerRecipientEmailIfRequested(request: TransferRequest) {
        guard informRecipient, recipientEmailIsValid else { return }
        let receipt = TransferEmailService.Receipt(
            amountEUR: request.amountEUR,
            recipientName: request.creditorName,
            recipientIban: request.creditorIban,
            purpose: request.remittance,
            scheduledDate: scheduledDate,
            senderBankName: senderBankName,
            senderSlotNickname: slot?.nickname?.nilIfEmpty,
            recipientBankName: recipientBankName.isEmpty ? nil : recipientBankName,
            executedAt: Date()
        )
        guard let pdfURL = TransferEmailService.writePDFReceipt(receipt) else {
            AppLogger.log("triggerRecipientEmail: PDF render failed", category: "Transfer", level: "WARN")
            return
        }
        _ = TransferEmailService.composeReceiptEmail(
            to: recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            recipientName: request.creditorName,
            amountEUR: request.amountEUR,
            pdfURL: pdfURL,
            senderSlotNickname: slot?.nickname?.nilIfEmpty
        )
    }

    // MARK: - Sanitizers

    private func sanitizeIban(_ s: String) -> String {
        // Erlaubt: A-Z, 0-9, Spaces. Alles andere strippen, uppercase,
        // dann in 4er-Gruppen formatieren.
        let filtered = s.uppercased().filter { c in
            c.isLetter || c.isNumber || c == " "
        }
        let clean = filtered.replacingOccurrences(of: " ", with: "")
        return formatIbanGroups(clean)
    }

    private func sanitizeDecimal(_ s: String) -> String {
        var r = s.filter { "0123456789,.".contains($0) }
        r = r.replacingOccurrences(of: ".", with: ",")
        if let firstComma = r.firstIndex(of: ",") {
            let before = r[..<firstComma]
            let after = r[r.index(after: firstComma)...].replacingOccurrences(of: ",", with: "")
            r = before + "," + after.prefix(2)
        }
        return String(r)
    }

    /// SEPA-PAIN.001: a-zA-Z0-9 + space + - / ? : ( ) , . ' und Umlaute.
    /// Max 140 Zeichen.
    private func sanitizePurpose(_ s: String) -> String {
        let extras: Set<Character> = [
            " ", "+", "-", "/", "?", ":", "(", ")", ",", ".", "'",
            "ä", "ö", "ü", "Ä", "Ö", "Ü", "ß"
        ]
        let filtered = s.filter { c in
            c.isLetter || c.isNumber || extras.contains(c)
        }
        return String(filtered.prefix(140))
    }

    // MARK: - Formatters

    private static let eurFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        return f
    }()

    fileprivate func formatEUR(_ amount: Decimal) -> String {
        Self.eurFormatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    fileprivate func formatAmountForInput(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

// MARK: - Autocomplete row

private struct AutocompleteRow: View {
    let candidate: TransferRecipientCandidate
    let highlighted: Bool
    let onPick: () -> Void
    let onHover: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                MerchantOrPersonIcon(name: candidate.creditorName, kind: candidate.kind, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.creditorName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.sbTextPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(shortIban(candidate.creditorIban))
                            .font(.system(size: 10.5).monospacedDigit())
                        if !candidate.lastBookingDate.isEmpty {
                            Text("·")
                            Text(L10n.t("zuletzt \(candidate.lastDateLabel())",
                                        "last \(candidate.lastDateLabel())"))
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(.sbTextSecondary)
                    .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlighted ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
    }

    private func shortIban(_ iban: String) -> String {
        let c = iban.replacingOccurrences(of: " ", with: "")
        guard c.count > 8 else { return iban }
        return "\(c.prefix(4)) … \(c.suffix(4))"
    }
}

// MARK: - SourcePill

private struct SourcePill: View {
    let slot: BankSlot?
    /// Alle eingerichteten Slots — bei >1 wird die Pill zum Dropdown.
    /// Single-Bank: bleibt read-only Pill wie bisher.
    var allSlots: [BankSlot] = []
    /// Wird mit dem neuen activeIndex gerufen. nil = read-only.
    var onSelect: ((Int) -> Void)? = nil

    @ObservedObject private var store = BankLogoStore.shared

    private var brand: BankLogoAssets.BankBrand? {
        BankLogoAssets.resolve(
            displayName: slot?.displayName,
            logoID: slot?.logoId,
            iban: slot?.iban
        )
    }

    private var hasMultipleSlots: Bool {
        allSlots.count > 1 && onSelect != nil
    }

    var body: some View {
        Group {
            if hasMultipleSlots {
                Menu {
                    ForEach(Array(allSlots.enumerated()), id: \.element.id) { idx, s in
                        Button {
                            onSelect?(idx)
                        } label: {
                            // Checkmark für aktiven Slot — macOS-Menu konvention.
                            let isActive = s.id == slot?.id
                            HStack {
                                Image(systemName: isActive ? "checkmark" : "")
                                    .frame(width: 12)
                                Text(labelFor(slot: s))
                            }
                        }
                    }
                } label: {
                    pillContent(showChevron: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                pillContent(showChevron: false)
            }
        }
        .onAppear { store.preload(brand: brand) }
    }

    private func pillContent(showChevron: Bool) -> some View {
        HStack(spacing: 6) {
            // Bank-Logo: NSImage VOR der SwiftUI-Konversion auf 14×14 setzen.
            // SwiftUI's Menu-Label auf macOS ignoriert .frame/.fixedSize beim
            // resizable Image und bläht es auf Container-Größe auf — pre-sized
            // NSImage hat intrinsische 14×14-Size und wird respektiert.
            if let brand, let img = store.image(for: brand), let sized = sizedLogo(img) {
                Image(nsImage: sized)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.sbTextSecondary)
                    .frame(width: 14, height: 14)
            }

            Text(labelFor(slot: slot))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.sbTextPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.sbTextSecondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.sbSurface)
        )
        .overlay(
            Capsule().stroke(Color.sbBorder, lineWidth: 0.5)
        )
        .contentShape(Capsule())
    }

    /// Kopiert das NSImage und setzt die intrinsische `size` auf 14×14.
    /// Verhindert die SwiftUI-Menu-Label-Inflation auf macOS.
    private func sizedLogo(_ src: NSImage) -> NSImage? {
        guard let copy = src.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 14, height: 14)
        return copy
    }

    private func labelFor(slot: BankSlot?) -> String {
        slot?.nickname?.nilIfEmpty
            ?? slot?.displayName.nilIfEmpty
            ?? L10n.t("Aktives Konto", "Active account")
    }
}

// MARK: - Shared atoms

private struct CapsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.sbTextSecondary.opacity(0.85))
    }
}

private struct MerchantOrPersonIcon: View {
    let name: String
    let kind: TransferRecipientKind
    let size: CGFloat

    @ObservedObject private var logoService = MerchantLogoService.shared

    private var key: String {
        logoService.effectiveLogoKey(
            normalizedMerchant: name.lowercased(),
            empfaenger: name,
            verwendungszweck: ""
        )
    }

    private var fallbackSymbol: String {
        switch kind {
        case .versicherung: return "shield"
        case .abo:          return "play.rectangle"
        case .vermieter:    return "house"
        case .online:       return "cart"
        case .privat:       return "person.crop.circle.fill"
        }
    }

    var body: some View {
        Group {
            if let img = logoService.image(for: key) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.7, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .onAppear { logoService.preload(normalizedMerchant: key) }
    }
}

/// Bank-Logo eines BankSlot. Resolves brand via BankLogoAssets, falls
/// kein Brand erkannt wird → SF-Symbol Fallback.
private struct SenderLogo: View {
    let slot: BankSlot?
    var size: CGFloat = 24

    @ObservedObject private var store = BankLogoStore.shared

    private var brand: BankLogoAssets.BankBrand? {
        BankLogoAssets.resolve(
            displayName: slot?.displayName,
            logoID: slot?.logoId,
            iban: slot?.iban
        )
    }

    var body: some View {
        Group {
            if let brand, let img = store.image(for: brand) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundColor(.sbTextSecondary)
                    .frame(width: size, height: size)
            }
        }
        .onAppear { store.preload(brand: brand) }
    }
}

private struct BankBrandIcon: View {
    let brand: BankLogoAssets.BankBrand
    let size: CGFloat

    @ObservedObject private var store = BankLogoStore.shared

    var body: some View {
        Group {
            if let img = store.image(for: brand) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: size * 0.65))
                    .foregroundColor(.sbTextSecondary)
                    .frame(width: size, height: size)
            }
        }
        .onAppear { store.preload(brand: brand) }
    }
}

private struct ProgressBar: View {
    let progress: CGFloat
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.sbBorder.opacity(0.5))
                Capsule().fill(accent)
                    .frame(width: geo.size.width * progress)
            }
        }
    }
}

private struct DemoBadge: View {
    var body: some View {
        Text("🎭 Demo")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.sbTextSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.sbSurfaceSoft)
            )
    }
}

private struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundColor(.sbTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed
                          ? Color.sbSurfaceSoft.opacity(0.7)
                          : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.sbBorder, lineWidth: 0.5)
            )
    }
}

// MARK: - KeyHandlingView (NSViewRepresentable für ↑/↓/Enter/Esc im Autocomplete)
//
// SwiftUI bietet keinen direkten Hook für Pfeil-Tasten ohne TextEditor-
// Submit-Override. Ein dünner NSView mit `keyDown`-Override fängt die Events
// während das TextField den Fokus hat. Aktiviert sich nur wenn die AC-Liste
// sichtbar ist.

private struct KeyHandlingView: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void
    let isActive: Bool

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onUp = onUp
        v.onDown = onDown
        v.onEnter = onEnter
        v.onEscape = onEscape
        v.isActive = isActive
        return v
    }

    func updateNSView(_ v: KeyCatcherView, context: Context) {
        v.onUp = onUp; v.onDown = onDown; v.onEnter = onEnter; v.onEscape = onEscape
        v.isActive = isActive
    }
}

private final class KeyCatcherView: NSView {
    var onUp:     (() -> Void)?
    var onDown:   (() -> Void)?
    var onEnter:  (() -> Void)?
    var onEscape: (() -> Void)?
    var isActive: Bool = false

    override var acceptsFirstResponder: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActive else { return false }
        guard event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case 126: onUp?();    return true   // ↑
        case 125: onDown?();  return true   // ↓
        case 36, 76: onEnter?(); return true // Enter / Numpad-Enter
        case 53:  onEscape?(); return true   // Esc
        default:  return false
        }
    }
}

// MARK: - IBAN-Helpers

/// Erwartete IBAN-Länge pro Country (Auszug). Default 22 (DE).
private func ibanLengthFor(country: String) -> Int {
    switch country.uppercased() {
    case "DE": return 22
    case "AT": return 20
    case "NL": return 18
    case "FR": return 27
    case "ES": return 24
    case "IT": return 27
    case "CH": return 21
    case "LU": return 20
    case "BE": return 16
    case "GB": return 22
    default:   return 22
    }
}

/// Formatiert IBAN in 4er-Gruppen für die Anzeige im Input.
private func formatIbanGroups(_ raw: String) -> String {
    let clean = raw.replacingOccurrences(of: " ", with: "").uppercased()
    var out = ""
    for (i, c) in clean.enumerated() {
        if i > 0, i % 4 == 0 { out.append(" ") }
        out.append(c)
    }
    return out
}
