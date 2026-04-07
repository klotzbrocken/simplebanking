import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// Breite des Gehaltseingang-Pickers ("31. des Monats") — via Font-Metriken + Button-Chrome
private let _settingsGehaltsPickerWidth: CGFloat = {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let textWidth = ("31. des Monats" as NSString).size(withAttributes: [.font: font]).width
    // NSPopUpButton chrome: linke Border+Padding (~12px) + Pfeil+Abstand rechts (~30px)
    return ceil(textWidth) + 42
}()

// MARK: - Fixed-Width NSPopUpButton & AccountMenuPicker

/// NSPopUpButton-Subklasse, die intrinsicContentSize auf eine feste Breite zwingt.
/// Nötig, weil SwiftUI frame(width:) bei NSViewRepresentable ignoriert wird wenn
/// intrinsicContentSize > proposed width ist.
private class _FixedWidthPopUpButton: NSPopUpButton {
    var targetWidth: CGFloat = 160
    override var intrinsicContentSize: NSSize {
        NSSize(width: targetWidth, height: super.intrinsicContentSize.height)
    }
}

/// Typsicherer NSViewRepresentable-Picker mit erzwungener Breite.
private struct AccountMenuPicker<T: Hashable>: NSViewRepresentable {
    var items: [(title: String, value: T)]
    @Binding var selection: T
    var width: CGFloat

    func makeNSView(context: Context) -> _FixedWidthPopUpButton {
        let btn = _FixedWidthPopUpButton()
        btn.targetWidth = width
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.changed(_:))
        return btn
    }

    func updateNSView(_ btn: _FixedWidthPopUpButton, context: Context) {
        btn.targetWidth = width
        context.coordinator.parent = self
        let newTitles = items.map(\.title)
        if btn.itemTitles != newTitles {
            btn.removeAllItems()
            for item in items {
                let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                mi.representedObject = _Box(item.value)
                btn.menu?.addItem(mi)
            }
        }
        if let idx = items.firstIndex(where: { $0.value == selection }),
           btn.indexOfSelectedItem != idx {
            btn.selectItem(at: idx)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: _FixedWidthPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.fittingSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: AccountMenuPicker
        init(_ p: AccountMenuPicker) { parent = p }
        @objc func changed(_ sender: NSPopUpButton) {
            if let box = sender.selectedItem?.representedObject as? _Box<T> {
                parent.selection = box.value
            }
        }
    }
}

private final class _Box<V>: NSObject {
    let value: V
    init(_ v: V) { value = v }
}

// MARK: - Settings View

enum AppearanceMode: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2
    
    var label: String {
        switch self {
        case .system: return L10n.t("System", "System")
        case .light: return L10n.t("Hell", "Light")
        case .dark: return L10n.t("Dunkel", "Dark")
        }
    }
}

enum RefreshInterval: Int, CaseIterable {
    case manual = 0
    case minutes60 = 60
    case minutes120 = 120
    case minutes180 = 180
    case minutes240 = 240
    case minutes360 = 360

    var label: String {
        switch self {
        case .manual: return L10n.t("Manuell", "Manual")
        case .minutes60: return L10n.t("1 Stunde", "1 hour")
        case .minutes120: return L10n.t("2 Stunden", "2 hours")
        case .minutes180: return L10n.t("3 Stunden", "3 hours")
        case .minutes240: return L10n.t("4 Stunden", "4 hours")
        case .minutes360: return L10n.t("6 Stunden", "6 hours")
        }
    }
}

enum ResetAttempts: Int, CaseIterable {
    case off = 0
    case three = 3
    case six = 6
    
    var label: String {
        switch self {
        case .off: return L10n.t("Aus", "Off")
        case .three: return L10n.t("3 Mal", "3 times")
        case .six: return L10n.t("6 Mal", "6 times")
        }
    }
}

enum BalanceClickMode: Int, CaseIterable {
    case mouseClick = 0
    case flyoutCard = 1
    case mouseOver = 2

    var label: String {
        switch self {
        case .mouseClick:
            return L10n.t("Mausklick", "Mouse click")
        case .flyoutCard:
            return L10n.t("Flyout-Karte", "Flyout card")
        case .mouseOver:
            return L10n.t("Mouse-Over", "Mouse over")
        }
    }

