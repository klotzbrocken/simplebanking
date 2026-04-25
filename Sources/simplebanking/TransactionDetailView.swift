import AppKit
import SwiftUI

// MARK: - Savings Bookmarks

enum SavingsBookmarks {
    private static let key = "savingsBookmarkedTransactions"

    static func isBookmarked(_ transactionId: String) -> Bool {
        let bookmarks = UserDefaults.standard.stringArray(forKey: key) ?? []
        return bookmarks.contains(transactionId)
    }

    static func toggle(_ transactionId: String) {
        var bookmarks = UserDefaults.standard.stringArray(forKey: key) ?? []
        if let index = bookmarks.firstIndex(of: transactionId) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(transactionId)
        }
        UserDefaults.standard.set(bookmarks, forKey: key)
    }

    static func allBookmarked() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}

// MARK: - Transaction Detail View

struct TransactionDetailView: View {
    let transaction: TransactionsResponse.Transaction
    var bankId: String = "primary"
    var initialUserNote: String? = nil
    var isUnread: Bool = false
    var hasReminder: Bool = false
    var reminderId: String? = nil
    var onEnrichmentChanged: (() -> Void)? = nil

    // Local mutable state mirroring enrichment props — updated optimistically on user action
    @State private var localIsUnread: Bool = false
    @State private var localHasReminder: Bool = false
    @State private var localReminderId: String? = nil
    @State private var showReminderPicker: Bool = false
    @State private var reminderPickerDate: Date = {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.day = (c.day ?? 1) + 1; c.hour = 9; c.minute = 0
        return Calendar.current.date(from: c) ?? Date()
    }()

    @AppStorage(MerchantResolver.pipelineEnabledKey) private var effectiveMerchantPipelineEnabled: Bool = true
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var logoService = MerchantLogoService.shared
    @State private var customLogo: NSImage? = nil
    @State private var isLogoDropTargeted: Bool = false
    @State private var isSavingsBookmarked: Bool = false
    @State private var displayedMerchantInput: String = ""
    @State private var rulePatternInput: String = ""
    @State private var merchantEditStatus: String = ""
    @State private var isApplyingMerchantChange: Bool = false
    @State private var selectedCategory: TransactionCategory = .sonstiges
    @State private var hasCategoryOverride: Bool = false
    @State private var isApplyingCategoryChange: Bool = false
    @State private var categoryEditStatus: String = ""
    @State private var categorySelectionReady: Bool = false
    // Enrichment state
    @State private var noteText: String = ""
    @State private var isSavingNote: Bool = false
    @State private var noteStatus: String = ""
    @State private var attachments: [AttachmentInfo] = []
    @State private var isDroppingFile: Bool = false
    @State private var attachmentError: String = ""
    @State private var isLoadingAttachments: Bool = false
    
    private static let inputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let outputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private func formatDate(_ dateStr: String?) -> String {
        guard let dateStr = dateStr else { return "—" }
        guard let date = Self.inputDateFormatter.date(from: dateStr) else { return dateStr }
        return Self.outputDateFormatter.string(from: date)
    }
    
    private func formatAmount() -> String {
        guard let amount = transaction.amount else { return "—" }
        let value = AmountParser.parse(amount.amount)
        let nf = NumberFormatter()
        nf.locale = Locale(identifier: "de_DE")
        nf.numberStyle = .currency
        nf.currencyCode = amount.currency
        return nf.string(from: NSNumber(value: value)) ?? "\(amount.amount) \(amount.currency)"
    }
    
    private var amountColor: Color {
        guard let amount = transaction.amount else { return .primary }
        let value = AmountParser.parse(amount.amount)
        return value < 0 ? Color(NSColor.systemRed) : Color(NSColor.systemGreen)
    }
    
    private var isOutgoing: Bool {
        guard let amount = transaction.amount else { return true }
        let value = AmountParser.parse(amount.amount)
        return value < 0
    }

