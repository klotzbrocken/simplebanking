import AppKit
import Foundation
import SwiftUI
import UserNotifications
import ServiceManagement

// MARK: - Credentials Panel (custom, because NSAlert sizing is limited)

@MainActor
final class CredentialsPanel {
    struct Result {
        let iban: String
        let userId: String
        let password: String
        let bankName: String?
    }

    private let panel: NSPanel
    private let logoView = NSImageView()
    private let ibanField = NSTextField(string: "")
    private let userField = NSTextField(string: "")
    private let passField = NSSecureTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton: NSButton
    private var result: Result? = nil
    private var discoveredBankName: String? = nil
    
    private let baseURL = URL(string: "http://127.0.0.1:8787")!

    init() {
        saveButton = NSButton(title: "Verbinden", target: nil, action: nil)
        
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Bank verbinden"
        panel.isFloatingPanel = true
        panel.level = .floating

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content
        
        // App Logo - load from app bundle resources
        if let logoImage = NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName) {
            logoView.image = logoImage
        }
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        
        // Header with logo and title
        let titleLabel = NSTextField(labelWithString: "SimpleBanking")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        
        let subtitleLabel = NSTextField(labelWithString: "Verbinde dein Bankkonto")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        
        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        
        let headerStack = NSStackView(views: [logoView, titleStack])
        headerStack.orientation = .horizontal
        headerStack.spacing = 12
        headerStack.alignment = .centerY
        
