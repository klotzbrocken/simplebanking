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
    /// Zweiter Parameter = in der Vorschau eingefrorenes Quellkonto → der Host validiert
    /// vor dem Bankaufruf, dass es noch das aktive Konto ist.
    var performSend: (@MainActor (TransferRequest, String) async -> TransferOutcome)? = nil
    /// Saldo + Dispo-Rahmen des aktiven Slots. Überweisungen darüber werden blockiert
    /// (dieselbe Hartgrenze wie in der großen `TransferSheet`). `nil` = unbekannt → keine Sperre.
    var availableLimit: Decimal? = nil
    /// Aktives Quellkonto (vom Host gesetzt, zusammen mit `availableLimit`). Wird beim
    /// Review eingefroren und beim Versand zur Konto-Validierung an den Host gereicht.
    var sourceSlotId: String = ""
    /// Schließt den Drawer (Host fährt die Popover-Höhe zurück).
    var onClose: (() -> Void)? = nil
    /// „+“ im Vorlagen-Bereich → springt in die Einstellungen (Vorlagen-Editor).
    var onAddTemplate: (() -> Void)? = nil
    /// Aus einer aufs Flyout gezogenen Rechnung erkannte Daten (PDF-Textebene/OCR).
    /// Wird beim Eintreffen in die Felder übernommen.
    var prefill: TransferClipboardParser.Parsed? = nil

    @ObservedObject private var favorites = QuickSendFavoritesStore.shared

    @State private var name: String = ""
    @State private var ibanText: String = ""
    @State private var amountInput: String = ""
    @State private var purpose: String = ""
    @State private var phase: Phase = .idle
    /// Der in der Confirm-Stufe geprüfte, fertig gebaute Request (rebuild-frei beim Senden).
    @State private var pendingRequest: TransferRequest? = nil
    /// Beim Review eingefrorenes Quellkonto — verhindert Versand von Konto B nach Wechsel.
    @State private var confirmedSourceSlotId: String? = nil

    /// Läuft gerade ein realer Versand (aus der Confirm-Stufe heraus)?
    @State private var isSending = false
    /// Empfänger-Vorschläge aus der Umsatzhistorie (Autocomplete).
    @State private var recipientCandidates: [TransferRecipientCandidate] = []
    /// Nach einer Auswahl die Liste geschlossen halten, bis der Name wieder editiert wird.
    @State private var acPicked = false
    /// Zuletzt per Autocomplete übernommener Name (unterscheidet Pick von Tippen).
    @State private var lastPickedName: String? = nil

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
        .task {
            loadRecipientCandidates()
            applyClipboardIfEmpty()
        }
        // Nach einer Auswahl bleibt die Liste zu; sobald der Nutzer den Namen wieder
        // ändert, schlagen wir erneut vor.
        .onChange(of: name) { newValue in
            if newValue != lastPickedName { acPicked = false }
        }
        // Aufs Flyout gezogene Rechnung → Felder übernehmen (überschreibt bewusst,
        // weil der Drop eine explizite Nutzeraktion ist).
        .onChange(of: prefill) { newValue in
            guard let p = newValue else { return }
            if let i = p.iban { ibanText = QuickSendFormatting.groupIban(i) }
            if let n = p.name { name = n; lastPickedName = n; acPicked = true }
            if let a = p.amount { amountInput = QuickSendFormatting.sanitizeAmountInput(a) }
            if let pu = p.purpose { purpose = pu }
        }
        .frame(height: Self.totalDrawerHeight)
    }

    // MARK: Autocomplete (Empfänger aus der Umsatzhistorie)

    /// Treffer nach Name, häufigste zuerst — gleiche Logik wie im großen TransferSheet.
    private var acMatches: [TransferRecipientCandidate] {
        let q = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2, !acPicked else { return [] }
        return recipientCandidates
            .filter { $0.creditorName.lowercased().contains(q) }
            .sorted { $0.frequency > $1.frequency }
            .prefix(3)
            .map { $0 }
    }

    @ViewBuilder
    private var autocompleteOverlay: some View {
        if !acMatches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(acMatches.enumerated()), id: \.offset) { _, c in
                    Button { pickCandidate(c) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.creditorName)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                            Text(QuickSendFormatting.maskedIban(c.creditorIban))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.sbSurface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.sbBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
            .offset(y: 33)
        }
    }

    /// Übernimmt Name + IBAN und schlägt Betrag/Zweck aus der Historie vor.
    private func pickCandidate(_ c: TransferRecipientCandidate) {
        name = c.creditorName
        ibanText = QuickSendFormatting.groupIban(c.creditorIban)
        if amountInput.trimmingCharacters(in: .whitespaces).isEmpty, let a = c.mostFrequentAmount {
            let value = NSDecimalNumber(decimal: a).doubleValue
            amountInput = QuickSendFormatting.sanitizeAmountInput(
                String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
            )
        }
        if purpose.trimmingCharacters(in: .whitespaces).isEmpty,
           let last = c.lastRemittance?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            purpose = last
        }
        lastPickedName = c.creditorName
        acPicked = true   // Liste schließen, bis der Nutzer den Namen wieder ändert
    }

    private func loadRecipientCandidates() {
        let bankId = UserDefaults.standard.bool(forKey: "demoMode") ? "demo" : "primary"
        recipientCandidates = (try? TransferRecipientStore.loadCandidates(
            slotId: sourceSlotId, bankId: bankId
        )) ?? []
    }

    /// Übernimmt Überweisungsdaten aus der Zwischenablage (Name/IBAN/Betrag/Zweck —
    /// auch als zusammenhängend kopierter Block). Bewusst konservativ: nur beim
    /// Öffnen, nur wenn das Formular NOCH LEER ist und eine gültige IBAN erkannt
    /// wurde — sonst würde die Zwischenablage ungefragt ins Zahlungsformular tropfen.
    private func applyClipboardIfEmpty() {
        guard name.isEmpty, ibanText.isEmpty, amountInput.isEmpty, purpose.isEmpty else { return }
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let parsed = TransferClipboardParser.parse(raw)
        guard let detectedIban = parsed.iban else { return }

        ibanText = QuickSendFormatting.groupIban(detectedIban)
        if let n = parsed.name { name = n }
        if let a = parsed.amount { amountInput = QuickSendFormatting.sanitizeAmountInput(a) }
        if let p = parsed.purpose { purpose = p }
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 7) {
            // Reihe 1: Name + Betrag
            HStack(spacing: 7) {
                TextField(L10n.t("Name", "Name"), text: $name, prompt: prompt("Name", "Name"))
                    .textFieldStyle(.plain)
                    .font(fieldFont())
                    .foregroundColor(fieldTextColor)
                    .overlay(themedPlaceholder("Name", "Name", visible: name.isEmpty))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(fieldBackground())
                    // Autocomplete aus der Umsatzhistorie — wie im großen TransferSheet.
                    .overlay(alignment: .topLeading) { autocompleteOverlay }

                HStack(spacing: 4) {
                    TextField(L10n.t("Betrag", "Amount"), text: $amountInput, prompt: prompt("Betrag", "Amount"))
                        .textFieldStyle(.plain)
                        .font(fieldFont(mono: true))
                        .foregroundColor(fieldTextColor)
                        .overlay(themedPlaceholder("Betrag", "Amount", visible: amountInput.isEmpty, trailing: true))
                        .multilineTextAlignment(.trailing)
                        .onChange(of: amountInput) { newValue in
                            let s = QuickSendFormatting.sanitizeAmountInput(newValue)
                            if s != newValue { amountInput = s }
                        }
                    Text("€")
                        .font(fieldFont())
                        .foregroundColor(lofi ? Color.themedInk.opacity(0.7) : .sbTextSecondary)
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
            // Die Vorschlagsliste ragt über die Zeile hinaus — der zIndex muss an die
            // ZEILE (Geschwister im VStack), sonst übermalen IBAN/Betreff sie.
            .zIndex(10)

            // Reihe 2: IBAN + grüner Haken
            HStack(spacing: 8) {
                TextField(L10n.t("IBAN", "IBAN"), text: $ibanText, prompt: prompt("IBAN", "IBAN"))
                    .textFieldStyle(.plain)
                    .font(fieldFont(mono: true))
                    .foregroundColor(fieldTextColor)
                    .overlay(themedPlaceholder("IBAN", "IBAN", visible: ibanText.isEmpty))
                    .onChange(of: ibanText) { newValue in
                        let grouped = QuickSendFormatting.groupIban(newValue)
                        if grouped != newValue { ibanText = grouped }
                    }
                if ibanValid {
                    // BTX: Text-Haken statt SF-Symbol.
                    if lofi {
                        Text("OK")
                            .font(ThemeFonts.flyoutBody(size: 13))
                            .foregroundColor(.themedIncome)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.sbGreenStrong)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(fieldBackground(border: ibanValid ? .sbGreenStrong : .sbBorder))

            // Reihe 3: Betreff
            TextField(L10n.t("Betreff", "Reference"), text: $purpose, prompt: prompt("Betreff", "Reference"))
                .textFieldStyle(.plain)
                .font(fieldFont())
                .foregroundColor(fieldTextColor)
                .overlay(themedPlaceholder("Betreff", "Reference", visible: purpose.isEmpty))
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
        let radius = ThemeChrome.cornerRadius(7)
        return Group {
            if lofi {
                // BTX: kein Smiley — leeres Feld als Platzhalter.
                Color.clear.frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(Color.themedInk.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.themedInk.opacity(0.35), lineWidth: 1))
                    )
            } else {
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
        }
    }

    /// „+“ → öffnet die Einstellungen am Vorlagen-Editor.
    private var addTemplateButton: some View {
        let radius = ThemeChrome.cornerRadius(7)
        return Button { onAddTemplate?() } label: {
            Text("+")
                .font(ThemeFonts.rowHeading(size: 12, weight: .semibold, lofiSize: 16))
                .foregroundColor(lofi ? Color.themedInk.opacity(0.7) : .sbTextSecondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundColor(lofi ? Color.themedInk.opacity(0.4) : .sbBorder)
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
                    .font(ThemeFonts.rowBody(size: 12, weight: .semibold, lofiSize: 15))
                    .textCase(ThemeChrome.textCase)
                if lofi {
                    Text(">").font(ThemeFonts.flyoutBody(size: 15))
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                // BTX: aktiv = gefüllter Block in Leitfarbe; inaktiv = heller Block mit
                // Tintenrahmen (klar lesbar, aber sichtbar „noch nicht bereit").
                RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(7))
                    .fill(lofi
                          ? (canSubmit ? Color.themedAccent : Color.white.opacity(0.4))
                          : (canSubmit ? Color.sbRedStrong : Color.sbSurfaceSoft))
                    .overlay(
                        (lofi && !canSubmit)
                        ? RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(7))
                            .stroke(Color.themedInk.opacity(0.6), lineWidth: 2)
                        : nil
                    )
            )
            .foregroundColor(lofi
                             ? (canSubmit ? Color.themedSurface : Color.themedInk.opacity(0.7))
                             : (canSubmit ? .white : .sbTextSecondary))
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
                Button { phase = .idle; confirmedSourceSlotId = nil } label: {
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

    /// Nur Lo-Fi (BTX) → Drawer in Block-Optik (eckig, VT323, helle Felder).
    /// Farb-Themes behalten die Default-Felder.
    private var themed: Bool { !ThemeManager.shared.currentTheme.isDefault }
    private var lofi: Bool { themed && ThemeChrome.lofi }

    /// Schrift der Eingabefelder — VT323 bei aktivem Theme, sonst System.
    private func fieldFont(mono: Bool = false) -> Font {
        if lofi { return ThemeFonts.flyoutBody(size: 15) }
        return mono ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5)
    }
    private var fieldTextColor: Color { lofi ? .themedInk : .primary }

    /// Platzhalter-Behandlung: der System-Prompt folgt dem (ggf. dunklen) Appearance-
    /// Modus und wäre auf dem hellen BTX-Feld weiß = unlesbar. Eine Prompt-Farbe wird
    /// vom Plain-TextField auf macOS ignoriert — deshalb wird der System-Platzhalter
    /// bei aktivem Theme mit `Text("")` unterdrückt und ein eigener Text übergelegt.
    private func prompt(_ de: String, _ en: String) -> Text? {
        lofi ? Text("") : nil
    }

    /// Eigener, lesbarer Platzhalter für die Theme-Felder (nur solange leer).
    @ViewBuilder
    private func themedPlaceholder(_ de: String, _ en: String, visible: Bool, trailing: Bool = false) -> some View {
        if lofi && visible {
            Text(L10n.t(de, en))
                .font(ThemeFonts.flyoutBody(size: 15))
                .foregroundColor(Color.themedInk.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                .allowsHitTesting(false)
        }
    }

    private func fieldBackground(border: Color = .sbBorder) -> some View {
        // Validierungsränder (rot/grün) bleiben auch im Theme erhalten; nur der
        // neutrale Standardrand und die Fläche folgen dem Theme.
        //
        // BTX-Lo-Fi: heller Block auf dem grauen Schirm mit hartem 2-px-Tintenrahmen —
        // wie ein Eingabebereich einer BTX-Seite, nicht wie ein modernes Soft-Feld.
        // Der helle Grund liefert zugleich den Kontrast für Text und Platzhalter.
        let radius = ThemeChrome.cornerRadius(7)
        let isNeutral = border == Color.sbBorder
        let fill = lofi ? Color.white.opacity(0.65) : Color.sbSurfaceSoft
        let stroke = (lofi && isNeutral) ? Color.themedInk : border
        return RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke, lineWidth: lofi ? 2 : 1))
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
        confirmedSourceSlotId = sourceSlotId   // Quellkonto einfrieren
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
        let frozenSlot = confirmedSourceSlotId ?? sourceSlotId
        isSending = true
        Task { @MainActor in
            let outcome = await performSend?(request, frozenSlot)
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