    var actionDescription: String {
        switch self {
        case .mouseClick:
            return L10n.t("Kontostand per Klick ein-/ausblenden", "Toggle balance via click")
        case .flyoutCard:
            return L10n.t("Kontostand-Flyout öffnen", "Open balance flyout")
        case .mouseOver:
            return L10n.t("Keine Klick-Aktion (Kontostand per Mouse-Over)", "No click action (balance via mouse over)")
        }
    }
}

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("menubarStyle") private var menubarStyle: Int = 0
    @AppStorage("loadTransactionsOnStart") private var loadTransactionsOnStart: Bool = false
    @AppStorage("globalHotkeyEnabled") private var globalHotkeyEnabled: Bool = true
    @AppStorage("globalHotkeyKeyCode") private var globalHotkeyKeyCode: Int = 1      // kVK_ANSI_S
    @AppStorage("globalHotkeyModifiers") private var globalHotkeyModifiers: Int = 4352 // controlKey | cmdKey
    @AppStorage("refreshInterval") private var refreshInterval: Int = 240
    @AppStorage("resetAttempts") private var resetAttempts: Int = 0
    @AppStorage("swapClickBehavior") private var swapClickBehavior: Bool = false
    @AppStorage("infiniteScrollEnabled") private var infiniteScrollEnabled: Bool = false
    @AppStorage("balanceClickMode") private var balanceClickMode: Int = BalanceClickMode.flyoutCard.rawValue
    @AppStorage("llmAPIKeyPresent") private var llmAPIKeyPresent: Bool = false
    @AppStorage("apiKeyPresent_anthropic") private var anthropicKeyPresent: Bool = false
    @AppStorage("apiKeyPresent_mistral") private var mistralKeyPresent: Bool = false
    @AppStorage("apiKeyPresent_openai") private var openaiKeyPresent: Bool = false
    @AppStorage(AIProvider.storageKey) private var selectedAIProvider: String = AIProvider.anthropic.rawValue
    @AppStorage(AICategorizationService.enabledKey) private var aiCategorizationEnabled: Bool = false
    @AppStorage("brandfetchEnabled") private var brandfetchEnabled: Bool = false
    @AppStorage("monthRingEnabled") private var monthRingEnabled: Bool = true
    @AppStorage("brandfetchClientId") private var brandfetchClientId: String = ""
    @AppStorage(AppLogger.enabledKey) private var appLoggingEnabled: Bool = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = AppLanguage.system.rawValue
    @AppStorage(ThemeManager.storageKey) private var themeId: String = ThemeManager.defaultThemeID
    
    // Finanz-Einstellungen
    @AppStorage("salaryDay") private var salaryDay: Int = 1
    @AppStorage("dispoLimit") private var dispoLimit: Int = 0
    @AppStorage("targetBuffer") private var targetBuffer: Int = 500
    @AppStorage("targetSavingsRate") private var targetSavingsRate: Int = 20
    @AppStorage("fetchDays") private var fetchDays: Int = 60
    @AppStorage("balanceSignalLowUpperBound") private var balanceSignalLowUpperBound: Int = 500
    @AppStorage("balanceSignalMediumUpperBound") private var balanceSignalMediumUpperBound: Int = 2000
    @AppStorage("confettiIncomeThreshold") private var confettiIncomeThreshold: Int = 50
    @AppStorage("confettiEffect") private var confettiEffect: Int = ConfettiEffect.money.rawValue
    @AppStorage("celebrationStyle") private var celebrationStyle: Int = 1
    @AppStorage("rippleAlwaysOn") private var rippleAlwaysOn: Bool = false
    @AppStorage(MerchantResolver.pipelineEnabledKey) private var effectiveMerchantPipelineEnabled: Bool = true

    // Sicherheit
    @AppStorage("passwordRequired") private var passwordRequired: Bool = true

    // Score Fine-Tuning
    @AppStorage("scoreStabilityMultiplier") private var scoreStabilityMultiplier: Double = 3.0
    @AppStorage("scoreCoverageWeight") private var scoreCoverageWeight: Double = 0.6
    @AppStorage("scoreFixedCostWarningRatio") private var scoreFixedCostWarningRatio: Double = 0.70
    @AppStorage("scoreSalaryToleranceDays") private var scoreSalaryToleranceDays: Int = 5

    @State private var selectedTab: Int = 0
    @State private var showResetConfirmation: Bool = false
    @State private var slotToDelete: BankSlot? = nil
    @State private var showSlotDeleteConfirmation: Bool = false
    @State private var slotBeingRenamed: BankSlot? = nil
    @State private var renameText: String = ""
    @State private var nicknameText: String = ""
    @State private var slotColorSelection: [String: Color] = [:]
    @ObservedObject private var multibankingStore = MultibankingStore.shared
    @ObservedObject private var logoStore = BankLogoStore.shared
    @State private var notificationStatus: String = ""
    @State private var touchIDAvailable: Bool = false
    @State private var touchIDEnabled: Bool = false
    @AppStorage("biometricOfferDismissed") private var biometricOfferDismissed: Bool = false
    @State private var anthropicAPIKeyInput: String = ""
    @State private var aiStatusMessage: String = ""
    private var activeAIProvider: AIProvider {
        AIProvider(rawValue: selectedAIProvider) ?? .anthropic
    }

    private var activeProviderHasKey: Bool {
        switch activeAIProvider {
        case .anthropic: return anthropicKeyPresent
        case .mistral:   return mistralKeyPresent
        case .openai:    return openaiKeyPresent
        }
    }
    @State private var availableThemes: [AppTheme] = []
    @State private var logStatusMessage: String = ""
    @State private var logoTapCount: Int = 0
    @State private var logoCacheClearStatus: String = ""
    @State private var mcpConfigCopied: Bool = false
    @State private var mcpSetupState: MCPSetupState = .idle

    private enum MCPSetupState: Equatable {
        case idle, success, alreadySet, error(String)
    }
    @State private var merchantResolutionStatusMessage: String = ""
    @State private var didInitialMerchantRefresh: Bool = false

    // Konten-Tab: per-Konto-Einstellungen
    @State private var selectedSettingsSlotId: String? = nil
    @State private var currentSlotSettings: BankSlotSettings = BankSlotSettings()
    @State private var detectedSalary: Int = 0
    // Sicherheits-Tab: Passwort deaktivieren
    @State private var showDisablePasswordSheet: Bool = false
    @State private var disablePasswordConfirmed: Bool = false
    @State private var disablePasswordError: String = ""
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private func t(_ de: String, _ en: String) -> String {
        L10n.t(de, en)
    }

    private var isDefaultThemeSelected: Bool {
        themeId == ThemeManager.defaultThemeID
    }

    private var normalizedBalanceSignalThresholds: BalanceSignalThresholds {
        BalanceSignal.normalizedThresholds(low: balanceSignalLowUpperBound, medium: balanceSignalMediumUpperBound)
    }

    private var selectedBalanceClickMode: BalanceClickMode {
        BalanceClickMode(rawValue: balanceClickMode) ?? .mouseClick
    }

    private var balanceSignalLowBinding: Binding<Int> {
        Binding(
            get: { balanceSignalLowUpperBound },
            set: { newValue in
                let normalizedLow = max(0, newValue)
                balanceSignalLowUpperBound = normalizedLow
                if balanceSignalMediumUpperBound <= normalizedLow {
                    balanceSignalMediumUpperBound = normalizedLow + 1
                }
            }
        )
    }

    private var balanceSignalMediumBinding: Binding<Int> {
        Binding(
            get: { balanceSignalMediumUpperBound },
            set: { newValue in
                let minAllowed = max(0, balanceSignalLowUpperBound) + 1
                balanceSignalMediumUpperBound = max(minAllowed, newValue)
            }
        )
    }

    private func normalizeBalanceSignalThresholds() {
        let normalized = normalizedBalanceSignalThresholds
        let normalizedLow = Int(normalized.lowUpperBound)
        let normalizedMedium = Int(normalized.mediumUpperBound)

        if balanceSignalLowUpperBound != normalizedLow {
            balanceSignalLowUpperBound = normalizedLow
        }
        if balanceSignalMediumUpperBound != normalizedMedium {
            balanceSignalMediumUpperBound = normalizedMedium
        }
    }
    
    // MARK: - Slot Deletion

    private func deleteSlot(id slotId: String) {
        let wasActive = MultibankingStore.shared.activeSlot?.id == slotId

        // 1. Delete credentials file
        let fm = FileManager.default
        if let appDir = try? CredentialsStore.appSupportURL() {
            let credFile = appDir.appendingPathComponent("credentials-\(slotId).json")
            try? fm.removeItem(at: credFile)
        }

        // 2. Delete transactions from DB for this slot
        try? TransactionsDatabase.deleteTransactions(forSlotId: slotId)

        // 2b. Clear Keychain session data for this slot
        Task { await YaxiService.clearSessionData(forSlotId: slotId) }

        // 3. Clear UserDefaults keys for this slot
        let defaults = UserDefaults.standard
        let keysToRemove = [
            "simplebanking.iban.\(slotId)",
            "simplebanking.yaxi.connectionId.\(slotId)",
            "simplebanking.yaxi.credModel.full.\(slotId)",
            "simplebanking.yaxi.credModel.userId.\(slotId)",
            "simplebanking.yaxi.credModel.none.\(slotId)",
            "simplebanking.yaxi.session.balances.\(slotId)",
            "simplebanking.yaxi.session.transactions.\(slotId)",
            "simplebanking.yaxi.connectionData.\(slotId)",
        ]
        for key in keysToRemove { defaults.removeObject(forKey: key) }

        // 4. Remove slot settings
        BankSlotSettingsStore.delete(slotId: slotId)

        // 5. Remove from store
        MultibankingStore.shared.removeSlot(id: slotId)

        // 5. Notify BalanceBar so it can react
        NotificationCenter.default.post(
            name: Notification.Name("simplebanking.slotDeleted"),
            object: nil,
            userInfo: ["slotId": slotId, "wasActive": wasActive]
        )
    }

    // MARK: - Launch at Login
    
    private func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Launch at login error: \(error)")
            }
        }
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    notificationStatus = t("Aktiviert", "Enabled")
                } else {
                    notificationStatus = t("Nicht erlaubt", "Not allowed")
                }
            }
        }
    }
    
    private func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [self] settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                switch status {
                case .authorized: notificationStatus = t("Aktiviert", "Enabled")
                case .denied: notificationStatus = t("Abgelehnt", "Denied")
                case .notDetermined: notificationStatus = t("Nicht festgelegt", "Not set")
                default: notificationStatus = ""
                }
            }
        }
    }
    
    // MARK: - Appearance
    
    private func applyAppearance(_ mode: Int) {
        switch mode {
        case 1: // Hell
            NSApp.appearance = NSAppearance(named: .aqua)
        case 2: // Dunkel
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default: // System
            NSApp.appearance = nil
        }
    }

    // MARK: - AI Key

    private func requestMasterPassword() -> String? {
        let panel = MasterPasswordPanel(isUnlock: true)
        let result = panel.runModalWithResult()
        if case .password(let password) = result {
            return password
        }
        return nil
    }

    private func publishAPIKeyChanged(_ apiKey: String?) {
        NotificationCenter.default.post(
            name: Notification.Name("AnthropicAPIKeyChanged"),
            object: nil,
            userInfo: ["apiKey": apiKey as Any]
        )
    }

    private func saveAnthropicAPIKey() {
        guard CredentialsStore.exists() else {
            aiStatusMessage = t("Bitte zuerst die Bankverbindung einrichten.", "Please set up the bank connection first.")
            return
        }
        guard let masterPassword = requestMasterPassword() else {
            aiStatusMessage = t("Vorgang abgebrochen.", "Operation cancelled.")
            return
        }
        do {
            let normalized = anthropicAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            try CredentialsStore.saveAPIKey(normalized, forProvider: activeAIProvider, masterPassword: masterPassword)
            let key = normalized.isEmpty ? nil : normalized
            let hasAnyKey = (try? CredentialsStore.hasActiveProviderKey(masterPassword: masterPassword)) ?? false
            llmAPIKeyPresent = hasAnyKey
            setProviderKeyPresent(key != nil, for: activeAIProvider)
            publishAPIKeyChanged(key)
            anthropicAPIKeyInput = ""
            aiStatusMessage = key == nil ? t("API-Key entfernt.", "API key removed.") : t("API-Key gespeichert.", "API key saved.")
        } catch {
            aiStatusMessage = "\(t("Speichern fehlgeschlagen", "Saving failed")): \(error.localizedDescription)"
        }
    }

    private func setProviderKeyPresent(_ present: Bool, for provider: AIProvider) {
        switch provider {
        case .anthropic: anthropicKeyPresent = present
        case .mistral:   mistralKeyPresent = present
        case .openai:    openaiKeyPresent = present
        }
    }

    private func removeAnthropicAPIKey() {
        guard CredentialsStore.exists() else {
            aiStatusMessage = t("Keine Zugangsdaten gefunden.", "No credentials found.")
            return
        }
        guard let masterPassword = requestMasterPassword() else {
            aiStatusMessage = t("Vorgang abgebrochen.", "Operation cancelled.")
            return
        }
        do {
            try CredentialsStore.saveAPIKey(nil, forProvider: activeAIProvider, masterPassword: masterPassword)
            let hasAnyKey = (try? CredentialsStore.hasActiveProviderKey(masterPassword: masterPassword)) ?? false
            llmAPIKeyPresent = hasAnyKey
            setProviderKeyPresent(false, for: activeAIProvider)
            publishAPIKeyChanged(nil)
            aiStatusMessage = t("API-Key entfernt.", "API key removed.")
        } catch {
            aiStatusMessage = "\(t("Entfernen fehlgeschlagen", "Removing failed")): \(error.localizedDescription)"
        }
    }

    private var appVersionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let channel = Bundle.main.object(forInfoDictionaryKey: "SBDistributionChannel") as? String
        if let channel { return "\(v) (\(channel))" }
        return v
    }

    private var appBuildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var appBuildTimestamp: String {
        Bundle.main.object(forInfoDictionaryKey: "SBBuildTimestamp") as? String ?? "-"
    }

    private var appBuildDateFormatted: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SBBuildDate") as? String ?? ""
        let parts = raw.split(separator: "-")
        guard parts.count == 3 else { return raw }
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }

    private func openLogFile() {
        AppLogger.openInFinder()
        logStatusMessage = t("Log-Datei im Finder geöffnet.", "Opened log file in Finder.")
    }

    private func clearLogFile() {
        do {
            try AppLogger.clear()
            logStatusMessage = t("Log-Datei geleert.", "Log file cleared.")
        } catch {
            logStatusMessage = "\(t("Leeren fehlgeschlagen", "Clearing failed")): \(error.localizedDescription)"
        }
    }

    // MARK: - Slot Settings

    private func loadSlotSettings() {
        if selectedSettingsSlotId == nil {
            selectedSettingsSlotId = multibankingStore.slots.first?.id
        }
        if let id = selectedSettingsSlotId {
            currentSlotSettings = BankSlotSettingsStore.load(slotId: id)
            autoDetectSalaryForDisplay(slotId: id)
        }
    }

    private func autoDetectSalaryForDisplay(slotId: String) {
        let settings = currentSlotSettings
        DispatchQueue.global(qos: .userInitiated).async {
            let txs = (try? TransactionsDatabase.loadUnifiedTransactions(slots: [slotId], days: 90)) ?? []
            let detected = SalaryProgressCalculator.detectedIncome(salaryDay: settings.effectiveSalaryDay, tolerance: settings.salaryDayTolerance, transactions: txs)
            DispatchQueue.main.async {
                let detectedInt = Int(detected.rounded())
                detectedSalary = detectedInt
                // Pre-fill comfort zone from detected salary if user hasn't changed it yet (still at default 2000)
                if detectedInt > 0 && currentSlotSettings.balanceSignalMediumUpperBound == 2000 {
                    let refSalary = currentSlotSettings.salaryAmount > 0 ? currentSlotSettings.salaryAmount : detectedInt
                    currentSlotSettings.balanceSignalMediumUpperBound = suggestedComfortZone(
                        salary: refSalary,
                        low: currentSlotSettings.balanceSignalLowUpperBound)
                    saveCurrentSlotSettings()
                }
            }
        }
    }

    private func suggestedComfortZone(salary: Int, low: Int) -> Int {
        let fromSalary = salary > 0 ? salary / 4 : 0
        let fromLow    = low * 5
        return max(max(fromSalary, fromLow), low + 1)
    }

    private func saveCurrentSlotSettings() {
        guard let id = selectedSettingsSlotId else { return }
        BankSlotSettingsStore.save(currentSlotSettings, slotId: id)
        NotificationCenter.default.post(name: .slotSettingsChanged, object: nil)
    }

    // MARK: - Disable Password

    private func disablePasswordWithVerification() {
        disablePasswordError = ""
        guard let pw = requestMasterPassword() else { return }
        guard (try? CredentialsStore.load(masterPassword: pw)) != nil else {
            disablePasswordError = t("Falsches Passwort.", "Wrong password.")
            return
        }
        do {
            try BiometricStore.saveForAutoUnlock(password: pw)
            passwordRequired = false
            disablePasswordConfirmed = false
            showDisablePasswordSheet = false
        } catch {
            disablePasswordError = "\(t("Speichern fehlgeschlagen", "Saving failed")): \(error.localizedDescription)"
        }
    }

    private func reenablePassword() {
        BiometricStore.clearAutoUnlock()
        passwordRequired = true
    }

    private func refreshMerchantResolutionData(pipelineEnabled: Bool) {
        if !CredentialsStore.exists() {
            merchantResolutionStatusMessage = pipelineEnabled
                ? t("Aktiviert. Wird bei der ersten Umsatzspeicherung angewendet.", "Enabled. Will apply on first transaction save.")
                : t("Deaktiviert. Wird bei der ersten Umsatzspeicherung angewendet.", "Disabled. Will apply on first transaction save.")
            return
        }

        merchantResolutionStatusMessage = t("Aktualisiere gespeicherte Umsätze...", "Updating stored transactions...")
        Task.detached {
            do {
                try TransactionsDatabase.refreshEffectiveMerchantData()
                await MainActor.run {
                    merchantResolutionStatusMessage = pipelineEnabled
                        ? t("Intermediär-Auflösung aktiviert und Daten aktualisiert.", "Intermediary resolution enabled and data updated.")
                        : t("Intermediär-Auflösung deaktiviert und Daten aktualisiert.", "Intermediary resolution disabled and data updated.")
                }
            } catch {
                await MainActor.run {
                    merchantResolutionStatusMessage = "\(t("Aktualisierung fehlgeschlagen", "Update failed")): \(error.localizedDescription)"
                }
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab Bar
            HStack(spacing: 0) {
                TabButton(title: t("Allgemein", "General"), icon: "gearshape", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }
                TabButton(title: t("Konten", "Accounts"), icon: "building.columns", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
                TabButton(title: t("Finanzen", "Finance"), icon: "chart.pie", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
                TabButton(title: t("Verhalten", "Behavior"), icon: "cursorarrow.click.2", isSelected: selectedTab == 3) {
                    selectedTab = 3
                }
                TabButton(title: t("Sicherheit", "Security"), icon: "lock.shield", isSelected: selectedTab == 4) {
                    selectedTab = 4
                }
                TabButton(title: t("Über", "About"), icon: "info.circle", isSelected: selectedTab == 5) {
                    selectedTab = 5
                }
                TabButton(title: "Labs", icon: "flask", isSelected: selectedTab == 6) {
                    selectedTab = 6
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            Divider()
                .padding(.top, 12)
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case 0:
                        generalSettings
                    case 1:
                        accountsSettings
                    case 2:
                        financeSettings
                    case 3:
                        behaviorSettings
                    case 4:
                        securitySettings
                    case 5:
                        aboutSection
                    case 6:
                        labsSettings
                    default:
                        EmptyView()
                    }
                }
                .padding(20)
            }
            
            Spacer()
        }
        .frame(width: 480, height: 520)
        .background(Color.panelBackground)
        .tint(Color.themeAccent)
        .onAppear {
            ThemeManager.shared.ensureThemeFiles()
            ThemeManager.shared.reloadThemes()
            availableThemes = ThemeManager.shared.availableThemes()
            if !availableThemes.contains(where: { $0.id == themeId }), let first = availableThemes.first {
                themeId = first.id
            }
            ThemeManager.shared.setSelectedThemeID(themeId)
            checkNotificationStatus()
            applyAppearance(appearanceMode)
            normalizeBalanceSignalThresholds()
            if !didInitialMerchantRefresh {
                didInitialMerchantRefresh = true
                refreshMerchantResolutionData(pipelineEnabled: effectiveMerchantPipelineEnabled)
            }
        }
        .onChange(of: launchAtLogin) { newValue in
            updateLaunchAtLogin(newValue)
        }
        .onChange(of: showNotifications) { newValue in
            if newValue {
                requestNotificationPermission()
            }
        }
        .onChange(of: appearanceMode) { newValue in
            applyAppearance(newValue)
        }
        .onChange(of: appLanguage) { _ in
            NotificationCenter.default.post(name: AppLanguage.didChangeNotification, object: nil)
        }
        .onChange(of: themeId) { newValue in
            ThemeManager.shared.setSelectedThemeID(newValue)
            ThemeManager.shared.reloadThemes()
            availableThemes = ThemeManager.shared.availableThemes()
        }
        .onChange(of: appLoggingEnabled) { newValue in
            AppLogger.setEnabled(newValue)
            logStatusMessage = newValue
                ? t("Logging aktiviert.", "Logging enabled.")
                : t("Logging deaktiviert.", "Logging disabled.")
        }
        .onChange(of: refreshInterval) { _ in
            NotificationCenter.default.post(name: Notification.Name("RefreshIntervalChanged"), object: nil)
        }
        .onChange(of: balanceClickMode) { _ in
            NotificationCenter.default.post(name: Notification.Name("BalanceDisplayModeChanged"), object: nil)
        }
        .onChange(of: effectiveMerchantPipelineEnabled) { newValue in
            refreshMerchantResolutionData(pipelineEnabled: newValue)
        }
        .onChange(of: balanceSignalLowUpperBound) { _ in
            normalizeBalanceSignalThresholds()
        }
        .onChange(of: balanceSignalMediumUpperBound) { _ in
            normalizeBalanceSignalThresholds()
        }
        .onChange(of: selectedTab) { tab in
            if tab == 4 {
                touchIDAvailable = BiometricStore.isAvailable
                touchIDEnabled = BiometricStore.hasSavedPassword
            }
            if tab == 1 {
                loadSlotSettings()
            }
        }
        .alert(t("simplebanking zurücksetzen?", "Reset simplebanking?"), isPresented: $showResetConfirmation) {
            Button(t("Abbrechen", "Cancel"), role: .cancel) { }
            Button(t("Zurücksetzen", "Reset"), role: .destructive) {
                resetApp()
            }
        } message: {
            Text(t(
                "Alle Zugangsdaten und Einstellungen werden gelöscht. Diese Aktion kann nicht rückgängig gemacht werden.",
                "All credentials and settings will be deleted. This action cannot be undone."
            ))
        }
    }
    
    // MARK: - General Settings
    
    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsToggleRow(
                title: t("Starte bei der Anmeldung", "Launch at login"),
                subtitle: t("simplebanking automatisch beim Mac-Start öffnen", "Start simplebanking automatically when macOS logs in"),
                isOn: $launchAtLogin
            )
            
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Mitteilungen bei neuen Kontobewegungen", "Notifications for new bookings"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                    Text(t("Benachrichtigung anzeigen, wenn neue Umsätze erkannt werden", "Show a notification when new transactions are detected"))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                    if !notificationStatus.isEmpty {
                        Text("\(t("Status", "Status")): \(notificationStatus)")
                            .font(ThemeFonts.body(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
                Toggle("", isOn: $showNotifications)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
            }
            
            SettingsToggleRow(
                title: t("Lade Umsätze beim Start", "Load transactions on startup"),
                subtitle: t("Umsatzliste automatisch beim Entsperren laden", "Automatically load transaction list after unlock"),
                isOn: $loadTransactionsOnStart
            )

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Kurzbefehl", "Shortcut"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                    Text(t("Flyout oder Kontostand ein-/ausblenden", "Show flyout or toggle balance"))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                HotkeyRecorderView(keyCode: $globalHotkeyKeyCode, modifiers: $globalHotkeyModifiers)
                    .frame(width: 90, height: 24)
                    .opacity(globalHotkeyEnabled ? 1.0 : 0.4)
                    .allowsHitTesting(globalHotkeyEnabled)
                    .onChange(of: globalHotkeyKeyCode) { _ in postHotkeyChanged() }
                    .onChange(of: globalHotkeyModifiers) { _ in postHotkeyChanged() }
                Toggle("", isOn: $globalHotkeyEnabled)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                    .onChange(of: globalHotkeyEnabled) { _ in postHotkeyChanged() }
            }

        }
    }

    private func postHotkeyChanged() {
        NotificationCenter.default.post(name: Notification.Name("simplebanking.globalHotkeyChanged"), object: nil)
    }

    private var aiAssistantSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("AI-Assistent (experimentell)", "AI assistant (experimental)"))
                .font(ThemeFonts.heading(size: 13))

            Text(t(
                "Mit einem API‑Key kannst du die AI‑Transaktions‑Kategorisierung aktivieren. Dabei werden Transaktionsdaten (Empfänger, Verwendungszweck, Betrag) zur Kategorisierung an den gewählten KI‑Anbieter übertragen (USA/EU). Der API‑Key wird verschlüsselt lokal gespeichert.",
                "With an API key you can enable AI transaction categorization. Transaction data (recipient, reference, amount) is sent to the selected AI provider for categorization (USA/EU). The API key is stored encrypted locally."
            ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)

            // Change 2 — provider picker
            Picker("", selection: $selectedAIProvider) {
                ForEach(AIProvider.allCases, id: \.rawValue) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedAIProvider) { _ in
                anthropicAPIKeyInput = ""
                aiStatusMessage = ""
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(activeProviderHasKey ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(activeProviderHasKey ? t("API-Key gesetzt", "API key set") : t("Kein API-Key gesetzt", "No API key set"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
            }

            SecureField(activeAIProvider.keyPlaceholder, text: $anthropicAPIKeyInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack(spacing: 8) {
                Button(activeProviderHasKey ? t("API-Key aktualisieren", "Update API key") : t("API-Key speichern", "Save API key")) {
                    saveAnthropicAPIKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(anthropicAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).count < 10
                          && !activeProviderHasKey)

                Button(t("API-Key entfernen", "Remove API key")) {
                    removeAnthropicAPIKey()
                }
                .buttonStyle(.bordered)
                .disabled(!activeProviderHasKey)
            }

            if !aiStatusMessage.isEmpty {
                Text(aiStatusMessage)
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Accounts Settings

    private var accountsSettings: some View {
        VStack(alignment: .leading, spacing: 16) {

            // --- Verbundene Konten ---
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Verbundene Konten", "Connected Accounts"))
                    .font(ThemeFonts.heading(size: 13))

                if multibankingStore.slots.isEmpty {
                    Text(t("Kein Konto verbunden.", "No account connected."))
                        .font(ThemeFonts.body(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    List {
                    ForEach(multibankingStore.slots) { slot in
                        HStack(spacing: 12) {
                            let slotBrand = BankLogoAssets.resolve(displayName: slot.displayName, logoID: slot.logoId, iban: slot.iban)
                            Group {
                                if let img = logoStore.image(for: slotBrand) {
                                    let invertSlot = colorScheme == .dark && BankLogoAssets.isDark(brandId: slotBrand?.id ?? "")
                                    if invertSlot {
                                        Image(nsImage: img).resizable().scaledToFit()
                                            .frame(width: 28, height: 28)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .colorInvert()
                                    } else {
                                        Image(nsImage: img).resizable().scaledToFit()
                                            .frame(width: 28, height: 28)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.12))
                                        .frame(width: 28, height: 28)
                                        .overlay(Image(systemName: "building.columns").font(.system(size: 12)).foregroundColor(.secondary))
                                }
                            }
                            .onAppear { BankLogoStore.shared.preload(brand: slotBrand) }

                            VStack(alignment: .leading, spacing: 2) {
                                if slotBeingRenamed?.id == slot.id {
                                    HStack(spacing: 6) {
                                        TextField(t("Kurzname", "Nickname"), text: $nicknameText)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                            .font(ThemeFonts.body(size: 13))
                                            .frame(minWidth: 100, maxWidth: 160)
                                            .onSubmit {
                                                let trimmed = nicknameText.trimmingCharacters(in: .whitespacesAndNewlines)
                                                MultibankingStore.shared.updateNickname(trimmed.isEmpty ? nil : trimmed, forSlotId: slot.id)
                                                slotBeingRenamed = nil
                                            }
                                        Button(t("OK", "OK")) {
                                            let trimmed = nicknameText.trimmingCharacters(in: .whitespacesAndNewlines)
                                            MultibankingStore.shared.updateNickname(trimmed.isEmpty ? nil : trimmed, forSlotId: slot.id)
                                            slotBeingRenamed = nil
                                        }.buttonStyle(PlainButtonStyle())
                                        Button(t("Abbruch", "Cancel")) { slotBeingRenamed = nil }
                                            .buttonStyle(PlainButtonStyle()).foregroundColor(.secondary)
                                    }
                                } else {
                                    HStack(spacing: 4) {
                                        Text(slot.displayName.isEmpty ? t("Konto", "Account") : slot.displayName)
                                            .font(ThemeFonts.body(size: 13))
                                        if let nick = slot.nickname {
                                            Text(nick)
                                                .font(.system(size: 11, weight: .medium))
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Capsule().fill(Color(NSColor.quaternaryLabelColor)))
                                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                                        }
                                    }
                                }
                                if !slot.iban.isEmpty {
                                    HStack(spacing: 4) {
                                        Text(slot.iban.prefix(4) + " ···· " + slot.iban.suffix(4))
                                            .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                                        if let curr = slot.currency {
                                            Text(curr)
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Capsule().fill(Color(NSColor.quaternaryLabelColor)))
                                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                                        }
                                    }
                                }
                            }
                            Spacer()
                            if slotBeingRenamed?.id != slot.id {
                                // Color picker for slot accent color
                                let currentColor: Color = {
                                    if let c = slotColorSelection[slot.id] { return c }
                                    if let hex = slot.customColor, let c = Color(hex: hex) { return c }
                                    if let logoId = slot.logoId,
                                       let hex = GeneratedBankColors.primaryColor(forLogoId: logoId),
                                       let c = Color(hex: hex) { return c }
                                    return Color.accentColor
                                }()
                                ColorPicker("", selection: Binding(
                                    get: { slotColorSelection[slot.id] ?? currentColor },
                                    set: { newColor in
                                        slotColorSelection[slot.id] = newColor
                                        if let nsColor = NSColor(newColor).usingColorSpace(.sRGB) {
                                            let r = Int(nsColor.redComponent * 255)
                                            let g = Int(nsColor.greenComponent * 255)
                                            let b = Int(nsColor.blueComponent * 255)
                                            let hex = String(format: "%02X%02X%02X", r, g, b)
                                            MultibankingStore.shared.updateCustomColor(hex, forSlotId: slot.id)
                                        }
                                    }
                                ), supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 28, height: 22)
                                Button(action: {
                                    nicknameText = slot.nickname ?? ""
                                    slotBeingRenamed = slot
                                }) {
                                    Image(systemName: "pencil").foregroundColor(.secondary)
                                }.buttonStyle(PlainButtonStyle())
                                Button(action: {
                                    slotToDelete = slot
                                    showSlotDeleteConfirmation = true
                                }) {
                                    Text(t("Entfernen", "Remove"))
                                        .foregroundColor(.red).font(ThemeFonts.body(size: 12))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(multibankingStore.slots.count == 1)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowSeparator(.hidden)
                    }
                    .onMove { source, destination in
                        multibankingStore.moveSlot(from: source, to: destination)
                    }
                    }
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .frame(height: CGFloat(multibankingStore.slots.count) * 54)
                }

                Button(action: {
                    NotificationCenter.default.post(name: Notification.Name("simplebanking.addAccount"), object: nil)
                }) {
                    Label(t("Konto hinzufügen", "Add account"), systemImage: "plus.circle")
                        .font(ThemeFonts.body(size: 13))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.accentColor)
            }
            .alert(t("Konto entfernen?", "Remove account?"), isPresented: $showSlotDeleteConfirmation, presenting: slotToDelete) { slot in
                Button(t("Entfernen", "Remove"), role: .destructive) { deleteSlot(id: slot.id) }
                Button(t("Abbrechen", "Cancel"), role: .cancel) {}
            } message: { slot in
                Text(t(
                    "Das Konto \"\(slot.displayName.isEmpty ? slot.iban : slot.displayName)\" und alle zugehörigen Daten werden unwiderruflich gelöscht.",
                    "The account \"\(slot.displayName.isEmpty ? slot.iban : slot.displayName)\" and all its data will be permanently deleted."
                ))
            }

            Divider()

            // --- Abfrage-Intervall ---
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Abfrage-Intervall", "Refresh interval"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                    Text(t("Wie oft soll der Kontostand automatisch abgefragt werden?", "How often should the balance be refreshed automatically?"))
                        .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                AccountMenuPicker(
                    items: RefreshInterval.allCases.map { (title: $0.label, value: $0.rawValue) },
                    selection: $refreshInterval,
                    width: _settingsGehaltsPickerWidth
                )
                .padding(.trailing, 14)
            }

            Divider()

            // --- Per-Konto-Einstellungen ---
            if !multibankingStore.slots.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("Konto-Einstellungen", "Account Settings"))
                        .font(ThemeFonts.heading(size: 13))
                    Text(t("Jede Einstellung gilt individuell für das ausgewählte Konto.", "Each setting applies individually to the selected account."))
                        .font(ThemeFonts.body(size: 12)).foregroundColor(.secondary)

                    // Account picker
                    HStack {
                        Text(t("Konto", "Account"))
                            .font(ThemeFonts.body(size: 13, weight: .medium))
                        Spacer()
                        AccountMenuPicker(
                            items: multibankingStore.slots.map { slot in
                                (title: slot.nickname ?? (slot.displayName.isEmpty ? slot.iban.suffix(8).description : slot.displayName),
                                 value: Optional(slot.id))
                            },
                            selection: $selectedSettingsSlotId,
                            width: _settingsGehaltsPickerWidth
                        )
                        .padding(.trailing, 14)
                        .onChange(of: selectedSettingsSlotId) { id in
                            if let id {
                                currentSlotSettings = BankSlotSettingsStore.load(slotId: id)
                                autoDetectSalaryForDisplay(slotId: id)
                            }
                        }
                    }

                    if selectedSettingsSlotId != nil {
                        VStack(alignment: .leading, spacing: 12) {

                            // Abruf-Zeitraum
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t("Abruf-Zeitraum", "Fetch range"))
                                        .font(ThemeFonts.body(size: 13, weight: .medium))
                                    Text(t("Wie viele Tage an Transaktionen sollen abgerufen werden?", "How many days of transactions to fetch?"))
                                        .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                                }
                                Spacer()
                                AccountMenuPicker(
                                    items: [
                                        (title: t("30 Tage", "30 days"), value: 30),
                                        (title: t("60 Tage", "60 days"), value: 60),
                                        (title: t("90 Tage", "90 days"), value: 90),
                                        (title: t("180 Tage", "180 days"), value: 180),
                                        (title: t("365 Tage", "365 days"), value: 365),
                                    ],
                                    selection: Binding(
                                        get: { currentSlotSettings.fetchDays },
                                        set: { currentSlotSettings.fetchDays = $0; saveCurrentSlotSettings() }
                                    ),
                                    width: _settingsGehaltsPickerWidth
                                )
                                .padding(.trailing, 14)
                            }

                            Divider()

                            // Gehaltseingang
                            VStack(alignment: .leading, spacing: 6) {
                                Text(t("Gehaltseingang", "Salary incoming day"))
                                    .font(ThemeFonts.body(size: 13, weight: .medium))
                                HStack(spacing: 6) {
                                    ForEach([
                                        (0, t("Anfang", "Start")),
                                        (1, t("Mitte", "Mid")),
                                        (2, t("Individuell", "Custom"))
                                    ], id: \.0) { preset, label in
                                        Button(action: {
                                            currentSlotSettings.salaryDayPreset = preset
                                            saveCurrentSlotSettings()
                                            autoDetectSalaryForDisplay(slotId: selectedSettingsSlotId ?? "")
                                        }) {
                                            Text(label)
                                                .font(ThemeFonts.body(size: 12))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 4)
                                                .background(currentSlotSettings.salaryDayPreset == preset
                                                    ? Color.accentColor.opacity(0.15) : Color.clear)
                                                .cornerRadius(6)
                                                .overlay(RoundedRectangle(cornerRadius: 6)
                                                    .stroke(currentSlotSettings.salaryDayPreset == preset
                                                        ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                if currentSlotSettings.salaryDayPreset == 0 {
                                    Text(t("Tag 1, ±4 Tage Toleranz", "Day 1, ±4 days tolerance"))
                                        .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                                } else if currentSlotSettings.salaryDayPreset == 1 {
                                    Text(t("Tag 15, ±4 Tage Toleranz", "Day 15, ±4 days tolerance"))
                                        .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                                } else {
                                    HStack(spacing: 6) {
                                        AccountMenuPicker(
                                            items: (1...31).map { day in
                                                (title: t("\(day). des Monats", "Day \(day)"), value: day)
                                            },
                                            selection: Binding(
                                                get: { currentSlotSettings.salaryDay },
                                                set: { v in
                                                    currentSlotSettings.salaryDay = v
                                                    saveCurrentSlotSettings()
                                                    autoDetectSalaryForDisplay(slotId: selectedSettingsSlotId ?? "")
                                                }
                                            ),
                                            width: _settingsGehaltsPickerWidth
                                        )
                                        Text(t("Genau dieser Tag", "Exact day"))
                                            .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                                    }
                                }
                            }

                            Divider()

                            // Ziel-Puffer
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t("Monatlicher Ziel-Puffer", "Monthly target buffer"))
                                        .font(ThemeFonts.body(size: 13, weight: .medium))
                                    Text(t("Wie viel soll nach allen Ausgaben übrig bleiben?", "How much should remain after all expenses?"))
                                        .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 6) {
                                    TextField("500", value: Binding(
                                        get: { currentSlotSettings.targetBuffer },
                                        set: { currentSlotSettings.targetBuffer = $0; saveCurrentSlotSettings() }
                                    ), format: .number)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    Text("€").font(ThemeFonts.body(size: 13)).foregroundColor(.secondary)
                                        .frame(width: 16, alignment: .leading)
                                }
                                .frame(width: 185)
                            }

                            Divider()

                            // Ziel-Sparrate
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t("Ziel-Sparrate", "Target savings rate"))
                                        .font(ThemeFonts.body(size: 13, weight: .medium))
                                    Text(t("Ziel-Sparquote (50/30/20 Regel: 20 %)", "Target savings ratio (50/30/20 rule: 20%)"))
                                        .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 6) {
                                    TextField("20", value: Binding(
                                        get: { currentSlotSettings.targetSavingsRate },
                                        set: { currentSlotSettings.targetSavingsRate = $0; saveCurrentSlotSettings() }
                                    ), format: .number)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    Text("%").font(ThemeFonts.body(size: 13)).foregroundColor(.secondary)
                                        .frame(width: 16, alignment: .leading)
                                }
                                .frame(width: 185)
                            }

                            Divider()

                            // Dispositionskredit
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t("Dispositionskredit", "Overdraft limit"))
                                        .font(ThemeFonts.body(size: 13, weight: .medium))
                                    Text(t("Dispo-Limit für die Score-Statistik. 0 = kein Dispo.", "Overdraft limit for score stats. 0 = none."))
                                        .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 6) {
                                    TextField("0", value: Binding(
                                        get: { currentSlotSettings.dispoLimit },
                                        set: { currentSlotSettings.dispoLimit = $0; saveCurrentSlotSettings() }
                                    ), format: .number)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    Text("€").font(ThemeFonts.body(size: 13)).foregroundColor(.secondary)
                                        .frame(width: 16, alignment: .leading)
                                }
                                .frame(width: 185)
                            }

                            Divider()

                            // Money Mood
                            VStack(alignment: .leading, spacing: 8) {
                                Text(t("Money Mood", "Money Mood"))
                                    .font(ThemeFonts.body(size: 13, weight: .medium))
                                HStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        TextField("500", value: Binding(
                                            get: { currentSlotSettings.balanceSignalLowUpperBound },
                                            set: { v in
                                                currentSlotSettings.balanceSignalLowUpperBound = max(0, v)
                                                if currentSlotSettings.balanceSignalMediumUpperBound <= currentSlotSettings.balanceSignalLowUpperBound {
                                                    currentSlotSettings.balanceSignalMediumUpperBound = currentSlotSettings.balanceSignalLowUpperBound + 1
                                                }
                                                saveCurrentSlotSettings()
                                            }
                                        ), format: .number)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        Text("€").font(ThemeFonts.body(size: 13)).foregroundColor(.secondary)
                                            .frame(width: 16, alignment: .leading)
                                    }
                                    .frame(width: 185)
                                    Text(t("Kritische Schwelle", "Critical threshold"))
                                        .font(ThemeFonts.body(size: 12)).foregroundColor(.secondary)
                                }
                                HStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        let refSalary = currentSlotSettings.salaryAmount > 0
                                            ? currentSlotSettings.salaryAmount
                                            : detectedSalary
                                        let placeholder = refSalary > 0
                                            ? "\(suggestedComfortZone(salary: refSalary, low: currentSlotSettings.balanceSignalLowUpperBound))"
                                            : "1500"
                                        TextField(placeholder, value: Binding(
                                            get: { currentSlotSettings.balanceSignalMediumUpperBound },
                                            set: { v in
                                                let clamped = max(currentSlotSettings.balanceSignalLowUpperBound + 1, v)
                                                currentSlotSettings.balanceSignalMediumUpperBound = clamped
                                                saveCurrentSlotSettings()
                                            }
                                        ), format: .number)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        Text("€").font(ThemeFonts.body(size: 13)).foregroundColor(.secondary)
                                            .frame(width: 16, alignment: .leading)
                                    }
                                    .frame(width: 185)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t("Komfortzone bis", "Comfort zone up to"))
                                            .font(ThemeFonts.body(size: 12)).foregroundColor(.secondary)
                                        let refSalary = currentSlotSettings.salaryAmount > 0
                                            ? currentSlotSettings.salaryAmount
                                            : detectedSalary
                                        if refSalary > 0 {
                                            let quarter = refSalary / 4
                                            Text(t("Vorschlag: \(quarter) € (¼ Gehalt)", "Suggested: \(quarter) € (¼ salary)"))
                                                .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary.opacity(0.7))
                                        }
                                    }
                                }
                                // Nettogehalt — setzt gleichzeitig die MoneyMood-Grün-Schwelle
                                HStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        let placeholder = detectedSalary > 0
                                            ? "\(detectedSalary)"
                                            : "0"
                                        TextField(placeholder, value: Binding(
                                            get: { currentSlotSettings.salaryAmount },
                                            set: { v in
                                                let clamped = max(0, v)
                                                currentSlotSettings.salaryAmount = clamped
                                                if clamped > 0 {
                                                    // Update comfort zone to salary/4 (suggested value)
                                                    currentSlotSettings.balanceSignalMediumUpperBound = suggestedComfortZone(
                                                        salary: clamped,
                                                        low: currentSlotSettings.balanceSignalLowUpperBound)
                                                    // Low threshold must stay below comfort zone
                                                    if currentSlotSettings.balanceSignalLowUpperBound >= currentSlotSettings.balanceSignalMediumUpperBound {
                                                        currentSlotSettings.balanceSignalLowUpperBound = max(0, currentSlotSettings.balanceSignalMediumUpperBound - 1)
                                                    }
                                                }
                                                saveCurrentSlotSettings()
                                            }
                                        ), format: .number)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        Text("€").font(ThemeFonts.body(size: 13)).foregroundColor(.secondary)
                                            .frame(width: 16, alignment: .leading)
                                    }
                                    .frame(width: 185)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t("Nettogehalt / Monat", "Monthly net salary"))
                                            .font(ThemeFonts.body(size: 12)).foregroundColor(.secondary)
                                        if currentSlotSettings.salaryAmount == 0 {
                                            let hint = detectedSalary > 0
                                                ? t("Erkannt: \(detectedSalary) €", "Detected: \(detectedSalary) €")
                                                : t("Setzt MoneyMood-Grün-Schwelle + Ring", "Sets MoneyMood green threshold + ring")
                                            Text(hint)
                                                .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary.opacity(0.7))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                        .padding(.leading, 12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))
                    }
                }
            }
        }
        .onAppear { loadSlotSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if selectedSettingsSlotId != nil { autoDetectSalaryForDisplay(slotId: selectedSettingsSlotId!) }
        }
    }

    // MARK: - Finance Settings

    private var financeSettings: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Info-Box: Wie wird der Score berechnet?
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text(t("Wie wird der Financial Health Score berechnet?", "How is the Financial Health Score calculated?"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.green).frame(width: 10, height: 10)
                        Text(t("Einnahmendeckung: Verhältnis Einnahmen / Ausgaben + absoluter Puffer", "Income coverage: income/expense ratio + absolute buffer margin"))
                            .font(ThemeFonts.body(size: 11))
                    }
                    HStack(spacing: 8) {
                        Circle().fill(Color.cyan).frame(width: 10, height: 10)
                        Text(t("Sparrate: Effektiver Cashflow-Überschuss vs. Ziel-Sparrate", "Savings rate: effective cashflow surplus vs. target rate"))
                            .font(ThemeFonts.body(size: 11))
                    }
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Text(t("Stabilität: Anteil ungewöhnlich hoher variabler Ausgaben", "Stability: share of unusually high variable expenses"))
                            .font(ThemeFonts.body(size: 11))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))
            }

            Divider()

            // Stabilitäts-Multiplikator
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Stabilitäts-Schwelle", "Stability threshold"))
                            .font(ThemeFonts.body(size: 13, weight: .medium))
                        Text(t(
                            "Eine Ausgabe gilt als Ausreißer, wenn sie mehr als X-mal so hoch ist wie der Durchschnitt. Kleiner Wert = strenger.",
                            "A transaction counts as an outlier if it is more than X times the average. Lower = stricter."
                        ))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f×", scoreStabilityMultiplier))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                        .frame(width: 40, alignment: .trailing)
                }
                Slider(value: $scoreStabilityMultiplier, in: 1.0...5.0, step: 0.5)
                    .frame(maxWidth: .infinity)
                HStack {
                    Text(t("1× (streng)", "1× (strict)"))
                        .font(ThemeFonts.body(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(t("5× (locker)", "5× (lenient)"))
                        .font(ThemeFonts.body(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Einnahmendeckung: Verhältnis vs. Puffer-Gewichtung
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Einnahmendeckung: Gewichtung", "Income coverage: weighting"))
                            .font(ThemeFonts.body(size: 13, weight: .medium))
                        Text(t(
                            "Anteil des Verhältnis-Scores (vs. Puffer-Score) an der Einnahmendeckung.",
                            "Share of the ratio score (vs. buffer score) in income coverage."
                        ))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(t("\(Int(scoreCoverageWeight * 100))% Verhältnis / \(Int((1 - scoreCoverageWeight) * 100))% Puffer",
                           "\(Int(scoreCoverageWeight * 100))% ratio / \(Int((1 - scoreCoverageWeight) * 100))% buffer"))
                        .font(ThemeFonts.body(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 130, alignment: .trailing)
                }
                Slider(value: $scoreCoverageWeight, in: 0.1...0.9, step: 0.1)
                    .frame(maxWidth: .infinity)
                HStack {
                    Text(t("Puffer-betont", "Buffer-heavy"))
                        .font(ThemeFonts.body(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(t("Verhältnis-betont", "Ratio-heavy"))
                        .font(ThemeFonts.body(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Fixkosten-Warnschwelle
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Fixkosten-Warnschwelle", "Fixed cost warning ratio"))
                            .font(ThemeFonts.body(size: 13, weight: .medium))
                        Text(t(
                            "Ab welchem Anteil am Einkommen gelten Fixkosten als kritisch? Empfehlung: 70%.",
                            "Above which share of income are fixed costs considered critical? Recommended: 70%."
                        ))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(Int(scoreFixedCostWarningRatio * 100))%")
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                        .frame(width: 40, alignment: .trailing)
                }
                Slider(value: $scoreFixedCostWarningRatio, in: 0.5...1.0, step: 0.05)
                    .frame(maxWidth: .infinity)
                HStack {
                    Text("50%")
                        .font(ThemeFonts.body(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("100%")
                        .font(ThemeFonts.body(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Gehaltstoleranz
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Gehaltstoleranz (Tage)", "Salary tolerance (days)"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                    Text(t(
                        "Wie viele Tage vor/nach dem Gehaltsdatum gilt ein Eingang noch als Gehalt?",
                        "How many days before/after salary day is an income still counted as salary?"
                    ))
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
                }
                Spacer()
                Stepper("\(scoreSalaryToleranceDays) \(t("Tage", "days"))", value: $scoreSalaryToleranceDays, in: 1...14)
                    .font(ThemeFonts.body(size: 13))
            }

            Divider()

            // Reset-Button
            Button(action: {
                scoreStabilityMultiplier = 3.0
                scoreCoverageWeight = 0.6
                scoreFixedCostWarningRatio = 0.70
                scoreSalaryToleranceDays = 5
            }) {
                Text(t("Auf Standard zurücksetzen", "Reset to defaults"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    // MARK: - Behavior Settings
    
    private var behaviorSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Mausklick-Verhalten", "Mouse click behavior"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Bestimmt, welche Aktion bei Klick bzw. Doppelklick ausgeführt wird", "Defines which action runs on click or double-click"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("Einfacher Klick", "Single click"))
                            .font(ThemeFonts.body(size: 12, weight: .medium))
                        Text(swapClickBehavior ? t("Umsatzliste öffnen", "Open transactions") : selectedBalanceClickMode.actionDescription)
                            .font(ThemeFonts.body(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("Doppelklick", "Double click"))
                            .font(ThemeFonts.body(size: 12, weight: .medium))
                        Text(swapClickBehavior ? selectedBalanceClickMode.actionDescription : t("Umsatzliste öffnen", "Open transactions"))
                            .font(ThemeFonts.body(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cardBackground)
            )
            
            SettingsToggleRow(
                title: t("Mausklick tauschen", "Swap click actions"),
                subtitle: t("Tauscht die Aktionen für Klick und Doppelklick", "Swaps actions for click and double-click"),
                isOn: $swapClickBehavior
            )

            SettingsToggleRow(
                title: t("Infinite Scroll", "Infinite scroll"),
                subtitle: t(
                    "Lädt beim Scrollen automatisch weitere Umsätze und ersetzt die Seitenanzeige.",
                    "Automatically loads more transactions while scrolling and replaces page indicators."
                ),
                isOn: $infiniteScrollEnabled
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(t("Kontostand anzeigen", "Show balance"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t(
                    "Wähle, wie der Kontostand angezeigt wird: Flyout-Karte, Mausklick oder Mouse-Over.",
                    "Choose how the balance is shown: flyout card, mouse click, or mouse over."
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)

                Picker("", selection: $balanceClickMode) {
                    ForEach(BalanceClickMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: 360)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cardBackground)
            )

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(t("Intermediär-Auflösung", "Intermediary resolution"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t(
                    "Löst PayPal/Klarna/Landesbank auf den wahrscheinlichen Händler auf (effective merchant).",
                    "Resolves PayPal/Klarna/Landesbank to the likely real merchant (effective merchant)."
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)

                SettingsToggleRow(
                    title: t("Erweiterte Händler-Auflösung", "Advanced merchant resolution"),
                    subtitle: t("Ein/Aus für die effective_merchant-Pipeline", "Enable/disable effective_merchant pipeline"),
                    isOn: $effectiveMerchantPipelineEnabled
                )

                if !merchantResolutionStatusMessage.isEmpty {
                    Text(merchantResolutionStatusMessage)
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Language
            HStack {
                Text(t("Sprache", "Language"))
                    .font(ThemeFonts.body(size: 13, weight: .medium))
                Spacer()
                Picker("", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                        Text(language.pickerLabel).tag(language.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 180)
            }

            Divider()

            // Theme (colors + typography from cfg files)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Theme", "Theme"))
                            .font(ThemeFonts.body(size: 13, weight: .medium))
                        Text(t(
                            "Wähle ein Theme aus .cfg-Dateien (Farben + Typografie).",
                            "Choose a theme from .cfg files (colors + typography)."
                        ))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $themeId) {
                        ForEach(availableThemes, id: \.id) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 180)
                }
                Text("\(t("Theme-Ordner", "Theme folder")): \(ThemeManager.shared.themesDirectoryPath)")
                    .font(ThemeFonts.body(size: 10))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            // Appearance
            HStack {
                Text(t("Darstellung", "Appearance"))
                    .font(ThemeFonts.body(size: 13, weight: .medium))
                Spacer()
                Picker("", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)
            }

            Divider()

            HStack {
                Text(t("Menüleiste", "Menu Bar"))
                    .font(ThemeFonts.body(size: 13, weight: .medium))
                Spacer()
                Picker("", selection: $menubarStyle) {
                    Text(t("Lang", "Long")).tag(0)
                    Text(t("Kurz", "Short")).tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 120)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(t("Effekte", "Effects"))
                    .font(ThemeFonts.heading(size: 13))

                HStack(spacing: 8) {
                    Text(t("Effekte bei Einnahme ab", "Effects from income of"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                    TextField("50", value: $confettiIncomeThreshold, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)
                    Text("€")
                        .font(ThemeFonts.body(size: 13))
                }
                Text(t("Effekte erscheinen bei neuen Einnahmen ab diesem Betrag. Setze 0 für keinen Effekt.", "Effects appear for new income above this amount. Set 0 for no effect."))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(t("Stil", "Style"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                    Spacer()
                    Picker("", selection: $celebrationStyle) {
                        Text(t("Classic (Konfetti)", "Classic (Confetti)")).tag(0)
                        Text(t("Ripple", "Ripple")).tag(1)
                    }
                    .frame(width: 180)
                }
                .disabled(confettiIncomeThreshold == 0)

                if celebrationStyle == 0 {
                    HStack {
                        Text(t("Konfetti-Stil", "Confetti style"))
                            .font(ThemeFonts.body(size: 13, weight: .medium))
                        Spacer()
                        Picker("", selection: $confettiEffect) {
                            ForEach(ConfettiEffect.allCases, id: \.rawValue) { effect in
                                Text(effect.label).tag(effect.rawValue)
                            }
                        }
                        .frame(width: 185)
                    }
                    .disabled(confettiIncomeThreshold == 0)
                } else {
                    Text(t("Ripple-Welle erscheint auf der Kontostand-Kachel und im Flyout.", "Ripple wave appears on the balance card and in the flyout."))
                        .font(ThemeFonts.body(size: 12))
                        .foregroundStyle(.secondary)
                    SettingsToggleRow(
                        title: t("Dauerhaft", "Always on"),
                        subtitle: t("Ripple bei jedem Öffnen — nicht nur bei neuen Einnahmen.", "Ripple on every open — not only on new income."),
                        isOn: $rippleAlwaysOn
                    )
                }
            }
        }
    }
    
    // MARK: - Security Settings

    private var securitySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Touch ID", "Touch ID"))
                    .font(ThemeFonts.heading(size: 13))
                if touchIDAvailable {
                    if touchIDEnabled {
                        Text(t("Touch ID ist aktiviert. Du kannst die App mit Touch ID entsperren.", "Touch ID is enabled. You can unlock the app with Touch ID."))
                            .font(ThemeFonts.body(size: 12))
                            .foregroundColor(.secondary)
                        Button(action: {
                            BiometricStore.clear()
                            touchIDEnabled = false
                            biometricOfferDismissed = false
                        }) {
                            Text(t("Touch ID deaktivieren", "Disable Touch ID"))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color(NSColor.systemOrange))
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    } else {
                        Text(t("Touch ID ist deaktiviert.", "Touch ID is disabled."))
                            .font(ThemeFonts.body(size: 12))
                            .foregroundColor(.secondary)
                        Button(action: {
                            biometricOfferDismissed = false
                        }) {
                            Text(t("Beim nächsten Entsperren anbieten", "Offer on next unlock"))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color(NSColor.controlAccentColor))
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                } else {
                    Text(t("Touch ID ist auf diesem Gerät nicht verfügbar.", "Touch ID is not available on this device."))
                        .font(ThemeFonts.body(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(t("Zurücksetzen nach falscher Kennworteingabe", "Reset after wrong password attempts"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Alle Daten löschen, wenn das Passwort mehrfach falsch eingegeben wird", "Delete all data when password is entered incorrectly multiple times"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)

                Picker("", selection: $resetAttempts) {
                    ForEach(ResetAttempts.allCases, id: \.rawValue) { attempt in
                        Text(attempt.label).tag(attempt.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: 250)
            }

            Divider()

            // MARK: App-Passwort deaktivieren
            VStack(alignment: .leading, spacing: 8) {
                Text(t("App-Passwort", "App password"))
                    .font(ThemeFonts.heading(size: 13))

                if passwordRequired {
                    Text(t(
                        "Das App-Passwort schützt deine Bankdaten vor unbefugtem Zugriff.",
                        "The app password protects your banking data from unauthorized access."
                    ))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)

                    Button(action: {
                        disablePasswordConfirmed = false
                        disablePasswordError = ""
                        showDisablePasswordSheet = true
                    }) {
                        Text(t("App-Passwort deaktivieren…", "Disable app password…"))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.systemOrange))
                            .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.open.fill")
                            .foregroundColor(.orange)
                        Text(t(
                            "App-Passwort ist deaktiviert. Die App startet ohne Passwort-Abfrage.",
                            "App password is disabled. The app starts without a password prompt."
                        ))
                        .font(ThemeFonts.body(size: 12))
                        .foregroundColor(.secondary)
                    }
                    Button(action: { reenablePassword() }) {
                        Text(t("App-Passwort wieder aktivieren", "Re-enable app password"))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.controlAccentColor))
                            .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .sheet(isPresented: $showDisablePasswordSheet) {
                disablePasswordSheet
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(t("simplebanking zurücksetzen", "Reset simplebanking"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Alle Zugangsdaten und Einstellungen löschen", "Delete all credentials and settings"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)

                Button(action: { showResetConfirmation = true }) {
                    Text(multibankingStore.slots.count > 1
                         ? t("Alle Konten zurücksetzen…", "Reset all accounts…")
                         : t("Zurücksetzen…", "Reset…"))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.expenseRed)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .onAppear {
            touchIDAvailable = BiometricStore.isAvailable
            touchIDEnabled = BiometricStore.hasSavedPassword
        }
    }

    // MARK: - Disable Password Sheet

    private var disablePasswordSheet: some View {
        VStack(spacing: 20) {
            // Icon + Titel
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                Text(t("App-Passwort deaktivieren", "Disable app password"))
                    .font(ThemeFonts.heading(size: 18, weight: .bold))
                Text(t(
                    "Ohne Passwort hat jede Person mit Zugang zu deinem Mac direkten Einblick in alle deine Bankdaten.",
                    "Without a password, anyone with access to your Mac can directly view all your banking data."
                ))
                .font(ThemeFonts.body(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Warnung-Box
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    t("Nicht empfohlen", "Not recommended"),
                    systemImage: "shield.slash.fill"
                )
                .font(ThemeFonts.body(size: 13, weight: .medium))
                .foregroundColor(.orange)

                Text(t(
                    "Dein Passwort wird im Schlüsselbund gespeichert, damit die App automatisch entsperren kann. Die Verschlüsselung bleibt erhalten — aber der Schutz vor unbefugtem Zugriff entfällt.",
                    "Your password will be stored in the Keychain so the app can auto-unlock. Encryption stays intact — but protection against unauthorized access is removed."
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))

            // Bestätigungs-Checkbox
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: $disablePasswordConfirmed)
                    .toggleStyle(CheckboxToggleStyle())
                    .labelsHidden()
                Text(t(
                    "Jaja, verstanden. Ich möchte das App-Passwort trotzdem deaktivieren.",
                    "Yes, I understand. I still want to disable the app password."
                ))
                .font(ThemeFonts.body(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { disablePasswordConfirmed.toggle() }
            }

            // Fehlermeldung
            if !disablePasswordError.isEmpty {
                Text(disablePasswordError)
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.red)
            }

            // Buttons
            HStack(spacing: 12) {
                Button(t("Abbrechen", "Cancel")) {
                    showDisablePasswordSheet = false
                    disablePasswordConfirmed = false
                    disablePasswordError = ""
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))

                Button(action: { disablePasswordWithVerification() }) {
                    Text(t("Passwort deaktivieren", "Disable password"))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(disablePasswordConfirmed ? Color.orange : Color(NSColor.disabledControlTextColor).opacity(0.3))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!disablePasswordConfirmed)
            }
        }
        .padding(28)
        .frame(width: 420)
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App Icon and Name
            HStack(spacing: 16) {
                Group {
                    if let nsImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    } else {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.accentColor)
                    }
                }
                .onTapGesture {
                    logoTapCount += 1
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("simplebanking")
                        .font(ThemeFonts.heading(size: 20, weight: .bold))
                    if logoTapCount >= 5 {
                        Text("\(t("Version", "Version")) \(appVersionString) (\(t("Build", "Build")) \(appBuildString))")
                            .font(ThemeFonts.body(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(t("Version", "Version")) \(appVersionString)")
                            .font(ThemeFonts.body(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Text("\(t("Erstellt", "Built")): \(appBuildDateFormatted)")
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                AboutRow(label: t("Herausgeber", "Publisher"), value: "Maik Klotz")
                HStack {
                    Text(t("Website", "Website"))
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .leading)
                    Link("simplebanking.de", destination: URL(string: "https://simplebanking.de")!)
                        .font(ThemeFonts.body(size: 13))
                }
                HStack {
                    Text(t("Support", "Support"))
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .leading)
                    Link("support@simplebanking.de", destination: URL(string: "mailto:support@simplebanking.de")!)
                        .font(ThemeFonts.body(size: 13))
                }
                HStack {
                    Text("GitHub")
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .leading)
                    Link("klotzbrocken/simplebanking", destination: URL(string: "https://github.com/klotzbrocken/simplebanking")!)
                        .font(ThemeFonts.body(size: 13))
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Technologie", "Technology"))
                    .font(ThemeFonts.heading(size: 13))
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Swift 5.9 / SwiftUI")
                    HStack(spacing: 4) {
                        Text("•")
                        Link("YAXI PSD2 Banking API", destination: URL(string: "https://yaxi.tech/")!)
                            .foregroundColor(.accentColor)
                        Text("→")
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    Text(t("• AES-256-GCM Verschlüsselung", "• AES-256-GCM encryption"))
                    Text(t("• macOS Keychain Integration", "• macOS Keychain integration"))
                }
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)
            }
            
            // YAXI Info Box
            HStack(spacing: 10) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Powered by YAXI", "Powered by YAXI"))
                        .font(ThemeFonts.body(size: 12, weight: .medium))
                    Link("yaxi.tech", destination: URL(string: "https://yaxi.tech/")!)
                        .font(ThemeFonts.body(size: 11))
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )

            // Clippy Open-Source & Lizenzen
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("📎")
                        .font(.system(size: 13))
                    Text("Open-Source & Lizenzen")
                        .font(ThemeFonts.body(size: 12, weight: .medium))
                }
                Text("Diese App verwendet Teile des Open-Source-Projekts \u{201E}Clippy\u{201C} von Felix Rieseberg (MIT-Lizenz). Der Programmcode dieser App steht unter der MIT-Lizenz.")
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
                Link("→ felixrieseberg/clippy auf GitHub", destination: URL(string: "https://github.com/felixrieseberg/clippy/")!)
                    .font(ThemeFonts.body(size: 11))
                Text("Die Figur \u{201E}Clippy\u{201C}, zugeh\u{00F6}rige Bilder und andere Marken sind urheberrechtlich und markenrechtlich Eigentum der Microsoft Corporation. Die Verwendung dieser Inhalte in dieser App erfolgt ausschlie\u{00DF}lich zu nostalgischen und edukativen Zwecken und begr\u{00FC}ndet keine Rechte an geistigem Eigentum von Microsoft.")
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.07))
            )

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(t("Protokollierung", "Logging"))
                    .font(ThemeFonts.heading(size: 13))

                Text(t("Diagnose-Logs in eine lokale Datei schreiben.", "Write diagnostic logs to a local file."))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)

                SettingsToggleRow(
                    title: t("Logging aktivieren", "Enable logging"),
                    subtitle: t("Speichert Laufzeit- und Netzwerkereignisse", "Stores runtime and network events"),
                    isOn: $appLoggingEnabled
                )

                HStack(spacing: 8) {
                    Button(t("Log öffnen", "Open log")) {
                        openLogFile()
                    }
                    .buttonStyle(.bordered)

                    Button(t("Log leeren", "Clear log")) {
                        clearLogFile()
                    }
                    .buttonStyle(.bordered)
                }

                Text(AppLogger.logFileURL.path)
                    .font(ThemeFonts.body(size: 10))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                if !logStatusMessage.isEmpty {
                    Text(logStatusMessage)
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Text(t("© 2026 Maik Klotz. Alle Rechte vorbehalten.", "© 2026 Maik Klotz. All rights reserved."))
                .font(ThemeFonts.body(size: 11))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Labs Settings

    private var labsSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            // AI Assistant
            aiAssistantSettings

            Divider()

            // Gehaltsring
            SettingsToggleRow(
                title: t("Gehaltsring anzeigen", "Show Salary Ring"),
                subtitle: t(
                    "Zeigt einen Ring im Flyout und in der Umsatzliste, der angibt wie viel vom Gehalt noch übrig ist. Wird im Mehrkonto-Ansicht automatisch ausgeblendet.",
                    "Shows a ring in the flyout and transaction list indicating how much of the salary remains. Hidden automatically in multi-account view."
                ),
                isOn: $monthRingEnabled
            )

            Divider()

            // Change 3 — AI categorization toggle
            SettingsToggleRow(
                title: t("AI-Transaktions-Kategorisierung", "AI Transaction Categorization"),
                subtitle: t(
                    "Unkategorisierte Umsätze werden nach dem Abruf automatisch über den aktiven KI-Anbieter kategorisiert.",
                    "Uncategorized transactions are automatically categorized via the active AI provider after fetching."
                ),
                isOn: $aiCategorizationEnabled
            )

            Divider()

            // Brandfetch Logos
            SettingsToggleRow(
                title: t("Brandfetch Händler-Logos", "Brandfetch Merchant Logos"),
                subtitle: t(
                    "Lädt Logos bekannter Marken über Brandfetch. Es werden ausschließlich Firmennamen (keine IBANs, Beträge oder Transaktionsdaten) übermittelt.",
                    "Fetches logos for known brands via Brandfetch. Only company names are transmitted — no IBANs, amounts, or transaction data."
                ),
                isOn: $brandfetchEnabled
            )

            if brandfetchEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Brandfetch Client ID", "Brandfetch Client ID"))
                        .font(ThemeFonts.body(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField(t("Client ID (c=...)", "Client ID (c=...)"), text: $brandfetchClientId)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(ThemeFonts.body(size: 12))
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            // Claude / MCP
            mcpSettings

            Divider()

            // Logo Cache löschen
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Logo-Cache löschen", "Clear Logo Cache"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                    Text(t(
                        "Alle gespeicherten Logos werden gelöscht und beim nächsten Anzeigen neu geladen.",
                        "All cached logos are deleted and reloaded on next display."
                    ))
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
                    if !logoCacheClearStatus.isEmpty {
                        Text(logoCacheClearStatus)
                            .font(ThemeFonts.body(size: 11))
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    }
                }
                Spacer()
                Button(t("Löschen", "Clear")) {
                    MerchantLogoService.shared.clearCache()
                    logoCacheClearStatus = t("Cache geleert.", "Cache cleared.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        logoCacheClearStatus = ""
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: brandfetchEnabled)
    }

    // MARK: - MCP Settings

    private var mcpConfigJSON: String {
        let mcpPath = Bundle.main.bundlePath + "/Contents/MacOS/simplebanking-mcp"
        return """
        {
          "mcpServers": {
            "simplebanking": {
              "command": "\(mcpPath)"
            }
          }
        }
        """
    }

    private func autoSetupMCP() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        let mcpPath = Bundle.main.bundlePath + "/Contents/MacOS/simplebanking-mcp"

        var config: [String: Any] = [:]
        var existingData: Data? = nil
        if let data = try? Data(contentsOf: configURL) {
            existingData = data
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                config = parsed
            }
        }

        if let existing = (config["mcpServers"] as? [String: Any])?["simplebanking"] as? [String: Any],
           existing["command"] as? String == mcpPath {
            mcpSetupState = .alreadySet
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { mcpSetupState = .idle }
            return
        }

        if let data = existingData, !data.isEmpty {
            let backupURL = configURL.deletingLastPathComponent()
                .appendingPathComponent("claude_desktop_config.backup.json")
            try? data.write(to: backupURL, options: .atomic)
        }

        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["simplebanking"] = ["command": mcpPath]
        config["mcpServers"] = servers

        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: configURL, options: .atomic)) != nil else {
            mcpSetupState = .error(t("Schreiben fehlgeschlagen", "Write failed"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { mcpSetupState = .idle }
            return
        }
        mcpSetupState = .success
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { mcpSetupState = .idle }
    }

    private var mcpSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Claude / MCP", "Claude / MCP"))
                .font(ThemeFonts.heading(size: 13))

            Text(t(
                "Der integrierte MCP-Server ermöglicht Claude Desktop direkten Lesezugriff auf deine lokalen Transaktionsdaten — ohne laufende App, ohne Internet.",
                "The built-in MCP server lets Claude Desktop read your local transaction data directly — no running app, no internet required."
            ))
            .font(ThemeFonts.body(size: 12))
            .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(t(
                    "Füge dies in ~/Library/Application Support/Claude/claude_desktop_config.json ein:",
                    "Add this to ~/Library/Application Support/Claude/claude_desktop_config.json:"
                ))
                .font(ThemeFonts.body(size: 11))
                .foregroundColor(.secondary)

                Text(mcpConfigJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcpConfigJSON, forType: .string)
                    mcpConfigCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { mcpConfigCopied = false }
                } label: {
                    Label(
                        mcpConfigCopied ? t("Kopiert!", "Copied!") : t("Config kopieren", "Copy config"),
                        systemImage: mcpConfigCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    autoSetupMCP()
                } label: {
                    switch mcpSetupState {
                    case .idle:
                        Label(t("Automatisch einrichten", "Set up automatically"), systemImage: "sparkles")
                    case .success:
                        Label(t("Eingerichtet! Claude neu starten.", "Done! Restart Claude."), systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .alreadySet:
                        Label(t("Bereits eingerichtet", "Already configured"), systemImage: "checkmark")
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle")
                            .foregroundColor(.red)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(mcpSetupState != .idle)
            }
        }
    }

    private func resetApp() {
        // Delete all credentials, DB files, attachments (all slots)
        CredentialsStore.deleteAllData()
        BiometricStore.clear()
        BiometricStore.clearAutoUnlock()
        llmAPIKeyPresent = false
        publishAPIKeyChanged(nil)

        // Clear YAXI keychain sessions for all slots
        let allSlotIds = MultibankingStore.shared.slots.map { $0.id } + ["legacy"]
        Task {
            for slotId in allSlotIds {
                await YaxiService.clearSessionData(forSlotId: slotId)
            }
        }

        // Reset all UserDefaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // Close settings and trigger app restart hint
        dismiss()
    }
}

private struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(ThemeFonts.body(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThemeFonts.body(size: 13, weight: .medium))
                Text(subtitle)
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
        }
    }
}

private struct AboutRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(ThemeFonts.body(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(ThemeFonts.body(size: 13))
        }
    }
}

// MARK: - Settings Panel

@MainActor
final class SettingsPanel {
    private var window: NSWindow?

    private func localizedTitle() -> String {
        L10n.t("Einstellungen", "Settings")
    }

    func refreshWindowTitle() {
        window?.title = localizedTitle()
    }
    
    func show() {
        if let existing = window, existing.isVisible {
            existing.title = localizedTitle()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = localizedTitle()
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