        // Form fields with consistent styling
        func makeLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            return label
        }
        
        func styleTextField(_ field: NSTextField) {
            field.font = .systemFont(ofSize: 13)
            field.bezelStyle = .roundedBezel
            field.focusRingType = .exterior
        }
        
        let ibanLabel = makeLabel("IBAN")
        let userLabel = makeLabel("ANMELDENAME / LEG.-ID")
        let passLabel = makeLabel("PIN")
        
        styleTextField(ibanField)
        styleTextField(userField)
        styleTextField(passField)
        
        ibanField.placeholderString = "DE89 3704 0044 0532 0130 00"
        userField.placeholderString = "z.B. Legitimations-ID"
        passField.placeholderString = "Online-Banking-PIN"
        
        // Status label
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        statusLabel.alignment = .center

        // Buttons
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(onCancel))
        cancel.bezelStyle = .rounded
        
        saveButton.target = self
        saveButton.action = #selector(onSave)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        
        // Make "Verbinden" button prominent
        if #available(macOS 11.0, *) {
            saveButton.hasDestructiveAction = false
        }

        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(NSView()) // Spacer
        buttons.addArrangedSubview(saveButton)
        buttons.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Main stack - compact spacing
        let formStack = NSStackView(views: [
            headerStack,
            ibanLabel, ibanField,
            userLabel, userField,
            passLabel, passField,
            statusLabel,
            buttons
        ])
        formStack.orientation = .vertical
        formStack.spacing = 6
        formStack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        formStack.translatesAutoresizingMaskIntoConstraints = false
        
        // Add extra spacing after header
        formStack.setCustomSpacing(16, after: headerStack)
        // Add spacing before buttons
        formStack.setCustomSpacing(12, after: statusLabel)

        content.addSubview(formStack)

        NSLayoutConstraint.activate([
            formStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            formStack.topAnchor.constraint(equalTo: content.topAnchor),
            formStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            logoView.widthAnchor.constraint(equalToConstant: 48),
            logoView.heightAnchor.constraint(equalToConstant: 48),
            
            ibanField.heightAnchor.constraint(equalToConstant: 28),
            userField.heightAnchor.constraint(equalToConstant: 28),
            passField.heightAnchor.constraint(equalToConstant: 28),
        ])

        panel.initialFirstResponder = ibanField
    }

    func runModal() -> Result? {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        if response == .stop { return result }
        return nil
    }

    @objc private func onSave() {
        let iban = ibanField.stringValue
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let u = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = passField.stringValue
        
        guard !iban.isEmpty else {
            statusLabel.stringValue = "⚠️ Bitte IBAN eingeben"
            statusLabel.textColor = .systemOrange
            NSSound.beep()
            return
        }
        
        guard !u.isEmpty, !p.isEmpty else {
            statusLabel.stringValue = "⚠️ Bitte alle Felder ausfüllen"
            statusLabel.textColor = .systemOrange
            NSSound.beep()
            return
        }
        
        // Just save the data and close - backend config happens after modal
        result = Result(iban: iban, userId: u, password: p, bankName: nil)
        NSApp.stopModal(withCode: .stop)
    }

    @objc private func onCancel() {
        NSApp.stopModal(withCode: .abort)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    @AppStorage("demoMode") private var demoMode: Bool = false
    @AppStorage("demoSeed") private var demoSeed: Int = 123456

    @AppStorage("hideIndex") private var hideIndex: Int = 0 // 0=off, 1=immediate, 2=10s, 3=30s, 4=60s
    @AppStorage("refreshInterval") private var refreshInterval: Int = 60
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    @AppStorage("loadTransactionsOnStart") private var loadTransactionsOnStart: Bool = false
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("swapClickBehavior") private var swapClickBehavior: Bool = false
    @AppStorage("balanceClickMode") private var balanceClickMode: Int = BalanceClickMode.mouseClick.rawValue
    @AppStorage("balanceSignalLowUpperBound") private var balanceSignalLowUpperBound: Int = 500
    @AppStorage("balanceSignalMediumUpperBound") private var balanceSignalMediumUpperBound: Int = 2000
    @AppStorage("llmAPIKeyPresent") private var llmAPIKeyPresent: Bool = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = AppLanguage.system.rawValue
    @AppStorage(ThemeManager.storageKey) private var themeId: String = ThemeManager.defaultThemeID
    @AppStorage("confettiEnabled") private var confettiEnabled: Bool = true
    @AppStorage("confettiOnBalanceThreshold") private var confettiOnBalanceThreshold: Bool = true
    @AppStorage("confettiBalanceThreshold") private var confettiBalanceThreshold: Int = 3000
    @AppStorage("confettiOnNewIncome") private var confettiOnNewIncome: Bool = true
    @AppStorage("confettiInitialShown") private var confettiInitialShown: Bool = false
    @AppStorage("connectedBankDisplayName") private var connectedBankDisplayName: String = ""
    @AppStorage("connectedBankLogoID") private var connectedBankLogoID: String = ""

    @AppStorage("lastSeenTxSig") private var lastSeenTxSig: String = ""
    @AppStorage("confettiLastIncomeTxSig") private var confettiLastIncomeTxSig: String = ""
    private var latestTxSig: String = ""
    
    // Für Balance-Anzeige
    private(set) var lastBalance: Double? = nil

    private var masterPassword: String? = nil
    private var locked: Bool = false

    private var isHiddenBalance: Bool = false
    private var hideTimer: Timer?
    private var pendingLeftClick: DispatchWorkItem?
    private var lastShownTitle: String = "— €"
    
    private var settingsPanel: SettingsPanel?
    private var updateChecker: UpdateChecker?
    private var refreshIntervalObserver: Any?
    private var apiKeyObserver: Any?
    private var languageObserver: Any?
    private var balanceDisplayModeObserver: Any?
    private var backendPreparedIBAN: String? = nil
    private var didTriggerAutoSetupThisLaunch: Bool = false

    private func decoratedTitle(_ title: String) -> String {
        // New booking indicator: dot if unseen newer transactions exist.
        if !latestTxSig.isEmpty, latestTxSig != lastSeenTxSig {
            return "\(title)  ●"
        }
        return title
    }

    private func t(_ de: String, _ en: String) -> String {
        L10n.t(de, en)
    }

    private var activeBalanceClickMode: BalanceClickMode {
        BalanceClickMode(rawValue: balanceClickMode) ?? .mouseClick
    }

    private var isMouseOverBalanceMode: Bool {
        activeBalanceClickMode == .mouseOver
    }

    private func hiddenBalanceMaskTitle() -> String {
        "••.••• €"
    }

    private func configuredColorScheme() -> ColorScheme? {
        switch appearanceMode {
        case 1:
            return .light
        case 2:
            return .dark
        default:
            return nil
        }
    }

    private func updateStatusBalanceTitle() {
        guard let button = statusItem?.button else { return }
        guard !locked else { return }

        if isHiddenBalance {
            button.title = isHoverRevealingBalance ? decoratedTitle(lastShownTitle) : hiddenBalanceMaskTitle()
        } else {
            button.title = decoratedTitle(lastShownTitle)
        }
    }

    private func updateHiddenBalanceTooltip() {
        guard isHiddenBalance else { return }
        if isHoverRevealingBalance {
            statusItem.button?.toolTip = t("Kontostand sichtbar (Mouse-Over)", "Balance visible (mouse over)")
        } else if isMouseOverBalanceMode {
            statusItem.button?.toolTip = t("Kontostand per Mouse-Over anzeigen", "Show balance via mouse over")
        } else {
            statusItem.button?.toolTip = t("Kontostand ausgeblendet", "Balance hidden")
        }
    }

    private func applyBalanceDisplayModeConstraints() {
        guard !locked else { return }

        if isMouseOverBalanceMode {
            balancePopover?.performClose(nil)
            isHiddenBalance = true
            isHoverRevealingBalance = false
            updateStatusBalanceTitle()
            updateHiddenBalanceTooltip()
            return
        }

        if isHoverRevealingBalance {
            isHoverRevealingBalance = false
            updateStatusBalanceTitle()
        }
    }

    private func revealBalanceOnHoverIfNeeded() {
        guard isMouseOverBalanceMode else { return }
        guard !locked, isHiddenBalance else { return }
        guard !isHoverRevealingBalance else { return }
        isHoverRevealingBalance = true
        updateStatusBalanceTitle()
        updateHiddenBalanceTooltip()
    }

    private func hideHoverRevealIfNeeded() {
        guard isMouseOverBalanceMode else { return }
        guard !locked, isHiddenBalance else { return }
        guard isHoverRevealingBalance else { return }
        isHoverRevealingBalance = false
        updateStatusBalanceTitle()
        updateHiddenBalanceTooltip()
    }

    private func cachedBackendConnectionDisplayName() -> String? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stateURL = appSupport
            .appendingPathComponent("com.maik.simplebanking", isDirectory: true)
            .appendingPathComponent("state.json")

        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let value = (json["connectionDisplayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func syncConnectedBankIntoViewModel(iban: String? = nil) {
        var displayName = connectedBankDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.isEmpty, let cachedDisplayName = cachedBackendConnectionDisplayName() {
            displayName = cachedDisplayName
            connectedBankDisplayName = cachedDisplayName
        }
        txVM.connectedBankDisplayName = displayName

        let logoID = connectedBankLogoID.trimmingCharacters(in: .whitespacesAndNewlines)
        txVM.connectedBankLogoID = logoID.isEmpty ? nil : logoID

        if let iban {
            let normalizedIBAN = iban
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            txVM.connectedBankIBAN = normalizedIBAN.isEmpty ? nil : normalizedIBAN
        }
    }

    private func updateConnectedBankState(_ bank: DiscoveredBank, iban: String? = nil) {
        connectedBankDisplayName = bank.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        connectedBankLogoID = bank.logoId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        syncConnectedBankIntoViewModel(iban: iban)
    }

    private func clearConnectedBankState() {
        connectedBankDisplayName = ""
        connectedBankLogoID = ""
        txVM.connectedBankDisplayName = ""
        txVM.connectedBankLogoID = nil
        txVM.connectedBankIBAN = nil
    }

    private let txVM = TransactionsViewModel()
    private var txPanel: TransactionsPanel?
    private var statusMenu: NSMenu?
    private var balancePopover: NSPopover?
    private var statusButtonTrackingArea: NSTrackingArea?
    private var isHoverRevealingBalance: Bool = false

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let iso8601UTCFormatter = ISO8601DateFormatter()

    private static let eurCurrencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .currency
        formatter.currencySymbol = "€"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    private static let eurWholeNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.log("Application did finish launching")
        installEditMenu()
        BackendManager.shared.start()
        do {
            try TransactionsDatabase.migrate()
        } catch {
            print("[DB] Migration failed: \(error.localizedDescription)")
            AppLogger.log("DB migration failed: \(error.localizedDescription)", category: "DB", level: "ERROR")
        }
        TransactionCategorizer.preload()
        Task.detached {
            do {
                try TransactionsDatabase.refreshTransactionCategories()
            } catch {
                AppLogger.log("Category refresh failed: \(error.localizedDescription)", category: "Category", level: "WARN")
            }
        }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let btn = statusItem.button {
             // Create a dummy image to force layout height/alignment
             let img = NSImage(size: NSSize(width: 1, height: 16), flipped: false) { _ in true } // 1x16 to ensure height
             img.isTemplate = true
             btn.image = img
             btn.imagePosition = .imageLeft
             
             btn.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
             btn.title = "— €"
             btn.target = self
             btn.action = #selector(statusItemClicked)
             btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        installStatusButtonTracking()

        // Unlock on startup if encrypted credentials exist (but not in demo mode)
        if CredentialsStore.exists() && !demoMode {
            locked = true
            promptUnlockIfNeeded()
        } else if demoMode {
            // Demo mode starts unlocked with demo data
            locked = false
            Task { await refreshAsync() }
        }

        ThemeManager.shared.ensureThemeFiles()
        ThemeManager.shared.reloadThemes()
        syncConnectedBankIntoViewModel()

        // Build a menu, but don't assign it to statusItem.menu, otherwise left click always opens the menu.
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: t("Aktualisieren", "Refresh"), action: #selector(refresh), keyEquivalent: "r")
        refreshItem.tag = 300
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem.separator())

        let demoItem = NSMenuItem(title: "", action: #selector(toggleDemoMode), keyEquivalent: "d")
        demoItem.tag = 301
        demoItem.state = demoMode ? .on : .off
        menu.addItem(demoItem)
        menu.addItem(NSMenuItem.separator())

        let hideSub = NSMenu()

        let offItem = NSMenuItem(title: t("Aus", "Off"), action: #selector(setHideOff), keyEquivalent: "")
        offItem.tag = 410
        offItem.state = (hideIndex == 0) ? .on : .off
        hideSub.addItem(offItem)

        let tenSecItem = NSMenuItem(title: t("10 Sekunden", "10 seconds"), action: #selector(setHide10), keyEquivalent: "")
        tenSecItem.tag = 412
        tenSecItem.state = (hideIndex == 2) ? .on : .off
        hideSub.addItem(tenSecItem)

        let thirtySecItem = NSMenuItem(title: t("30 Sekunden", "30 seconds"), action: #selector(setHide30), keyEquivalent: "")
        thirtySecItem.tag = 413
        thirtySecItem.state = (hideIndex == 3) ? .on : .off
        hideSub.addItem(thirtySecItem)

        let sixtySecItem = NSMenuItem(title: t("60 Sekunden", "60 seconds"), action: #selector(setHide60), keyEquivalent: "")
        sixtySecItem.tag = 414
        sixtySecItem.state = (hideIndex == 4) ? .on : .off
        hideSub.addItem(sixtySecItem)

        let hideItem = NSMenuItem(title: t("Automatisch verstecken", "Auto-hide"), action: nil, keyEquivalent: "")
        hideItem.tag = 401
        hideItem.submenu = hideSub
        menu.addItem(hideItem)
        menu.addItem(NSMenuItem.separator())

        let lockItem = NSMenuItem(title: "", action: #selector(toggleLock), keyEquivalent: "l")
        lockItem.tag = 999
        menu.addItem(lockItem)

        let setupItem = NSMenuItem(title: t("Einrichtungsassistent…", "Setup Wizard…"), action: #selector(connect), keyEquivalent: "c")
        setupItem.tag = 100
        menu.addItem(setupItem)

        let forgetItem = NSMenuItem(title: t("Zugangsdaten vergessen", "Forget Credentials"), action: #selector(forget), keyEquivalent: "")
        forgetItem.tag = 101
        menu.addItem(forgetItem)
        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: t("Nach Updates suchen…", "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "u")
        updateItem.tag = 202
        menu.addItem(updateItem)

        let settingsItem = NSMenuItem(title: t("Einstellungen…", "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.tag = 200
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: t("Beenden", "Quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.tag = 1000
        menu.addItem(quitItem)

        menu.autoenablesItems = false
        self.statusMenu = menu
        menu.delegate = self
        applyLocalizedMenuTitles()
        syncAutoHideMenuState()

        txPanel = TransactionsPanel(vm: txVM, onRefresh: { [weak self] in
            await self?.openTransactionsPanel()
        }, onSettings: { [weak self] in
            self?.showSettings()
        })
        settingsPanel = SettingsPanel()

        setupRefreshTimer()
        applyAppearance()
        applyBalanceDisplayModeConstraints()
        
        // Observer für Settings-Änderungen
        refreshIntervalObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("RefreshIntervalChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupRefreshTimer()
            }
        }

        apiKeyObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AnthropicAPIKeyChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let value = notification.userInfo?["apiKey"] as? String
            Task { @MainActor in
                let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = (normalized?.isEmpty == false) ? normalized : nil
                self.txVM.anthropicApiKey = key
                self.llmAPIKeyPresent = key != nil
            }
        }

        languageObserver = NotificationCenter.default.addObserver(
            forName: AppLanguage.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.applyLocalizedMenuTitles()
                self.settingsPanel?.refreshWindowTitle()
            }
        }

        balanceDisplayModeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("BalanceDisplayModeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.applyBalanceDisplayModeConstraints()
            }
        }
        
        refresh()

        // Preload subscription logos once so the Abos sheet can render icons immediately.
        SubscriptionLogoStore.shared.preloadInitial(displayNames: LogoAssets.allDisplayNames)

        updateChecker = UpdateChecker()
        autoStartSetupWizardIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.log("Application will terminate")
        BackendManager.shared.stop()
        if let observer = refreshIntervalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = apiKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = balanceDisplayModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func applyAppearance() {
        switch appearanceMode {
        case 1: // Hell
            NSApp.appearance = NSAppearance(named: .aqua)
        case 2: // Dunkel
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default: // System
            NSApp.appearance = nil
        }
    }

    @objc private func refresh() {
        Task { await refreshAsync() }
    }

    @objc private func toggleDemoMode() {
        demoMode.toggle()
        rebuildMenuTitleForDemoMode()
        if demoMode {
            randomizeDemo() // Shuffle on enable
            txVM.anthropicApiKey = nil
            txVM.connectedBankDisplayName = "Demo-Bank"
            txVM.connectedBankLogoID = nil
            txVM.connectedBankIBAN = nil
            // Sofort Fake-Kontostand anzeigen – gleiche Funktion wie refreshAsync/openTransactionsPanel
            var seed = UInt64(truncatingIfNeeded: demoSeed)
            let fake = FakeData.demoBalance(seed: &seed)
            lastShownTitle = formatEURNoDecimals(String(format: "%.2f", fake))
            lastBalance = fake
            txVM.currentBalance = formatEURWithCents(fake)
            applyBalanceDisplayModeConstraints()
            updateStatusBalanceTitle()
            statusItem.button?.toolTip = "Demo Mode: Zufälliger Kontostand"
        } else {
            // Demo aus: Wechsel zu Live-Modus
            if CredentialsStore.exists() {
                // Credentials vorhanden → Passwort abfragen
                locked = true
                showLockIcon()
                promptUnlockIfNeeded()
            } else {
                // Keine Credentials → Zeige Verbindungs-Hinweis
                statusItem.button?.title = "Verbinden…"
                statusItem.button?.toolTip = "Rechtsklick → Einrichtungsassistent"
            }
        }
    }

    @objc private func randomizeDemo() {
        demoSeed = Int.random(in: 1...Int.max)
    }

    @objc private func toggleLock() {
        if locked {
             unlock()
        } else {
             lock()
        }
    }
    
    private func lock() {
        // Clear credentials from memory for security
        masterPassword = nil
        txVM.anthropicApiKey = nil
        locked = true
        isHiddenBalance = true
        isHoverRevealingBalance = false
        hideTimer?.invalidate()
        hideTimer = nil
        balancePopover?.performClose(nil)
        showLockIcon()
        statusItem.button?.toolTip = "Gesperrt – Rechtsklick zum Entsperren"
    }
    
    private func showLockIcon() {
        guard let btn = statusItem.button else { return }
        btn.title = ""
        
        // Try to load lock icon from bundle resources
        if let iconPath = Bundle.main.path(forResource: "lock", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = false // Show icon as-is (not as template)
            btn.image = icon
            btn.imagePosition = .imageOnly
        } else {
            // Fallback to SF Symbol
            if let lockIcon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Gesperrt") {
                lockIcon.size = NSSize(width: 14, height: 14)
                lockIcon.isTemplate = true
                btn.image = lockIcon
                btn.imagePosition = .imageOnly
            } else {
                // Ultimate fallback
                btn.title = "🔒"
                btn.image = nil
            }
        }
    }
    
    private func hideLockIcon() {
        guard let btn = statusItem.button else { return }
        // Restore the small dummy image for layout
        let img = NSImage(size: NSSize(width: 1, height: 16), flipped: false) { _ in true }
        img.isTemplate = true
        btn.image = img
        btn.imagePosition = .imageLeft
    }

    @objc private func unlock() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.locked = true // Start locked state for logic
            self.promptUnlockIfNeeded()
            self.refresh()
        }
    }
    
    /// Installs a hidden Edit menu so that Cmd+C / Cmd+V / Cmd+X / Cmd+A
    /// and right-click context menu work inside NSTextField / NSSecureTextField
    /// even when the app uses `.accessory` activation policy (no menu bar).
    private func installEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu

        if NSApp.mainMenu == nil {
            NSApp.mainMenu = NSMenu()
        }
        NSApp.mainMenu?.addItem(editItem)
    }

    // NSMenuDelegate
    func menuWillOpen(_ menu: NSMenu) {
        let isSetup = CredentialsStore.exists()
        applyLocalizedMenuTitles()
        syncAutoHideMenuState()
        
        // Update lock/unlock title
        if let item = menu.item(withTag: 999) {
            item.title = locked ? t("Entsperren…", "Unlock…") : t("Sperren", "Lock")
        }
        
        // Disable items based on setup/lock state
        for item in menu.items {
            if item.isSeparatorItem { continue }
            
            // Always enabled: Einrichtungsassistent (100), Updates (202), Einstellungen (200), Beenden (1000)
            if item.tag == 100 || item.tag == 200 || item.tag == 202 || item.tag == 1000 {
                item.isEnabled = true
                continue
            }
            
            // Not setup: disable everything except Einrichtungsassistent and Beenden
            if !isSetup {
                item.isEnabled = false
                continue
            }
            
            // Setup but locked: only Entsperren (999) and Beenden (1000) enabled
            if locked {
                item.isEnabled = (item.tag == 999)
                continue
            }
            
            // Setup and unlocked: enable all
            item.isEnabled = true
        }
    }

    @objc private func hideNow() {
        // manual hide always hides immediately
        hideBalance()
        // keep timer behavior consistent after manual hide/unhide
        applyHideTimer()
    }

    @objc private func setHideOff() { hideIndex = 0; applyHideTimer() }
    @objc private func setHideImmediate() { hideIndex = 1; applyHideTimer() }
    @objc private func setHide10() { hideIndex = 2; applyHideTimer() }
    @objc private func setHide30() { hideIndex = 3; applyHideTimer() }
    @objc private func setHide60() { hideIndex = 4; applyHideTimer() }

    private func applyLocalizedMenuTitles() {
        guard let menu = statusMenu else { return }

        if let item = menu.item(withTag: 300) {
            item.title = t("Aktualisieren", "Refresh")
        }
        if let item = menu.item(withTag: 301) {
            let stateLabel = demoMode ? t("An", "On") : t("Aus", "Off")
            item.title = "\(t("Demo-Modus", "Demo Mode")): \(stateLabel)"
        }
        if let item = menu.item(withTag: 401), let hideSub = item.submenu {
            item.title = t("Automatisch verstecken", "Auto-hide")
            hideSub.item(withTag: 410)?.title = t("Aus", "Off")
            hideSub.item(withTag: 412)?.title = t("10 Sekunden", "10 seconds")
            hideSub.item(withTag: 413)?.title = t("30 Sekunden", "30 seconds")
            hideSub.item(withTag: 414)?.title = t("60 Sekunden", "60 seconds")
        }
        if let item = menu.item(withTag: 999) {
            item.title = locked ? t("Entsperren…", "Unlock…") : t("Sperren", "Lock")
        }
        menu.item(withTag: 100)?.title = t("Einrichtungsassistent…", "Setup Wizard…")
        menu.item(withTag: 101)?.title = t("Zugangsdaten vergessen", "Forget Credentials")
        menu.item(withTag: 202)?.title = t("Nach Updates suchen…", "Check for Updates…")
        menu.item(withTag: 200)?.title = t("Einstellungen…", "Settings…")
        menu.item(withTag: 1000)?.title = t("Beenden", "Quit")
    }

    private func syncAutoHideMenuState() {
        guard let menu = statusMenu, let hideItem = menu.item(withTag: 401), let hideSub = hideItem.submenu else { return }

        hideItem.state = hideIndex == 0 ? .off : .on

        for item in hideSub.items {
            switch item.tag {
            case 410:
                item.state = hideIndex == 0 ? .on : .off
            case 412:
                item.state = hideIndex == 2 ? .on : .off
            case 413:
                item.state = hideIndex == 3 ? .on : .off
            case 414:
                item.state = hideIndex == 4 ? .on : .off
            default:
                item.state = .off
            }
        }
    }

    private func applyHideTimer() {
        syncAutoHideMenuState()
        hideTimer?.invalidate()
        hideTimer = nil

        // don't schedule when off
        let secs: TimeInterval?
        switch hideIndex {
        case 1: secs = 0
        case 2: secs = 10
        case 3: secs = 30
        case 4: secs = 60
        default: secs = nil
        }

        guard let delay = secs else { return }

        // If delay is immediate and we're currently visible → hide now.
        if delay == 0 {
            if !isHiddenBalance {
                hideBalance()
            }
            return
        }

        // Only schedule auto-hide when we are currently visible.
        guard !isHiddenBalance else { return }

        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hideBalance()
            }
        }
    }

    private func hideBalance() {
        guard !isHiddenBalance else { return }
        isHiddenBalance = true
        isHoverRevealingBalance = false
        updateStatusBalanceTitle()
        updateHiddenBalanceTooltip()
    }

    private func unhideNow() {
        guard isHiddenBalance, !locked else { return }
        isHiddenBalance = false
        isHoverRevealingBalance = false
        hideLockIcon() // Reset image to small spacer
        updateStatusBalanceTitle()
        statusItem.button?.toolTip = ""
        applyHideTimer()
    }

    @AppStorage("resetAttempts") private var resetAttemptsLimit: Int = 0
    private var failedAttempts: Int = 0
    
    private func promptUnlockIfNeeded() {
        guard locked else { return }
        
        let panel = MasterPasswordPanel(isUnlock: true)
        let result = panel.runModalWithResult()
        
        switch result {
        case .password(let pw):
            do {
                _ = try CredentialsStore.load(masterPassword: pw)
                masterPassword = pw
                locked = false
                isHiddenBalance = false
                isHoverRevealingBalance = false
                failedAttempts = 0 // Reset counter on success
                balancePopover?.performClose(nil)
                hideLockIcon()
                applyBalanceDisplayModeConstraints()

                // Touch ID einmalig anbieten nach manuellem Unlock
                offerBiometricEnrollmentIfNeeded(password: pw)

                // Show loading state while refreshing
                statusItem.button?.title = "Lädt…"
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    await refreshAsync()
                }
            } catch {
                // Wrong password - increment counter
                failedAttempts += 1
                
                // Check if we should reset after X failed attempts
                if resetAttemptsLimit > 0 && failedAttempts >= resetAttemptsLimit {
                    // Reset the app
                    performSecurityReset()
                    return
                }
                
                // Show error with remaining attempts
                let alert = NSAlert()
                alert.messageText = "Falsches Passwort"
                if resetAttemptsLimit > 0 {
                    let remaining = resetAttemptsLimit - failedAttempts
                    alert.informativeText = "Das eingegebene Passwort ist nicht korrekt.\n\nNoch \(remaining) Versuch\(remaining == 1 ? "" : "e") bevor alle Daten gelöscht werden."
                } else {
                    alert.informativeText = "Das eingegebene Passwort ist nicht korrekt."
                }
                alert.alertStyle = .warning
                // Set app icon explicitly
                if let iconPath = Bundle.main.path(forResource: "app_icon", ofType: "png"),
                   let icon = NSImage(contentsOfFile: iconPath) {
                    alert.icon = icon
                }
                alert.addButton(withTitle: "OK")
                alert.runModal()
                
                locked = true
                showLockIcon()
            }
            
        case .reset:
            // Delete all credentials and reset app state
            performSecurityReset()
            
        case .cancelled:
            // User cancelled - stay locked
            locked = true
            showLockIcon()
        }
    }
    
    @AppStorage("biometricOfferDismissed") private var biometricOfferDismissed: Bool = false

    private func offerBiometricEnrollmentIfNeeded(password: String) {
        guard BiometricStore.isAvailable else { return }
        guard !BiometricStore.hasSavedPassword else { return }
        guard !biometricOfferDismissed else { return }

        let alert = NSAlert()
        alert.messageText = "Touch ID aktivieren?"
        alert.informativeText = "Du kannst simplebanking künftig mit Touch ID entsperren – ohne Passwort eingeben."
        alert.addButton(withTitle: "Touch ID aktivieren")
        alert.addButton(withTitle: "Nicht jetzt")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            biometricOfferDismissed = true
            do {
                try BiometricStore.save(password: password)
            } catch {
                AppLogger.log("Touch ID save failed: \(error.localizedDescription)", category: "Biometric", level: "WARN")
                let errorAlert = NSAlert()
                errorAlert.messageText = "Touch ID konnte nicht aktiviert werden"
                errorAlert.informativeText = "Touch ID kann in den Einstellungen unter \"Sicherheit\" erneut aktiviert werden."
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
            }
        } else {
            biometricOfferDismissed = true
        }
    }

    private func performSecurityReset() {
        // Delete credentials
        do { try CredentialsStore.delete() } catch { }
        do { try TransactionsDatabase.deleteDatabaseFileIfExists() } catch { }
        BiometricStore.clear()
        biometricOfferDismissed = false
        Task { await NetworkService.clearSessionState() }
        
        // Reset UserDefaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        
        // Reset state
        masterPassword = nil
        txVM.anthropicApiKey = nil
        llmAPIKeyPresent = false
        confettiLastIncomeTxSig = ""
        confettiInitialShown = false
        backendPreparedIBAN = nil
        clearConnectedBankState()
        locked = false
        isHiddenBalance = false
        isHoverRevealingBalance = false
        failedAttempts = 0
        balancePopover?.performClose(nil)
        hideLockIcon()
        statusItem.button?.title = "Verbinden…"
        statusItem.button?.toolTip = "Rechtsklick → Einrichtungsassistent"
        
        // Show notification
        let alert = NSAlert()
        alert.messageText = "simplebanking wurde zurückgesetzt"
        alert.informativeText = "Alle Zugangsdaten und Einstellungen wurden gelöscht."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func rebuildMenuTitleForDemoMode() {
        applyLocalizedMenuTitles()
    }

    private func installStatusButtonTracking() {
        guard let button = statusItem?.button else { return }
        if let existing = statusButtonTrackingArea {
            button.removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        statusButtonTrackingArea = area
    }

    @objc(mouseEntered:) func mouseEntered(_ event: NSEvent) {
        revealBalanceOnHoverIfNeeded()
    }

    @objc(mouseExited:) func mouseExited(_ event: NSEvent) {
        hideHoverRevealIfNeeded()
    }

    @objc private func statusItemClicked() {
        guard let ev = NSApp.currentEvent else { return }

        if ev.type == .rightMouseUp {
            // Right click: menu - let the system position it properly
            if let btn = statusItem.button, let menu = statusMenu {
                menu.popUp(positioning: menu.items.first, at: NSPoint(x: 0, y: 0), in: btn)
            }
            return
        }

        // Left click behavior depends on swapClickBehavior setting:
        // Default (false): Single=Balance action, Double=Transactions
        // Swapped (true):  Single=Transactions, Double=Balance action
        // Balance action itself is configurable (toggle hide/show or flyout card).
        if ev.type == .leftMouseUp {
            if locked { return }
            
            if ev.clickCount >= 2 {
                pendingLeftClick?.cancel()
                pendingLeftClick = nil
                if swapClickBehavior {
                    // Doppelklick: Balance action
                    performBalancePrimaryAction()
                } else {
                    // Doppelklick: Umsatzliste öffnen
                    Task { await openTransactionsPanel() }
                }
                return
            }

            pendingLeftClick?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard !self.locked else { return }
                if self.swapClickBehavior {
                    // Einfachklick: Umsatzliste öffnen
                    Task { await self.openTransactionsPanel() }
                } else {
                    // Einfachklick: Balance action
                    self.performBalancePrimaryAction()
                }
            }
            pendingLeftClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func performBalancePrimaryAction() {
        switch activeBalanceClickMode {
        case .mouseClick:
            toggleBalanceVisibility()
        case .flyoutCard:
            showBalanceFlyout()
        case .mouseOver:
            return
        }
    }
    
    private func toggleBalanceVisibility() {
        if isHiddenBalance {
            unhideNow()
        } else {
            hideBalance()
        }
    }

    private func showBalanceFlyout() {
        guard let button = statusItem?.button else { return }

        if balancePopover?.isShown == true {
            balancePopover?.performClose(nil)
            return
        }

        let popover = balancePopover ?? NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let balanceText = lastBalance.map(formatEURWithCents) ?? "--,-- €"
        let thresholds = BalanceSignal.normalizedThresholds(
            low: balanceSignalLowUpperBound,
            medium: balanceSignalMediumUpperBound
        )
        let rootView = StatusBalanceFlyoutCardView(
            balanceText: balanceText,
            balanceValue: lastBalance,
            thresholds: thresholds,
            isDefaultTheme: themeId == ThemeManager.defaultThemeID,
            forcedColorScheme: configuredColorScheme()
        )
        let host = NSHostingController(rootView: rootView)
        popover.contentSize = NSSize(width: 348, height: 170)
        popover.contentViewController = host
        balancePopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func showTransactions() {
        Task { await openTransactionsPanel() }
    }

    private func shouldBootstrapBackendConnection(for errorText: String?) -> Bool {
        let normalized = (errorText ?? "").lowercased()
        return normalized.contains("no connectionid") ||
            normalized.contains("missing iban") ||
            normalized.contains("post /discover")
    }

    private func ensureBackendConnection(iban: String) async -> Bool {
        let normalizedIBAN = iban
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !normalizedIBAN.isEmpty else { return false }

        if backendPreparedIBAN == normalizedIBAN {
            return true
        }

        guard await NetworkService.waitUntilBackendUp(maxWaitSeconds: 12) else {
            return false
        }

        guard await NetworkService.configureBackend(iban: normalizedIBAN) else {
            return false
        }

        guard let bank = await NetworkService.discoverBank() else {
            return false
        }

        backendPreparedIBAN = normalizedIBAN
        updateConnectedBankState(bank, iban: normalizedIBAN)
        statusItem.button?.toolTip = "Verbunden mit \(bank.displayName)"
        return true
    }

    private func refreshAsync() async {
        // Demo-Modus: Keine echten API-Calls
        if demoMode {
            var seed = UInt64(truncatingIfNeeded: demoSeed)
            let fake = FakeData.demoBalance(seed: &seed)
            lastShownTitle = formatEURNoDecimals(String(format: "%.2f", fake))
            lastBalance = fake
            applyBalanceDisplayModeConstraints()
            updateStatusBalanceTitle()
            statusItem.button?.toolTip = "🎭 Demo-Modus: Simulierter Kontostand"
            applyHideTimer()
            return
        }
        
        // Live-Modus
        if !(await NetworkService.waitUntilBackendUp(maxWaitSeconds: 12)) {
            statusItem.button?.title = "Nicht verbunden"
            statusItem.button?.toolTip = "Backend nicht erreichbar"
            AppLogger.log("Backend not reachable during refresh", category: "Backend", level: "WARN")
            return
        }

        if locked { promptUnlockIfNeeded() }
        guard !locked, let pw = masterPassword else {
            statusItem.button?.title = "Gesperrt"
            statusItem.button?.toolTip = "Entsperren erforderlich"
            return
        }

        let creds: StoredCredentials
        do {
            creds = try CredentialsStore.load(masterPassword: pw)
        } catch {
            statusItem.button?.title = "Gesperrt"
            statusItem.button?.toolTip = "Entsperren fehlgeschlagen"
            locked = true
            AppLogger.log("Unlock failed during refresh: \(error.localizedDescription)", category: "Auth", level: "WARN")
            return
        }

        let userId = creds.userId
        let password = creds.password
        // Demo-Modus kann während async-Fetch aktiviert worden sein → Bank-Info nicht überschreiben
        if !demoMode { syncConnectedBankIntoViewModel(iban: creds.iban) }
        let normalizedAPIKey = creds.anthropicApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        txVM.anthropicApiKey = (normalizedAPIKey?.isEmpty == false) ? normalizedAPIKey : nil
        llmAPIKeyPresent = txVM.anthropicApiKey != nil

        do {
            var resp = try await NetworkService.fetchBalances(userId: userId, password: password)

            if !resp.ok && shouldBootstrapBackendConnection(for: resp.error) {
                if await ensureBackendConnection(iban: creds.iban) {
                    resp = try await NetworkService.fetchBalances(userId: userId, password: password)
                }
            }

            if resp.ok, let booked = resp.booked {
                lastShownTitle = formatEURNoDecimals(booked.amount)
                self.lastBalance = AmountParser.parse(booked.amount)
                applyBalanceDisplayModeConstraints()
                updateStatusBalanceTitle()
                statusItem.button?.toolTip = "Kontostand (Auto-Refresh: \(refreshInterval) Min.)"

                applyHideTimer()

                // Avoid implicit TAN prompts on startup/auto-refresh unless explicitly enabled.
                if loadTransactionsOnStart {
                    Task { await checkNewBookings(userId: userId, password: password) }
                }
            } else {
                statusItem.button?.title = "— €"
                statusItem.button?.toolTip = resp.error ?? "Keine Daten"
            }
        } catch {
            statusItem.button?.title = "— €"
            statusItem.button?.toolTip = "Fehler: \(error.localizedDescription)"
            AppLogger.log("Balance refresh failed: \(error.localizedDescription)", category: "Network", level: "ERROR")
        }
    }

    private func openTransactionsPanel() async {
        txPanel?.show()
        let didTriggerInitialConfetti = triggerInitialConfettiIfNeeded()
        
        // Demo-Modus: Komplett synthetische Daten ohne API-Calls
        if demoMode {
            txVM.anthropicApiKey = nil
            txVM.connectedBankDisplayName = "Demo-Bank"
            txVM.connectedBankLogoID = nil
            txVM.connectedBankIBAN = nil
            var seed = UInt64(truncatingIfNeeded: demoSeed)
            let fakeBalance = FakeData.demoBalance(seed: &seed)
            txVM.currentBalance = formatEURWithCents(fakeBalance)
            
            let fetchDaysDemo = UserDefaults.standard.integer(forKey: "fetchDays")
            let daysToFetch = fetchDaysDemo > 0 ? fetchDaysDemo : 60
            let from = isoDateDaysAgo(daysToFetch)
            let to = isoDateDaysAgo(0)
            txVM.fromDate = from
            txVM.toDate = to
            
            // Generiere synthetische Transaktionen mit wiederkehrenden Zahlungen
            txVM.transactions = FakeData.generateDemoTransactions(seed: &seed, days: daysToFetch)
            txVM.resetPaging()
            txVM.isLoading = false
            if !didTriggerInitialConfetti {
                maybeTriggerTransactionsConfetti(transactions: txVM.transactions, currentBalance: fakeBalance)
            }
            return
        }
        
        // Live-Modus
        if let b = self.lastBalance {
            txVM.currentBalance = formatEURWithCents(b)
        } else {
            txVM.currentBalance = "--,-- €"
        }

        // Opening the transactions panel counts as "seen".
        if !latestTxSig.isEmpty {
            lastSeenTxSig = latestTxSig
        }

        if locked { promptUnlockIfNeeded() }
        guard !locked, let pw = masterPassword else {
            txVM.error = "Unlock required"
            return
        }

        let creds: StoredCredentials
        do {
            creds = try CredentialsStore.load(masterPassword: pw)
        } catch {
            txVM.error = "Unlock failed"
            locked = true
            return
        }

        let userId = creds.userId
        let password = creds.password
        // Demo-Modus kann während async-Fetch aktiviert worden sein → Bank-Info nicht überschreiben
        if !demoMode { syncConnectedBankIntoViewModel(iban: creds.iban) }
        let normalizedAPIKey = creds.anthropicApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        txVM.anthropicApiKey = (normalizedAPIKey?.isEmpty == false) ? normalizedAPIKey : nil
        llmAPIKeyPresent = txVM.anthropicApiKey != nil

        txVM.isLoading = true
        txVM.error = nil

        let fetchDaysSetting = UserDefaults.standard.integer(forKey: "fetchDays")
        let daysToFetch = fetchDaysSetting > 0 ? fetchDaysSetting : 60
        // Do not force 365-day network sync on each panel open, because this can
        // repeatedly trigger SCA/TAN at some banks. Historical data remains in SQLite.
        let syncDays = daysToFetch
        let from = isoDateDaysAgo(syncDays)
        let to = Self.iso8601UTCFormatter.string(from: Date())
        
        txVM.fromDate = isoDateDaysAgo(daysToFetch)
        txVM.toDate = to

        var cachedTransactions: [TransactionsResponse.Transaction] = []
        var confettiTransactions: [TransactionsResponse.Transaction] = []
        do {
            cachedTransactions = try TransactionsDatabase.loadTransactions(days: daysToFetch)
            if !cachedTransactions.isEmpty {
                txVM.transactions = sortTransactionsNewestFirst(cachedTransactions)
                txVM.resetPaging()
                confettiTransactions = txVM.transactions
            }
        } catch {
            print("[DB] Load cached transactions failed: \(error.localizedDescription)")
        }

        if !(await NetworkService.waitUntilBackendUp(maxWaitSeconds: 12)) {
            txVM.error = cachedTransactions.isEmpty ? "Backend off" : "Offline, zeige gespeicherte Umsätze"
            txVM.isLoading = false
            if !didTriggerInitialConfetti {
                maybeTriggerTransactionsConfetti(transactions: confettiTransactions, currentBalance: self.lastBalance)
            }
            return
        }

        do {
            var resp = try await NetworkService.fetchTransactions(userId: userId, password: password, from: from)

            if !(resp.ok ?? false) && shouldBootstrapBackendConnection(for: resp.error) {
                if await ensureBackendConnection(iban: creds.iban) {
                    resp = try await NetworkService.fetchTransactions(userId: userId, password: password, from: from)
                }
            }

            if (resp.ok ?? false), let tx = resp.transactions {
                let sortedNetwork = sortTransactionsNewestFirst(tx)

                do {
                    try TransactionsDatabase.upsert(transactions: sortedNetwork)
                    let persistedTransactions = try TransactionsDatabase.loadTransactions(days: daysToFetch)
                    txVM.transactions = sortTransactionsNewestFirst(persistedTransactions)
                } catch {
                    print("[DB] Upsert/load failed, using network data: \(error.localizedDescription)")
                    txVM.transactions = sortedNetwork
                }
                txVM.resetPaging()
                confettiTransactions = txVM.transactions
            } else {
                if cachedTransactions.isEmpty {
                    txVM.transactions = []
                    txVM.error = resp.error ?? "No data"
                    confettiTransactions = []
                } else {
                    txVM.error = "Offline, zeige gespeicherte Umsätze"
                    confettiTransactions = txVM.transactions
                }
            }
        } catch {
            if cachedTransactions.isEmpty {
                txVM.transactions = []
                txVM.error = "Fetch failed: \(error.localizedDescription)"
                confettiTransactions = []
            } else {
                txVM.error = "Offline, zeige gespeicherte Umsätze"
                confettiTransactions = txVM.transactions
            }
        }

        txVM.isLoading = false
        if !didTriggerInitialConfetti {
            maybeTriggerTransactionsConfetti(transactions: confettiTransactions, currentBalance: self.lastBalance)
        }
    }

    private func sortTransactionsNewestFirst(_ transactions: [TransactionsResponse.Transaction]) -> [TransactionsResponse.Transaction] {
        transactions.enumerated().sorted { a, b in
            let dateA = a.element.bookingDate ?? a.element.valueDate ?? ""
            let dateB = b.element.bookingDate ?? b.element.valueDate ?? ""
            if dateA != dateB {
                return dateA > dateB
            }
            return a.offset < b.offset
        }.map(\.element)
    }
    
    private func isoDateDaysAgo(_ days: Int) -> String {
        let cal = Calendar(identifier: .gregorian)
        let d = cal.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return Self.isoDateFormatter.string(from: d)
    }

    private func computeTxSignature(_ t: TransactionsResponse.Transaction) -> String {
        // Best-effort stable signature from visible fields.
        let date = (t.bookingDate ?? t.valueDate ?? "")
        let amt = (t.amount?.amount ?? "")
        let cur = (t.amount?.currency ?? "")
        let creditor = (t.creditor?.name ?? "")
        let debtor = (t.debtor?.name ?? "")
        let rem = (t.remittanceInformation ?? []).joined(separator: "|")
        return "\(date)|\(amt)|\(cur)|\(creditor)|\(debtor)|\(rem)"
    }

    private func balanceAboveConfettiThreshold(currentBalance: Double?) -> Bool {
        guard confettiEnabled, confettiOnBalanceThreshold else { return false }
        guard let currentBalance else { return false }
        let threshold = max(0, Double(confettiBalanceThreshold))
        return currentBalance >= threshold
    }

    private func hasNewIncomeForConfetti(in transactions: [TransactionsResponse.Transaction]) -> Bool {
        guard confettiEnabled, confettiOnNewIncome else { return false }
        let newestIncoming = transactions
            .filter { $0.parsedAmount > 0 }
            .sorted { a, b in
                let dateA = a.bookingDate ?? a.valueDate ?? ""
                let dateB = b.bookingDate ?? b.valueDate ?? ""
                if dateA != dateB {
                    return dateA > dateB
                }
                return computeTxSignature(a) > computeTxSignature(b)
            }
            .first

        guard let newestIncoming else { return false }

        let incomingSignature = computeTxSignature(newestIncoming)
        if confettiLastIncomeTxSig.isEmpty {
            confettiLastIncomeTxSig = incomingSignature
            return false
        }

        let isNewIncome = confettiLastIncomeTxSig != incomingSignature
        confettiLastIncomeTxSig = incomingSignature
        return isNewIncome
    }

    private func maybeTriggerTransactionsConfetti(transactions: [TransactionsResponse.Transaction], currentBalance: Double?) {
        guard confettiEnabled else { return }
        let shouldTrigger = balanceAboveConfettiThreshold(currentBalance: currentBalance)
            || hasNewIncomeForConfetti(in: transactions)
        guard shouldTrigger else { return }
        txVM.confettiTrigger += 1
    }

    private func triggerInitialConfettiIfNeeded() -> Bool {
        guard !confettiInitialShown else { return false }
        confettiInitialShown = true
        txVM.confettiTrigger += 1
        return true
    }

    private func checkNewBookings(userId: String, password: String) async {
        // Avoid noisy UI if locked/hidden; still compute indicator.
        let from = isoDateDaysAgo(7)
        do {
            let resp = try await NetworkService.fetchTransactions(userId: userId, password: password, from: from)
            guard (resp.ok ?? false), let tx = resp.transactions, !tx.isEmpty else { return }
            let sorted = tx.sorted { ($0.bookingDate ?? $0.valueDate ?? "") > ($1.bookingDate ?? $1.valueDate ?? "") }
            let sig = computeTxSignature(sorted[0])
            
            // Check if this is a new transaction
            let isNew = !lastSeenTxSig.isEmpty && sig != lastSeenTxSig && sig != latestTxSig
            latestTxSig = sig

            // Update title with dot if needed.
            updateStatusBalanceTitle()
            
            // Send notification for new bookings
            if isNew && showNotifications {
                let newest = sorted[0]
                sendNewBookingNotification(transaction: newest)
            }
        } catch {
            // ignore
        }
    }
    
    private func sendNewBookingNotification(transaction: TransactionsResponse.Transaction) {
        let isIncoming = transaction.parsedAmount >= 0

        // Resolved + truncated merchant name (same logic as the list)
        let resolvedMerchant: String = {
            if UserDefaults.standard.object(forKey: MerchantResolver.pipelineEnabledKey) == nil
            || UserDefaults.standard.bool(forKey: MerchantResolver.pipelineEnabledKey) {
                let r = MerchantResolver.resolve(transaction: transaction).effectiveMerchant
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty { return Self.truncateNotifName(r) }
            }
            let raw = isIncoming
                ? (transaction.debtor?.name  ?? transaction.creditor?.name ?? "")
                : (transaction.creditor?.name ?? transaction.debtor?.name  ?? "")
            return Self.truncateNotifName(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }()

        // Formatted amount  "+12,50 €" / "−45,00 €"
        let amountValue = abs(transaction.parsedAmount)
        let amountStr   = Self.eurCurrencyFormatter.string(from: NSNumber(value: amountValue))
                          ?? String(format: "%.2f €", amountValue)
        let amountLine  = isIncoming ? "+\(amountStr)" : "−\(amountStr)"

        // Category emoji + name
        let category = TransactionCategorizer.category(for: transaction)
        let categoryLine = "\(Self.categoryEmoji(category))  \(category.displayName)"

        let content        = UNMutableNotificationContent()
        content.title      = resolvedMerchant.isEmpty ? "Neue Buchung" : resolvedMerchant
        content.subtitle   = amountLine
        content.body       = categoryLine
        content.sound      = .default

        // Try to attach merchant logo; send notification once we know the result
        let logoService = MerchantLogoService.shared
        let domain      = logoService.domain(for: resolvedMerchant.lowercased())

        Task {
            var attachment: UNNotificationAttachment? = nil

            if let domain {
                // Use cached image or wait for a fresh fetch (max 3 s)
                let image: NSImage? = await {
                    if let cached = logoService.imageCache[domain] { return cached }
                    logoService.preload(normalizedMerchant: resolvedMerchant)
                    let deadline = Date().addingTimeInterval(3)
                    while Date() < deadline {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if let img = logoService.imageCache[domain] { return img }
                    }
                    return nil
                }()

                if let image {
                    attachment = Self.makeNotifAttachment(image: image, domain: domain)
                }
            }

            if let attachment {
                content.attachments = [attachment]
            }

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error { AppLogger.log("Notification error: \(error)", category: "Notif", level: "WARN") }
            }
        }
    }

    // MARK: - Notification helpers

    private static func truncateNotifName(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let words = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return raw }
        if words[1].hasPrefix("(") {
            return words[1].hasSuffix(")") ? words.prefix(2).joined(separator: " ") : words[0]
        }
        return words.prefix(2).joined(separator: " ")
    }

    private static func categoryEmoji(_ cat: TransactionCategory) -> String {
        switch cat {
        case .einkommen:     return "💼"
        case .essenAlltag:   return "🍽️"
        case .abosDigital:   return "📺"
        case .shopping:      return "🛍️"
        case .versicherungen:return "🛡️"
        case .mobilitaet:    return "🚗"
        case .wohnenKredit:  return "🏠"
        case .sonstiges:     return "🏷️"
        }
    }

    private static func makeNotifAttachment(image: NSImage, domain: String) -> UNNotificationAttachment? {
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notif_logo_\(domain).png")
        do {
            try png.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: domain, url: url, options: nil)
        } catch {
            return nil
        }
    }

    // (old text panel helper removed in favor of TransactionsPanelView)

    private func formatEURWithCents(_ amount: Double) -> String {
        Self.eurCurrencyFormatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f €", amount)
    }

    private func formatEURNoDecimals(_ amount: String) -> String {
        let d = AmountParser.parse(amount)
        let rounded = d.rounded()

        let s = Self.eurWholeNumberFormatter.string(from: NSNumber(value: rounded)) ?? "0"
        return "\(s) €"
    }

    @objc private func connect() {
        // Defer showing modal panels until the status bar menu fully dismisses.
        DispatchQueue.main.async { [weak self] in
            self?.runSetupWizardIfNeeded()
        }
    }

    private func autoStartSetupWizardIfNeeded() {
        guard !didTriggerAutoSetupThisLaunch else { return }
        guard !demoMode else { return }
        guard !CredentialsStore.exists() else { return }

        didTriggerAutoSetupThisLaunch = true

        // Let launch settle before presenting a modal wizard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.runSetupWizardIfNeeded()
        }
    }

    private func runSetupWizardIfNeeded() {
        let wizard = SetupWizardPanel(connectAction: { payload, selectedBankName, options, masterPassword in
            AppLogger.log(
                "Setup connectAction entered ibanPrefix=\(String(payload.iban.prefix(6))) selectedBank=\(selectedBankName ?? "-") diagnostics=\(options.diagnosticsEnabled)",
                category: "Setup"
            )
            let setupResult = try await Self.performSetupConnection(
                result: payload,
                selectedBankName: selectedBankName,
                masterPassword: masterPassword,
                options: options
            )
            return setupResult.bank
        })

        switch wizard.runModal() {
        case .realBanking(let pw, let bank):
            self.masterPassword = pw
            locked = false
            if let creds = try? CredentialsStore.load(masterPassword: pw) {
                let normalizedAPIKey = creds.anthropicApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
                txVM.anthropicApiKey = (normalizedAPIKey?.isEmpty == false) ? normalizedAPIKey : nil
                llmAPIKeyPresent = txVM.anthropicApiKey != nil
                let normalizedIBAN = creds.iban
                    .replacingOccurrences(of: " ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                backendPreparedIBAN = normalizedIBAN.isEmpty ? nil : normalizedIBAN
                updateConnectedBankState(bank, iban: normalizedIBAN)
            } else {
                updateConnectedBankState(bank)
            }
            statusItem.button?.toolTip = "Verbunden mit \(bank.displayName)"
            Task { await self.refreshAsync() }
        case .demoMode:
            self.demoMode = true
            self.demoSeed = Int.random(in: 1...9999)
            Task { await self.refreshAsync() }
        case .cancelled:
            break
        }
    }
    
    private enum SetupFlowError: LocalizedError {
        case cancelled
        case backendUnavailable(details: String?)
        case backendConfigFailed
        case bankNotFound
        case connectTimeout(step: String)
        case authenticationFailed(String)
        case storageFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Einrichtung abgebrochen."
            case let .backendUnavailable(details):
                let detailText = details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if detailText.isEmpty {
                    return "Backend ist nicht erreichbar. Bitte erneut versuchen."
                }
                return "Backend ist nicht erreichbar. Bitte erneut versuchen. Ursache: \(detailText)"
            case .backendConfigFailed:
                return "Backend konnte nicht konfiguriert werden. Bitte Eingaben prüfen und erneut versuchen."
            case .bankNotFound:
                return "Bankverbindung konnte nicht erkannt werden. Bitte IBAN prüfen."
            case .connectTimeout:
                return "Keine Rückmeldung von der Bank seit 60 Sekunden. Bitte erneut versuchen."
            case .authenticationFailed(let message):
                return message
            case .storageFailed(let message):
                return "Speichern fehlgeschlagen: \(message)"
            }
        }
    }

    private struct SetupConnectResult {
        let bank: DiscoveredBank
        let normalizedIBAN: String
        let apiKey: String?
    }


    nonisolated private static func setupWarmupFromDate(days: Int) -> String {
        let cal = Calendar(identifier: .gregorian)
        let d = cal.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: d)
    }

    nonisolated private static func isLikelyCredentialError(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("pin") ||
            text.contains("passwort") ||
            text.contains("password") ||
            text.contains("anmeldename") ||
            text.contains("legitimations") ||
            text.contains("zugangsdaten") ||
            text.contains("credentials") ||
            text.contains("wrong") ||
            text.contains("unauthorized")
    }

    nonisolated private static func ensureBackendReadyForSetup(
        logger: SetupDiagnosticsLogger?
    ) async throws {
        if await NetworkService.waitUntilBackendUp(maxWaitSeconds: 6) {
            logger?.log(step: "backend_health", event: "already_ready")
            return
        }

        let startIssue = await MainActor.run { () -> String? in
            BackendManager.shared.startIfNeeded()
            let issue = BackendManager.shared.lastStartupIssue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return issue?.isEmpty == true ? nil : issue
        }
        if let startIssue {
            logger?.log(step: "backend_health", event: "start_if_needed_issue", details: ["issue": startIssue])
        } else {
            logger?.log(step: "backend_health", event: "start_if_needed")
        }

        if await NetworkService.waitUntilBackendUp(maxWaitSeconds: 20) {
            logger?.log(step: "backend_health", event: "ready_after_start")
            return
        }

        let restartIssue = await MainActor.run { () -> String? in
            BackendManager.shared.restartForRecovery()
            let issue = BackendManager.shared.lastStartupIssue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return issue?.isEmpty == true ? nil : issue
        }
        if let restartIssue {
            logger?.log(step: "backend_health", event: "restart_issue", details: ["issue": restartIssue])
        } else {
            logger?.log(step: "backend_health", event: "restart_triggered")
        }

        if await NetworkService.waitUntilBackendUp(maxWaitSeconds: 30) {
            logger?.log(step: "backend_health", event: "ready_after_restart")
            return
        }

        let finalIssue = await MainActor.run { () -> String? in
            let issue = BackendManager.shared.lastStartupIssue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return issue?.isEmpty == true ? nil : issue
        }
        throw SetupFlowError.backendUnavailable(details: finalIssue)
    }

    nonisolated private static func runSetupStepWithTimeout<T: Sendable>(
        step: String,
        timeout: TimeInterval = 60,
        logger: SetupDiagnosticsLogger?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutSeconds: TimeInterval = timeout
        logger?.log(step: step, event: "start")
        let startedAt = Date()
        do {
            let value = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await operation()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw SetupFlowError.connectTimeout(step: step)
                }

                guard let result = try await group.next() else {
                    throw SetupFlowError.authenticationFailed("Einrichtung wurde unterbrochen.")
                }
                group.cancelAll()
                return result
            }
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger?.log(step: step, event: "success", details: ["duration_ms": String(durationMs)])
            return value
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger?.log(
                step: step,
                event: "failure",
                details: [
                    "duration_ms": String(durationMs),
                    "error": error.localizedDescription,
                ]
            )
            throw error
        }
    }

    nonisolated private static func normalizeSetupError(_ error: Error) -> SetupFlowError {
        if let setupError = error as? SetupFlowError {
            return setupError
        }
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        // "Unauthorized: " (empty userMessage) — bank rejected connection.
        // Most common cause: blocked SCA device or expired consent.
        if lower.hasPrefix("unauthorized") {
            return .authenticationFailed("Zugang nicht autorisiert. Bitte prüfe deine Zugangsdaten und ob dein Online-Banking-Zugang aktiv ist.")
        }

        if raw.isEmpty {
            return .authenticationFailed("Verbindungsprüfung fehlgeschlagen.")
        }
        return .authenticationFailed("Verbindungsprüfung fehlgeschlagen: \(raw)")
    }

    nonisolated private static func performSetupConnection(
        result: CredentialsPanel.Result,
        selectedBankName: String?,
        masterPassword: String,
        options: SetupConnectOptions
    ) async throws -> SetupConnectResult {
        AppLogger.log("Setup performSetupConnection start", category: "Setup")
        let diagnosticsLogger: SetupDiagnosticsLogger? = {
            guard options.diagnosticsEnabled else { return nil }
            do {
                return try SetupDiagnosticsLogger.startAttempt()
            } catch {
                AppLogger.log(
                    "Setup diagnostics logger unavailable: \(error.localizedDescription)",
                    category: "Setup",
                    level: "WARN"
                )
                return nil
            }
        }()
        diagnosticsLogger?.log(
            step: "setup",
            event: "attempt_start",
            details: ["diagnostics_enabled": options.diagnosticsEnabled ? "true" : "false"]
        )

        do {
            options.onProgress?(.startingBackend)
            AppLogger.log("Setup step backend_health", category: "Setup")
            try await runSetupStepWithTimeout(step: "backend_health", logger: diagnosticsLogger) {
                try await ensureBackendReadyForSetup(logger: diagnosticsLogger)
            }

            let normalizedIBAN = result.iban
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()

            options.onProgress?(.configuringBank)
            AppLogger.log("Setup step backend_config", category: "Setup")
            let configured = try await runSetupStepWithTimeout(step: "backend_config", logger: diagnosticsLogger) {
                await NetworkService.configureBackend(iban: normalizedIBAN)
            }
            guard configured else {
                throw SetupFlowError.backendConfigFailed
            }

            options.onProgress?(.discoveringBank)
            AppLogger.log("Setup step discover_bank", category: "Setup")
            let discoveredBank = try await runSetupStepWithTimeout(step: "discover_bank", logger: diagnosticsLogger) {
                guard let discoveredBank = await NetworkService.discoverBank() else {
                    throw SetupFlowError.bankNotFound
                }
                return discoveredBank
            }

            let fallbackName = selectedBankName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let discoveredName = discoveredBank.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalBank = discoveredName.isEmpty && !fallbackName.isEmpty
                ? DiscoveredBank(
                    id: discoveredBank.id,
                    displayName: fallbackName,
                    logoId: discoveredBank.logoId,
                    credentials: discoveredBank.credentials,
                    userIdLabel: discoveredBank.userIdLabel,
                    advice: discoveredBank.advice
                )
                : discoveredBank

            try await runSetupStepWithTimeout(step: "clear_session_initial", logger: diagnosticsLogger) {
                await NetworkService.clearSessionState()
            }

            let fetchDaysSetting = UserDefaults.standard.integer(forKey: "fetchDays")
            let warmupDays = fetchDaysSetting > 0 ? fetchDaysSetting : 60
            let warmupFrom = setupWarmupFromDate(days: warmupDays)

            options.onProgress?(.requestingApproval)
            AppLogger.log("Setup step warmup_balances", category: "Setup")
            // Redirect-Flows (z.B. Sparkasse): Nutzer muss sich auf Bank-Website einloggen
            // und SCA bestätigen. Server pollt bis zu 300 s — Swift-Timeout muss größer sein.
            let warmupBalances = try await runSetupStepWithTimeout(step: "warmup_balances", timeout: 360, logger: diagnosticsLogger) {
                try await NetworkService.fetchBalances(
                    userId: result.userId,
                    password: result.password
                )
            }
            if !warmupBalances.ok, let techMsg = warmupBalances.error, isLikelyCredentialError(techMsg) {
                let displayMsg = warmupBalances.userMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? techMsg
                throw SetupFlowError.authenticationFailed(displayMsg)
            }

            // Nur Fortschritt zeigen wenn Kontostand erfolgreich war (sonst SCA noch ausstehend)
            if warmupBalances.ok { options.onProgress?(.fetchingTransactions) }
            AppLogger.log("Setup step warmup_transactions", category: "Setup")
            var warmupTransactions = try await runSetupStepWithTimeout(step: "warmup_transactions", timeout: 150, logger: diagnosticsLogger) {
                try await NetworkService.fetchTransactions(
                    userId: result.userId,
                    password: result.password,
                    from: warmupFrom
                )
            }

            if !(warmupTransactions.ok ?? false) {
                try await runSetupStepWithTimeout(step: "clear_session_retry", logger: diagnosticsLogger) {
                    // Nur Sessions löschen, connectionData behalten:
                    // Ohne connectionData kennt die Bank das Gerät nicht und schickt
                    // keinen Push-TAN – sie fällt auf interaktive TAN zurück.
                    await NetworkService.clearSessionsKeepingConnectionData()
                }
                _ = try await runSetupStepWithTimeout(step: "warmup_balances_retry", timeout: 360, logger: diagnosticsLogger) {
                    try await NetworkService.fetchBalances(userId: result.userId, password: result.password)
                }
                warmupTransactions = try await runSetupStepWithTimeout(step: "warmup_transactions_retry", timeout: 150, logger: diagnosticsLogger) {
                    try await NetworkService.fetchTransactions(
                        userId: result.userId,
                        password: result.password,
                        from: warmupFrom
                    )
                }
            }

            if !(warmupTransactions.ok ?? false) {
                let techMsg = warmupTransactions.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = "Umsatzabfrage konnte nicht bestätigt werden. Bitte Freigabe in deiner Banking-App prüfen und erneut verbinden."
                let displayMsg = warmupTransactions.userMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? techMsg?.nilIfEmpty
                    ?? fallback
                throw SetupFlowError.authenticationFailed(displayMsg)
            }

            if let techMsg = warmupTransactions.error, isLikelyCredentialError(techMsg) {
                let displayMsg = warmupTransactions.userMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? techMsg
                throw SetupFlowError.authenticationFailed(displayMsg)
            }

            options.onProgress?(.savingCredentials)
            let existingAPIKey = try? CredentialsStore.loadAPIKey(masterPassword: masterPassword)
            try await runSetupStepWithTimeout(step: "store_credentials", logger: diagnosticsLogger) {
                try CredentialsStore.save(
                    StoredCredentials(
                        iban: normalizedIBAN,
                        userId: result.userId,
                        password: result.password,
                        anthropicApiKey: existingAPIKey
                    ),
                    masterPassword: masterPassword
                )
            }

            diagnosticsLogger?.finish(success: true, error: nil)
            AppLogger.log("Setup performSetupConnection success", category: "Setup")
            return SetupConnectResult(
                bank: finalBank,
                normalizedIBAN: normalizedIBAN,
                apiKey: existingAPIKey
            )
        } catch {
            let setupError = normalizeSetupError(error)
            AppLogger.log("Setup performSetupConnection failed error=\(setupError.localizedDescription)", category: "Setup", level: "ERROR")
            diagnosticsLogger?.finish(success: false, error: setupError.localizedDescription)
            throw SetupConnectActionError(
                message: setupError.localizedDescription,
                diagnosticsLogURL: diagnosticsLogger?.latestLogURL
            )
        }
    }

    @objc private func forget() {
        do { try CredentialsStore.delete() } catch { }
        do { try TransactionsDatabase.deleteDatabaseFileIfExists() } catch { }
        Task { await NetworkService.clearSessionState() }
        masterPassword = nil
        txVM.anthropicApiKey = nil
        llmAPIKeyPresent = false
        confettiLastIncomeTxSig = ""
        confettiInitialShown = false
        backendPreparedIBAN = nil
        clearConnectedBankState()
        locked = false
        statusItem.button?.title = "Einrichten…"
        statusItem.button?.toolTip = "Credentials removed"
    }
    
    @objc private func showSettings() {
        settingsPanel?.show()
    }

    @objc private func checkForUpdates() {
        updateChecker?.checkForUpdates()
    }

    private func setupRefreshTimer() {
        timer?.invalidate()
        timer = nil
        
        // 0 = Manuell, kein Timer
        guard refreshInterval > 0 else { return }
        
        let interval = TimeInterval(refreshInterval * 60)
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private struct StatusBalanceFlyoutCardView: View {
    let balanceText: String
    let balanceValue: Double?
    let thresholds: BalanceSignalThresholds
    let isDefaultTheme: Bool
    let forcedColorScheme: ColorScheme?

    @Environment(\.colorScheme) private var environmentColorScheme

    private var activeColorScheme: ColorScheme {
        forcedColorScheme ?? environmentColorScheme
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isDefaultTheme {
                    defaultThemeCard
                } else {
                    legacyCard
                }
            }
            .padding(14)
        }
        .frame(width: 348, height: 170)
        .background(Color.panelBackground)
        .preferredColorScheme(forcedColorScheme)
    }

    private var defaultThemeCard: some View {
        let level = BalanceSignal.classify(balance: balanceValue, thresholds: thresholds)
        let style = BalanceSignal.style(for: level)
        let displayBalance = balanceValue == nil ? "--,-- €" : balanceText
        let glassColor = activeColorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.60)
        let borderColor = activeColorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.35)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wallet.pass")
                    .font(.system(size: 16))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                Text(L10n.t("Aktueller Kontostand", "Current balance"))
                    .font(.system(size: 14))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }

            Text(displayBalance)
                .font(.system(size: 30, weight: .bold, design: .default))
                .foregroundColor(style.amountColor)

            Text(style.localizedStatusText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(style.statusColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(glassColor)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [style.gradientBaseColor.opacity(0.10), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var legacyCard: some View {
        let displayBalance = balanceValue == nil ? "--,-- €" : balanceText
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "creditcard")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                Text(L10n.t("Aktueller Kontostand", "Current balance"))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            Text(displayBalance)
                .font(.system(size: 30, weight: .bold, design: .default))
                .foregroundColor((balanceValue ?? 0) < 0 ? .expenseRed : ((balanceValue ?? 0) > 0 ? .incomeGreen : .primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground)
        )
    }
}
