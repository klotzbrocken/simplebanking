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
/// Sets controlSize = .regular explicitly so the natural height matches the
/// SwiftUI RoundedBorderTextField / segmented Picker it sits next to.
private class _FixedWidthPopUpButton: NSPopUpButton {
    var targetWidth: CGFloat = 160

    override init(frame: NSRect, pullsDown flag: Bool) {
        super.init(frame: frame, pullsDown: flag)
        self.controlSize = .regular
        self.font = .systemFont(ofSize: NSFont.systemFontSize)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

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
        let btn = _FixedWidthPopUpButton(frame: .zero, pullsDown: false)
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
    @AppStorage("dockModeEnabled") private var dockModeEnabled: Bool = false
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
    
    // Greenring + MMI
    @AppStorage("greenZoneIncludeOtherIncome") private var greenZoneIncludeOtherIncome: Bool = false
    @AppStorage("greenZoneShowDispo") private var greenZoneShowDispo: Bool = true
    @AppStorage("mmiIncludeSavings") private var mmiIncludeSavings: Bool = true

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

    @State private var selectedTab: Int = 0
    @State private var showResetConfirmation: Bool = false
    @State private var slotToDelete: BankSlot? = nil
    @State private var showSlotDeleteConfirmation: Bool = false
    @State private var slotBeingRenamed: BankSlot? = nil
    @State private var slotBeingImported: BankSlot? = nil
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
    @State private var cliInstalled: Bool = CLIInstaller.isInstalled
    @State private var cliStatusMessage: String = ""
    @State private var cliStatusIsError: Bool = false

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
            .padding(.top, 12)

            Divider()
                .padding(.top, 8)
            
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
        .frame(width: 520, height: 520)
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
            VStack(alignment: .leading, spacing: 14) {
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
                            .foregroundColor(.sbOrangeStrong)
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
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.settingsCard))
        }
    }

    private func postHotkeyChanged() {
        NotificationCenter.default.post(name: Notification.Name("simplebanking.globalHotkeyChanged"), object: nil)
    }

    private var aiAssistantSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: t("AI-Assistent (experimentell)", "AI assistant (experimental)"), icon: "cpu")

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
                    .fill(activeProviderHasKey ? Color.sbGreenStrong : Color.sbOrangeStrong)
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
                SettingsSectionHeader(title: t("Verbundene Konten", "Connected Accounts"), icon: "building.columns")

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
                                    slotBeingImported = slot
                                }) {
                                    Image(systemName: "arrow.down.doc").foregroundColor(.secondary)
                                        .help(t("Umsätze importieren", "Import transactions"))
                                }.buttonStyle(PlainButtonStyle())
                                Button(action: {
                                    slotToDelete = slot
                                    showSlotDeleteConfirmation = true
                                }) {
                                    Text(t("Entfernen", "Remove"))
                                        .foregroundColor(.sbRedStrong).font(ThemeFonts.body(size: 12))
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
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
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
            .sheet(item: $slotBeingImported) { slot in
                ImportSheet(
                    slotId: slot.id,
                    bankDisplayName: slot.displayName.isEmpty ? slot.iban : slot.displayName,
                    requestMasterPassword: { requestMasterPassword() },
                    onClose: { slotBeingImported = nil }
                )
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.settingsCard))

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
                    SettingsSectionHeader(title: t("Konto-Einstellungen", "Account Settings"), icon: "slider.horizontal.3")
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
                        // ─── Card 1: Stammdaten ────────────────────────────
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsSectionHeader(
                                title: t("Stammdaten", "Basics"),
                                icon: "slider.horizontal.3"
                            )

                            SettingsRow(
                                title: t("Auto-Sync-Zeitraum", "Auto-sync range"),
                                subtitle: t("Automatisch synchronisiert. Älteren Zeitraum einmalig laden: Import.",
                                            "Automatically synced. Load older history once: Import.")
                            ) {
                                AccountMenuPicker(
                                    items: [
                                        (title: t("30 Tage", "30 days"), value: 30),
                                        (title: t("60 Tage", "60 days"), value: 60),
                                        (title: t("90 Tage", "90 days"), value: 90),
                                    ],
                                    selection: Binding(
                                        get: { currentSlotSettings.fetchDays },
                                        set: { currentSlotSettings.fetchDays = $0; saveCurrentSlotSettings() }
                                    ),
                                    width: _settingsGehaltsPickerWidth
                                )
                            }

                            // Gehaltseingang — mehrzeilig (chip buttons + optional day picker)
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
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.settingsCard))

                        // ─── Card 2: Finanz-Ziele ──────────────────────────
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsSectionHeader(
                                title: t("Finanz-Ziele", "Financial targets"),
                                icon: "target"
                            )

                            SettingsRow(
                                title: t("Monatlicher Ziel-Puffer", "Monthly target buffer"),
                                subtitle: t("Wie viel soll nach allen Ausgaben übrig bleiben?",
                                            "How much should remain after all expenses?")
                            ) {
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

                            SettingsRow(
                                title: t("Ziel-Sparrate", "Target savings rate"),
                                subtitle: t("Ziel-Sparquote (50/30/20 Regel: 20 %)",
                                            "Target savings ratio (50/30/20 rule: 20%)")
                            ) {
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

                            SettingsRow(
                                title: t("Dispositionskredit", "Overdraft limit"),
                                subtitle: t("Dispo-Limit für die Score-Statistik. 0 = kein Dispo.",
                                            "Overdraft limit for score stats. 0 = none.")
                            ) {
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

                            SettingsRow(
                                title: t("Dispo ist im Kontostand enthalten",
                                         "Overdraft included in balance"),
                                subtitle: t("Aktiviere dies, wenn deine Bank den Kontostand inkl. Dispokredit liefert (z.B. C24). Dispo wird dann abgezogen.",
                                            "Enable this if your bank reports the balance with the overdraft already included (e.g. C24). The overdraft is then subtracted.")
                            ) {
                                Toggle("", isOn: Binding(
                                    get: { currentSlotSettings.creditLimitIncluded },
                                    set: { currentSlotSettings.creditLimitIncluded = $0; saveCurrentSlotSettings() }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.settingsCard))

                        // ─── Card 3: Kontostand-Schwellen (was "Money Mood") ─
                        VStack(alignment: .leading, spacing: 10) {
                            SettingsSectionHeader(
                                title: t("Kontostand-Schwellen", "Balance thresholds"),
                                icon: "chart.bar.fill"
                            )
                            Text(t("Bei welchem Kontostand wechselt die Stimmung des Symbols?",
                                   "At what balance does the indicator change mood?"))
                                .font(ThemeFonts.body(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            // Kritisch ab
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                                Text(t("Kritisch ab", "Critical below"))
                                    .font(ThemeFonts.body(size: 12)).foregroundColor(.secondary)
                            }

                            // Komfortzone ab
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                                    Text(t("Komfortzone ab", "Comfort zone from"))
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

                            // Nettogehalt / Monat — setzt gleichzeitig die Grün-Schwelle
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                                                currentSlotSettings.balanceSignalMediumUpperBound = suggestedComfortZone(
                                                    salary: clamped,
                                                    low: currentSlotSettings.balanceSignalLowUpperBound)
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
                                            : t("Setzt Grün-Schwelle + Ring", "Sets green threshold + ring")
                                        Text(hint)
                                            .font(ThemeFonts.body(size: 11)).foregroundColor(.secondary.opacity(0.7))
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.settingsCard))
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

            // ── Kontoring ───────────────────────────────────────
            SettingsSectionHeader(title: t("Kontoring", "Account Ring"), icon: "circle.dotted")

            SettingsToggleRow(
                title: t("Kontoring anzeigen", "Show Account Ring"),
                subtitle: t(
                    "Zeigt einen Ring im Flyout und in der Umsatzliste, der deinen Kontostand ins Verhältnis zu deinem Gehalt setzt und zeigt, ob du bis zum nächsten Gehalt im grünen Bereich bist.",
                    "Shows a ring in the flyout and transaction list that compares your balance to your salary and indicates whether you're in the green until next payday."
                ),
                isOn: $monthRingEnabled
            )

            SettingsToggleRow(
                title: t("Weitere Einnahmen berücksichtigen", "Include other income"),
                subtitle: t(
                    "Berücksichtigt zusätzliche positive Einnahmen im laufenden Zeitraum. Aus ist konservativer und orientiert sich nur am Gehalt.",
                    "Includes additional positive income in the current period. Off is more conservative and only considers salary."
                ),
                isOn: $greenZoneIncludeOtherIncome
            )

            SettingsToggleRow(
                title: t("Dispo im Ring anzeigen", "Show overdraft in ring"),
                subtitle: t(
                    "Zeigt verfügbaren Dispo zusätzlich im Ring. Dispo gilt dabei nicht als echtes Guthaben, sondern nur als verfügbarer Kreditrahmen.",
                    "Shows available overdraft in the ring. Overdraft is not treated as real balance, only as available credit."
                ),
                isOn: $greenZoneShowDispo
            )

            // Info-Box: Kontoring
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.sbBlueStrong)
                    Text(t("Wie wird der Kontoring berechnet?", "How is the Account Ring calculated?"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                }
                Text(t(
                    "Der Kontoring zeigt, wie dein aktueller Kontostand im Verhältnis zu deinem monatlichen Referenzwert steht. Ein voller Ring bedeutet: Du hast genug Puffer bis zum nächsten Eingang. Bei negativem Kontostand wechselt der Ring in den Dispo-Modus.",
                    "The Account Ring shows your current balance relative to your monthly reference value. A full ring means you have enough buffer until the next income. When your balance is negative, the ring switches to overdraft mode."
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // ── Money Mass Index (MMI) ────────────────────────────
            SettingsSectionHeader(title: "Money Mass Index (MMI)", icon: "chart.pie")

            SettingsToggleRow(
                title: t("Sparbewegungen einbeziehen", "Include savings"),
                subtitle: t(
                    "Zählt erkannte Spar- und Vorsorgebewegungen positiv in die Sparrate ein, zum Beispiel ETF, Depot oder Sparplan.",
                    "Counts detected savings and investment outflows positively in the savings rate, e.g. ETF, depot, or savings plans."
                ),
                isOn: $mmiIncludeSavings
            )

            // Info-Box: MMI
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.sbBlueStrong)
                    Text(t("Wie wird der MMI berechnet?", "How is the MMI calculated?"))
                        .font(ThemeFonts.body(size: 13, weight: .medium))
                }
                Text(t(
                    "Der MMI ist ein normierter Wert zwischen 0 und 1. Er verbindet zwei Fragen: Sparst du im betrachteten Zeitraum Geld, und wie groß ist dein aktueller Puffer gemessen an deinen Ausgaben?",
                    "The MMI is a normalized value between 0 and 1. It combines two questions: Are you saving money in the selected period, and how large is your buffer relative to your expenses?"
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("SR")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .frame(width: 28, alignment: .leading)
                        Text(t(
                            "Sparrate: (Einkommen − Ausgaben + Sparbewegungen) / Einkommen. Aktives Sparen kann positiv mitgezählt werden.",
                            "Savings rate: (income − expenses + savings) / income. Active savings can count positively."
                        ))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text("BF")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(MMIColors.liquid)
                            .frame(width: 28, alignment: .leading)
                        Text(t(
                            "Puffer-Faktor: Kontostand im Verhältnis zu den durchschnittlichen Monatsausgaben. Ein voller Monats-Puffer entspricht 1,0.",
                            "Buffer factor: balance relative to average monthly expenses. One full month of expenses as buffer = 1.0."
                        ))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.settingsCard))
            }
        }
    }
    
    // MARK: - Behavior Settings
    
    private var behaviorSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: t("Mausklick-Verhalten", "Mouse click behavior"), icon: "cursorarrow.click")
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
                    .fill(Color.settingsCard)
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
                SettingsSectionHeader(title: t("Dock", "Dock"), icon: "dock.rectangle")
                Text(t(
                    "Zeige simplebanking zusätzlich im Dock und in ⌘+Tab. Menüleisten-Icon bleibt aktiv.",
                    "Also show simplebanking in the Dock and ⌘+Tab. The menu bar icon stays active."
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)
            }

            SettingsToggleRow(
                title: t("Im Dock anzeigen", "Show in Dock"),
                subtitle: t(
                    "Klick auf das Dock-Icon öffnet die Umsatzliste. ⌘+Q beendet die App.",
                    "Clicking the Dock icon opens the transactions panel. ⌘+Q quits the app."
                ),
                isOn: $dockModeEnabled
            )
            .onChange(of: dockModeEnabled) { _ in
                NotificationCenter.default.post(
                    name: Notification.Name("simplebanking.dockModeChanged"),
                    object: nil
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionHeader(title: t("Kontostand anzeigen", "Show balance"), icon: "eye")
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
                .frame(maxWidth: .infinity)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.settingsCard)
            )

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionHeader(title: t("Intermediär-Auflösung", "Intermediary resolution"), icon: "arrow.triangle.branch")
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
                SettingsSectionHeader(title: t("Effekte", "Effects"), icon: "sparkles")

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
                SettingsSectionHeader(title: t("Touch ID", "Touch ID"), icon: "touchid")
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
                SettingsSectionHeader(title: t("Zurücksetzen nach falscher Kennworteingabe", "Reset after wrong password attempts"), icon: "arrow.counterclockwise.circle")
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
                SettingsSectionHeader(title: t("App-Passwort", "App password"), icon: "lock")

                if passwordRequired {
                    Text(t(
                        "Das App-Passwort schützt deine Bank-Zugangsdaten (Login) im Keychain. Lokal gespeicherte Umsätze (Cache) bleiben für CLI-Tools und MCP-Clients lesbar.",
                        "The app password protects your bank login credentials in the Keychain. Locally cached transactions remain readable by CLI tools and MCP clients."
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
                            .foregroundColor(.sbOrangeStrong)
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
                SettingsSectionHeader(title: t("simplebanking zurücksetzen", "Reset simplebanking"), icon: "trash")
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
                    .foregroundColor(.sbOrangeStrong)
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
                .foregroundColor(.sbOrangeStrong)

                Text(t(
                    "Dein Passwort wird im Schlüsselbund gespeichert, damit die App automatisch entsperren kann. Die Verschlüsselung bleibt erhalten — aber der Schutz vor unbefugtem Zugriff entfällt.",
                    "Your password will be stored in the Keychain so the app can auto-unlock. Encryption stays intact — but protection against unauthorized access is removed."
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.sbOrangeSoft))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.sbOrangeMid, lineWidth: 1))

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
                    .foregroundColor(.sbRedStrong)
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
                                .fill(disablePasswordConfirmed ? Color.sbOrangeStrong : Color(NSColor.disabledControlTextColor).opacity(0.3))
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
                    if let nsImage = AppIconLoader.load() {
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
                SettingsSectionHeader(title: t("Technologie", "Technology"), icon: "cpu")
                
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
                    .foregroundColor(.sbBlueStrong)
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
                    .fill(Color.sbBlueSoft)
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
                SettingsSectionHeader(title: t("Protokollierung", "Logging"), icon: "doc.text")

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

            // Terminal CLI (sb)
            cliSettings

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
            SettingsSectionHeader(title: t("Claude / MCP", "Claude / MCP"), icon: "server.rack")

            Text(t(
                "Der integrierte MCP-Server ermöglicht Claude Desktop direkten Lesezugriff auf deine lokalen Transaktionsdaten — ohne laufende App. Lokaler MCP-Zugriff; Claude kann Inhalte je nach Nutzung weiterverarbeiten.",
                "The built-in MCP server lets Claude Desktop read your local transaction data directly — no running app required. Local MCP access; Claude may process content depending on usage."
            ))
            .font(ThemeFonts.body(size: 12))
            .foregroundColor(.secondary)

            // MCP ist nicht Claude-exklusiv — die Config (command/args/env) ist
            // protokoll-kompatibel mit jedem MCP-Client. AnythingLLM ist der bekannteste
            // Non-Claude-Client; wir erwähnen ihn stellvertretend.
            Text(t(
                "Das Protokoll ist offen: die gleiche Config läuft auch mit anderen MCP-Clients wie AnythingLLM oder Cline.",
                "The protocol is open: the same config works with other MCP clients such as AnythingLLM or Cline."
            ))
            .font(ThemeFonts.body(size: 11))
            .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(t(
                    "Für Claude Desktop: füge dies in ~/Library/Application Support/Claude/claude_desktop_config.json ein. Andere Clients (AnythingLLM u.a.) haben einen eigenen Import-Dialog, nutzen aber dasselbe JSON.",
                    "For Claude Desktop: add this to ~/Library/Application Support/Claude/claude_desktop_config.json. Other clients (AnythingLLM, etc.) have their own import dialog but use the same JSON."
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
                            .foregroundColor(.sbGreenStrong)
                    case .alreadySet:
                        Label(t("Bereits eingerichtet", "Already configured"), systemImage: "checkmark")
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle")
                            .foregroundColor(.sbRedStrong)
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

    // MARK: - CLI Install

    private var cliSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: t("Terminal CLI", "Terminal CLI"), icon: "terminal")

            Text(t(
                "Installiert das Kommandozeilen-Tool `sb` in `~/.local/bin/`. Nutzung: `sb balance`, `sb tx --days 30`, `sb summary`.",
                "Installs the command-line tool `sb` into `~/.local/bin/`. Usage: `sb balance`, `sb tx --days 30`, `sb summary`."
            ))
            .font(ThemeFonts.body(size: 12))
            .foregroundColor(.secondary)

            // Privacy-Hinweis: Die CLI greift direkt auf den unverschlüsselten SQLite-Cache zu
            // — exakt wie `sqlite3 transactions.db` das immer schon konnte. Wir sagen das
            // explizit, damit niemand annimmt, das Master-Passwort würde den Lesezugriff blocken.
            (Text(Image(systemName: "info.circle")) + Text(" ") + Text(t(
                "Liest den unverschlüsselten lokalen Cache unter `~/Library/Application Support/simplebanking/`. Wer Dateisystem-Zugriff auf diesen Mac hat, konnte diese Daten schon immer mit `sqlite3` einsehen — das Master-Passwort schützt nur den Bank-Abruf, nicht den Cache.",
                "Reads the unencrypted local cache under `~/Library/Application Support/simplebanking/`. Anyone with filesystem access to this Mac could already read this data with `sqlite3` — the master password only protects bank fetches, not the cache."
            )))
            .font(ThemeFonts.body(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !CLIInstaller.isAvailable {
                Text(t(
                    "CLI-Binary ist in diesem Build nicht enthalten. Bitte auf eine neuere Version aktualisieren.",
                    "CLI binary is not bundled in this build. Please update to a newer version."
                ))
                .font(ThemeFonts.body(size: 11))
                .foregroundColor(.orange)
            } else {
                HStack(spacing: 8) {
                    if cliInstalled {
                        Label(t("Installiert: ~/.local/bin/sb", "Installed: ~/.local/bin/sb"),
                              systemImage: "checkmark.circle.fill")
                            .font(ThemeFonts.body(size: 12))
                            .foregroundColor(.green)
                    } else {
                        Label(t("Nicht installiert", "Not installed"),
                              systemImage: "xmark.circle")
                            .font(ThemeFonts.body(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if cliInstalled {
                        Button(t("Deinstallieren", "Uninstall")) {
                            performCLIUninstall()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(t("Installieren", "Install")) {
                            performCLIInstall()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if cliInstalled && !CLIInstaller.isInPath {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t(
                            "`~/.local/bin` ist nicht in deinem PATH. Wir können das automatisch eintragen.",
                            "`~/.local/bin` is not in your PATH. We can fix this automatically."
                        ))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.orange)

                        HStack(spacing: 8) {
                            Button(action: performPathAutoFix) {
                                Label(
                                    t("PATH automatisch eintragen", "Add to PATH automatically"),
                                    systemImage: "wand.and.stars"
                                )
                                .font(ThemeFonts.body(size: 11))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)

                            Button(action: performPathLineCopy) {
                                Label(
                                    t("Zeile kopieren", "Copy line"),
                                    systemImage: "doc.on.doc"
                                )
                                .font(ThemeFonts.body(size: 11))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(6)
                }

                if !cliStatusMessage.isEmpty {
                    Text(cliStatusMessage)
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(cliStatusIsError ? .sbRedStrong : .secondary)
                        .transition(.opacity)
                }
            }
        }
    }

    private func performCLIInstall() {
        do {
            try CLIInstaller.install()
            cliInstalled = true
            cliStatusIsError = false
            cliStatusMessage = t("CLI installiert. Öffne ein Terminal und tippe: sb balance",
                                 "CLI installed. Open a terminal and type: sb balance")
        } catch {
            cliInstalled = CLIInstaller.isInstalled
            cliStatusIsError = true
            cliStatusMessage = error.localizedDescription
        }
        clearCLIStatusMessageAfterDelay()
    }

    private func performCLIUninstall() {
        do {
            try CLIInstaller.uninstall()
            cliInstalled = false
            cliStatusIsError = false
            cliStatusMessage = t("CLI entfernt.", "CLI removed.")
        } catch {
            cliStatusIsError = true
            cliStatusMessage = error.localizedDescription
        }
        clearCLIStatusMessageAfterDelay()
    }

    private func performPathAutoFix() {
        do {
            let result = try CLIInstaller.ensurePathInShellRc()
            cliStatusIsError = false
            switch result {
            case .alreadyConfigured(let url):
                cliStatusMessage = t(
                    "PATH war schon konfiguriert (\(url.lastPathComponent)). Terminal neu starten.",
                    "PATH was already configured (\(url.lastPathComponent)). Restart Terminal."
                )
            case .appended(let url):
                cliStatusMessage = t(
                    "Eintrag in \(url.lastPathComponent) hinzugefügt. Terminal neu starten, dann sb verfügbar.",
                    "Added entry to \(url.lastPathComponent). Restart Terminal, then sb is available."
                )
            }
        } catch {
            cliStatusIsError = true
            cliStatusMessage = error.localizedDescription
        }
        clearCLIStatusMessageAfterDelay()
    }

    private func performPathLineCopy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(CLIInstaller.shellRcLine, forType: .string)
        cliStatusIsError = !ok
        cliStatusMessage = ok
            ? t("Zeile in Zwischenablage. Terminal → ~/.zshrc öffnen, ans Ende einfügen, speichern.",
                "Line in clipboard. Open ~/.zshrc in Terminal, paste at end, save.")
            : t("Konnte nicht in Zwischenablage schreiben.",
                "Could not write to clipboard.")
        clearCLIStatusMessageAfterDelay()
    }

    private func clearCLIStatusMessageAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            withAnimation { cliStatusMessage = "" }
        }
    }
}

// Subtle gray for settings section cards — lighter than panelBackground (0.92),
// not pure white. Matches macOS grouped-form card feel.
private extension Color {
    static let settingsCard = Color(NSColor(name: nil) { app in
        app.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 0.22, alpha: 1)
            : NSColor(white: 0.96, alpha: 1)
    })
}

private struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)
        }
        .padding(.bottom, 2)
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

/// Standard label + control row for the Settings panel.
/// Uses firstTextBaseline alignment so controls (dropdowns, text fields,
/// chip buttons) sit on the same optical line as the label — not floating
/// at the top of a multi-line label block.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThemeFonts.body(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing()
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
        window.setContentSize(NSSize(width: 520, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
