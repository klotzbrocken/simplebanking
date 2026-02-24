import AppKit
import SwiftUI

// MARK: - Transaction Detail View

struct TransactionDetailView: View {
    let transaction: TransactionsResponse.Transaction
    var bankId: String = "primary"
    var initialUserNote: String? = nil
    var onEnrichmentChanged: (() -> Void)? = nil

    @AppStorage(MerchantResolver.pipelineEnabledKey) private var effectiveMerchantPipelineEnabled: Bool = true
    @Environment(\.dismiss) private var dismiss
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

    private func initializeCategorySelectionIfNeeded() {
        guard !categorySelectionReady else { return }
        selectedCategory = TransactionCategorizer.category(for: transaction)
        hasCategoryOverride = TransactionCategorizer.hasOverride(txID: txFingerprint)
        categorySelectionReady = true
    }

    private func applyCategorySelection(_ newCategory: TransactionCategory) {
        let autoCategory = TransactionCategorizer.autoCategory(for: transaction)
        let txID = txFingerprint
        isApplyingCategoryChange = true
        categoryEditStatus = "Kategorie wird aktualisiert..."

        Task.detached {
            if newCategory == autoCategory {
                _ = TransactionCategorizer.removeOverride(txID: txID)
            } else {
                TransactionCategorizer.saveOverride(txID: txID, category: newCategory)
            }

            do {
                try TransactionsDatabase.refreshTransactionCategories()
                await MainActor.run {
                    NotificationCenter.default.post(name: Notification.Name("TransactionCategoriesChanged"), object: nil)
                    hasCategoryOverride = TransactionCategorizer.hasOverride(txID: txID)
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
        guard hasCategoryOverride || TransactionCategorizer.hasOverride(txID: txFingerprint) else {
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
        MerchantResolver.saveOverride(txID: txFingerprint, merchant: merchant)
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
        let removedOverride = MerchantResolver.removeOverride(txID: txFingerprint)
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
        let capturedBankId = bankId
        Task.detached {
            try? TransactionsDatabase.saveNote(txID: capturedTxID, note: trimmed.isEmpty ? nil : trimmed, bankId: capturedBankId)
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
        let capturedBankId = bankId
        Task.detached {
            let atts = (try? TransactionsDatabase.loadAttachments(txID: capturedTxID, bankId: capturedBankId)) ?? []
            await MainActor.run {
                attachments = atts
                isLoadingAttachments = false
            }
        }
    }

    private func deleteAttachment(_ att: AttachmentInfo) {
        let capturedTxID = txFingerprint
        let capturedBankId = bankId
        Task.detached {
            try? TransactionsDatabase.deleteAttachment(id: att.id, txID: capturedTxID, bankId: capturedBankId)
            await MainActor.run {
                attachments.removeAll { $0.id == att.id }
                onEnrichmentChanged?()
            }
        }
    }

    private func openAttachment(_ att: AttachmentInfo) {
        guard let dir = try? TransactionsDatabase.attachmentsDirectory(txID: txFingerprint, bankId: bankId) else { return }
        let fileURL = dir.appendingPathComponent(att.filename)
        NSWorkspace.shared.open(fileURL)
    }

    private func openAttachmentFolder() {
        guard let dir = try? TransactionsDatabase.attachmentsDirectory(txID: txFingerprint, bankId: bankId) else { return }
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
                            let att = try TransactionsDatabase.addAttachment(txID: txFingerprint, bankId: bankId, sourceURL: url)
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
                    // Betrag groß
                    VStack(spacing: 4) {
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
                                    Text("Zählt im Financial Health Score als Sparen, nicht als Ausgabe")
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
