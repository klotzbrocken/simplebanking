import AppKit
import Foundation
import Routex
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

    @AppStorage("hideIndex") private var hideIndex: Int = 2 // 0=off, 1=immediate, 2=5s, 3=10s
    @AppStorage(AppLogger.enabledKey) private var appLoggingEnabled: Bool = false
    @AppStorage("menubarStyle") private var menubarStyle: Int = 1  // 0=lang (fixed), 1=kurz (dynamic)
    @AppStorage("refreshInterval") private var refreshInterval: Int = 60
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    @AppStorage("loadTransactionsOnStart") private var loadTransactionsOnStart: Bool = false
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("swapClickBehavior") private var swapClickBehavior: Bool = false
    @AppStorage("balanceClickMode") private var balanceClickMode: Int = BalanceClickMode.flyoutCard.rawValue
    @AppStorage("balanceSignalLowUpperBound") private var balanceSignalLowUpperBound: Int = 500
    @AppStorage("balanceSignalMediumUpperBound") private var balanceSignalMediumUpperBound: Int = 2000
    @AppStorage("llmAPIKeyPresent") private var llmAPIKeyPresent: Bool = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage: String = AppLanguage.system.rawValue
    @AppStorage(ThemeManager.storageKey) private var themeId: String = ThemeManager.defaultThemeID
    @AppStorage("confettiIncomeThreshold") private var confettiIncomeThreshold: Int = 50
    @AppStorage("confettiInitialShown") private var confettiInitialShown: Bool = false
    @AppStorage("connectedBankDisplayName") private var connectedBankDisplayName: String = ""
    @AppStorage("connectedBankLogoID") private var connectedBankLogoID: String = ""

    @AppStorage("lastSeenTxSig") private var lastSeenTxSig: String = ""
    @AppStorage("confettiLastIncomeTxSig") private var confettiLastIncomeTxSig: String = ""
    private var latestTxSig: String = ""
    private var flyoutRippleTrigger: Int = 0
    
    // Für Balance-Anzeige
    private(set) var lastBalance: Double? = nil

    private var masterPassword: String? = nil
    private var locked: Bool = false

    /// Incremented on every slot switch. Async tasks capture this at start and bail if it changed.
    private var slotEpoch: Int = 0
    private var isHBCICallInFlight: Bool = false    // guard against concurrent HBCI calls (balance + transactions)
    private var isTanPending: Bool = false

    private var isHiddenBalance: Bool = false
    private var hideTimer: Timer?
    private var pendingLeftClick: DispatchWorkItem?
    private var lastShownTitle: String = "—"
    
    private var settingsPanel: SettingsPanel?
    private var updateChecker: UpdateChecker?
    private var refreshIntervalObserver: Any?
    private var apiKeyObserver: Any?
    private var languageObserver: Any?
    private var balanceDisplayModeObserver: Any?
    private var didTriggerAutoSetupThisLaunch: Bool = false
    // After a missed SCA redirect, pause auto-refresh to avoid burning through the bank's
    // daily SCA authorization limit (e.g. Sparkasse allows ~4 redirects per day).
    private var scaBackoffUntil: Date? = nil

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
        "•••.•• €"
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
        updateMenuBarButton()
    }

    // Returns the bank logo (16×16, template) for the menu bar, or nil if none available.
    // When nil, "€" is used as text fallback instead.
    private func menuBarLogoImage() -> NSImage? {
        if demoMode {
            let img = NSImage(systemSymbolName: "wallet.pass", accessibilityDescription: "Demo")
            img?.isTemplate = true
            return img
        }
        let logoID = connectedBankLogoID.isEmpty ? nil : connectedBankLogoID
        guard let logoID else { return nil }
        let brand = BankLogoAssets.resolve(displayName: connectedBankDisplayName, logoID: logoID, iban: nil)
        BankLogoStore.shared.preload(brand: brand)
        guard let img = BankLogoStore.shared.image(for: brand) else { return nil }
        let sized = img.resized(to: NSSize(width: 16, height: 16))
        sized.isTemplate = true
        return sized
    }

    private func updateMenuBarButton() {
        guard let button = statusItem?.button else { return }
        guard !locked else { return }

        let isShort = menubarStyle == 1
        let logo = menuBarLogoImage()

        // Logo on the LEFT, text on the right.
        // If no logo: "€" is prepended to the title text instead.
        button.image = logo
        button.imagePosition = logo != nil ? .imageLeft : .noImage

        let p = logo != nil ? " " : "€ "  // prefix: space after logo, or "€ " when no logo

        // TAN / 2FA pending
        if isTanPending {
            setButtonTitle(button, "\(p)TAN")
            statusItem.length = isShort ? NSStatusItem.variableLength : menubarFixedWidth()
            return
        }

        // Hidden balance
        if isHiddenBalance && !isHoverRevealingBalance {
            if isShort {
                // Short: logo only (or "€" if no logo)
                setButtonTitle(button, logo != nil ? "" : "€")
            } else {
                // Long: logo + mask
                setButtonTitle(button, "\(p)•••.•• ")
            }
            statusItem.length = isShort ? NSStatusItem.variableLength : menubarFixedWidth()
            return
        }

        // Normal balance
        setButtonTitle(button, "\(p)\(decoratedTitle(lastShownTitle))")
        statusItem.length = isShort ? NSStatusItem.variableLength : menubarFixedWidth()
    }

    private func menubarFixedWidth() -> CGFloat {
        let refString = " \(lastShownTitle.isEmpty ? "1.234" : lastShownTitle) "
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        let textWidth = (refString as NSString).size(withAttributes: attrs).width
        return textWidth + 22  // 22px for the logo image + gap
    }

    private func setButtonTitle(_ button: NSStatusBarButton, _ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
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

    /// Single source of truth: applies a BankSlot's identity to both AppStorage globals and txVM.
    /// Call this at startup and on every slot switch — NOT during data refresh.
    private func applySlotToViewModel(_ slot: BankSlot) {
        let store = MultibankingStore.shared
        var resolvedName = slot.displayName
        var resolvedLogo = slot.logoId ?? ""

        // Brand resolution: name takes priority over YAXI's logoId (which can be wrong, e.g. "commerzbank" for C24).
        // Priority: 1) user-visible name → 2) stored logoId → 3) IBAN lookup
        if !resolvedName.isEmpty, let brand = BankLogoAssets.find(byName: resolvedName) {
            resolvedLogo = brand.id
        } else if !resolvedLogo.isEmpty, BankLogoAssets.find(byLogoID: resolvedLogo) != nil {
            // logo is already valid — keep it
        } else if !slot.iban.isEmpty, let brand = BankLogoAssets.find(byIBAN: slot.iban) {
            if resolvedName.isEmpty { resolvedName = brand.displayName }
            resolvedLogo = brand.id
        }

        // Persist resolved logo/name back to the slot so it's correct on next launch.
        // This auto-heals existing accounts that were set up before the icon fix.
        if resolvedLogo != (slot.logoId ?? "") || resolvedName != slot.displayName {
            var updated = slot
            updated.displayName = resolvedName
            updated.logoId = resolvedLogo.isEmpty ? nil : resolvedLogo
            store.updateSlot(updated)
        }

        let normalizedIBAN = slot.iban
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        connectedBankDisplayName = resolvedName
        connectedBankLogoID = resolvedLogo
        txVM.connectedBankDisplayName = resolvedName
        txVM.connectedBankLogoID = resolvedLogo.isEmpty ? nil : resolvedLogo
        txVM.connectedBankIBAN = normalizedIBAN.isEmpty ? nil : normalizedIBAN
    }

    private func updateConnectedBankState(_ bank: DiscoveredBank, iban: String? = nil) {
        connectedBankDisplayName = bank.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        connectedBankLogoID = bank.logoId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        txVM.connectedBankDisplayName = connectedBankDisplayName
        txVM.connectedBankLogoID = connectedBankLogoID.isEmpty ? nil : connectedBankLogoID
        if let iban {
            let n = iban.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            txVM.connectedBankIBAN = n.isEmpty ? nil : n
        }
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
        YaxiService.migrateCredentialsModelIfNeeded()

        // TAN/SCA state callback → update menu bar and transactions panel
        YaxiService.onTanStateChanged = { [weak self] isPending in
            self?.isTanPending = isPending
            self?.txVM.isTanPending = isPending
            self?.updateMenuBarButton()
        }

        // Task 4: Set active slot IDs in all data layers at startup
        let store = MultibankingStore.shared
        if let slot = store.activeSlot {
            YaxiService.activeSlotId = slot.id
            CredentialsStore.activeSlotId = slot.id
            TransactionsDatabase.activeSlotId = slot.id
            applySlotToViewModel(slot)
            // SessionStore.init() always loads the legacy (no-suffix) keys regardless of which
            // slot was last active. For non-legacy slots this means the wrong session is in memory.
            // Reload immediately so the first refreshAsync uses the correct slot's session.
            Task { await YaxiService.sessionStore.reloadForActiveSlot() }
        }

        // One-time migration: clear ALL corrupted legacy slot state.
        // During early multibanking builds, C24 setup wrote its connectionId, connectionData
        // and session to the legacy (Sparkasse) keys, causing Sparkasse to show C24's balance.
        // We clear everything and re-discover the Sparkasse bank so it can re-auth via redirect.
        if store.slots.count > 1 {
            let migrationKey = "simplebanking.migration.legacySlotFullReset.v1"
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                Task {
                    // 1. Clear session/connectionData (actor-isolated)
                    await YaxiService.sessionStore.clearLegacySessionData()
                    // 2. Clear connectionId and credModel (non-actor UserDefaults keys)
                    let d = UserDefaults.standard
                    d.removeObject(forKey: "simplebanking.yaxi.connectionId")
                    d.removeObject(forKey: "simplebanking.yaxi.credModel.full")
                    d.removeObject(forKey: "simplebanking.yaxi.credModel.userId")
                    d.removeObject(forKey: "simplebanking.yaxi.credModel.none")
                    AppLogger.log("Migration: legacy slot state cleared (multi-slot corruption fix)", category: "App")
                    // 3. Re-discover legacy bank so next refresh can trigger SCA/redirect
                    let prev = YaxiService.activeSlotId
                    YaxiService.activeSlotId = "legacy"
                    if await YaxiService.discoverBank() != nil {
                        AppLogger.log("Migration: legacy bank re-discovered successfully", category: "App")
                    } else {
                        AppLogger.log("Migration: legacy bank re-discovery failed — user may need to re-run setup", category: "App", level: "WARN")
                    }
                    YaxiService.activeSlotId = prev
                }
            }
        }

        installEditMenu()
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

        // Build a menu, but don't assign it to statusItem.menu, otherwise left click always opens the menu.
        let menu = NSMenu()

        // ── Aktualisieren ────────────────────────────────────────────────
        let refreshItem = NSMenuItem(title: t("Aktualisieren", "Refresh"), action: #selector(refresh), keyEquivalent: "r")
        refreshItem.tag = 300
        if let img = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil) {
            img.isTemplate = true; refreshItem.image = img
        }
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem.separator())

        // ── Automatisch verstecken (submenu) ─────────────────────────────
        let hideSub = NSMenu()

        let immediateItem = NSMenuItem(title: t("Sofort", "Immediately"), action: #selector(setHideImmediate), keyEquivalent: "")
        immediateItem.tag = 411
        immediateItem.state = (hideIndex == 1) ? .on : .off
        hideSub.addItem(immediateItem)

        let fiveSecItem = NSMenuItem(title: t("Nach 5 Sekunden", "After 5 seconds"), action: #selector(setHide10), keyEquivalent: "")
        fiveSecItem.tag = 412
        fiveSecItem.state = (hideIndex == 2) ? .on : .off
        hideSub.addItem(fiveSecItem)

        let tenSecItem = NSMenuItem(title: t("Nach 10 Sekunden", "After 10 seconds"), action: #selector(setHide30), keyEquivalent: "")
        tenSecItem.tag = 413
        tenSecItem.state = (hideIndex == 3) ? .on : .off
        hideSub.addItem(tenSecItem)

        let offItem = NSMenuItem(title: t("Aus", "Off"), action: #selector(setHideOff), keyEquivalent: "")
        offItem.tag = 410
        offItem.state = (hideIndex == 0) ? .on : .off
        hideSub.addItem(offItem)

        let hideItem = NSMenuItem(title: t("Automatisch verstecken", "Auto-hide"), action: nil, keyEquivalent: "")
        hideItem.tag = 401
        hideItem.submenu = hideSub
        if let img = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil) {
            img.isTemplate = true; hideItem.image = img
        }
        menu.addItem(hideItem)

        // ── Sperren ───────────────────────────────────────────────────────
        let lockItem = NSMenuItem(title: "", action: #selector(toggleLock), keyEquivalent: "l")
        lockItem.tag = 999
        if let img = NSImage(systemSymbolName: "lock", accessibilityDescription: nil) {
            img.isTemplate = true; lockItem.image = img
        }
        menu.addItem(lockItem)
        menu.addItem(NSMenuItem.separator())

        // ── Einstellungen (submenu) ───────────────────────────────────────
        let settingsSub = NSMenu()

        let addBankItem = NSMenuItem(title: t("Bankkonto hinzufügen…", "Add Bank Account…"), action: #selector(connect), keyEquivalent: "b")
        addBankItem.tag = 100
        settingsSub.addItem(addBankItem)

        let openSettingsItem = NSMenuItem(title: t("Einstellungen öffnen…", "Open Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        openSettingsItem.tag = 200
        settingsSub.addItem(openSettingsItem)

        settingsSub.addItem(NSMenuItem.separator())

        // Demo-Modus submenu
        let demoSub = NSMenu()

        let demoOnItem = NSMenuItem(title: t("An", "On"), action: #selector(setDemoOn), keyEquivalent: "")
        demoOnItem.tag = 3011
        demoOnItem.state = demoMode ? .on : .off
        demoSub.addItem(demoOnItem)

        let demoOffItem = NSMenuItem(title: t("Aus", "Off"), action: #selector(setDemoOff), keyEquivalent: "")
        demoOffItem.tag = 3010
        demoOffItem.state = demoMode ? .off : .on
        demoSub.addItem(demoOffItem)

        demoSub.addItem(NSMenuItem.separator())

        let generateTxItem = NSMenuItem(title: t("Umsätze generieren", "Generate Transactions"), action: #selector(randomizeDemo), keyEquivalent: "")
        generateTxItem.tag = 3012
        demoSub.addItem(generateTxItem)

        let demoItem = NSMenuItem(title: t("Demo-Modus", "Demo Mode"), action: nil, keyEquivalent: "")
        demoItem.tag = 301
        demoItem.submenu = demoSub
        settingsSub.addItem(demoItem)

        let einstellungenItem = NSMenuItem(title: t("Einstellungen", "Settings"), action: nil, keyEquivalent: "")
        einstellungenItem.tag = 400
        einstellungenItem.submenu = settingsSub
        if let img = NSImage(systemSymbolName: "gear", accessibilityDescription: nil) {
            img.isTemplate = true; einstellungenItem.image = img
        }
        menu.addItem(einstellungenItem)
        menu.addItem(NSMenuItem.separator())

        // ── Nach Updates suchen ───────────────────────────────────────────
        let updateItem = NSMenuItem(title: t("Nach Updates suchen…", "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "u")
        updateItem.tag = 202
        if let img = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil) {
            img.isTemplate = true; updateItem.image = img
        }
        menu.addItem(updateItem)

        // ── Support (submenu) ─────────────────────────────────────────────
        let supportSub = NSMenu()

        let diagEnableItem = NSMenuItem(title: t("Diagnose aktivieren", "Enable Diagnostics"), action: #selector(toggleSupportDiagnostics), keyEquivalent: "")
        diagEnableItem.tag = 501
        diagEnableItem.state = appLoggingEnabled ? .on : .off
        supportSub.addItem(diagEnableItem)

        let diagReportItem = NSMenuItem(title: t("Diagnosebericht versenden…", "Send Diagnostic Report…"), action: #selector(sendDiagnosticReport), keyEquivalent: "")
        diagReportItem.tag = 502
        supportSub.addItem(diagReportItem)

        supportSub.addItem(NSMenuItem.separator())

        let openLogsItem = NSMenuItem(title: t("Logs öffnen", "Open Logs"), action: #selector(openLogs), keyEquivalent: "")
        openLogsItem.tag = 503
        supportSub.addItem(openLogsItem)

        let docItem = NSMenuItem(title: t("Dokumentation", "Documentation"), action: #selector(openDocumentation), keyEquivalent: "")
        docItem.tag = 504
        supportSub.addItem(docItem)

        supportSub.addItem(NSMenuItem.separator())

        let forgetItem = NSMenuItem(title: t("Zurücksetzen", "Reset"), action: #selector(resetApp), keyEquivalent: "")
        forgetItem.tag = 101
        if let img = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) {
            img.isTemplate = true
            forgetItem.image = img
        }
        supportSub.addItem(forgetItem)

        let supportItem = NSMenuItem(title: t("Support", "Support"), action: nil, keyEquivalent: "")
        supportItem.tag = 500
        supportItem.submenu = supportSub
        if let img = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil) {
            img.isTemplate = true; supportItem.image = img
        }
        menu.addItem(supportItem)
        menu.addItem(NSMenuItem.separator())

        // ── Beenden ───────────────────────────────────────────────────────
        let quitItem = NSMenuItem(title: t("Beenden", "Quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.tag = 1000
        if let img = NSImage(systemSymbolName: "power", accessibilityDescription: nil) {
            img.isTemplate = true; quitItem.image = img
        }
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
        updateTxPanelAccountNav()
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
                self.txVM.aiProvider = AIProvider.active
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

        NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.slotRenamed"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                let store = MultibankingStore.shared
                if let slot = store.activeSlot {
                    self.applySlotToViewModel(slot)
                    self.updateTxPanelAccountNav()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.slotDeleted"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let wasActive = (note.userInfo?["wasActive"] as? Bool) == true
            Task { @MainActor in
                if wasActive {
                    let store = MultibankingStore.shared
                    if store.slots.isEmpty {
                        self.autoStartSetupWizardIfNeeded()
                    } else {
                        await self.switchToSlot(index: store.activeIndex)
                    }
                }
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
        // Manual refresh always clears the SCA backoff — user explicitly wants to retry.
        scaBackoffUntil = nil
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
                statusItem.button?.title = t("Verbinden…", "Connect…")
                statusItem.button?.toolTip = t("Rechtsklick → Einrichtungsassistent", "Right-click → Setup Wizard")
            }
            // Kontoname/-logo sofort aus aktivem Slot wiederherstellen
            if let slot = MultibankingStore.shared.activeSlot {
                applySlotToViewModel(slot)
            }
            updateTxPanelAccountNav()
        }
    }

    @objc private func randomizeDemo() {
        demoSeed = Int.random(in: 1...Int.max)
    }

    @objc private func setDemoOn() {
        if !demoMode { toggleDemoMode() }
    }

    @objc private func setDemoOff() {
        if demoMode { toggleDemoMode() }
    }

    @objc private func toggleSupportDiagnostics() {
        AppLogger.setEnabled(!appLoggingEnabled)
        applyLocalizedMenuTitles()
    }

    @objc private func sendDiagnosticReport() {
        DispatchQueue.global(qos: .userInitiated).async {
            let logsDir = AppLogger.logDirectoryURL
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            let dateStr = formatter.string(from: Date())

            // Collect log files — sandbox-safe, no shell/Process spawn needed.
            let fm = FileManager.default
            var attachments: [URL] = []
            if let enumerator = fm.enumerator(at: logsDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        attachments.append(fileURL)
                    }
                }
            }

            DispatchQueue.main.async {
                guard !attachments.isEmpty else {
                    NSWorkspace.shared.open(logsDir)
                    return
                }
                if let service = NSSharingService(named: .composeEmail) {
                    service.recipients = ["support@simplebanking.de"]
                    service.subject = "simplebanking Diagnosebericht \(dateStr)"
                    service.perform(withItems: attachments.sorted { $0.lastPathComponent < $1.lastPathComponent })
                }
            }
        }
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(AppLogger.logDirectoryURL)
    }

    @objc private func openDocumentation() {
        if let url = URL(string: "https://www.simplebanking.de/doc") {
            NSWorkspace.shared.open(url)
        }
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
        statusItem.length = NSStatusItem.variableLength

        let logo = menuBarLogoImage()
        if let logo {
            // Logo on left + lock symbol as title
            btn.image = logo
            btn.imagePosition = .imageLeft
            setButtonTitle(btn, " 🔒")
        } else {
            // No logo: show "€ 🔒"
            btn.image = nil
            btn.imagePosition = .noImage
            setButtonTitle(btn, "€ 🔒")
        }
    }
    
    private func hideLockIcon() {
        guard let btn = statusItem.button else { return }
        // Restore the small dummy image for layout
        let img = NSImage(size: NSSize(width: 1, height: 16), flipped: false) { _ in true }
        img.isTemplate = true
        btn.image = img
        btn.imagePosition = .imageLeft
        updateMenuBarButton()
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

            // Always enabled regardless of state: Updates (202), Support (500), Beenden (1000)
            if item.tag == 202 || item.tag == 500 || item.tag == 1000 {
                item.isEnabled = true
                continue
            }

            // Not setup: disable everything else
            if !isSetup {
                item.isEnabled = false
                continue
            }

            // Setup but locked: only Entsperren (999) enabled
            if locked {
                item.isEnabled = (item.tag == 999)
                continue
            }

            // Setup and unlocked: enable all
            item.isEnabled = true
        }

        // Support submenu items are always enabled in every app state
        if let supportItem = menu.item(withTag: 500), let sub = supportItem.submenu {
            for item in sub.items where !item.isSeparatorItem {
                item.isEnabled = true
            }
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

        menu.item(withTag: 300)?.title = t("Aktualisieren", "Refresh")

        // Auto-hide submenu
        if let hideItem = menu.item(withTag: 401), let sub = hideItem.submenu {
            hideItem.title = t("Automatisch verstecken", "Auto-hide")
            sub.item(withTag: 411)?.title = t("Sofort", "Immediately")
            sub.item(withTag: 412)?.title = t("Nach 5 Sekunden", "After 5 seconds")
            sub.item(withTag: 413)?.title = t("Nach 10 Sekunden", "After 10 seconds")
            sub.item(withTag: 410)?.title = t("Aus", "Off")
        }

        if let item = menu.item(withTag: 999) {
            item.title = locked ? t("Entsperren…", "Unlock…") : t("Sperren", "Lock")
        }

        // Einstellungen submenu
        if let einItem = menu.item(withTag: 400), let sub = einItem.submenu {
            einItem.title = t("Einstellungen", "Settings")
            sub.item(withTag: 100)?.title = t("Bankkonto hinzufügen…", "Add Bank Account…")
            sub.item(withTag: 200)?.title = t("Einstellungen öffnen…", "Open Settings…")
            // Demo-Modus submenu
            if let demoItem = sub.item(withTag: 301), let demoSub = demoItem.submenu {
                demoItem.title = t("Demo-Modus", "Demo Mode")
                demoSub.item(withTag: 3011)?.title = t("An", "On")
                demoSub.item(withTag: 3010)?.title = t("Aus", "Off")
                demoSub.item(withTag: 3012)?.title = t("Umsätze generieren", "Generate Transactions")
                // sync checkmarks
                demoSub.item(withTag: 3011)?.state = demoMode ? .on : .off
                demoSub.item(withTag: 3010)?.state = demoMode ? .off : .on
            }
        }

        menu.item(withTag: 202)?.title = t("Nach Updates suchen…", "Check for Updates…")

        // Support submenu
        if let supportItem = menu.item(withTag: 500), let sub = supportItem.submenu {
            supportItem.title = t("Support", "Support")
            if let diagItem = sub.item(withTag: 501) {
                diagItem.title = t("Diagnose aktivieren", "Enable Diagnostics")
                diagItem.state = appLoggingEnabled ? .on : .off
            }
            sub.item(withTag: 502)?.title = t("Diagnosebericht versenden…", "Send Diagnostic Report…")
            sub.item(withTag: 503)?.title = t("Logs öffnen", "Open Logs")
            sub.item(withTag: 504)?.title = t("Dokumentation", "Documentation")
            sub.item(withTag: 101)?.title = t("Zurücksetzen", "Reset")
        }

        menu.item(withTag: 1000)?.title = t("Beenden", "Quit")
    }

    private func syncAutoHideMenuState() {
        guard let menu = statusMenu, let hideItem = menu.item(withTag: 401), let hideSub = hideItem.submenu else { return }

        hideItem.state = hideIndex == 0 ? .off : .on

        for item in hideSub.items {
            switch item.tag {
            case 410: item.state = hideIndex == 0 ? .on : .off
            case 411: item.state = hideIndex == 1 ? .on : .off
            case 412: item.state = hideIndex == 2 ? .on : .off
            case 413: item.state = hideIndex == 3 ? .on : .off
            default:  item.state = .off
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
        case 1: secs = 0   // Sofort
        case 2: secs = 5   // Nach 5 Sekunden
        case 3: secs = 10  // Nach 10 Sekunden
        default: secs = nil // Aus
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
    private var isPromptingUnlock: Bool = false

    private func promptUnlockIfNeeded() {
        guard locked else { return }
        guard !isPromptingUnlock else { return }  // prevent modal stacking during nested event loop
        isPromptingUnlock = true
        defer { isPromptingUnlock = false }
        showLockIcon()

        // MasterPasswordPanel uses .floating level + isFloatingPanel, so it
        // appears above all windows without needing .regular activation policy
        // (which would show a Dock icon).
        NSApp.activate(ignoringOtherApps: true)

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
                statusItem.button?.title = t("Lädt…", "Loading…")
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
                alert.messageText = t("Falsches Passwort", "Wrong password")
                if resetAttemptsLimit > 0 {
                    let remaining = resetAttemptsLimit - failedAttempts
                    alert.informativeText = t(
                        "Das eingegebene Passwort ist nicht korrekt.\n\nNoch \(remaining) Versuch\(remaining == 1 ? "" : "e") bevor alle Daten gelöscht werden.",
                        "The entered password is incorrect.\n\n\(remaining) attempt\(remaining == 1 ? "" : "s") remaining before all data is deleted."
                    )
                } else {
                    alert.informativeText = t("Das eingegebene Passwort ist nicht korrekt.", "The entered password is incorrect.")
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
        alert.messageText = t("Touch ID aktivieren?", "Enable Touch ID?")
        alert.informativeText = t("Du kannst simplebanking künftig mit Touch ID entsperren – ohne Passwort eingeben.", "You can unlock simplebanking with Touch ID in the future – no password required.")
        alert.addButton(withTitle: t("Touch ID aktivieren", "Enable Touch ID"))
        alert.addButton(withTitle: t("Nicht jetzt", "Not now"))
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            biometricOfferDismissed = true
            do {
                try BiometricStore.save(password: password)
            } catch {
                AppLogger.log("Touch ID save failed: \(error.localizedDescription)", category: "Biometric", level: "WARN")
                let errorAlert = NSAlert()
                errorAlert.messageText = t("Touch ID konnte nicht aktiviert werden", "Touch ID could not be enabled")
                errorAlert.informativeText = t("Touch ID kann in den Einstellungen unter \"Sicherheit\" erneut aktiviert werden.", "Touch ID can be enabled again in Settings under \"Security\".")
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
            }
        } else {
            biometricOfferDismissed = true
        }
    }

    private func performSecurityReset() {
        // Delete all credentials, DB files, attachments (all slots)
        CredentialsStore.deleteAllData()
        BiometricStore.clear()
        biometricOfferDismissed = false
        let allSlotIds = MultibankingStore.shared.slots.map { $0.id } + ["legacy"]
        Task {
            for slotId in allSlotIds {
                CredentialsStore.activeSlotId = slotId
                await YaxiService.clearSessionState()
            }
            CredentialsStore.activeSlotId = "legacy"
        }

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
        clearConnectedBankState()
        lastBalance = nil
        txVM.transactions = []
        txVM.resetPaging()
        lastShownTitle = "—"
        locked = false
        isHiddenBalance = false
        isHoverRevealingBalance = false
        failedAttempts = 0
        balancePopover?.performClose(nil)
        hideLockIcon()
        statusItem.button?.title = t("Verbinden…", "Connect…")
        statusItem.button?.toolTip = t("Rechtsklick → Einrichtungsassistent", "Right-click → Setup Wizard")
        
        // Show notification
        let alert = NSAlert()
        alert.messageText = t("simplebanking wurde zurückgesetzt", "simplebanking has been reset")
        alert.informativeText = t("Alle Zugangsdaten und Einstellungen wurden gelöscht.", "All credentials and settings have been deleted.")
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
        let store = MultibankingStore.shared
        let idx = store.activeIndex
        let count = store.slots.count

        var rootView = StatusBalanceFlyoutCardView(
            balanceText: balanceText,
            balanceValue: lastBalance,
            thresholds: thresholds,
            isDefaultTheme: themeId == ThemeManager.defaultThemeID,
            forcedColorScheme: configuredColorScheme()
        )
        rootView.onDoubleTap = { [weak self] in
            self?.balancePopover?.performClose(nil)
            Task { await self?.openTransactionsPanel() }
        }
        // Bank logo
        if demoMode {
            rootView.bankLogoImage = NSImage(systemSymbolName: "wallet.pass", accessibilityDescription: "Demo")
        } else {
            let flyoutBrand = BankLogoAssets.resolve(displayName: txVM.connectedBankDisplayName,
                                                      logoID: connectedBankLogoID.isEmpty ? nil : connectedBankLogoID,
                                                      iban: nil)
            BankLogoStore.shared.preload(brand: flyoutBrand)
            rootView.bankLogoImage = BankLogoStore.shared.image(for: flyoutBrand)
        }
        // Navigation callbacks — hidden in demo mode
        if !demoMode {
            rootView.onPrevAccount = idx > 0 ? { [weak self] in Task { await self?.switchToSlot(index: idx - 1) } } : nil
            rootView.onNextAccount = idx < count - 1 ? { [weak self] in Task { await self?.switchToSlot(index: idx + 1) } } : nil
            rootView.onAddAccount  = { [weak self] in self?.runSetupWizardForAddingAccount() }
        }
        // Ripple if unread new transactions, or always-on Ripple mode
        let rippleAlwaysOn = UserDefaults.standard.bool(forKey: "rippleAlwaysOn")
            && UserDefaults.standard.integer(forKey: "celebrationStyle") == 1
        if rippleAlwaysOn || (!latestTxSig.isEmpty && latestTxSig != lastSeenTxSig) {
            rootView.rippleTrigger = max(1, flyoutRippleTrigger)
        }
        let host = NSHostingController(rootView: rootView)
        popover.contentSize = NSSize(width: 348, height: 170)
        popover.contentViewController = host
        balancePopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Updates the flyout card in-place after a slot switch (balance + nav arrows), without closing/reopening.
    private func refreshFlyoutIfVisible() {
        guard let popover = balancePopover, popover.isShown,
              let host = popover.contentViewController as? NSHostingController<StatusBalanceFlyoutCardView>
        else { return }
        let store = MultibankingStore.shared
        let idx = store.activeIndex
        let count = store.slots.count
        let balanceText = lastBalance.map(formatEURWithCents) ?? "--,-- €"
        let thresholds = BalanceSignal.normalizedThresholds(
            low: balanceSignalLowUpperBound,
            medium: balanceSignalMediumUpperBound
        )
        var rootView = StatusBalanceFlyoutCardView(
            balanceText: balanceText,
            balanceValue: lastBalance,
            thresholds: thresholds,
            isDefaultTheme: themeId == ThemeManager.defaultThemeID,
            forcedColorScheme: configuredColorScheme()
        )
        rootView.onDoubleTap = { [weak self] in
            self?.balancePopover?.performClose(nil)
            Task { await self?.openTransactionsPanel() }
        }
        let refreshBrand = BankLogoAssets.resolve(displayName: txVM.connectedBankDisplayName,
                                                   logoID: connectedBankLogoID.isEmpty ? nil : connectedBankLogoID,
                                                   iban: nil)
        BankLogoStore.shared.preload(brand: refreshBrand)
        rootView.bankLogoImage = BankLogoStore.shared.image(for: refreshBrand)
        if !demoMode {
            rootView.onPrevAccount = idx > 0 ? { [weak self] in Task { await self?.switchToSlot(index: idx - 1) } } : nil
            rootView.onNextAccount = idx < count - 1 ? { [weak self] in Task { await self?.switchToSlot(index: idx + 1) } } : nil
            rootView.onAddAccount = { [weak self] in self?.runSetupWizardForAddingAccount() }
        }
        rootView.rippleTrigger = flyoutRippleTrigger
        host.rootView = rootView
    }

    @objc private func showTransactions() {
        Task { await openTransactionsPanel() }
    }

    private func refreshAsync() async {
        // Prevent concurrent HBCI calls — banks like Volksbank fail with "Fehlender Dialogkontext"
        // when two simultaneous requests hit the same HBCI connection.
        guard !isHBCICallInFlight else {
            AppLogger.log("refreshAsync: HBCI call already in flight, skipping", category: "Network", level: "WARN")
            return
        }
        isHBCICallInFlight = true
        defer { isHBCICallInFlight = false }

        let epochAtStart = slotEpoch
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
        
        // SCA backoff: after a missed redirect approval, pause auto-refresh for 1 hour
        // to avoid exhausting the bank's daily SCA authorization limit (~4/day at Sparkasse).
        if let backoff = scaBackoffUntil, backoff > Date() {
            let remaining = Int(backoff.timeIntervalSinceNow / 60)
            statusItem.button?.toolTip = t(
                "SCA-Freigabe erforderlich — bitte manuell aktualisieren (Limit erreicht, noch ~\(remaining) Min.)",
                "SCA approval required — please refresh manually (limit reached, ~\(remaining) min remaining)"
            )
            return
        }

        if locked { promptUnlockIfNeeded() }
        guard !locked, let pw = masterPassword else {
            statusItem.button?.title = t("Gesperrt", "Locked")
            statusItem.button?.toolTip = t("Entsperren erforderlich", "Unlock required")
            return
        }

        let creds: StoredCredentials
        do {
            creds = try CredentialsStore.load(masterPassword: pw)
        } catch {
            statusItem.button?.title = t("Gesperrt", "Locked")
            statusItem.button?.toolTip = t("Entsperren fehlgeschlagen", "Unlock failed")
            locked = true
            AppLogger.log("Unlock failed during refresh: \(error.localizedDescription)", category: "Auth", level: "WARN")
            return
        }

        // Bail early if the slot changed between timer fire and creds load
        guard slotEpoch == epochAtStart else {
            return
        }

        let userId = creds.userId
        let password = creds.password
        let activeProvider = AIProvider.active
        let activeKey = (try? CredentialsStore.loadAPIKey(forProvider: activeProvider, masterPassword: pw))?.nilIfEmpty
        txVM.anthropicApiKey = activeKey
        txVM.aiProvider = activeProvider
        llmAPIKeyPresent = activeKey != nil

        do {
            let resp = try await YaxiService.fetchBalances(userId: userId, password: password)

            // Bail if the slot changed while we were awaiting the network response
            guard slotEpoch == epochAtStart else {
                return
            }

            if resp.ok, let booked = resp.booked {
                lastShownTitle = formatEURNoDecimals(booked.amount)
                self.lastBalance = AmountParser.parse(booked.amount)
                self.txVM.currentBalance = self.formatEURWithCents(self.lastBalance ?? 0)
                // Cache per slot for instant display on next slot switch
                if let balance = self.lastBalance {
                    UserDefaults.standard.set(balance, forKey: "simplebanking.cachedBalance.\(YaxiService.activeSlotId)")
                }
                applyBalanceDisplayModeConstraints()
                updateStatusBalanceTitle()
                statusItem.button?.toolTip = "Kontostand (Auto-Refresh: \(refreshInterval) Min.)"

                applyHideTimer()

                // Avoid implicit TAN prompts on startup/auto-refresh unless explicitly enabled.
                if loadTransactionsOnStart {
                    Task { await checkNewBookings(userId: userId, password: password) }
                }
            } else if resp.scaRequired == true {
                // SCA redirect timed out or was missed. State has been cleared (server + Swift).
                // Pause auto-refresh for 1 hour so we don't burn through the bank's daily
                // SCA authorization limit before the user can approve.
                scaBackoffUntil = Date().addingTimeInterval(3600)
                statusItem.button?.title = "— €"
                statusItem.button?.toolTip = t(
                    "Banking-Freigabe erforderlich — klicke \"Aktualisieren\" wenn du bereit bist, die SCA-Anfrage in deiner Banking-App zu bestätigen",
                    "Banking approval required — click \"Refresh\" when ready to approve the SCA request in your banking app"
                )
                AppLogger.log("SCA required — auto-refresh paused for 1h to preserve daily SCA limit", category: "Network", level: "WARN")
            } else {
                statusItem.button?.title = "— €"
                statusItem.button?.toolTip = resp.error ?? "Keine Daten"
            }
        } catch {
            statusItem.button?.title = "— €"
            statusItem.button?.toolTip = "Fehler: \(error.localizedDescription)"
            txVM.currentBalance = "— €"
            AppLogger.log("Balance refresh failed: \(error.localizedDescription)", category: "Network", level: "ERROR")
        }
    }

    private func openTransactionsPanel() async {
        let epochAtStart = slotEpoch
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
        // Wait for any concurrent HBCI call (e.g. balance refresh) to finish before
        // fetching transactions — banks fail with "Fehlender Dialogkontext" on parallel calls.
        var waitMs = 0
        while isHBCICallInFlight && waitMs < 10_000 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            waitMs += 200
        }
        guard !isHBCICallInFlight else {
            AppLogger.log("openTransactionsPanel: HBCI still busy after \(waitMs)ms, skipping", category: "Network", level: "WARN")
            return
        }
        isHBCICallInFlight = true
        defer { isHBCICallInFlight = false }

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

        // Bail early if the slot changed between the panel show and creds load
        guard slotEpoch == epochAtStart else { return }

        let userId = creds.userId
        let password = creds.password
        let activeProvider = AIProvider.active
        let activeKey = (try? CredentialsStore.loadAPIKey(forProvider: activeProvider, masterPassword: pw))?.nilIfEmpty
        txVM.anthropicApiKey = activeKey
        txVM.aiProvider = activeProvider
        llmAPIKeyPresent = activeKey != nil

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

        do {
            let resp = try await YaxiService.fetchTransactions(userId: userId, password: password, from: from)

            // Bail if the slot changed while we were awaiting the network response
            guard slotEpoch == epochAtStart else {
                txVM.isLoading = false
                return
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
                    txVM.error = resp.error ?? t("Keine Umsatzdaten verfügbar.", "No transaction data available.")
                    confettiTransactions = []
                } else {
                    txVM.error = t("Offline, zeige gespeicherte Umsätze", "Offline, showing cached transactions")
                    confettiTransactions = txVM.transactions
                }
            }
        } catch {
            guard slotEpoch == epochAtStart else {
                txVM.isLoading = false
                return
            }
            if cachedTransactions.isEmpty {
                txVM.transactions = []
                txVM.error = "Fetch failed: \(error.localizedDescription)"
                confettiTransactions = []
            } else {
                txVM.error = t("Offline, zeige gespeicherte Umsätze", "Offline, showing cached transactions")
                confettiTransactions = txVM.transactions
            }
        }

        txVM.isLoading = false
        if !didTriggerInitialConfetti {
            maybeTriggerTransactionsConfetti(transactions: confettiTransactions, currentBalance: self.lastBalance)
        }

        // AI categorization — fire-and-forget, silent on error, reloads from DB when done
        let pwForCategorization = pw
        let epochForCategorization = slotEpoch
        let daysForCategorization = daysToFetch
        Task.detached {
            await AICategorizationService.runIfEnabled(masterPassword: pwForCategorization)
            guard await self.slotEpoch == epochForCategorization else { return }
            if let updated = try? TransactionsDatabase.loadTransactions(days: daysForCategorization), !updated.isEmpty {
                await MainActor.run {
                    guard self.slotEpoch == epochForCategorization else { return }
                    self.txVM.transactions = self.sortTransactionsNewestFirst(updated)
                }
            }
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

    private func hasNewIncomeForConfetti(in transactions: [TransactionsResponse.Transaction]) -> Bool {
        let minAmount = Double(confettiIncomeThreshold)
        guard minAmount > 0 else { return false }  // 0 = Effekte deaktiviert
        let newestIncoming = transactions
            .filter { $0.parsedAmount >= minAmount }
            .sorted { a, b in
                let dateA = a.bookingDate ?? a.valueDate ?? ""
                let dateB = b.bookingDate ?? b.valueDate ?? ""
                if dateA != dateB { return dateA > dateB }
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
        guard hasNewIncomeForConfetti(in: transactions) else { return }
        if UserDefaults.standard.integer(forKey: "celebrationStyle") == 1 {
            txVM.rippleTrigger += 1
        } else {
            txVM.confettiTrigger += 1
        }
    }

    private func triggerInitialConfettiIfNeeded() -> Bool {
        guard !confettiInitialShown else { return false }
        confettiInitialShown = true
        if UserDefaults.standard.integer(forKey: "celebrationStyle") == 1 {
            txVM.rippleTrigger += 1
        } else {
            txVM.confettiTrigger += 1
        }
        return true
    }

    private func checkNewBookings(userId: String, password: String) async {
        // Avoid noisy UI if locked/hidden; still compute indicator.
        let from = isoDateDaysAgo(7)
        do {
            let resp = try await YaxiService.fetchTransactions(userId: userId, password: password, from: from)
            guard (resp.ok ?? false), let tx = resp.transactions, !tx.isEmpty else { return }
            let sorted = tx.sorted { ($0.bookingDate ?? $0.valueDate ?? "") > ($1.bookingDate ?? $1.valueDate ?? "") }
            let sig = computeTxSignature(sorted[0])
            
            // Check if this is a new transaction
            let isNew = !lastSeenTxSig.isEmpty && sig != lastSeenTxSig && sig != latestTxSig
            latestTxSig = sig

            // Update title with dot if needed.
            updateStatusBalanceTitle()

            // Ripple on flyout if open
            if isNew {
                flyoutRippleTrigger += 1
                refreshFlyoutIfVisible()
            }

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
        let logoService   = MerchantLogoService.shared
        let merchantKey   = resolvedMerchant.lowercased()

        Task {
            var attachment: UNNotificationAttachment? = nil

            if !merchantKey.isEmpty {
                // Use cached image or wait for a fresh fetch (max 3 s)
                let image: NSImage? = await {
                    if let cached = logoService.image(for: merchantKey) { return cached }
                    logoService.preload(normalizedMerchant: merchantKey)
                    let deadline = Date().addingTimeInterval(3)
                    while Date() < deadline {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if let img = logoService.image(for: merchantKey) { return img }
                    }
                    return nil
                }()

                if let image {
                    attachment = Self.makeNotifAttachment(image: image, domain: merchantKey)
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
        case .gastronomie:   return "🍴"
        case .sparen:        return "💰"
        case .freizeit:      return "🎭"
        case .gehalt:        return "💶"
        case .gesundheit:    return "🏥"
        case .umbuchung:     return "↔️"
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
        return s
    }

    @objc private func connect() {
        // Defer showing modal panels until the status bar menu fully dismisses.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // If a real account already exists, treat this as "add another account"
            // rather than a full reinstall — same as tapping "+" in the transaction list.
            let hasRealAccount = CredentialsStore.exists() && !self.demoMode
            if hasRealAccount {
                self._runSetupWizardForAddingAccount()
            } else {
                self.runSetupWizardIfNeeded()
            }
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

    // MARK: - Task 1: Slot switching

    private func switchToSlot(index: Int) async {
        let store = MultibankingStore.shared
        guard store.slots.indices.contains(index) else {
            return
        }
        let slot = store.slots[index]

        // Invalidate any in-flight refreshAsync / openTransactionsPanel from the old slot
        slotEpoch += 1

        // Switch active slot in all data layers
        YaxiService.activeSlotId = slot.id
        CredentialsStore.activeSlotId = slot.id
        TransactionsDatabase.activeSlotId = slot.id
        await YaxiService.sessionStore.reloadForActiveSlot()
        store.setActive(index: index)

        // Apply the new slot's identity to AppStorage + txVM immediately
        applySlotToViewModel(slot)

        // Clear displayed data immediately
        txVM.transactions = []
        txVM.resetPaging()
        txVM.currentBalance = nil
        lastBalance = nil

        // Show cached balance instantly (avoids "…" flash when balance is known)
        if let cachedBalance = UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slot.id)") as? Double {
            lastBalance = cachedBalance
            txVM.currentBalance = formatEURWithCents(cachedBalance)
            updateStatusBalanceTitle()
        } else if !isHiddenBalance {
            statusItem.button?.title = "…"
        }

        // Show cached transactions from DB right away (no network wait)
        if let cached = try? TransactionsDatabase.loadTransactions(days: 60), !cached.isEmpty {
            txVM.transactions = sortTransactionsNewestFirst(cached)
            txVM.resetPaging()
        }

        // Wait for any in-flight HBCI call to finish before refreshing for the new slot.
        // The old call was epoch-invalidated above and will return soon.
        while isHBCICallInFlight {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Fetch live balance
        await refreshAsync()

        // Update flyout card in-place with new balance + nav arrows (without closing)
        refreshFlyoutIfVisible()

        // If the transactions panel is already open, reload live transactions for the new slot
        if txPanel?.isVisible == true {
            await openTransactionsPanel()
        }

        updateTxPanelAccountNav()
    }

    /// Aktualisiert die < / > / + Callbacks im Transaktions-Panel nach jedem Slot-Wechsel.
    @MainActor private func updateTxPanelAccountNav() {
        guard let nav = txPanel?.accountNav else { return }
        guard !demoMode else {
            nav.onPrevAccount = nil
            nav.onNextAccount = nil
            nav.onAddAccount  = nil
            return
        }
        let store = MultibankingStore.shared
        let idx   = store.activeIndex
        let count = store.slots.count
        nav.onPrevAccount = idx > 0
            ? { [weak self] in Task { await self?.switchToSlot(index: idx - 1) } } : nil
        nav.onNextAccount = idx < count - 1
            ? { [weak self] in Task { await self?.switchToSlot(index: idx + 1) } } : nil
        nav.onAddAccount  = { [weak self] in self?.runSetupWizardForAddingAccount() }
    }

    // MARK: - Task 3: Add account wizard

    private func runSetupWizardForAddingAccount() {
        DispatchQueue.main.async { [weak self] in
            self?._runSetupWizardForAddingAccount()
        }
    }

    private func _runSetupWizardForAddingAccount() {
        let previousSlot = MultibankingStore.shared.activeSlot

        // Neue Slot-ID VOR dem Wizard erstellen und aktivieren,
        // damit performSetupConnection alle Daten in den richtigen Slot schreibt.
        let newSlot = BankSlot.makeNew(iban: "", displayName: "", logoId: nil)
        YaxiService.activeSlotId = newSlot.id
        CredentialsStore.activeSlotId = newSlot.id
        TransactionsDatabase.activeSlotId = newSlot.id

        final class AdditionalAccountsBox: @unchecked Sendable { var value: [Routex.Account] = [] }
        let additionalAccountsBox = AdditionalAccountsBox()

        let wizard = SetupWizardPanel(
            connectAction: { payload, selectedBankName, options, masterPassword in
                AppLogger.log(
                    "AddAccount connectAction ibanPrefix=\(String(payload.iban.prefix(6))) selectedBank=\(selectedBankName ?? "-")",
                    category: "Setup"
                )
                let setupResult = try await Self.performSetupConnection(
                    result: payload,
                    selectedBankName: selectedBankName,
                    masterPassword: masterPassword,
                    options: options
                )
                additionalAccountsBox.value = setupResult.additionalAccounts
                return setupResult.bank
            },
            existingMasterPassword: masterPassword   // Passwort-Schritt überspringen
        )

        switch wizard.runModal() {
        case .realBanking(let pw, let bank):
            // IBAN aus frisch gespeicherten Credentials lesen
            let creds = try? CredentialsStore.load(masterPassword: pw)
            let normalizedIBAN = (creds?.iban ?? "")
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let finalSlot = BankSlot(
                id: newSlot.id,
                iban: normalizedIBAN,
                displayName: bank.displayName,
                logoId: bank.logoId
            )
            MultibankingStore.shared.addSlot(finalSlot)

            // Create extra slots for additional accounts selected in the picker
            let primarySlotId = newSlot.id
            for account in additionalAccountsBox.value {
                let iban = (account.iban ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !iban.isEmpty else { continue }
                let extraSlot = BankSlot.makeNew(iban: "", displayName: "", logoId: nil)
                let extraSlotId = extraSlot.id
                CredentialsStore.activeSlotId = primarySlotId
                if var extraCreds = try? CredentialsStore.load(masterPassword: pw) {
                    extraCreds.iban = iban
                    CredentialsStore.activeSlotId = extraSlotId
                    try? CredentialsStore.save(extraCreds, masterPassword: pw)
                }
                Task { await YaxiService.copyConnectionState(fromSlotId: primarySlotId, toSlotId: extraSlotId) }
                YaxiService.activeSlotId = extraSlotId
                YaxiService.storeDiscoveredIBAN(iban)
                let accountTitle: String = {
                    let parts = [account.displayName, account.ownerName, String(iban.prefix(12)) + "…"].compactMap { $0?.nilIfEmpty }
                    return parts.first ?? iban
                }()
                let extraBankSlot = BankSlot(id: extraSlotId, iban: iban, displayName: accountTitle, logoId: bank.logoId)
                MultibankingStore.shared.addSlot(extraBankSlot)
            }
            // Restore to primary slot
            CredentialsStore.activeSlotId = newSlot.id
            YaxiService.activeSlotId = newSlot.id
            TransactionsDatabase.activeSlotId = newSlot.id

            updateTxPanelAccountNav()
            applySlotToViewModel(finalSlot)   // uses name-first brand resolution (logo + name)
            statusItem.button?.toolTip = t("Verbunden mit \(bank.displayName)", "Connected to \(bank.displayName)")
            Task { await self.refreshAsync() }

        case .demoMode, .cancelled:
            // Vorherigen Slot wiederherstellen
            let restoreId = previousSlot?.id ?? "legacy"
            YaxiService.activeSlotId = restoreId
            CredentialsStore.activeSlotId = restoreId
            TransactionsDatabase.activeSlotId = restoreId
            if let prev = previousSlot {
                MultibankingStore.shared.setActive(index: MultibankingStore.shared.slots.firstIndex(where: { $0.id == prev.id }) ?? 0)
                applySlotToViewModel(prev)
            }
        }
    }

    private func runSetupWizardIfNeeded() {
        // Clear old state immediately — opening the wizard means starting fresh
        lastBalance = nil
        txVM.transactions = []
        txVM.resetPaging()
        statusItem.button?.title = t("Verbinden…", "Connect…")

        // Ensure legacy slot is active for first-time setup.
        // If the app was reset while a non-legacy slot was active, activeSlotId would still
        // hold the old slot ID — causing all setup data to be written under the wrong keys.
        YaxiService.activeSlotId = "legacy"
        CredentialsStore.activeSlotId = "legacy"
        TransactionsDatabase.activeSlotId = "legacy"

        final class AdditionalAccountsBox2: @unchecked Sendable { var value: [Routex.Account] = [] }
        let additionalAccountsBox2 = AdditionalAccountsBox2()

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
            additionalAccountsBox2.value = setupResult.additionalAccounts
            return setupResult.bank
        })

        switch wizard.runModal() {
        case .realBanking(let pw, let bank):
            self.masterPassword = pw
            locked = false
            if let creds = try? CredentialsStore.load(masterPassword: pw) {
                let activeProvider = AIProvider.active
                let activeKey = (try? CredentialsStore.loadAPIKey(forProvider: activeProvider, masterPassword: pw))?.nilIfEmpty
                txVM.anthropicApiKey = activeKey
                txVM.aiProvider = activeProvider
                llmAPIKeyPresent = activeKey != nil
                _ = creds // suppress unused warning
                let normalizedIBAN = creds.iban
                    .replacingOccurrences(of: " ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                // Ersten Slot in MultibankingStore anlegen (id="legacy" für Erstkonto)
                let legacySlot = BankSlot(id: "legacy", iban: normalizedIBAN, displayName: bank.displayName, logoId: bank.logoId)
                MultibankingStore.shared.replaceFirstSlot(with: legacySlot)

                // Create extra slots for additional accounts selected in the picker
                for account in additionalAccountsBox2.value {
                    let iban = (account.iban ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    guard !iban.isEmpty else { continue }
                    let extraSlot = BankSlot.makeNew(iban: "", displayName: "", logoId: nil)
                    let extraSlotId = extraSlot.id
                    CredentialsStore.activeSlotId = "legacy"
                    if var extraCreds = try? CredentialsStore.load(masterPassword: pw) {
                        extraCreds.iban = iban
                        CredentialsStore.activeSlotId = extraSlotId
                        try? CredentialsStore.save(extraCreds, masterPassword: pw)
                    }
                    Task { await YaxiService.copyConnectionState(fromSlotId: "legacy", toSlotId: extraSlotId) }
                    YaxiService.activeSlotId = extraSlotId
                    YaxiService.storeDiscoveredIBAN(iban)
                    let accountTitle: String = {
                        let parts = [account.displayName, account.ownerName, String(iban.prefix(12)) + "…"].compactMap { $0?.nilIfEmpty }
                        return parts.first ?? iban
                    }()
                    let extraBankSlot = BankSlot(id: extraSlotId, iban: iban, displayName: accountTitle, logoId: bank.logoId)
                    MultibankingStore.shared.addSlot(extraBankSlot)
                }
                // Restore to legacy slot
                CredentialsStore.activeSlotId = "legacy"
                YaxiService.activeSlotId = "legacy"
                TransactionsDatabase.activeSlotId = "legacy"

                updateTxPanelAccountNav()
                applySlotToViewModel(legacySlot)
            } else {
                updateConnectedBankState(bank)
            }
            statusItem.button?.toolTip = "Verbunden mit \(bank.displayName)"
            // Fresh setup — mark legacy slot migration as done so it never wipes sessions on first restart
            UserDefaults.standard.set(true, forKey: "simplebanking.migration.legacySlotFullReset.v1")
            Task { await self.refreshAsync() }
            // After first-time setup: offer to add a second account
            promptAddAnotherAccount()
        case .demoMode:
            self.demoMode = true
            self.demoSeed = Int.random(in: 1...9999)
            Task { await self.refreshAsync() }
        case .cancelled:
            break
        }
    }
    
    private func promptAddAnotherAccount() {
        let alert = NSAlert()
        alert.messageText = t("Weiteres Konto einrichten?", "Add another account?")
        alert.informativeText = t(
            "Möchtest du ein weiteres Bankkonto zur App hinzufügen?",
            "Would you like to add another bank account to the app?"
        )
        alert.addButton(withTitle: t("Ja", "Yes"))
        alert.addButton(withTitle: t("Nein", "No"))
        if alert.runModal() == .alertFirstButtonReturn {
            _runSetupWizardForAddingAccount()
        }
    }

    private enum SetupFlowError: LocalizedError {
        case cancelled
        case bankNotFound
        case connectTimeout(step: String)
        case authenticationFailed(String)
        case storageFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Einrichtung abgebrochen."
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
        let additionalAccounts: [Routex.Account]
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
                // Drain remaining cancelled tasks to prevent CancellationError propagation
                while let _ = try? await group.next() {}
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

        // "Unauthorized" — bank rejected connection.
        // Most common cause: wrong credentials, blocked SCA device, or expired consent.
        if lower.contains("unauthorized") {
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
            options.onProgress?(.discoveringBank)
            AppLogger.log("Setup step accounts_flow: using pre-discovered bank", category: "Setup")

            // Bank discovery already happened in SetupWizardPanel.onSearchContinue (discoverBankByTerm).
            // connectionId is stored in UserDefaults. IBAN will be discovered via accounts() API after SCA.
            let fallbackName = selectedBankName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            try await runSetupStepWithTimeout(step: "clear_session_initial", logger: diagnosticsLogger) {
                // Full wipe of connectionData AND in-memory sessions at setup start.
                //
                // SessionStore.session(for:) returns shared in-memory state (not slot-scoped).
                // Sessions written by background refreshes on other slots remain in memory when
                // the active slot switches to a new setup slot, and bleed into fetchAccounts —
                // causing "FGW Fehlender Dialogkontext" for FinTS banks (stale dialog token).
                //
                // Per YAXI credentials model (docs.yaxi.tech/credentials.html):
                //   full    → fresh credentials entered → no session benefit
                //   userId  → decoupled auth (Push-TAN via app) → fresh challenge
                //   none    → redirect to bank website → fresh auth
                //   userId+none → YAXI tries decoupled, falls back to redirect if needed
                // In all cases the setup wizard triggers a fresh auth flow. An old session
                // from a different slot provides no benefit and may cause stale-dialog errors.
                // Note: connectionId must NOT be cleared here — it was just stored by bank
                // selection (storeConnectionInfo) and is required for the accounts() call below.
                await YaxiService.clearSessionOnly()
            }

            let fetchDaysSetting = UserDefaults.standard.integer(forKey: "fetchDays")
            let warmupDays = fetchDaysSetting > 0 ? fetchDaysSetting : 60
            let warmupFrom = setupWarmupFromDate(days: warmupDays)

            // Build finalBank from pre-discovered connectionId + selected bank name
            let storedConnectionId = UserDefaults.standard.string(forKey: YaxiService.connectionIdKey) ?? ""
            let finalBank = DiscoveredBank(
                id: storedConnectionId,
                displayName: fallbackName.isEmpty ? "Bank" : fallbackName,
                logoId: nil,
                credentials: YaxiService.loadStoredCredentials(),
                userIdLabel: nil,
                advice: nil
            )

            // Step 1: accounts() — SCA (einmalige Freigabe per Push-TAN).
            // Liefert IBAN + connectionData für alle weiteren Aufrufe (recurring consent).
            // Redirect-Flows (z.B. Sparkasse): Nutzer muss sich auf Bank-Website einloggen
            // und SCA bestätigen. Server pollt bis zu 600 s — Swift-Timeout muss größer sein.
            options.onProgress?(.requestingApproval)
            AppLogger.log("Setup step warmup_accounts", category: "Setup")
            let discoveredAccounts = try await runSetupStepWithTimeout(step: "warmup_accounts", timeout: 720, logger: diagnosticsLogger) {
                try await YaxiService.fetchAccounts(userId: result.userId, password: result.password)
            }
            let selectableAccounts = discoveredAccounts.filter { account in
                let iban = account.iban?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !iban.isEmpty
            }
            guard !selectableAccounts.isEmpty else {
                throw SetupFlowError.authenticationFailed(
                    L10n.t("Kein Konto gefunden. Bitte Bank erneut verbinden.", "No account found. Please reconnect.")
                )
            }
            let selectedAccounts: [Routex.Account]
            if selectableAccounts.count == 1 {
                selectedAccounts = [selectableAccounts[0]]
            } else if let picker = options.onPickAccount {
                guard let picked = await picker(selectableAccounts), !picked.isEmpty else {
                    throw SetupFlowError.cancelled
                }
                selectedAccounts = picked
            } else {
                // No wizard UI available — fall back to first account
                selectedAccounts = [selectableAccounts[0]]
            }
            let primaryAccount = selectedAccounts[0]
            let additionalAccounts = Array(selectedAccounts.dropFirst())
            let selectedIBAN = (primaryAccount.iban ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            YaxiService.storeDiscoveredIBAN(selectedIBAN)
            AppLogger.log("Setup: account selected ibanPrefix=\(String(selectedIBAN.prefix(8))) total=\(discoveredAccounts.count) additional=\(additionalAccounts.count)", category: "Setup")

            // Step 2: balances() — nutzt connectionData + IBAN aus accounts().
            // Kein SCA mehr nötig (recurring consent ist gesetzt).
            options.onProgress?(.fetchingBalance)
            AppLogger.log("Setup step warmup_balances", category: "Setup")
            let warmupBalances = try await runSetupStepWithTimeout(step: "warmup_balances", timeout: 300, logger: diagnosticsLogger) {
                try await YaxiService.fetchBalances(
                    userId: result.userId,
                    password: result.password
                )
            }
            if !warmupBalances.ok {
                let techMsg = warmupBalances.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let techMsg, isLikelyCredentialError(techMsg) {
                    let displayMsg = warmupBalances.userMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? techMsg
                    throw SetupFlowError.authenticationFailed(displayMsg)
                }
                let fallback = warmupBalances.scaRequired == true
                    ? "Kontostand: Freigabe konnte nicht abgeschlossen werden. Bitte erneut verbinden."
                    : "Kontostandabfrage fehlgeschlagen. Bitte erneut versuchen."
                throw SetupFlowError.authenticationFailed(
                    warmupBalances.userMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? techMsg?.nilIfEmpty
                    ?? fallback
                )
            }

            options.onProgress?(.requestingTransactionApproval)
            AppLogger.log("Setup step warmup_transactions", category: "Setup")
            var warmupTransactions = try await runSetupStepWithTimeout(step: "warmup_transactions", timeout: 720, logger: diagnosticsLogger) {
                try await YaxiService.fetchTransactions(
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
                    await YaxiService.clearSessionsKeepingConnectionData()
                }
                _ = try await runSetupStepWithTimeout(step: "warmup_balances_retry", timeout: 720, logger: diagnosticsLogger) {
                    try await YaxiService.fetchBalances(userId: result.userId, password: result.password)
                }
                warmupTransactions = try await runSetupStepWithTimeout(step: "warmup_transactions_retry", timeout: 720, logger: diagnosticsLogger) {
                    try await YaxiService.fetchTransactions(
                        userId: result.userId,
                        password: result.password,
                        from: warmupFrom
                    )
                }
            }

            if !(warmupTransactions.ok ?? false) {
                let techMsg = warmupTransactions.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = warmupTransactions.scaRequired == true
                    ? "Umsätze: Freigabe konnte nicht abgeschlossen werden (Schritt 3 von 3). Bitte erneut verbinden."
                    : "Umsatzabfrage fehlgeschlagen (Schritt 3 von 3). Bitte erneut versuchen."
                let displayMsg = warmupTransactions.userMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? techMsg?.nilIfEmpty
                    ?? fallback
                throw SetupFlowError.authenticationFailed(displayMsg)
            }

            if let techMsg = warmupTransactions.error, isLikelyCredentialError(techMsg) {
                let displayMsg = warmupTransactions.userMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? techMsg
                throw SetupFlowError.authenticationFailed(displayMsg)
            }

            // IBAN was stored from the selected account above.
            let storedIBAN = selectedIBAN
            AppLogger.log("Setup: IBAN stored prefix=\(String(storedIBAN.prefix(8)))", category: "Setup")

            options.onProgress?(.savingCredentials)
            let existingCreds = try? CredentialsStore.load(masterPassword: masterPassword)
            try await runSetupStepWithTimeout(step: "store_credentials", logger: diagnosticsLogger) {
                try CredentialsStore.save(
                    StoredCredentials(
                        iban: storedIBAN,
                        userId: result.userId,
                        password: result.password,
                        anthropicApiKey: existingCreds?.anthropicApiKey,
                        mistralApiKey: existingCreds?.mistralApiKey,
                        openaiApiKey: existingCreds?.openaiApiKey
                    ),
                    masterPassword: masterPassword
                )
            }

            diagnosticsLogger?.finish(success: true, error: nil)
            AppLogger.log("Setup performSetupConnection success", category: "Setup")
            return SetupConnectResult(
                bank: finalBank,
                normalizedIBAN: storedIBAN,
                apiKey: nil,
                additionalAccounts: additionalAccounts
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

    @objc private func resetApp() {
        let alert = NSAlert()
        alert.messageText = t("simplebanking zurücksetzen?", "Reset simplebanking?")
        alert.informativeText = t(
            "Willst Du wirklich simplebanking zurücksetzen? Alle Zugangsdaten und Einstellungen werden gelöscht.",
            "Do you really want to reset simplebanking? All credentials and settings will be deleted."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("Zurücksetzen", "Reset"))
        alert.addButton(withTitle: t("Abbrechen", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            performSecurityReset()
        }
    }
    
    @objc private func showSettings() {
        settingsPanel?.show()
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
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
    var bankLogoImage: NSImage? = nil
    var onDoubleTap: (() -> Void)? = nil
    // Task 2: Navigation callbacks
    var onPrevAccount: (() -> Void)? = nil
    var onNextAccount: (() -> Void)? = nil
    var onAddAccount:  (() -> Void)? = nil
    var rippleTrigger: Int = 0

    @Environment(\.colorScheme) private var environmentColorScheme
    @State private var showNav: Bool = false

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
            // Ripple confined to the card tile — double-tap bubbles up to parent
            .rippleEffect(trigger: rippleTrigger, defaultOrigin: CGPoint(x: 310, y: 130))
            .padding(14)
        }
        .frame(width: 348, height: 170)
        .background(Color.panelBackground)
        .preferredColorScheme(forcedColorScheme)
        .onTapGesture(count: 2) { onDoubleTap?() }
        .overlay(alignment: .top) {
            if showNav || onPrevAccount != nil || onNextAccount != nil || onAddAccount != nil {
                HStack {
                    // Left: previous account
                    if let prev = onPrevAccount {
                        Button(action: prev) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .opacity(showNav ? 1 : 0)
                    }
                    Spacer()
                    // Right: next account or add account
                    if let next = onNextAccount {
                        Button(action: next) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .opacity(showNav ? 1 : 0)
                    } else if let add = onAddAccount {
                        Button(action: add) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .opacity(showNav ? 1 : 0)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .animation(.easeInOut(duration: 0.15), value: showNav)
            }
        }
        .onHover { hovering in showNav = hovering }
    }

    private var defaultThemeCard: some View {
        let level = BalanceSignal.classify(balance: balanceValue, thresholds: thresholds)
        let style = BalanceSignal.style(for: level)
        let displayBalance = balanceValue == nil ? "--,-- €" : balanceText
        let glassColor = activeColorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.60)
        let borderColor = activeColorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.35)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let img = bankLogoImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: "wallet.pass")
                        .font(.system(size: 16))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
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
