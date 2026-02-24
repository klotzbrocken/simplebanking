import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

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
    case minutes360 = 360
    
    var label: String {
        switch self {
        case .manual: return L10n.t("Manuell", "Manual")
        case .minutes60: return L10n.t("60 Minuten", "60 minutes")
        case .minutes120: return L10n.t("120 Minuten", "120 minutes")
        case .minutes180: return L10n.t("180 Minuten", "180 minutes")
        case .minutes360: return L10n.t("360 Minuten", "360 minutes")
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
    @AppStorage("loadTransactionsOnStart") private var loadTransactionsOnStart: Bool = false
    @AppStorage("refreshInterval") private var refreshInterval: Int = 60
    @AppStorage("resetAttempts") private var resetAttempts: Int = 0
    @AppStorage("swapClickBehavior") private var swapClickBehavior: Bool = false
    @AppStorage("infiniteScrollEnabled") private var infiniteScrollEnabled: Bool = false
    @AppStorage("balanceClickMode") private var balanceClickMode: Int = BalanceClickMode.mouseClick.rawValue
    @AppStorage("llmAPIKeyPresent") private var llmAPIKeyPresent: Bool = false
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
    @AppStorage("confettiEnabled") private var confettiEnabled: Bool = true
    @AppStorage("confettiEffect") private var confettiEffect: Int = ConfettiEffect.money.rawValue
    @AppStorage("confettiOnBalanceThreshold") private var confettiOnBalanceThreshold: Bool = true
    @AppStorage("confettiBalanceThreshold") private var confettiBalanceThreshold: Int = 3000
    @AppStorage("confettiOnNewIncome") private var confettiOnNewIncome: Bool = true
    @AppStorage(MerchantResolver.pipelineEnabledKey) private var effectiveMerchantPipelineEnabled: Bool = true
    
    @State private var selectedTab: Int = 0
    @State private var showResetConfirmation: Bool = false
    @State private var notificationStatus: String = ""
    @State private var touchIDAvailable: Bool = false
    @State private var touchIDEnabled: Bool = false
    @AppStorage("biometricOfferDismissed") private var biometricOfferDismissed: Bool = false
    @State private var anthropicAPIKeyInput: String = ""
    @State private var aiStatusMessage: String = ""
    @State private var availableThemes: [AppTheme] = []
    @State private var logStatusMessage: String = ""
    @State private var merchantResolutionStatusMessage: String = ""
    @State private var didInitialMerchantRefresh: Bool = false
    
    @Environment(\.dismiss) private var dismiss

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
            try CredentialsStore.saveAPIKey(normalized, masterPassword: masterPassword)
            let key = normalized.isEmpty ? nil : normalized
            llmAPIKeyPresent = key != nil
            publishAPIKeyChanged(key)
            anthropicAPIKeyInput = ""
            aiStatusMessage = key == nil ? t("API-Key entfernt.", "API key removed.") : t("API-Key gespeichert.", "API key saved.")
        } catch {
            aiStatusMessage = "\(t("Speichern fehlgeschlagen", "Saving failed")): \(error.localizedDescription)"
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
            try CredentialsStore.saveAPIKey(nil, masterPassword: masterPassword)
            llmAPIKeyPresent = false
            publishAPIKeyChanged(nil)
            aiStatusMessage = t("API-Key entfernt.", "API key removed.")
        } catch {
            aiStatusMessage = "\(t("Entfernen fehlgeschlagen", "Removing failed")): \(error.localizedDescription)"
        }
    }

    private var appVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var appBuildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var appBuildTimestamp: String {
        Bundle.main.object(forInfoDictionaryKey: "SBBuildTimestamp") as? String ?? "-"
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
                TabButton(title: t("Finanzen", "Finance"), icon: "chart.pie", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
                TabButton(title: t("Verhalten", "Behavior"), icon: "cursorarrow.click.2", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
                TabButton(title: t("Sicherheit", "Security"), icon: "lock.shield", isSelected: selectedTab == 3) {
                    selectedTab = 3
                }
                TabButton(title: t("Über", "About"), icon: "info.circle", isSelected: selectedTab == 4) {
                    selectedTab = 4
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
                        financeSettings
                    case 2:
                        behaviorSettings
                    case 3:
                        securitySettings
                    case 4:
                        aboutSection
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

            Divider()

            aiAssistantSettings
            Divider()
            
            // Refresh Interval
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Abfrage-Intervall", "Refresh interval"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Wie oft soll der Kontostand automatisch abgefragt werden?", "How often should the balance be refreshed automatically?"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
                
                Picker("", selection: $refreshInterval) {
                    ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                        Text(interval.label).tag(interval.rawValue)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: 200)
            }
        }
    }

    private var aiAssistantSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("AI-Assistent", "AI assistant"))
                .font(ThemeFonts.heading(size: 13))

            Text(t("Anthropic API-Key für Umsatz-Fragen. Der Key wird verschlüsselt gespeichert.", "Anthropic API key for transaction questions. The key is stored encrypted."))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(llmAPIKeyPresent ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(llmAPIKeyPresent ? t("API-Key gesetzt", "API key set") : t("Kein API-Key gesetzt", "No API key set"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
            }

            SecureField("sk-ant-...", text: $anthropicAPIKeyInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack(spacing: 8) {
                Button(llmAPIKeyPresent ? t("API-Key aktualisieren", "Update API key") : t("API-Key speichern", "Save API key")) {
                    saveAnthropicAPIKey()
                }
                .buttonStyle(.borderedProminent)

                Button(t("API-Key entfernen", "Remove API key")) {
                    removeAnthropicAPIKey()
                }
                .buttonStyle(.bordered)
                .disabled(!llmAPIKeyPresent)
            }

            if !aiStatusMessage.isEmpty {
                Text(aiStatusMessage)
                    .font(ThemeFonts.body(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Finance Settings
    
    private var financeSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Abruf-Zeitraum
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Abruf-Zeitraum", "Fetch range"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Wie viele Tage an Transaktionen sollen abgerufen werden?", "How many days of transactions should be fetched?"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    Picker("Tage", selection: $fetchDays) {
                        Text(t("30 Tage", "30 days")).tag(30)
                        Text(t("60 Tage", "60 days")).tag(60)
                        Text(t("90 Tage", "90 days")).tag(90)
                        Text(t("180 Tage", "180 days")).tag(180)
                        Text(t("365 Tage", "365 days")).tag(365)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 120)
                }
            }

            Divider()

            // Balance-Ampel (nur Default-Theme)
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Balance-Ampel", "Balance signal"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t(
                    "Farb- und Statusanzeige für den Kontostand in der Umsatzliste.",
                    "Color and status display for the account balance in the transaction list."
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)

                if !isDefaultThemeSelected {
                    Text(t("Nur im Default-Theme aktiv.", "Only active in the Default theme."))
                        .font(ThemeFonts.body(size: 11))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    TextField("500", value: balanceSignalLowBinding, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 110)
                        .disabled(!isDefaultThemeSelected)
                    Text(t("Niedriger Stand bis (€)", "Low balance up to (€)"))
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    TextField("2000", value: balanceSignalMediumBinding, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 110)
                        .disabled(!isDefaultThemeSelected)
                    Text(t("Mittlerer Stand bis (€)", "Medium balance up to (€)"))
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                }

                let low = Int(normalizedBalanceSignalThresholds.lowUpperBound)
                let medium = Int(normalizedBalanceSignalThresholds.mediumUpperBound)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(BalanceSignal.style(for: .overdraft).amountColor).frame(width: 10, height: 10)
                        Text(t("< 0 €: Konto überzogen", "< 0 €: Account overdrawn"))
                            .font(ThemeFonts.body(size: 11))
                    }
                    HStack(spacing: 8) {
                        Circle().fill(BalanceSignal.style(for: .low).amountColor).frame(width: 10, height: 10)
                        Text(t("0 € bis unter \(low) €: Niedriger Stand", "0 € to below \(low) €: Low balance"))
                            .font(ThemeFonts.body(size: 11))
                    }
                    HStack(spacing: 8) {
                        Circle().fill(BalanceSignal.style(for: .medium).amountColor).frame(width: 10, height: 10)
                        Text(t("\(low) € bis \(medium) €: Mittlerer Stand", "\(low) € to \(medium) €: Medium balance"))
                            .font(ThemeFonts.body(size: 11))
                    }
                    HStack(spacing: 8) {
                        Circle().fill(BalanceSignal.style(for: .good).amountColor).frame(width: 10, height: 10)
                        Text(t("> \(medium) €: Gutes Polster", "> \(medium) €: Healthy buffer"))
                            .font(ThemeFonts.body(size: 11))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cardBackground)
                )
                .opacity(isDefaultThemeSelected ? 1 : 0.7)
            }

            Divider()
            
            // Gehaltsdatum
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Gehaltseingang", "Salary incoming day"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Tag des Monats, an dem dein Gehalt eingeht. Die Finanzanalyse wird entsprechend berechnet.", "Day of month when salary arrives. Financial analysis uses this setting."))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Picker("Tag", selection: $salaryDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day).").tag(day)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 80)
                    
                    Text(t("des Monats", "of the month"))
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Ziel-Puffer
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Monatlicher Ziel-Puffer", "Monthly target buffer"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Wie viel sollte nach Abzug aller Ausgaben übrig bleiben? Beeinflusst die Einnahmen-Deckung im Score.", "How much should remain after all expenses? Affects income coverage in the score."))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    TextField("500", value: $targetBuffer, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                    
                    Text("€")
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Ziel-Sparrate
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Ziel-Sparrate", "Target savings rate"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Wie viel Prozent deines Einkommens möchtest du sparen? Faustregel: 20% (50/30/20 Regel).", "How much of your income do you want to save? Rule of thumb: 20% (50/30/20 rule)."))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    TextField("20", value: $targetSavingsRate, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)
                    
                    Text("%")
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Dispositionskredit
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Dispositionskredit", "Overdraft limit"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Dein Dispo-Limit für die Statistik. Leer lassen, wenn kein Dispo vorhanden.", "Your overdraft limit for statistics. Leave empty if no overdraft exists."))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    TextField("0", value: $dispoLimit, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                    
                    Text("€")
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Info-Box
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
                        Text(t("Einnahmendeckung: Verhältnis + Puffer (\(targetBuffer)€)", "Income coverage: ratio + buffer (\(targetBuffer)€)"))
                            .font(ThemeFonts.body(size: 11))
                    }
                    HStack(spacing: 8) {
                        Circle().fill(Color.cyan).frame(width: 10, height: 10)
                        Text(t("Sparrate: Ziel ist \(targetSavingsRate)% Überschuss", "Savings rate: target is \(targetSavingsRate)% surplus"))
                            .font(ThemeFonts.body(size: 11))
                    }
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Text(t("Stabilität: Variable Ausgaben ohne Fixkosten", "Stability: variable expenses without fixed costs"))
                            .font(ThemeFonts.body(size: 11))
                    }
                    if dispoLimit > 0 {
                        HStack(spacing: 8) {
                            Circle().fill(Color.orange).frame(width: 10, height: 10)
                            Text(t("Dispo-Nutzung: Tage & Höhe im Minus", "Overdraft usage: days and depth below zero"))
                                .font(ThemeFonts.body(size: 11))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cardBackground)
                )
            }
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
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Sprache", "Language"))
                    .font(ThemeFonts.heading(size: 13))

                Picker("", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                        Text(language.pickerLabel).tag(language.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: 320)
            }

            Divider()

            // Theme (colors + typography from cfg files)
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Theme", "Theme"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t(
                    "Wähle ein Theme aus .cfg-Dateien (Farben + Typografie).",
                    "Choose a theme from .cfg files (colors + typography)."
                ))
                .font(ThemeFonts.body(size: 12))
                .foregroundColor(.secondary)

                Picker("", selection: $themeId) {
                    ForEach(availableThemes, id: \.id) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: 260)

                Text("\(t("Theme-Ordner", "Theme folder")): \(ThemeManager.shared.themesDirectoryPath)")
                    .font(ThemeFonts.body(size: 10))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            // Appearance
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Darstellung", "Appearance"))
                    .font(ThemeFonts.heading(size: 13))

                Picker("", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: 300)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(t("Konfetti in der Umsatzliste", "Confetti in transaction list"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Beim Öffnen der Umsatzliste optional anzeigen.", "Optionally show when opening the transaction list."))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)

                SettingsToggleRow(
                    title: t("Konfetti aktivieren", "Enable confetti"),
                    subtitle: t("Effekt grundsätzlich einschalten", "Enable the effect globally"),
                    isOn: $confettiEnabled
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Konfetti-Effekt", "Confetti effect"))
                        .font(ThemeFonts.body(size: 12, weight: .medium))

                    Picker("", selection: $confettiEffect) {
                        ForEach(ConfettiEffect.allCases, id: \.rawValue) { effect in
                            Text(effect.label).tag(effect.rawValue)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(maxWidth: 220)
                    .disabled(!confettiEnabled)
                }

                SettingsToggleRow(
                    title: t("Bei Kontostand über Schwellwert", "When balance exceeds threshold"),
                    subtitle: t("Löst aus, wenn dein Kontostand hoch genug ist", "Triggers when your account balance is high enough"),
                    isOn: $confettiOnBalanceThreshold
                )
                .disabled(!confettiEnabled)

                HStack(spacing: 8) {
                    TextField("3000", value: $confettiBalanceThreshold, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 110)
                        .disabled(!confettiEnabled || !confettiOnBalanceThreshold)
                    Text(t("€ Schwellwert", "€ threshold"))
                        .font(ThemeFonts.body(size: 13))
                        .foregroundColor(.secondary)
                }

                SettingsToggleRow(
                    title: t("Bei neuer Einnahme", "On new income"),
                    subtitle: t("Löst aus, wenn seit dem letzten Öffnen ein neuer Geldeingang da ist", "Triggers when a new incoming payment appears since the last open"),
                    isOn: $confettiOnNewIncome
                )
                .disabled(!confettiEnabled)
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
                                .padding(.horizontal, 16)
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
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color(NSColor.controlAccentColor))
                                .foregroundColor(.white)
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

            VStack(alignment: .leading, spacing: 8) {
                Text(t("simplebanking zurücksetzen", "Reset simplebanking"))
                    .font(ThemeFonts.heading(size: 13))
                Text(t("Alle Zugangsdaten und Einstellungen löschen", "Delete all credentials and settings"))
                    .font(ThemeFonts.body(size: 12))
                    .foregroundColor(.secondary)

                Button(action: { showResetConfirmation = true }) {
                    Text(t("Zurücksetzen…", "Reset…"))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
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
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App Icon and Name
            HStack(spacing: 16) {
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
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("simplebanking")
                        .font(ThemeFonts.heading(size: 20, weight: .bold))
                    Text("\(t("Version", "Version")) \(appVersionString) (\(t("Build", "Build")) \(appBuildString))")
                        .font(ThemeFonts.body(size: 12))
                        .foregroundColor(.secondary)
                    Text("\(t("Erstellt", "Built")): \(appBuildTimestamp)")
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
    
    private func resetApp() {
        // Delete credentials
        try? CredentialsStore.delete()
        try? TransactionsDatabase.deleteDatabaseFileIfExists()
        llmAPIKeyPresent = false
        publishAPIKeyChanged(nil)
        
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