    private var counterpartyName: String {
        if effectiveMerchantPipelineEnabled {
            let merchant = MerchantResolver.resolve(transaction: transaction).effectiveMerchant
            if !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return merchant
            }
        }
        return isOutgoing
            ? (transaction.creditor?.name ?? transaction.debtor?.name ?? "—")
            : (transaction.debtor?.name ?? transaction.creditor?.name ?? "—")
    }

    private var txFingerprint: String {
        TransactionRecord.fingerprint(for: transaction)
    }

    private var txSlotId: String {
        transaction.slotId ?? TransactionsDatabase.activeSlotId
    }

    private var empfaengerText: String {
        [transaction.creditor?.name, transaction.debtor?.name]
            .compactMap { $0 }.joined(separator: " ")
    }

    private var verwendungszweckText: String {
        ((transaction.remittanceInformation ?? []) + [transaction.additionalInformation])
            .compactMap { $0 }.joined(separator: " ")
    }

    private var normalizedMerchant: String {
        MerchantResolver.resolve(transaction: transaction).normalizedMerchant
    }

    private var logoKey: String {
        logoService.effectiveLogoKey(
            normalizedMerchant: normalizedMerchant,
            empfaenger: empfaengerText,
            verwendungszweck: verwendungszweckText
        )
    }

    private var merchantLogo: NSImage? {
        logoService.image(for: logoKey)
    }

    /// Anzeige-Logo: Custom (Händler-weit) > Service-Cache > nil (→ Kategorie-Icon)
    private var displayLogo: NSImage? { merchantLogo }

    private var hasCustomLogo: Bool { logoService.hasCustomLogo(forKey: logoKey) }

    private func loadCustomLogo() {
        // Merchant custom logos are loaded into MerchantLogoService at startup.
        // Per-txId legacy entries are kept for backward compat but no longer primary.
        let txId = txFingerprint
        Task.detached {
            guard let data = TransactionsDatabase.loadCustomLogo(txId: txId) else { return }
            // Migrate old per-txId logo to merchant-wide storage if not yet done
            let key = await MainActor.run { self.logoKey }
            if !TransactionsDatabase.loadAllMerchantCustomLogos().keys.contains(key) {
                await MainActor.run {
                    MerchantLogoService.shared.setCustomLogo(data: data, forKey: key)
                }
            }
        }
    }

    private func applyLogoURL(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        // Save merchant-wide (all transactions of this merchant get the logo)
        MerchantLogoService.shared.setCustomLogo(data: data, forKey: logoKey)
        // Keep per-txId entry for backward compat
        let txId = txFingerprint
        Task.detached { TransactionsDatabase.saveCustomLogo(txId: txId, data: data) }
    }

    private func deleteCustomLogo() {
        MerchantLogoService.shared.removeCustomLogo(forKey: logoKey)
        let txId = txFingerprint
        Task.detached { TransactionsDatabase.deleteCustomLogo(txId: txId) }
    }

    private func openLogoPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .svg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Logo für diesen Händler auswählen (gilt für alle Buchungen)"
        if panel.runModal() == .OK, let url = panel.url {
            applyLogoURL(url)
        }
    }

    private func handleLogoDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in applyLogoURL(url) }
                }
                return true
            }
        }
        return false
    }

    private func initializeCategorySelectionIfNeeded() {
        guard !categorySelectionReady else { return }
        selectedCategory = TransactionCategorizer.category(for: transaction)
        hasCategoryOverride = TransactionCategorizer.hasOverride(txID: txFingerprint, slotId: txSlotId)
        categorySelectionReady = true
    }

    private func applyCategorySelection(_ newCategory: TransactionCategory) {
        let autoCategory = TransactionCategorizer.autoCategory(for: transaction)
        let txID = txFingerprint
        let capturedSlotId = txSlotId
        isApplyingCategoryChange = true
        categoryEditStatus = "Kategorie wird aktualisiert..."

        Task.detached {
            // Slot-scoped override (Composite-Key seit v19) — sonst leakt der
            // Override auf identische Tx in anderen Slots.
            if newCategory == autoCategory {
                _ = TransactionCategorizer.removeOverride(txID: txID, slotId: capturedSlotId)
            } else {
                TransactionCategorizer.saveOverride(txID: txID, slotId: capturedSlotId, category: newCategory)
            }

            do {
                // Update only this transaction's category row instead of rebuilding all.
                try TransactionsDatabase.updateKategorie(txID: txID, slotId: capturedSlotId, kategorie: newCategory.displayName)
                await MainActor.run {
                    NotificationCenter.default.post(name: Notification.Name("TransactionCategoriesChanged"), object: nil)
                    hasCategoryOverride = TransactionCategorizer.hasOverride(txID: txID, slotId: capturedSlotId)
                    categoryEditStatus = hasCategoryOverride
                        ? "Kategorie überschrieben."
                        : "Automatische Kategorie aktiv."
                    isApplyingCategoryChange = false
                }
            } catch {
                await MainActor.run {
                    categoryEditStatus = "Kategorie konnte nicht gespeichert werden: \(error.localizedDescription)"
                    isApplyingCategoryChange = false
                }
            }
        }
    }

    private func resetCategoryOverride() {
        guard hasCategoryOverride || TransactionCategorizer.hasOverride(txID: txFingerprint, slotId: txSlotId) else {
            categoryEditStatus = "Für diese Buchung ist kein Kategorie-Override vorhanden."
            return
        }
        let autoCategory = TransactionCategorizer.autoCategory(for: transaction)
        if selectedCategory == autoCategory {
            applyCategorySelection(autoCategory)
        } else {
            selectedCategory = autoCategory
        }
    }

    private func applyMerchantChange(successMessage: String) {
        isApplyingMerchantChange = true
        merchantEditStatus = "Aktualisiere gespeicherte Umsätze..."

        Task.detached {
            do {
                try TransactionsDatabase.refreshEffectiveMerchantData()
                NotificationCenter.default.post(name: Notification.Name("MerchantRulesChanged"), object: nil)
                let refreshedMerchant = MerchantResolver.resolve(transaction: transaction).effectiveMerchant
                await MainActor.run {
                    displayedMerchantInput = refreshedMerchant
                    merchantEditStatus = successMessage
                    isApplyingMerchantChange = false
                }
            } catch {
                await MainActor.run {
                    merchantEditStatus = "Aktualisierung fehlgeschlagen: \(error.localizedDescription)"
                    isApplyingMerchantChange = false
                }
            }
        }
    }

    private func saveSingleOverride() {
        let merchant = displayedMerchantInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchant.isEmpty else {
            merchantEditStatus = "Bitte einen Empfänger angeben."
            return
        }
        MerchantResolver.saveOverride(txID: txFingerprint, slotId: txSlotId, merchant: merchant)
        applyMerchantChange(successMessage: "Korrektur für diese Buchung gespeichert.")
    }

    private func saveRule() {
        let merchant = displayedMerchantInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = rulePatternInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchant.isEmpty else {
            merchantEditStatus = "Bitte einen Empfänger angeben."
            return
        }
        guard !pattern.isEmpty else {
            merchantEditStatus = "Bitte ein Suchmuster für die Regel angeben."
            return
        }
        guard MerchantResolver.saveRule(pattern: pattern, merchant: merchant, scope: .verwendungszweck, matchType: .contains) != nil else {
            merchantEditStatus = "Regel konnte nicht gespeichert werden."
            return
        }
        applyMerchantChange(successMessage: "Regel gespeichert (nur Verwendungszweck) und auf Umsätze angewendet.")
    }

    private func removeSingleOverride() {
        let removedOverride = MerchantResolver.removeOverride(txID: txFingerprint, slotId: txSlotId)
        if removedOverride {
            applyMerchantChange(successMessage: "Buchungs-Override entfernt.")
            return
        }

        let remittance = (transaction.remittanceInformation ?? []).joined(separator: " ")
        if let matchingRule = MerchantResolver.firstMatchingRule(
            empfaenger: transaction.creditor?.name,
            absender: transaction.debtor?.name,
            verwendungszweck: remittance,
            additionalInformation: transaction.additionalInformation
        ), MerchantResolver.removeRule(id: matchingRule.id) {
            applyMerchantChange(successMessage: "Kein Einzel-Override gefunden, aber passende Regel wurde entfernt.")
            return
        }

        merchantEditStatus = "Für diese Buchung ist kein Override gespeichert."
    }
    
    private func saveNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingNote = true
        let capturedTxID = txFingerprint
        let capturedSlotId = txSlotId
        let capturedBankId = bankId
        Task.detached {
            try? TransactionsDatabase.saveNote(txID: capturedTxID, slotId: capturedSlotId, note: trimmed.isEmpty ? nil : trimmed, bankId: capturedBankId)
            await MainActor.run {
                isSavingNote = false
                noteStatus = trimmed.isEmpty ? "Notiz gelöscht." : "Notiz gespeichert."
                onEnrichmentChanged?()
            }
        }
    }

    private func loadAttachments() {
        isLoadingAttachments = true
        let capturedTxID = txFingerprint
        let capturedSlotId = txSlotId
        let capturedBankId = bankId
        Task.detached {
            let atts = (try? TransactionsDatabase.loadAttachments(txID: capturedTxID, slotId: capturedSlotId, bankId: capturedBankId)) ?? []
            await MainActor.run {
                attachments = atts
                isLoadingAttachments = false
            }
        }
    }

    private func deleteAttachment(_ att: AttachmentInfo) {
        let capturedTxID = txFingerprint
        let capturedSlotId = txSlotId
        let capturedBankId = bankId
        Task.detached {
            try? TransactionsDatabase.deleteAttachment(id: att.id, txID: capturedTxID, slotId: capturedSlotId, bankId: capturedBankId)
            await MainActor.run {
                attachments.removeAll { $0.id == att.id }
                onEnrichmentChanged?()
            }
        }
    }

    private func openAttachment(_ att: AttachmentInfo) {
        guard let fileURL = try? TransactionsDatabase.resolveAttachmentURL(txID: txFingerprint, slotId: txSlotId, bankId: bankId, filename: att.filename) else { return }
        NSWorkspace.shared.open(fileURL)
    }

    private func openAttachmentFolder() {
        guard let dir = try? TransactionsDatabase.attachmentsDirectory(txID: txFingerprint, slotId: txSlotId, bankId: bankId) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard attachments.count < 3 else {
            attachmentError = "Maximal 3 Anhänge pro Buchung erlaubt."
            return false
        }
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        do {
                            let att = try TransactionsDatabase.addAttachment(txID: txFingerprint, slotId: txSlotId, bankId: bankId, sourceURL: url)
                            attachments.append(att)
                            attachmentError = ""
                            onEnrichmentChanged?()
                        } catch {
                            attachmentError = error.localizedDescription
                        }
                    }
                }
                handled = true
                if attachments.count >= 3 { break }
            }
        }
        return handled
    }

    private func formatPurposeCode(_ code: String?) -> String {
        guard let code = code else { return "—" }
        // Common PSD2 purpose codes
        let codes: [String: String] = [
            "RINP": "Eingehende Zahlung",
            "SALA": "Gehalt",
            "PENS": "Rente",
            "SSBE": "Sozialleistung",
            "TAXS": "Steuer",
            "VATX": "Mehrwertsteuer",
            "GOVT": "Behördenzahlung",
            "LOAN": "Darlehen",
            "RENT": "Miete",
            "SUPP": "Lieferant",
            "CASH": "Bargeld",
            "CCRD": "Kreditkarte",
            "DCRD": "Debitkarte",
            "OTHR": "Sonstiges"
        ]
        return codes[code] ?? code
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Buchungsdetails")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                // Unread indicator — always visible, toggleable
                Button(action: { toggleUnread() }) {
                    Image(systemName: localIsUnread ? "circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundColor(localIsUnread ? .accentColor : .secondary.opacity(0.5))
                }
                .buttonStyle(PlainButtonStyle())
                .help(localIsUnread ? "Als gelesen markieren" : "Als ungelesen markieren")
                // Reminder indicator
                Button(action: {
                    if localHasReminder {
                        removeDetailReminder()
                    } else {
                        showReminderPicker = true
                    }
                }) {
                    Image(systemName: localHasReminder ? "bell.fill" : "bell")
                        .font(.system(size: 16))
                        .foregroundColor(localHasReminder ? .orange : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(localHasReminder ? "Erinnerung entfernen" : "Erinnerung setzen")
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            ScrollView {
                VStack(spacing: 16) {
                    // Betrag-Kachel mit Logo / Kategorie-Icon
                    HStack(spacing: 16) {
                        // Logo-Bereich: Klick = Dateiauswahl, Drag & Drop = eigenes Logo
                        ZStack {
                            if let logo = displayLogo {
                                Image(nsImage: logo)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
                            } else {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(width: 48, height: 48)
                                    .overlay(
                                        Image(systemName: selectedCategory.icon)
                                            .font(.system(size: 22))
                                            .foregroundColor(.secondary)
                                    )
                            }
                            // Drop-Highlight
                            if isLogoDropTargeted {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.accentColor.opacity(0.15))
                                    )
                            }
                        }
                        .frame(width: 48, height: 48)
                        .help("Klick oder Drag & Drop für eigenes Logo")
                        .onTapGesture { openLogoPicker() }
                        .onDrop(of: ["public.file-url"], isTargeted: $isLogoDropTargeted) { providers in
                            handleLogoDrop(providers)
                        }
                        .overlay(alignment: .topTrailing) {
                            if hasCustomLogo {
                                Button(action: { deleteCustomLogo() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.sbRedStrong).padding(2))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .offset(x: 6, y: -6)
                                .help("Benutzerdefiniertes Logo löschen")
                            }
                        }

                        Text(formatAmount())
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(amountColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.cardBackground)
                    )
                    .onAppear {
                        MerchantLogoService.shared.preload(normalizedMerchant: logoKey)
                        loadCustomLogo()
                    }
                    
                    // Details Card
                    VStack(alignment: .leading, spacing: 16) {
                        // 1) Begünstigter/Zahlungspflichtiger (komplett)
                        // Bei Ausgabe: creditor ist Empfänger, bei Eingang: debtor ist Absender
                        DetailRow(
                            label: isOutgoing ? "Begünstigter" : "Zahlungspflichtiger",
                            value: counterpartyName
                        )
                        
                        Divider()
                        
                        // 2) Buchungstag und Valutadatum
                        HStack(spacing: 20) {
                            DetailColumn(label: "Buchungstag", value: formatDate(transaction.bookingDate))
                            DetailColumn(label: "Valutadatum", value: formatDate(transaction.valueDate))
                        }
                        
                        Divider()
                        
                        // 3) Verwendungszweck
                        DetailRow(
                            label: "Verwendungszweck",
                            value: (transaction.remittanceInformation ?? []).joined(separator: " ")
                        )
                        
                        Divider()
                        
                        // 4) Buchungstext und Kategorie
                        HStack(alignment: .top, spacing: 20) {
                            DetailColumn(
                                label: "Buchungstext",
                                value: transaction.additionalInformation ?? "—"
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Kategorie")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)

                                Picker("", selection: $selectedCategory) {
                                    ForEach(TransactionCategory.allCases, id: \.self) { category in
                                        Label(category.displayName, systemImage: category.icon)
                                            .tag(category)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .labelsHidden()
                                .disabled(isApplyingCategoryChange)

                                if let purposeCode = transaction.purposeCode,
                                   !purposeCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Bankcode: \(formatPurposeCode(purposeCode))")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        Divider()
                        
                        // 5) IBAN und BIC (SWIFT-Code)
                        // Bei Ausgabe: creditor (Empfänger), bei Eingang: debtor (Absender)
                        HStack(spacing: 20) {
                            DetailColumn(
                                label: "IBAN",
                                value: isOutgoing
                                    ? (transaction.creditor?.iban ?? transaction.debtor?.iban ?? "—")
                                    : (transaction.debtor?.iban ?? transaction.creditor?.iban ?? "—")
                            )
                            DetailColumn(
                                label: "BIC (SWIFT)",
                                value: isOutgoing
                                    ? (transaction.creditor?.bic ?? transaction.debtor?.bic ?? "—")
                                    : (transaction.debtor?.bic ?? transaction.creditor?.bic ?? "—")
                            )
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.cardBackground)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Kategorie")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Image(systemName: selectedCategory.icon)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Text(selectedCategory.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()

                            if hasCategoryOverride {
                                Button("Automatik verwenden") {
                                    resetCategoryOverride()
                                }
                                .buttonStyle(.bordered)
                                .disabled(isApplyingCategoryChange)
                            }
                        }

                        if isApplyingCategoryChange {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Speichere Kategorie...")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !categoryEditStatus.isEmpty {
                            Text(categoryEditStatus)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.cardBackground)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Angezeigter Empfänger")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        TextField("Empfänger", text: $displayedMerchantInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        TextField("Regel (Text im Verwendungszweck)", text: $rulePatternInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .disabled(!effectiveMerchantPipelineEnabled)

                        HStack(spacing: 8) {
                            Button("Nur diese Buchung korrigieren") {
                                saveSingleOverride()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Als Regel speichern") {
                                saveRule()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!effectiveMerchantPipelineEnabled)

                            Button("Override entfernen") {
                                removeSingleOverride()
                            }
                            .buttonStyle(.bordered)
                        }

                        if isApplyingMerchantChange {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Wende Änderungen an...")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !merchantEditStatus.isEmpty {
                            Text(merchantEditStatus)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        if !effectiveMerchantPipelineEnabled {
                            Text("Hinweis: Die Intermediär-Auflösung ist deaktiviert. Regeln werden erst im aktivierten Modus angewendet.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.cardBackground)
                    )
                    
                    // Notiz
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "pencil.line")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text("Notiz")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            if isSavingNote {
                                ProgressView().controlSize(.small)
                            }
                        }

                        TextEditor(text: $noteText)
                            .font(.system(size: 13))
                            .frame(minHeight: 60, maxHeight: 120)
                            .scrollContentBackground(.hidden)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)

                        HStack {
                            if !noteStatus.isEmpty {
                                Text(noteStatus)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Speichern") { saveNote() }
                                .buttonStyle(.borderedProminent)
                                .disabled(isSavingNote)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))

                    // Anhänge
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "paperclip")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text("Anhänge")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(attachments.count)/3")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            if !attachments.isEmpty {
                                Button(action: openAttachmentFolder) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .foregroundColor(.secondary)
                                .help("Anhang-Ordner öffnen")
                            }
                        }

                        if attachments.isEmpty && !isLoadingAttachments {
                            Text("Datei hierher ziehen (PDF, Bild) — max. 3 Dateien, 3 MB")
                                .font(.system(size: 12))
                                .foregroundColor(Color(NSColor.placeholderTextColor))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .multilineTextAlignment(.center)
                        } else {
                            ForEach(attachments) { att in
                                HStack(spacing: 8) {
                                    Image(systemName: att.mimeType == "application/pdf" ? "doc.fill" : "photo.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(att.filename)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: att.fileSize, countStyle: .file))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button(action: { openAttachment(att) }) {
                                        Image(systemName: "eye")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .foregroundColor(.secondary)
                                    Button(action: { deleteAttachment(att) }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .foregroundColor(Color(NSColor.systemRed))
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        if !attachmentError.isEmpty {
                            Text(attachmentError)
                                .font(.system(size: 11))
                                .foregroundColor(Color(NSColor.systemOrange))
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDroppingFile ? Color.themeAccent.opacity(0.08) : Color.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isDroppingFile ? Color.themeAccent : Color.clear, lineWidth: 1.5)
                            )
                    )
                    .onDrop(of: ["public.file-url"], isTargeted: $isDroppingFile, perform: handleDrop)

                    // Sparrate-Bookmark (nur für Ausgaben)
                    if isOutgoing {
                        Button(action: {
                            let txId = transaction.stableIdentifier
                            SavingsBookmarks.toggle(txId)
                            isSavingsBookmarked.toggle()
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: isSavingsBookmarked ? "bookmark.fill" : "bookmark")
                                    .font(.system(size: 18))
                                    .foregroundColor(isSavingsBookmarked ? .cyan : .secondary)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(isSavingsBookmarked ? "Als Sparrate markiert" : "Als Sparrate markieren")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text("Zählt im MMI als Sparen, nicht als Ausgabe")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                if isSavingsBookmarked {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.cyan)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isSavingsBookmarked ? Color.cyan.opacity(0.1) : Color.cardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isSavingsBookmarked ? Color.cyan.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 420, height: 560)
        .background(Color.panelBackground)
        .onAppear {
            // Sync local enrichment state from passed props
            localIsUnread = isUnread
            localHasReminder = hasReminder
            localReminderId = reminderId
            isSavingsBookmarked = SavingsBookmarks.isBookmarked(transaction.stableIdentifier)
            displayedMerchantInput = counterpartyName
            rulePatternInput = MerchantResolver.suggestedRulePattern(for: transaction)
            initializeCategorySelectionIfNeeded()
            noteText = initialUserNote ?? ""
            loadAttachments()
        }
        .onChange(of: selectedCategory) { newCategory in
            guard categorySelectionReady else { return }
            applyCategorySelection(newCategory)
        }
        .sheet(isPresented: $showReminderPicker) {
            ReminderPickerSheet(
                date: $reminderPickerDate,
                onConfirm: { date in
                    showReminderPicker = false
                    createDetailReminder(dueDate: date)
                },
                onCancel: { showReminderPicker = false }
            )
        }
    }

    // MARK: - Enrichment actions (executed locally in detail view)

    private func toggleUnread() {
        localIsUnread.toggle()
        let txID = txFingerprint
        try? TransactionsDatabase.setUnread(txID: txID, slotId: txSlotId, bankId: bankId, value: localIsUnread)
        onEnrichmentChanged?()
    }

    private func createDetailReminder(dueDate: Date) {
        let txID = txFingerprint
        let slotId = txSlotId
        let resolution = MerchantResolver.resolve(transaction: transaction)
        let merchant = resolution.effectiveMerchant
        let amountStr = formatAmount()
        let title = "\(merchant) \(amountStr)".trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let id = try await ReminderService.shared.createReminder(title: title, dueDate: dueDate)
                // DB-write rückwärtskompensieren wenn er fehlschlägt — sonst hätten
                // wir einen orphaned EventKit-Reminder, den die App nicht kennt
                // (User sieht ihn in Reminders.app, aber nicht in simplebanking).
                do {
                    try TransactionsDatabase.setReminderId(txID: txID, slotId: slotId, bankId: bankId, reminderId: id)
                    await MainActor.run {
                        localReminderId = id
                        localHasReminder = true
                        onEnrichmentChanged?()
                    }
                } catch {
                    AppLogger.log("Reminder DB write failed, rolling back EventKit reminder: \(error.localizedDescription)",
                                  category: "Reminder", level: "ERROR")
                    await ReminderService.shared.deleteReminder(id: id)
                }
            } catch {
                AppLogger.log("Reminder create failed: \(error.localizedDescription)",
                              category: "Reminder", level: "WARN")
            }
        }
    }

    private func removeDetailReminder() {
        let txID = txFingerprint
        let slotId = txSlotId
        let capturedId = localReminderId
        localReminderId = nil
        localHasReminder = false
        Task {
            if let id = capturedId {
                await ReminderService.shared.deleteReminder(id: id)
            }
            // DB-clear darf fehlschlagen (z.B. DB locked) — pruneStaleReminders()
            // beim nächsten App-Start räumt orphaned reminder_ek_id-Werte ohne
            // existierenden EventKit-Reminder auf. Aber wir loggen den Fehler
            // statt ihn ganz zu schlucken.
            do {
                try TransactionsDatabase.setReminderId(txID: txID, slotId: slotId, bankId: bankId, reminderId: nil)
            } catch {
                AppLogger.log("Reminder DB clear failed (pruneStale heilt beim nächsten Start): \(error.localizedDescription)",
                              category: "Reminder", level: "WARN")
            }
            await MainActor.run { onEnrichmentChanged?() }
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 14))
                .foregroundColor(.primary)
        }
    }
}

private struct DetailColumn: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 14))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
