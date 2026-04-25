import AppKit
import Combine
import Foundation
import Routex
import SwiftUI
import UserNotifications
import ServiceManagement

extension Notification.Name {
    static let slotSettingsChanged = Notification.Name("simplebanking.slotSettingsChanged")
}

// Custom vertical alignment: aligns ring center with balance-amount text center.
private extension VerticalAlignment {
    private enum BalanceTextCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d.height / 2 }
    }
    static let balanceTextCenter = VerticalAlignment(BalanceTextCenter.self)
}

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    @AppStorage("demoMode") private var demoMode: Bool = false
    @AppStorage("demoStyle") private var demoStyle: Int = 0   // 0 = single, 1 = multi
    @AppStorage("demoSeed") private var demoSeed: Int = 123456
    private var updateChecker: UpdateChecker?

    private var isMultiDemo: Bool { demoMode && demoStyle == 1 }

    // Backup storage for slot state before multi-demo was activated
    private var demoPreviousSlots: [BankSlot] = []
    private var demoPreviousActiveIndex: Int = 0
    private var demoPreviousUnifiedMode: Bool = false

    private var hideIndex: Int {
        get { UserDefaults.standard.object(forKey: "hideIndex") as? Int ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "hideIndex") }
    }
    @AppStorage(AppLogger.enabledKey) private var appLoggingEnabled: Bool = false
    @AppStorage("menubarStyle") private var menubarStyle: Int = 1  // 0=lang (fixed), 1=kurz (dynamic)
    @AppStorage("refreshInterval") private var refreshInterval: Int = 240
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
    /// Optional: App zusätzlich im Dock + Cmd-Tab zeigen. Default: off (Agent-App-Verhalten).
    @AppStorage("dockModeEnabled") private var dockModeEnabled: Bool = false
    /// Referenz auf das App-Menu-Close-Item, damit Cmd-Q-Verhalten live umschaltbar ist.
    private var appMenuCloseItem: NSMenuItem?

    @AppStorage("confettiLastIncomeTxSig") private var confettiLastIncomeTxSig: String = ""
    /// Per-slot dict: latest tx sig observed from YAXI (not yet "seen" by opening the panel).
    private var latestTxSigBySlot: [String: String] = [:]
    private var flyoutRippleTrigger: Int = 0
    private var logoObserver: AnyCancellable?
    private var txObserver: AnyCancellable?
    private var leftToPayObserver: AnyCancellable?

    // MARK: - Per-slot lastSeenTxSig helpers

    private func lastSeenTxSig(for slotId: String) -> String {
        UserDefaults.standard.string(forKey: "simplebanking.lastSeenTxSig.\(slotId)") ?? ""
    }

    private func setLastSeenTxSig(_ sig: String, for slotId: String) {
        UserDefaults.standard.set(sig, forKey: "simplebanking.lastSeenTxSig.\(slotId)")
    }

    /// One-time migration: copy old scalar lastSeenTxSig → legacy slot key.
    private func migrateLastSeenTxSigIfNeeded() {
        let legacyKey = "simplebanking.lastSeenTxSig.legacy"
        guard UserDefaults.standard.string(forKey: legacyKey) == nil,
              let old = UserDefaults.standard.string(forKey: "lastSeenTxSig"), !old.isEmpty else { return }
        UserDefaults.standard.set(old, forKey: legacyKey)
    }
    
    // Für Balance-Anzeige
    private(set) var lastBalance: Double? = nil

    private var masterPassword: String? = nil
    private var locked: Bool = false

    /// Incremented on every slot switch. Async tasks capture this at start and bail if it changed.
    private var slotEpoch: Int = 0
    /// Cancellable task for the current slot switch — ensures only the last click wins.
    private var switchTask: Task<Void, Never>?
    private var isHBCICallInFlight: Bool = false    // guard against concurrent HBCI calls (balance + transactions)
    private var isTanPending: Bool = false

    private var isHiddenBalance: Bool = false
    private var hideTimer: Timer?
    private var pendingLeftClick: DispatchWorkItem?
    private var flyoutClosedByClickAt: Date?
    private var lastShownTitle: String = "—"
    
    private var settingsPanel: SettingsPanel?
    private var refreshIntervalObserver: Any?
    private var apiKeyObserver: Any?
    private var languageObserver: Any?
    private var balanceDisplayModeObserver: Any?
    private var addAccountObserver: Any?
    private var globalHotkeyObserver: Any?
    private var didTriggerAutoSetupThisLaunch: Bool = false
    // After a missed SCA redirect, pause auto-refresh to avoid burning through the bank's
    // daily SCA authorization limit (e.g. Sparkasse allows ~4 redirects per day).
    private var scaBackoffUntil: Date? = nil

    private func decoratedTitle(_ title: String) -> String {
        // New booking indicator: dot if any slot has unseen newer transactions.
        let hasNew = latestTxSigBySlot.contains { slotId, sig in
            !sig.isEmpty && sig != lastSeenTxSig(for: slotId)
        }
        if hasNew { return "\(title)  ●" }
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

    /// Computes the unified balance string for the menu bar (all slots summed).
    /// Returns nil if unified mode is off, no slots have cached balances, or only one slot exists.
    private func computeUnifiedBalanceTitle() -> String? {
        guard txVM.isUnifiedMode else { return nil }
        let slots = MultibankingStore.shared.slots
        guard slots.count > 1 else { return nil }
        // Read cached balances; skip slots without a cached value (never synced)
        var byCurrency: [String: Double] = [:]
        for slot in slots {
            guard let balance = UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slot.id)") as? Double else { continue }
            let currency = slot.currency ?? "EUR"
            byCurrency[currency, default: 0] += balance
        }
        guard !byCurrency.isEmpty else { return nil }
        // Sort by abs(balance) descending, cap at 2 currencies + "+N"
        let sorted = byCurrency.sorted { abs($0.value) > abs($1.value) }
        func fmt(_ currency: String, _ amount: Double) -> String {
            let symbol: String
            switch currency {
            case "EUR": symbol = "€"
            case "USD": symbol = "$"
            case "GBP": symbol = "£"
            case "CHF": symbol = "₣"
            default: symbol = currency
            }
            let absAmt = abs(amount)
            let formatted: String
            if absAmt >= 1000 {
                formatted = String(format: "%.0f", absAmt)
                    .reversed()
                    .enumerated()
                    .map { $0.offset > 0 && $0.offset % 3 == 0 ? ".\(String($0.element))" : String($0.element) }
                    .reversed()
                    .joined()
            } else {
                formatted = String(format: "%.0f", absAmt)
            }
            return amount < 0 ? "-\(symbol) \(formatted)" : "\(symbol) \(formatted)"
        }
        let shown = sorted.prefix(2)
        let overflow = sorted.count - 2
        var parts = shown.map { fmt($0.key, $0.value) }
        if overflow > 0 { parts.append("+\(overflow)") }
        return parts.joined(separator: " · ")
    }

    /// Builds per-slot display items for the unified flyout card.
    private func computeFlyoutSlots() -> [FlyoutSlotItem] {
        let store = MultibankingStore.shared
        return store.slots.map { slot in
            let brand = BankLogoAssets.resolve(displayName: slot.displayName, logoID: slot.logoId, iban: slot.iban)
            BankLogoStore.shared.preload(brand: brand)
            let logo = BankLogoStore.shared.image(for: brand)
            let balance = UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slot.id)") as? Double
            let currency = slot.currency ?? "EUR"
            let symbol: String
            switch currency {
            case "EUR": symbol = "€"
            case "USD": symbol = "$"
            case "GBP": symbol = "£"
            case "CHF": symbol = "₣"
            default: symbol = currency
            }
            let balText: String
            if let b = balance {
                let absAmt = abs(b)
                let formatted: String
                if absAmt >= 1000 {
                    formatted = String(format: "%.0f", absAmt)
                        .reversed()
                        .enumerated()
                        .map { $0.offset > 0 && $0.offset % 3 == 0 ? ".\(String($0.element))" : String($0.element) }
                        .reversed()
                        .joined()
                } else {
                    formatted = String(format: "%.0f", absAmt)
                }
                balText = b < 0 ? "-\(symbol) \(formatted)" : "\(symbol) \(formatted)"
            } else {
                balText = "--"
            }
            let barColor: Color
            if let hex = slot.customColor, let c = Color(hex: hex) {
                barColor = c
            } else if let logoId = slot.logoId,
                      let hex = GeneratedBankColors.primaryColor(forLogoId: logoId),
                      let c = Color(hex: hex) {
                barColor = c
            } else {
                barColor = Color.secondary.opacity(0.4)
            }
            return FlyoutSlotItem(
                logo: logo,
                brandId: brand?.id,
                balanceText: balText,
                isNegative: balance.map { $0 < 0 } ?? false,
                barColor: barColor,
                nickname: slot.nickname
            )
        }
    }

    /// Computes the unified total balance (Double) for the flyout card.
    private func computeUnifiedFlyoutTotal() -> Double? {
        guard txVM.isUnifiedMode else { return nil }
        let slots = MultibankingStore.shared.slots
        guard slots.count > 1 else { return nil }
        var total = 0.0
        var hasAny = false
        for slot in slots {
            guard let b = UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slot.id)") as? Double else { continue }
            total += b
            hasAny = true
        }
        return hasAny ? total : nil
    }

    /// Ring fraction: balance / salaryReference, 0…1.
    /// Uses salary (manual or auto-detected from loaded transactions) as 100% mark.
    /// Falls back to balanceSignalMediumUpperBound only when no salary is known.
    private func computeGreenZoneFraction() -> Double {
        let slotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        let s = BankSlotSettingsStore.load(slotId: slotId)
        let reference: Int
        if s.salaryAmount > 0 {
            reference = s.salaryAmount
        } else {
            let detected = SalaryProgressCalculator.detectedIncome(
                salaryDay: s.effectiveSalaryDay,
                tolerance: s.salaryDayTolerance,
                transactions: txVM.transactions)
            reference = detected > 0 ? Int(detected.rounded()) : s.balanceSignalMediumUpperBound
        }
        var effectiveRef = reference
        if UserDefaults.standard.bool(forKey: "greenZoneIncludeOtherIncome") {
            let other = SalaryProgressCalculator.detectedOtherIncome(
                salaryDay: s.effectiveSalaryDay, transactions: txVM.transactions)
            effectiveRef += Int(other.rounded())
        }
        return SalaryProgressCalculator.greenZoneFraction(
            balance: lastBalance,
            mediumThreshold: effectiveRef)
    }

    /// Computes the unified total balance for the flyout card (formatted with cents).
    private func computeUnifiedFlyoutBalanceText() -> String? {
        guard let total = computeUnifiedFlyoutTotal() else { return nil }
        return formatEURWithCents(total)
    }

    private func updateMenuBarButton() {
        guard let button = statusItem?.button else { return }
        guard !locked else { return }

        let isShort = menubarStyle == 1
        let logo = menuBarLogoImage()

        // Logo on the LEFT, text on the right.
        // In unified mode: use building.columns.fill SF Symbol instead of active slot logo.
        // If no logo: "€" is prepended to the title text instead.
        if txVM.isUnifiedMode && (!demoMode || isMultiDemo) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            if let unifiedIcon = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                unifiedIcon.isTemplate = true
                button.image = unifiedIcon
                button.imagePosition = .imageLeft
            } else {
                button.image = logo
                button.imagePosition = logo != nil ? .imageLeft : .noImage
            }
        } else {
            button.image = logo
            button.imagePosition = logo != nil ? .imageLeft : .noImage
        }

        let p = " "  // small gap; currency symbol is part of the formatted amount

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

        // Normal balance (unified sum when in unified mode)
        if let unifiedTitle = computeUnifiedBalanceTitle() {
            let indicator = latestTxSigBySlot.contains { id, sig in !sig.isEmpty && sig != lastSeenTxSig(for: id) } ? "  ●" : ""
            setButtonTitle(button, "\(unifiedTitle)\(indicator)")
        } else {
            setButtonTitle(button, "\(p)\(decoratedTitle(lastShownTitle))")
        }
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
        txVM.connectedBankCurrency = slot.currency
        txVM.connectedBankNickname = slot.nickname

        // Kick off logo download immediately so the balance card and titlebar
        // have the image ready (or nearly ready) when SwiftUI re-renders.
        let brand = BankLogoAssets.resolve(displayName: resolvedName,
                                           logoID: resolvedLogo.isEmpty ? nil : resolvedLogo,
                                           iban: normalizedIBAN.isEmpty ? nil : normalizedIBAN)
        BankLogoStore.shared.preload(brand: brand)
        txVM.connectedBankLogoImage = BankLogoStore.shared.image(for: brand)
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
        txVM.connectedBankLogoImage = nil
        txVM.connectedBankIBAN = nil
        txVM.connectedBankCurrency = nil
        txVM.connectedBankNickname = nil
    }

    private let txVM = TransactionsViewModel()
    private var txPanel: TransactionsPanel?
    private var statusMenu: NSMenu?
    private var balancePopover: NSPopover?
    private var isFlyoutHovered: Bool = false
    private var statusButtonTrackingArea: NSTrackingArea?
    private var isHoverRevealingBalance: Bool = false

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Local TZ so `isoDateDaysAgo` returns the user-perceived calendar day.
        // UTC would shift past-midnight locals into the previous day.
        formatter.timeZone = TimeZone.current
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
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
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

        // One-time migration: copy scalar lastSeenTxSig → per-slot key for legacy slot.
        migrateLastSeenTxSigIfNeeded()

        installEditMenu()
        applyDockMode()
        // Settings-Toggle → Live-Umschalten
        NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.dockModeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyDockMode()
        }
        // CLI-IPC: `sb refresh` → DistributedNotification → Haupt-App-Refresh.
        // CLI hat keine Routex-Dependency, triggert stattdessen den bestehenden
        // Refresh-Pfad der App. WICHTIG: Der reguläre `refresh()` holt nur den Saldo
        // (Cache in UserDefaults). Transaktionen werden nur fetched wenn
        // `loadTransactionsOnStart=true`. Für die CLI ist der Transactions-Fetch aber
        // essentiell — ohne ihn bumpt `MAX(updated_at)` nicht und das CLI-Polling
        // läuft in den Timeout. Wir rufen daher den Full-Refresh-Pfad direkt.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("tech.yaxi.simplebanking.cli.refreshRequested"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AppLogger.log("CLI-Refresh angefordert", category: "CLI")
            self?.refreshFromCLI()
        }
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
        statusItem.autosaveName = "com.simplebanking.statusItem"

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

        // When a bank logo finishes downloading, refresh the flyout and menu bar button
        // so the correct icon appears without needing a manual account switch.
        logoObserver = BankLogoStore.shared.$images
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshFlyoutIfVisible()
                self?.updateMenuBarButton()
                self?.updateTxPanelAccountNav()
                self?.updateTxPanelLogoImage()
            }

        // When transactions are loaded (from DB cache or network), refresh the flyout so the
        // ring fraction is correct even if the flyout was opened before the first refresh.
        txObserver = txVM.$transactions
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.refreshFlyoutIfVisible() }

        // "Noch offen" changes (recompute finished) → re-render flyout so the
        // subtitle appears/updates without waiting for the next open.
        leftToPayObserver = txVM.$leftToPayAmount
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.refreshFlyoutIfVisible() }

        // When per-slot settings change (e.g. Kritische Schwelle, Gehaltstag),
        // refresh the flyout and recompute "Noch offen" so cycle-dependent
        // values update immediately without waiting for the next balance fetch.
        NotificationCenter.default.addObserver(forName: .slotSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshFlyoutIfVisible()
            self?.recomputeLeftToPay()
        }

        // Register UserDefaults defaults (only apply when key has no stored value).
        UserDefaults.standard.register(defaults: ["celebrationStyle": 1])

        // Unlock on startup if encrypted credentials exist (but not in demo mode)
        if CredentialsStore.exists() && !demoMode {
            let pwRequired = UserDefaults.standard.object(forKey: "passwordRequired") as? Bool ?? true
            if !pwRequired, let autoPw = BiometricStore.loadAutoUnlockPassword() {
                // Auto-unlock without prompt
                if let _ = try? CredentialsStore.load(masterPassword: autoPw) {
                    masterPassword = autoPw
                    locked = false
                    Task { await refreshAsync() }
                } else {
                    // Auto-unlock password mismatch → fall back to prompt
                    locked = true
                    promptUnlockIfNeeded()
                }
            } else {
                locked = true
                promptUnlockIfNeeded()
            }
        } else if demoMode {
            // Demo mode starts unlocked with demo data
            locked = false
            if demoStyle == 1 { activateMultiDemo() }
            Task { await refreshAsync() }
            recomputeLeftToPay()
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

        let immediateItem = NSMenuItem(title: t("2 Sekunden", "2 Seconds"), action: #selector(setHideImmediate), keyEquivalent: "")
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

        let twentySecItem = NSMenuItem(title: t("Nach 20 Sekunden", "After 20 seconds"), action: #selector(setHide60), keyEquivalent: "")
        twentySecItem.tag = 414
        twentySecItem.state = (hideIndex == 4) ? .on : .off
        hideSub.addItem(twentySecItem)

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

        let demoSingleItem = NSMenuItem(title: t("Single-Banking", "Single Banking"), action: #selector(setDemoSingle), keyEquivalent: "")
        demoSingleItem.tag = 3011
        demoSingleItem.state = (demoMode && !isMultiDemo) ? .on : .off
        demoSub.addItem(demoSingleItem)

        let demoMultiItem = NSMenuItem(title: t("Multi-Banking", "Multi Banking"), action: #selector(setDemoMulti), keyEquivalent: "")
        demoMultiItem.tag = 3013
        demoMultiItem.state = isMultiDemo ? .on : .off
        demoSub.addItem(demoMultiItem)

        let demoOffItem = NSMenuItem(title: t("Aus", "Off"), action: #selector(setDemoOff), keyEquivalent: "")
        demoOffItem.tag = 3010
        demoOffItem.state = !demoMode ? .on : .off
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

        // ── Support (submenu) ─────────────────────────────────────────────
        let supportSub = NSMenu()

        let diagEnableItem = NSMenuItem(title: t("Diagnose aktivieren", "Enable Diagnostics"), action: #selector(toggleSupportDiagnostics), keyEquivalent: "")
        diagEnableItem.tag = 501
        diagEnableItem.target = self
        diagEnableItem.state = appLoggingEnabled ? .on : .off
        supportSub.addItem(diagEnableItem)

        let diagReportItem = NSMenuItem(title: t("Diagnosebericht versenden…", "Send Diagnostic Report…"), action: #selector(sendDiagnosticReport), keyEquivalent: "")
        diagReportItem.tag = 502
        diagReportItem.target = self
        supportSub.addItem(diagReportItem)

        supportSub.addItem(NSMenuItem.separator())

        let openLogsItem = NSMenuItem(title: t("Logs öffnen", "Open Logs"), action: #selector(openLogs), keyEquivalent: "")
        openLogsItem.tag = 503
        openLogsItem.target = self
        supportSub.addItem(openLogsItem)

        let docItem = NSMenuItem(title: t("Dokumentation", "Documentation"), action: #selector(openDocumentation), keyEquivalent: "")
        docItem.tag = 504
        docItem.target = self
        supportSub.addItem(docItem)

        supportSub.addItem(NSMenuItem.separator())

        let reconnectItem = NSMenuItem(title: t("Bank neu verbinden", "Reconnect Bank"), action: #selector(reconnectBank), keyEquivalent: "")
        reconnectItem.target = self
        reconnectItem.tag = 505
        if let img = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) {
            img.isTemplate = true
            reconnectItem.image = img
        }
        supportSub.addItem(reconnectItem)

        let forgetItem = NSMenuItem(title: t("Zurücksetzen", "Reset"), action: #selector(resetApp), keyEquivalent: "")
        forgetItem.target = self
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

        // ── Nach Updates suchen ───────────────────────────────────────────
        let updateItem = NSMenuItem(title: t("Nach Updates suchen…", "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.tag = 202
        menu.addItem(updateItem)
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
            // Only open/refresh if the panel is already visible.
            // This prevents onChange(of: unifiedModeEnabled) in TransactionsPanelView
            // from auto-opening the panel when unified mode is toggled from the flyout.
            guard self?.txPanel?.isVisible == true else { return }
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

        addAccountObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.addAccount"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.connect()
        }

        refresh()

        // Preload subscription logos once so the Abos sheet can render icons immediately.
        SubscriptionLogoStore.shared.preloadInitial(displayNames: LogoAssets.allDisplayNames)

        autoStartSetupWizardIfNeeded()

        setupGlobalHotkey()
        globalHotkeyObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.globalHotkeyChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.setupGlobalHotkey() }

        updateChecker = UpdateChecker()
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
        if let observer = addAccountObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = globalHotkeyObserver {
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

    // MARK: - CLI refresh outcome

    /// True solange ein CLI-Refresh läuft. Erlaubt den internen catch-Blöcken
    /// in `refreshAsync` / `checkNewBookings`, ihre Fehlertexte an den Outcome
    /// zu hängen, ohne die Funktions-Signaturen zu brechen. Wird sync auf
    /// MainActor gesetzt — verhindert dass parallele `sb refresh`-Calls
    /// gegenseitig den Outcome überschreiben.
    private var cliRefreshInFlight: Bool = false
    private var cliRefreshErrorDetail: String?

    /// Wird aus catch-Blöcken gerufen. No-op außerhalb eines CLI-Refresh.
    /// First-wins: der erste Fehler gewinnt, damit Folgefehler den root cause
    /// nicht überschreiben.
    private func recordCLIRefreshError(_ detail: String) {
        guard cliRefreshInFlight, cliRefreshErrorDetail == nil else { return }
        cliRefreshErrorDetail = detail
    }

    /// Schreibt den Outcome als JSON nach `simplebanking.cli.lastRefreshOutcome`.
    /// Setzt zusätzlich den alten `lastRefreshCompletedAt`-Marker, damit ältere
    /// `sb`-Binaries nicht brechen (rückwärtskompat). Wire-Format steckt in
    /// `CLIRefreshOutcomeMarshaller` — dort liegen auch die Tests.
    private func writeCLIRefreshOutcome(_ status: CLIRefreshOutcomeStatus, detail: String? = nil) {
        guard let encoded = CLIRefreshOutcomeMarshaller.encode(status: status, detail: detail) else {
            AppLogger.log("CLI-Refresh outcome encode failed (\(status.rawValue))", category: "CLI", level: "ERROR")
            return
        }
        UserDefaults.standard.set(encoded.json, forKey: CLIRefreshOutcomeKeys.outcome)
        UserDefaults.standard.set(encoded.timestamp, forKey: CLIRefreshOutcomeKeys.legacy)
        AppLogger.log("CLI-Refresh \(status.rawValue)\(detail.map { " — \($0)" } ?? "")", category: "CLI")
    }

    /// Vom CLI-Observer getriggert. Holt Saldo *und* Transaktionen in jedem Fall
    /// (unabhängig von `loadTransactionsOnStart`), damit das CLI-Polling einen
    /// DB-Bump sieht. Schreibt nach Abschluss einen Outcome-Marker (success /
    /// locked / failed), damit die CLI unterscheiden kann, ob tatsächlich ein
    /// Bankabruf gelungen ist oder nur „irgendwas passiert" ist.
    @objc private func refreshFromCLI() {
        // Race-Guard: zweiter `sb refresh` während ein erster noch läuft würde
        // sonst den Outcome-State des ersten überschreiben. Wir melden den
        // Conflict ehrlich zurück statt einen falschen Erfolg zu schreiben.
        if cliRefreshInFlight {
            writeCLIRefreshOutcome(.failed, detail: "Refresh läuft bereits")
            return
        }
        cliRefreshInFlight = true
        cliRefreshErrorDetail = nil
        scaBackoffUntil = nil

        Task {
            defer { cliRefreshInFlight = false }

            // Gate: kein Refresh möglich ohne entsperrten Master-Password-Kontext.
            guard !locked, let pw = masterPassword,
                  let creds = try? CredentialsStore.load(masterPassword: pw) else {
                writeCLIRefreshOutcome(.locked)
                return
            }

            await refreshAsync()
            // Transactions-Fetch ist für `sb refresh` Pflicht — refreshAsync() holt
            // nur den Saldo wenn loadTransactionsOnStart=false.
            await checkNewBookings(userId: creds.userId, password: creds.password)

            // SCA-Backoff wurde während refreshAsync gesetzt → als failed werten,
            // auch wenn kein einzelner catch-Block Detail geliefert hat.
            if let detail = cliRefreshErrorDetail {
                writeCLIRefreshOutcome(.failed, detail: detail)
            } else if scaBackoffUntil != nil {
                writeCLIRefreshOutcome(.failed, detail: "SCA-Freigabe erforderlich")
            } else {
                writeCLIRefreshOutcome(.success)
            }
        }
    }

    // Called from SetupFlowPanel outcome — activates single demo
    @objc private func toggleDemoMode() {
        if !demoMode { setDemoSingle() } else { setDemoOff() }
    }

    @objc private func setDemoSingle() {
        let wasMulti = isMultiDemo
        if wasMulti { tearDownMultiDemo() }
        demoStyle = 0
        demoMode = true
        demoSeed = Int.random(in: 1...Int.max)
        txVM.anthropicApiKey = nil
        txVM.connectedBankDisplayName = "Demo-Bank"
        txVM.connectedBankLogoID = nil
        txVM.connectedBankIBAN = nil
        txVM.leftToPayAmount = nil   // drop stale live value
        var seed = UInt64(truncatingIfNeeded: demoSeed)
        let fake = FakeData.demoBalance(seed: &seed)
        lastShownTitle = formatEURNoDecimals(String(format: "%.2f", fake))
        lastBalance = fake
        txVM.currentBalance = formatEURWithCents(fake)
        applyBalanceDisplayModeConstraints()
        updateStatusBalanceTitle()
        updateMenuBarButton()
        statusItem.button?.toolTip = "🎭 Demo-Modus: Single-Banking"
        rebuildMenuTitleForDemoMode()
        recomputeLeftToPay()
    }

    @objc private func setDemoMulti() {
        let wasMulti = isMultiDemo
        if wasMulti { tearDownMultiDemo() }
        demoStyle = 1
        demoMode = true
        demoSeed = Int.random(in: 1...Int.max)
        txVM.leftToPayAmount = nil   // drop stale live value
        activateMultiDemo()
        rebuildMenuTitleForDemoMode()
        recomputeLeftToPay()
    }

    @objc private func setDemoOff() {
        guard demoMode else { return }
        if isMultiDemo { tearDownMultiDemo() }
        demoMode = false
        demoStyle = 0
        txVM.transactions = []
        txVM.leftToPayAmount = nil   // drop stale demo value
        txVM.resetPaging()
        rebuildMenuTitleForDemoMode()
        // Apply the live slot BEFORE checking credentials — CredentialsStore context
        // (slot ID) must be set correctly, otherwise exists() returns false and the
        // menu shows "Verbinden" even though credentials are stored on disk.
        //
        // tearDownMultiDemo restores MultibankingStore.slots, but the static
        // activeSlotIds (YaxiService/CredentialsStore/TransactionsDatabase) still
        // point at a non-existent "demo-slot-N" if the user navigated between
        // demo accounts. Restore them from the active live slot so the credential
        // lookup below hits the right keys.
        if let slot = MultibankingStore.shared.activeSlot {
            YaxiService.activeSlotId        = slot.id
            CredentialsStore.activeSlotId   = slot.id
            TransactionsDatabase.activeSlotId = slot.id
            applySlotToViewModel(slot)
        }
        updateTxPanelAccountNav()
        if CredentialsStore.exists() {
            locked = true
            showLockIcon()
            promptUnlockIfNeeded()
        } else {
            statusItem.button?.title = t("Verbinden…", "Connect…")
            statusItem.button?.toolTip = t("Rechtsklick → Einrichtungsassistent", "Right-click → Setup Wizard")
        }
    }

    @objc private func randomizeDemo() {
        demoSeed = Int.random(in: 1...Int.max)
        guard demoMode else { return }
        if isMultiDemo {
            tearDownMultiDemo()
            activateMultiDemo()
        }
        Task { await refreshAsync() }
    }

    private func activateMultiDemo() {
        // Backup current slot state
        demoPreviousSlots = MultibankingStore.shared.slots
        demoPreviousActiveIndex = MultibankingStore.shared.activeIndex
        demoPreviousUnifiedMode = UserDefaults.standard.bool(forKey: "unifiedModeEnabled")

        // Pick 3 distinct random banks
        var seed = UInt64(truncatingIfNeeded: demoSeed)
        let brands = BankLogoAssets.brands
        var usedIndices = Set<Int>()
        var picked: [BankLogoAssets.BankBrand] = []
        while picked.count < 3 && picked.count < brands.count {
            let idx = Int(FakeData.nextDouble(&seed) * Double(brands.count))
            guard idx >= 0 && idx < brands.count else { continue }
            if usedIndices.insert(idx).inserted {
                picked.append(brands[idx])
            }
        }

        let demoSlots = picked.enumerated().map { i, brand -> BankSlot in
            BankSlot(id: "demo-slot-\(i)", iban: "DE\(String(format: "%020d", i))",
                     displayName: brand.displayName, logoId: brand.id)
        }
        MultibankingStore.shared.injectDemoSlots(demoSlots)

        // Keep user's unified mode preference — don't force it on for demo

        // Compute per-slot balances and store for flyout; save demo-specific slot settings
        var total = 0.0
        for (i, slot) in demoSlots.enumerated() {
            let b = FakeData.demoBalance(seed: &seed, slotProfile: i)
            UserDefaults.standard.set(b, forKey: "simplebanking.cachedBalance.\(slot.id)")
            total += b
            var settings = BankSlotSettingsStore.load(slotId: slot.id)
            settings.salaryDay  = FakeData.demoSalaryDay(slotProfile: i)
            settings.dispoLimit = FakeData.demoDispoLimit(slotProfile: i)
            BankSlotSettingsStore.save(settings, slotId: slot.id)
        }

        lastBalance = total
        lastShownTitle = formatEURNoDecimals(String(format: "%.2f", total))
        txVM.currentBalance = formatEURWithCents(total)
        txVM.connectedBankDisplayName = "Demo"
        txVM.connectedBankLogoID = nil
        txVM.connectedBankIBAN = nil
        applyBalanceDisplayModeConstraints()
        updateStatusBalanceTitle()
        updateMenuBarButton()
        statusItem.button?.toolTip = "🎭 Demo-Modus: Multi-Banking"

        // Preload logos for flyout
        for slot in demoSlots {
            let brand = BankLogoAssets.resolve(displayName: slot.displayName, logoID: slot.logoId, iban: nil)
            BankLogoStore.shared.preload(brand: brand)
        }
    }

    private func tearDownMultiDemo() {
        for i in 0..<3 {
            UserDefaults.standard.removeObject(forKey: "simplebanking.cachedBalance.demo-slot-\(i)")
            BankSlotSettingsStore.delete(slotId: "demo-slot-\(i)")
        }
        MultibankingStore.shared.restoreDemoSlots(demoPreviousSlots, activeIndex: demoPreviousActiveIndex)
        txVM.unifiedModeEnabled = demoPreviousUnifiedMode
        demoPreviousSlots = []
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
        txPanel?.close()   // close detail view so it can't block unlock
        showLockIcon()
        statusItem.button?.toolTip = "Gesperrt – Doppelklick oder Rechtsklick zum Entsperren"
    }
    
    private func showLockIcon() {
        guard let btn = statusItem.button else { return }
        statusItem.length = NSStatusItem.variableLength

        let logo = menuBarLogoImage()
        btn.image = logo
        btn.imagePosition = logo != nil ? .imageLeft : .noImage

        // Build monochrome lock title using SF Symbol (adapts to light/dark menu bar)
        let prefix = logo != nil ? " " : "€ "
        let attrTitle = NSMutableAttributedString(
            string: prefix,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
        )
        if let lockSym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Gesperrt"),
           let lockImg = lockSym.withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))?.copy() as? NSImage {
            lockImg.isTemplate = true
            let att = NSTextAttachment()
            att.image = lockImg
            attrTitle.append(NSAttributedString(attachment: att))
        } else {
            attrTitle.append(NSAttributedString(string: "🔒"))
        }
        btn.attributedTitle = attrTitle
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
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = NSMenu()
        }

        // App menu with Cmd+Q — Action wird von applyDockMode() je nach
        // Activation Policy gesetzt (Agent: "Fenster schließen", Dock: "Beenden").
        let appMenu = NSMenu()
        let closeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "q")
        appMenu.addItem(closeItem)
        appMenuCloseItem = closeItem
        let appMenuItem = NSMenuItem(title: "simplebanking", action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu?.addItem(appMenuItem)

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
        NSApp.mainMenu?.addItem(editItem)
    }

    /// Schaltet zwischen Agent-Mode (nur Menüleiste) und Dock-Mode (zusätzlich Dock + Cmd-Tab)
    /// anhand der `dockModeEnabled`-Einstellung. Kann jederzeit live gerufen werden.
    func applyDockMode() {
        let targetPolicy: NSApplication.ActivationPolicy = dockModeEnabled ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
            AppLogger.log("applyDockMode: activationPolicy → \(dockModeEnabled ? ".regular" : ".accessory")",
                          category: "App")
        }
        // Cmd-Q-Verhalten an Modus anpassen
        if let item = appMenuCloseItem {
            if dockModeEnabled {
                item.title = L10n.t("simplebanking beenden", "Quit simplebanking")
                item.action = #selector(NSApplication.terminate(_:))
                item.target = nil  // first responder chain → NSApp
            } else {
                item.title = L10n.t("Fenster schließen", "Close Window")
                item.action = #selector(closeVisibleWindows)
                item.target = self
            }
        }
    }

    /// macOS ruft das auf, wenn der User das Dock-Icon klickt (nur im Dock-Mode).
    /// Wir öffnen das Umsatzfenster, sofern es nicht schon sichtbar ist.
    /// `hasVisibleWindows` zählt JEDES Fenster (Settings, Sheets …) — wir müssen
    /// daher spezifisch den Sichtbarkeits-Status des Umsatzpanels prüfen, damit
    /// die Zusage „Dock-Icon öffnet die Umsatzliste" auch dann stimmt, wenn
    /// gerade nur Settings o.ä. offen ist.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if txPanel?.isVisible != true {
            Task { [weak self] in await self?.openTransactionsPanel() }
        }
        return true
    }

    @objc private func closeVisibleWindows() {
        var closed = false
        if txPanel?.isVisible == true {
            txPanel?.close()
            closed = true
        }
        // Close settings window if visible
        for window in NSApp.windows where window.isVisible && window.title == L10n.t("Einstellungen", "Settings") {
            window.orderOut(nil)
            closed = true
        }
        // If no windows were open, do nothing (don't quit)
        _ = closed
    }

    // NSMenuDelegate
    func menuWillOpen(_ menu: NSMenu) {
        let isSetup = CredentialsStore.exists() || demoMode
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

    @objc private func setHideOff() { hideIndex = 0; restartHideTimer() }
    @objc private func setHideImmediate() { hideIndex = 1; restartHideTimer() }
    @objc private func setHide10() { hideIndex = 2; restartHideTimer() }
    @objc private func setHide30() { hideIndex = 3; restartHideTimer() }
    @objc private func setHide60() { hideIndex = 4; restartHideTimer() }

    /// Force-restart the hide timer (used when the user changes the hide setting).
    private func restartHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
        applyHideTimer()
    }

    private func applyLocalizedMenuTitles() {
        guard let menu = statusMenu else { return }

        menu.item(withTag: 300)?.title = t("Aktualisieren", "Refresh")

        // Auto-hide submenu
        if let hideItem = menu.item(withTag: 401), let sub = hideItem.submenu {
            hideItem.title = t("Automatisch verstecken", "Auto-hide")
            sub.item(withTag: 411)?.title = t("2 Sekunden", "2 Seconds")
            sub.item(withTag: 412)?.title = t("Nach 5 Sekunden", "After 5 seconds")
            sub.item(withTag: 413)?.title = t("Nach 10 Sekunden", "After 10 seconds")
            sub.item(withTag: 414)?.title = t("Nach 20 Sekunden", "After 20 seconds")
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
                demoSub.item(withTag: 3011)?.title = t("Single-Banking", "Single Banking")
                demoSub.item(withTag: 3013)?.title = t("Multi-Banking", "Multi Banking")
                demoSub.item(withTag: 3010)?.title = t("Aus", "Off")
                demoSub.item(withTag: 3012)?.title = t("Umsätze generieren", "Generate Transactions")
                // sync checkmarks
                demoSub.item(withTag: 3011)?.state = (demoMode && !isMultiDemo) ? .on : .off
                demoSub.item(withTag: 3013)?.state = isMultiDemo ? .on : .off
                demoSub.item(withTag: 3010)?.state = !demoMode ? .on : .off
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
            case 414: item.state = hideIndex == 4 ? .on : .off
            default:  item.state = .off
            }
        }
    }

    private func applyHideTimer() {
        syncAutoHideMenuState()

        // don't schedule when off
        let secs: TimeInterval?
        switch hideIndex {
        case 1: secs = 2   // 2 Sekunden
        case 2: secs = 5   // Nach 5 Sekunden
        case 3: secs = 10  // Nach 10 Sekunden
        case 4: secs = 20  // Nach 20 Sekunden
        default: secs = nil // Aus
        }

        guard let delay = secs else {
            hideTimer?.invalidate()
            hideTimer = nil
            // "Aus" — balance always visible; show immediately if currently hidden
            if isHiddenBalance && !locked {
                isHiddenBalance = false
                isHoverRevealingBalance = false
                hideLockIcon()
                updateStatusBalanceTitle()
                statusItem.button?.toolTip = ""
            }
            return
        }

        // Only schedule auto-hide when we are currently visible.
        guard !isHiddenBalance else { return }

        // Don't reset an already-running timer — prevents balance refreshes
        // from restarting the countdown and making the hide feel delayed.
        if hideTimer?.isValid == true { return }

        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hideBalance()
            }
        }
    }

    private func hideBalance() {
        balancePopover?.performClose(nil)
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
                if demoMode {
                    // In demo mode there are no credential files to decrypt.
                    // Verify the password directly against the Keychain master password.
                    guard BiometricStore.verifyPasswordDirectly(pw) else {
                        throw NSError(domain: "simplebanking.auth", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "Wrong password"])
                    }
                } else {
                    _ = try CredentialsStore.load(masterPassword: pw)
                }
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
        BiometricStore.clearAutoUnlock()
        biometricOfferDismissed = false
        let allSlotIds = MultibankingStore.shared.slots.map { $0.id } + ["legacy"]
        Task {
            for slotId in allSlotIds {
                await YaxiService.clearSessionData(forSlotId: slotId)
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

    private var hoverExitWork: DispatchWorkItem?

    @objc(mouseEntered:) func mouseEntered(_ event: NSEvent) {
        hoverExitWork?.cancel()
        hoverExitWork = nil
        revealBalanceOnHoverIfNeeded()
    }

    @objc(mouseExited:) func mouseExited(_ event: NSEvent) {
        hoverExitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideHoverRevealIfNeeded()
        }
        hoverExitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
            if locked {
                // Double-click while locked: show unlock dialog directly
                if ev.clickCount >= 2 {
                    pendingLeftClick?.cancel()
                    pendingLeftClick = nil
                    promptUnlockIfNeeded()
                }
                return
            }
            
            // Szenario A: Flyout ist noch sichtbar (statusItemClicked kommt vor .transient-Dismiss).
            // Bei Doppelklick: Flyout schließen + Umsatzliste öffnen.
            // Bei Einfachklick: nur Flyout schließen (kein Re-open via Debounce).
            // popoverWillClose-Delegate setzt flyoutClosedByClickAt synchron.
            if balancePopover?.isShown == true {
                pendingLeftClick?.cancel()
                pendingLeftClick = nil
                if ev.clickCount >= 2 {
                    balancePopover?.performClose(nil)
                    if swapClickBehavior {
                        performBalancePrimaryAction()
                    } else {
                        Task { await openTransactionsPanel() }
                    }
                } else {
                    balancePopover?.performClose(nil)
                    // flyoutClosedByClickAt wird von popoverWillClose synchron gesetzt.
                    // Kein Debounce-Re-open — nächster Click < doubleClickInterval → Umsatzliste.
                }
                return
            }

            // Szenario B: .transient hat den ersten Click konsumiert und Flyout bereits geschlossen.
            // popoverWillClose hat flyoutClosedByClickAt synchron gesetzt.
            // Falls zweiter Click (Doppelklick-Intent) innerhalb des System-Doppelklick-Intervalls kommt:
            // → Umsatzliste öffnen.
            let doubleClickInterval = NSEvent.doubleClickInterval
            if let closedAt = flyoutClosedByClickAt,
               Date().timeIntervalSince(closedAt) < doubleClickInterval {
                flyoutClosedByClickAt = nil
                pendingLeftClick?.cancel()
                pendingLeftClick = nil
                if swapClickBehavior {
                    performBalancePrimaryAction()
                } else {
                    Task { await openTransactionsPanel() }
                }
                return
            }
            flyoutClosedByClickAt = nil

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
    
    // MARK: - YAXI error helpers

    /// Extracts the bank-provided userMessage from a RoutexClientError, if present.
    private static func yaxiUserMessage(_ error: Error) -> String? {
        guard let re = error as? RoutexClientError else { return nil }
        switch re {
        case .UnexpectedError(let msg): return msg
        case .InvalidCredentials(let msg): return msg
        case .ServiceBlocked(let msg, _): return msg
        case .Unauthorized(let msg): return msg
        case .ConsentExpired(let msg): return msg
        case .ProviderError(_, let msg): return msg
        default: return nil
        }
    }

    private static func isCanceledError(_ error: Error) -> Bool {
        guard let re = error as? RoutexClientError else { return false }
        if case .Canceled = re { return true }
        return false
    }

    /// Human-readable refresh interval: "Manuell", "60 Min.", "4 Stunden".
    /// Mirrors the RefreshInterval enum labels in SettingsPanel so tooltip and
    /// settings stay in sync.
    private func formatRefreshInterval(_ minutes: Int) -> String {
        if minutes <= 0 {
            return L10n.t("Manuell", "Manual")
        }
        if minutes >= 60 && minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1
                ? L10n.t("1 Stunde", "1 hour")
                : L10n.t("\(hours) Stunden", "\(hours) hours")
        }
        return L10n.t("\(minutes) Min.", "\(minutes) min")
    }

    /// Recompute "Noch offen" (sum of recurring payments still expected this cycle)
    /// off-thread from 90 days of history. Safe to call after every successful
    /// balance refresh — cheap enough (<100ms on typical history).
    ///
    /// Unified mode: compute per-slot with that slot's own salaryDay, then sum.
    /// Each account's recurring payments are evaluated against that account's
    /// own cycle — otherwise a combined total would be judged against a single
    /// slot's salary rhythm, which is fachlich wrong.
    ///
    /// Demo mode: transactions are never persisted to SQLite, so generate
    /// 90 days of fake history via FakeData with the current demoSeed.
    private func recomputeLeftToPay() {
        let activeSlot = YaxiService.activeSlotId
        let isDemo = demoMode
        let isMulti = isMultiDemo
        let seedSnapshot = demoSeed
        let isUnified = txVM.isUnifiedMode
        let allSlots = MultibankingStore.shared.slots.map { $0.id }
        let activeIdx = MultibankingStore.shared.activeIndex

        Task.detached(priority: .utility) {
            var total: Double = 0
            var sawAny = false

            if isDemo {
                // Generate fake history per slot profile (matches what the panel shows).
                // Use the active demo seed so left-to-pay is consistent with visible tx list.
                if isMulti {
                    // Compute per profile first, then aggregate based on unified vs per-slot.
                    var seed = UInt64(truncatingIfNeeded: seedSnapshot)
                    var perProfile: [Double] = []
                    for (i, _) in allSlots.enumerated() {
                        let history = FakeData.generateDemoTransactions(
                            seed: &seed, days: 90, slotProfile: i
                        )
                        guard !history.isEmpty else { perProfile.append(0); continue }
                        let payments = FixedCostsAnalyzer.analyze(transactions: history)
                        let salaryDay = FakeData.demoSalaryDay(slotProfile: i)
                        perProfile.append(LeftToPayCalculator.compute(
                            payments: payments,
                            salaryDay: salaryDay
                        ))
                    }
                    if isUnified {
                        total = perProfile.reduce(0, +)
                        sawAny = perProfile.contains { $0 > 0 }
                    } else if perProfile.indices.contains(activeIdx) {
                        total = perProfile[activeIdx]
                        sawAny = total > 0
                    }
                } else {
                    var seed = UInt64(truncatingIfNeeded: seedSnapshot)
                    let history = FakeData.generateDemoTransactions(seed: &seed, days: 90, slotProfile: 0)
                    if !history.isEmpty {
                        let payments = FixedCostsAnalyzer.analyze(transactions: history)
                        total = LeftToPayCalculator.compute(
                            payments: payments,
                            salaryDay: FakeData.demoSalaryDay(slotProfile: 0)
                        )
                        sawAny = total > 0
                    }
                }
            } else {
                let slotIds = isUnified ? allSlots : [activeSlot]
                for slot in slotIds {
                    let history = (try? TransactionsDatabase.loadUnifiedTransactions(
                        slots: [slot], days: 90, bankId: "primary")) ?? []
                    guard !history.isEmpty else { continue }
                    sawAny = true
                    let payments = FixedCostsAnalyzer.analyze(transactions: history)
                    let cfg = BankSlotSettingsStore.load(slotId: slot)
                    total += LeftToPayCalculator.compute(
                        payments: payments,
                        salaryDay: cfg.effectiveSalaryDay,
                        toleranceBefore: cfg.salaryDayToleranceBefore,
                        toleranceAfter: cfg.salaryDayToleranceAfter
                    )
                }
            }

            AppLogger.log(
                "leftToPay: demo=\(isDemo) multi=\(isMulti) unified=\(isUnified) activeIdx=\(activeIdx) sawAny=\(sawAny) total=\(String(format: "%.2f", total))",
                category: "LeftToPay"
            )
            await MainActor.run { [weak self] in
                self?.txVM.leftToPayAmount = sawAny ? total : nil
            }
        }
    }

    private func toggleBalanceVisibility() {
        if isHiddenBalance {
            unhideNow()
        } else {
            hideBalance()
        }
    }

    // NSPopoverDelegate — fired synchronously on main thread before statusItemClicked fires.
    // MainActor.assumeIsolated is safe here because NSPopoverDelegate always runs on the main thread.
    nonisolated func popoverWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            flyoutClosedByClickAt = Date()
        }
    }

    private func showBalanceFlyout() {
        guard let button = statusItem?.button else { return }

        if balancePopover?.isShown == true {
            balancePopover?.performClose(nil)
            return
        }

        let popover = balancePopover ?? NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self

        let isUnified = txVM.isUnifiedMode && (!demoMode || isMultiDemo)
        let balanceText = isUnified
            ? (computeUnifiedFlyoutBalanceText() ?? "--,-- €")
            : (lastBalance.map(formatEURWithCents) ?? "--,-- €")
        let activeSlotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        let activeSlotCfg = BankSlotSettingsStore.load(slotId: activeSlotId)
        let thresholds = BalanceSignal.normalizedThresholds(
            low: activeSlotCfg.balanceSignalLowUpperBound,
            medium: activeSlotCfg.balanceSignalMediumUpperBound
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
        rootView.leftToPayAmount = txVM.leftToPayAmount
        let subMetricsSettings = BankSlotSettingsStore.load(
            slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy"
        )
        rootView.salaryDay = subMetricsSettings.effectiveSalaryDay
        rootView.salaryToleranceBefore = subMetricsSettings.salaryDayToleranceBefore
        rootView.salaryToleranceAfter = subMetricsSettings.salaryDayToleranceAfter
        rootView.onDoubleTap = { [weak self] in
            self?.balancePopover?.performClose(nil)
            Task { await self?.openTransactionsPanel() }
        }
        rootView.onHoverChanged = { [weak self] hovering in
            self?.isFlyoutHovered = hovering
        }
        if isUnified {
            // Unified flyout: show aggregated card with per-slot pills, no cycle button
            rootView.unifiedSlots = computeFlyoutSlots()
            rootView.unifiedTotalBalance = computeUnifiedFlyoutTotal()
        } else {
            // Bank logo
            if demoMode {
                rootView.bankLogoImage = NSImage(systemSymbolName: "wallet.pass", accessibilityDescription: "Demo")
            } else {
                let flyoutBrand = BankLogoAssets.resolve(displayName: txVM.connectedBankDisplayName,
                                                          logoID: connectedBankLogoID.isEmpty ? nil : connectedBankLogoID,
                                                          iban: nil)
                BankLogoStore.shared.preload(brand: flyoutBrand)
                rootView.bankLogoImage = BankLogoStore.shared.image(for: flyoutBrand)
                rootView.bankLogoBrandId = flyoutBrand?.id
            }
            rootView.currency = MultibankingStore.shared.activeSlot?.currency
            rootView.nickname = MultibankingStore.shared.activeSlot?.nickname
            rootView.bankName = txVM.connectedBankDisplayName
            rootView.balanceFetchedAt = txVM.currentBalanceFetchedAt
        }
        // Ripple if unread new transactions, or always-on Ripple mode
        let rippleAlwaysOn = UserDefaults.standard.bool(forKey: "rippleAlwaysOn")
            && UserDefaults.standard.integer(forKey: "celebrationStyle") == 1
        let hasUnseenTx = latestTxSigBySlot.contains { slotId, sig in !sig.isEmpty && sig != lastSeenTxSig(for: slotId) }
        if rippleAlwaysOn || hasUnseenTx {
            rootView.rippleTrigger = max(1, flyoutRippleTrigger)
        }
        // Ensure transactions are loaded before computing the ring fraction.
        // Without this, the ring is empty on first flyout open (before panel is opened).
        if txVM.transactions.isEmpty {
            let days = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").fetchDays
            let daysToUse = days > 0 ? days : 60
            if demoMode {
                // Replay the same seed sequence as openTransactionsPanel so transactions are identical.
                if isMultiDemo {
                    var seed = UInt64(truncatingIfNeeded: demoSeed)
                    let slots = MultibankingStore.shared.slots
                    let activeIdx = MultibankingStore.shared.activeIndex
                    for (i, slot) in slots.enumerated() {
                        _ = FakeData.demoBalance(seed: &seed, slotProfile: i)
                        let slotTx = FakeData.generateDemoTransactions(seed: &seed, days: daysToUse, slotId: slot.id, slotProfile: i)
                        if i == activeIdx { txVM.transactions = slotTx }
                    }
                } else {
                    var seed = UInt64(truncatingIfNeeded: demoSeed)
                    _ = FakeData.demoBalance(seed: &seed)
                    txVM.transactions = FakeData.generateDemoTransactions(seed: &seed, days: daysToUse)
                }
            } else {
                if txVM.isUnifiedMode {
                    let allSlotIds = MultibankingStore.shared.slots.map { $0.id }
                    if let cached = try? TransactionsDatabase.loadUnifiedTransactions(slots: allSlotIds, days: daysToUse), !cached.isEmpty {
                        txVM.transactions = sortTransactionsNewestFirst(cached)
                    }
                } else if let cached = try? TransactionsDatabase.loadTransactions(days: daysToUse), !cached.isEmpty {
                    txVM.transactions = sortTransactionsNewestFirst(cached)
                }
            }
        }
        rootView.greenZoneFraction = computeGreenZoneFraction()
        rootView.dispoLimit = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").dispoLimit
        applyFlyoutDots(to: &rootView)
        let hasDots = MultibankingStore.shared.slots.count > 1 && (!demoMode || isMultiDemo)
        let host = NSHostingController(rootView: rootView)
        host.view.wantsLayer = true
        // Freeze-Mode: Blue Soft aus der Color Harmony Palette (theme-aware via dynamic NSColor).
        host.view.layer?.backgroundColor = FreezeState.shared.isActive
            ? NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                return AppTheme.color(from: isDark ? "#1F3144" : "#EAF1F8", fallback: .controlBackgroundColor)
            }.cgColor
            : NSColor.windowBackgroundColor.cgColor
        popover.contentSize = NSSize(width: 348, height: hasDots ? 192 : 170)
        popover.contentViewController = host
        balancePopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // If auto-hide is enabled, close the flyout after the same delay.
        // This handles the case where the balance is already hidden when the flyout opens
        // (the main auto-hide timer already fired and won't fire again for this cycle).
        let flyoutDelay: TimeInterval? = hideIndex == 1 ? 2 : hideIndex == 2 ? 5 : hideIndex == 3 ? 10 : hideIndex == 4 ? 20 : nil
        if let delay = flyoutDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.balancePopover?.isShown == true else { return }
                if self.isFlyoutHovered {
                    // Mouse is over the flyout — defer close until mouse leaves
                    self.deferFlyoutCloseUntilMouseLeaves()
                    return
                }
                self.balancePopover?.performClose(nil)
            }
        }
    }

    /// Polls until the mouse leaves the flyout, then closes it.
    private func deferFlyoutCloseUntilMouseLeaves() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.balancePopover?.isShown == true else { return }
            if self.isFlyoutHovered {
                self.deferFlyoutCloseUntilMouseLeaves()
            } else {
                self.balancePopover?.performClose(nil)
            }
        }
    }

    /// Updates the flyout card in-place after a slot switch, without closing/reopening.
    private func refreshFlyoutIfVisible() {
        guard let popover = balancePopover, popover.isShown,
              let host = popover.contentViewController as? NSHostingController<StatusBalanceFlyoutCardView>
        else { return }
        let store = MultibankingStore.shared
        let idx = store.activeIndex
        let count = store.slots.count
        let isUnified = txVM.isUnifiedMode && (!demoMode || isMultiDemo)
        let balanceText = isUnified
            ? (computeUnifiedFlyoutBalanceText() ?? "--,-- €")
            : (lastBalance.map(formatEURWithCents) ?? "--,-- €")
        let refreshSlotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        let refreshSlotCfg = BankSlotSettingsStore.load(slotId: refreshSlotId)
        let thresholds = BalanceSignal.normalizedThresholds(
            low: refreshSlotCfg.balanceSignalLowUpperBound,
            medium: refreshSlotCfg.balanceSignalMediumUpperBound
        )
        var rootView = StatusBalanceFlyoutCardView(
            balanceText: balanceText,
            balanceValue: lastBalance,
            thresholds: thresholds,
            isDefaultTheme: themeId == ThemeManager.defaultThemeID,
            forcedColorScheme: configuredColorScheme()
        )
        rootView.leftToPayAmount = txVM.leftToPayAmount
        let subMetricsSettings = BankSlotSettingsStore.load(
            slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy"
        )
        rootView.salaryDay = subMetricsSettings.effectiveSalaryDay
        rootView.salaryToleranceBefore = subMetricsSettings.salaryDayToleranceBefore
        rootView.salaryToleranceAfter = subMetricsSettings.salaryDayToleranceAfter
        rootView.onDoubleTap = { [weak self] in
            self?.balancePopover?.performClose(nil)
            Task { await self?.openTransactionsPanel() }
        }
        rootView.onHoverChanged = { [weak self] hovering in
            self?.isFlyoutHovered = hovering
        }
        if isUnified {
            rootView.unifiedSlots = computeFlyoutSlots()
            rootView.unifiedTotalBalance = computeUnifiedFlyoutTotal()
        } else {
            let refreshBrand = BankLogoAssets.resolve(displayName: txVM.connectedBankDisplayName,
                                                       logoID: connectedBankLogoID.isEmpty ? nil : connectedBankLogoID,
                                                       iban: nil)
            BankLogoStore.shared.preload(brand: refreshBrand)
            rootView.bankLogoImage = BankLogoStore.shared.image(for: refreshBrand)
            rootView.bankLogoBrandId = refreshBrand?.id
            rootView.currency = MultibankingStore.shared.activeSlot?.currency
            rootView.nickname = MultibankingStore.shared.activeSlot?.nickname
            rootView.bankName = txVM.connectedBankDisplayName
            rootView.balanceFetchedAt = txVM.currentBalanceFetchedAt
        }
        rootView.rippleTrigger = flyoutRippleTrigger
        rootView.greenZoneFraction = computeGreenZoneFraction()
        rootView.dispoLimit = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").dispoLimit
        applyFlyoutDots(to: &rootView)
        let hasDots = store.slots.count > 1 && (!demoMode || isMultiDemo)
        popover.contentSize = NSSize(width: 348, height: hasDots ? 192 : 170)
        host.rootView = rootView
    }

    /// Populates dot-indicator data on a flyout rootView.
    private func applyFlyoutDots(to rootView: inout StatusBalanceFlyoutCardView) {
        let store = MultibankingStore.shared
        guard store.slots.count > 1, (!demoMode || isMultiDemo) else { return }
        rootView.allSlots = computeFlyoutSlots()
        rootView.activeSlotIndex = store.activeIndex
        rootView.isUnifiedMode = txVM.isUnifiedMode
        rootView.onSwitchToIndex = { [weak self] i in
            guard let self else { return }
            self.txVM.unifiedModeEnabled = false
            Task { await self.switchToSlot(index: i) }
        }
        rootView.onActivateUnified = { [weak self] in
            guard let self else { return }
            self.txVM.unifiedModeEnabled = true
            self.refreshFlyoutIfVisible()
        }
    }

    @objc private func showTransactions() {
        Task { await openTransactionsPanel() }
    }

    private func refreshAsync() async {
        // Prevent concurrent HBCI calls — banks like Volksbank fail with "Fehlender Dialogkontext"
        // when two simultaneous requests hit the same HBCI connection.
        guard !isHBCICallInFlight else {
            AppLogger.log("refreshAsync: HBCI call already in flight, skipping", category: "Network", level: "WARN")
            // Schedule a retry for the currently active slot once the in-flight call finishes.
            // Without this, switching slots while another account is doing SCA silently drops
            // the new slot's refresh request — it never gets data until the timer fires again.
            let epochWhenQueued = slotEpoch
            Task {
                while isHBCICallInFlight {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }
                // Only retry if the slot hasn't changed again since we queued
                guard slotEpoch == epochWhenQueued else { return }
                await refreshAsync()
            }
            return
        }
        isHBCICallInFlight = true
        defer { isHBCICallInFlight = false }

        let epochAtStart = slotEpoch
        // Demo-Modus: Keine echten API-Calls
        if demoMode {
            if isMultiDemo {
                var seed = UInt64(truncatingIfNeeded: demoSeed)
                var total = 0.0
                for (i, slot) in MultibankingStore.shared.slots.enumerated() {
                    let b = FakeData.demoBalance(seed: &seed, slotProfile: i)
                    UserDefaults.standard.set(b, forKey: "simplebanking.cachedBalance.\(slot.id)")
                    total += b
                }
                // In unified mode show the aggregate; in per-slot mode show the active slot's balance.
                let displayBalance: Double
                if txVM.isUnifiedMode {
                    displayBalance = total
                } else if let slotId = MultibankingStore.shared.activeSlot?.id {
                    let slotBalance = UserDefaults.standard.double(forKey: "simplebanking.cachedBalance.\(slotId)")
                    displayBalance = slotBalance > 0 ? slotBalance : total
                } else {
                    displayBalance = total
                }
                lastBalance = displayBalance
                lastShownTitle = formatEURNoDecimals(String(format: "%.2f", displayBalance))
                txVM.currentBalance = formatEURWithCents(displayBalance)
                applyBalanceDisplayModeConstraints()
                updateStatusBalanceTitle()
                applyHideTimer()
                recomputeLeftToPay()
                return
            }
            var seed = UInt64(truncatingIfNeeded: demoSeed)
            let fake = FakeData.demoBalance(seed: &seed)
            lastShownTitle = formatEURNoDecimals(String(format: "%.2f", fake))
            lastBalance = fake
            applyBalanceDisplayModeConstraints()
            updateStatusBalanceTitle()
            statusItem.button?.toolTip = "🎭 Demo-Modus: Simulierter Kontostand"
            applyHideTimer()
            recomputeLeftToPay()
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
                // Wenn die Bank den Kontostand inkl. Dispokredit liefert (z.B. C24),
                // zieht die per-Slot-Einstellung `creditLimitIncluded` den Dispo ab,
                // bevor irgendetwas angezeigt / gecacht wird.
                let slotSettings = BankSlotSettingsStore.load(slotId: YaxiService.activeSlotId)
                let rawParsed = AmountParser.parse(booked.amount)
                let adjustedBalance = (slotSettings.creditLimitIncluded && slotSettings.dispoLimit > 0)
                    ? rawParsed - Double(slotSettings.dispoLimit)
                    : rawParsed
                let roundedNoDecimals = adjustedBalance.rounded()
                lastShownTitle = Self.eurWholeNumberFormatter.string(
                    from: NSNumber(value: roundedNoDecimals)
                ) ?? "0"
                self.lastBalance = adjustedBalance
                self.txVM.currentBalance = self.formatEURWithCents(self.lastBalance ?? 0)
                self.txVM.currentBalanceFetchedAt = Date()
                if !booked.currency.isEmpty {
                    if !demoMode {
                        MultibankingStore.shared.updateCurrency(booked.currency, forSlotId: YaxiService.activeSlotId)
                    }
                    self.txVM.connectedBankCurrency = booked.currency
                }
                // Cache per slot for instant display on next slot switch
                if let balance = self.lastBalance {
                    UserDefaults.standard.set(balance, forKey: "simplebanking.cachedBalance.\(YaxiService.activeSlotId)")
                }
                applyBalanceDisplayModeConstraints()
                updateStatusBalanceTitle()
                statusItem.button?.toolTip = t(
                    "Kontostand (Auto-Refresh: \(formatRefreshInterval(refreshInterval)))",
                    "Balance (auto-refresh: \(formatRefreshInterval(refreshInterval)))"
                )

                applyHideTimer()

                // Avoid implicit TAN prompts on startup/auto-refresh unless explicitly enabled.
                if loadTransactionsOnStart {
                    Task { await checkNewBookings(userId: userId, password: password) }
                }

                recomputeLeftToPay()
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
                recordCLIRefreshError("SCA-Freigabe erforderlich")
            } else {
                statusItem.button?.title = "— €"
                statusItem.button?.toolTip = resp.error ?? "Keine Daten"
                recordCLIRefreshError(resp.error ?? "Keine Daten")
            }
        } catch {
            statusItem.button?.title = "— €"
            statusItem.button?.toolTip = "Fehler: \(error.localizedDescription)"
            txVM.currentBalance = "— €"
            AppLogger.log("Balance refresh failed: \(error.localizedDescription)", category: "Network", level: "ERROR")
            recordCLIRefreshError(error.localizedDescription)
        }
    }

    private func openTransactionsPanel() async {
        let epochAtStart = slotEpoch
        txPanel?.show()
        let didTriggerInitialConfetti = triggerInitialConfettiIfNeeded()
        
        // Demo-Modus: Komplett synthetische Daten ohne API-Calls
        if demoMode {
            txVM.anthropicApiKey = nil
            let daysToFetch: Int = {
                let d = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").fetchDays
                return d > 0 ? d : 60
            }()
            txVM.fromDate = isoDateDaysAgo(daysToFetch)
            txVM.toDate = isoDateDaysAgo(0)

            if isMultiDemo {
                var seed = UInt64(truncatingIfNeeded: demoSeed)
                let demoSlots = MultibankingStore.shared.slots
                let activeIdx = MultibankingStore.shared.activeIndex
                var slotMap: [String: BankSlot] = [:]
                var allTx: [TransactionsResponse.Transaction] = []
                var total = 0.0

                // Always generate all slots so per-slot cached balances stay consistent.
                // Only keep the transactions relevant to the current view mode.
                for (i, slot) in demoSlots.enumerated() {
                    slotMap[slot.id] = slot
                    let b = FakeData.demoBalance(seed: &seed, slotProfile: i)
                    UserDefaults.standard.set(b, forKey: "simplebanking.cachedBalance.\(slot.id)")
                    total += b
                    let slotTx = FakeData.generateDemoTransactions(seed: &seed, days: daysToFetch, slotId: slot.id, slotProfile: i)
                    if txVM.isUnifiedMode {
                        allTx.append(contentsOf: slotTx)
                    } else if i == activeIdx {
                        allTx = slotTx  // per-slot view: show only the active account
                        // Update balance card to this slot's balance, not the total
                        let slotBalance = UserDefaults.standard.double(forKey: "simplebanking.cachedBalance.\(slot.id)")
                        txVM.currentBalance = formatEURWithCents(slotBalance)
                        lastBalance = slotBalance
                    }
                }
                if txVM.isUnifiedMode {
                    txVM.currentBalance = formatEURWithCents(total)
                    lastBalance = total
                }
                allTx.sort { ($0.bookingDate ?? "") > ($1.bookingDate ?? "") }
                txVM.slotMap = slotMap
                txVM.transactions = allTx
                txVM.resetPaging()
                txVM.isLoading = false
                return
            }

            // Single-Banking demo
            txVM.connectedBankDisplayName = "Demo-Bank"
            txVM.connectedBankLogoID = nil
            txVM.connectedBankIBAN = nil
            var seed = UInt64(truncatingIfNeeded: demoSeed)
            let fakeBalance = FakeData.demoBalance(seed: &seed)
            txVM.currentBalance = formatEURWithCents(fakeBalance)
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

        // Load from local DB immediately — panel shows instant data while network loads.
        // Opening the transactions panel counts as "seen" for new-booking indicator.
        let fetchDaysPreview = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").fetchDays
        let daysToPreview = fetchDaysPreview > 0 ? fetchDaysPreview : 60
        let activeSlotIdNow = TransactionsDatabase.activeSlotId
        if txVM.isUnifiedMode {
            let allSlotIds = MultibankingStore.shared.slots.map { $0.id }
            if let cached = try? TransactionsDatabase.loadUnifiedTransactions(slots: allSlotIds, days: daysToPreview), !cached.isEmpty {
                let slotMap = Dictionary(uniqueKeysWithValues: MultibankingStore.shared.slots.map { ($0.id, $0) })
                txVM.slotMap = slotMap
                txVM.transactions = sortTransactionsNewestFirst(cached)
                txVM.resetPaging()
                let ownIBANs = Set(MultibankingStore.shared.slots.compactMap { $0.iban }.filter { !$0.isEmpty })
                txVM.detectInternalTransfers(ownIBANs: ownIBANs)
            }
            // Mark all slots as seen when opening unified view
            for (slotId, sig) in latestTxSigBySlot where !sig.isEmpty {
                setLastSeenTxSig(sig, for: slotId)
            }
        } else {
            if let cached = try? TransactionsDatabase.loadTransactions(days: daysToPreview), !cached.isEmpty {
                txVM.transactions = sortTransactionsNewestFirst(cached)
                txVM.resetPaging()
            }
            if let sig = latestTxSigBySlot[activeSlotIdNow], !sig.isEmpty {
                setLastSeenTxSig(sig, for: activeSlotIdNow)
            }
        }
        updateStatusBalanceTitle()

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
        txVM.errorNeedsReconnect = false

        let fetchDaysSetting = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").fetchDays
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
                if !txVM.isUnifiedMode {
                    txVM.transactions = sortTransactionsNewestFirst(cachedTransactions)
                    txVM.resetPaging()
                }
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
                    // Reload enrichment so newly inserted rows (is_unread=1) show
                    // the blue unread dot immediately, not after the next onAppear.
                    txVM.loadEnrichmentData(bankId: demoMode ? "demo" : "primary")
                } catch {
                    print("[DB] Upsert/load failed, using network data: \(error.localizedDescription)")
                    txVM.transactions = sortedNetwork
                }
                txVM.resetPaging()
                confettiTransactions = txVM.transactions
            } else {
                if cachedTransactions.isEmpty {
                    txVM.transactions = []
                    txVM.error = resp.userMessage ?? resp.error ?? t("Keine Umsatzdaten verfügbar.", "No transaction data available.")
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
                let msg = Self.yaxiUserMessage(error) ?? "Fetch failed: \(error.localizedDescription)"
                txVM.error = msg
                txVM.errorNeedsReconnect = Self.isCanceledError(error)
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
        let unifiedForCategorization = txVM.isUnifiedMode
        let slotIdsForCategorization = MultibankingStore.shared.slots.map { $0.id }
        Task.detached {
            await AICategorizationService.runIfEnabled(masterPassword: pwForCategorization)
            guard await self.slotEpoch == epochForCategorization else { return }
            if unifiedForCategorization {
                if let updated = try? TransactionsDatabase.loadUnifiedTransactions(slots: slotIdsForCategorization, days: daysForCategorization), !updated.isEmpty {
                    await MainActor.run {
                        guard self.slotEpoch == epochForCategorization else { return }
                        self.txVM.transactions = self.sortTransactionsNewestFirst(updated)
                    }
                }
            } else {
                if let updated = try? TransactionsDatabase.loadTransactions(days: daysForCategorization), !updated.isEmpty {
                    await MainActor.run {
                        guard self.slotEpoch == epochForCategorization else { return }
                        self.txVM.transactions = self.sortTransactionsNewestFirst(updated)
                    }
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
        let slotId = TransactionsDatabase.activeSlotId
        // Slot-Epoch beim Start festhalten — wenn der User mid-fetch den Slot
        // wechselt, dürfen wir die Antwort nicht auf den neuen Slot anwenden
        // (sonst falsche Notification, falscher Ripple, falscher Unread-Indikator).
        // Gleicher Pattern wie in refreshAsync und openTransactionsPanel.
        let epochAtStart = slotEpoch
        do {
            let resp = try await YaxiService.fetchTransactions(userId: userId, password: password, from: from)
            // Bail wenn Slot mid-await gewechselt hat — Ergebnis gehört zum alten Slot.
            guard slotEpoch == epochAtStart else { return }
            guard (resp.ok ?? false), let tx = resp.transactions, !tx.isEmpty else { return }
            let sorted = tx.sorted { ($0.bookingDate ?? $0.valueDate ?? "") > ($1.bookingDate ?? $1.valueDate ?? "") }
            let sig = computeTxSignature(sorted[0])

            // Check if this is a new transaction (compare against per-slot seen key)
            let seenSig = lastSeenTxSig(for: slotId)
            let prevLatest = latestTxSigBySlot[slotId] ?? ""
            let isNew = !seenSig.isEmpty && sig != seenSig && sig != prevLatest
            latestTxSigBySlot[slotId] = sig

            // Update title with dot if needed.
            updateStatusBalanceTitle()

            // Ripple on flyout if open
            if isNew {
                flyoutRippleTrigger += 1
                refreshFlyoutIfVisible()
            }

            // Send notification for new bookings (dedup: only once across all slots in unified mode)
            if isNew && showNotifications {
                let newest = sorted[0]
                sendNewBookingNotification(transaction: newest)
            }
        } catch {
            // Silent in UI (das ist ein Hintergrund-Poll), aber wenn wir gerade
            // im CLI-Pfad sind, soll `sb refresh` den Fehler ehrlich sehen.
            recordCLIRefreshError(error.localizedDescription)
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
        // Cancel any in-flight switch so only the last click wins
        switchTask?.cancel()
        let task = Task { [weak self] in
            await self?.doSwitchToSlot(index: index) ?? ()
        }
        switchTask = task
        await task.value
    }

    private func doSwitchToSlot(index: Int) async {
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

        guard !Task.isCancelled else { return }

        // Wait for any in-flight HBCI call to finish before refreshing for the new slot.
        // The old call was epoch-invalidated above and will return soon.
        while isHBCICallInFlight {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            guard !Task.isCancelled else { return }
        }

        guard !Task.isCancelled else { return }

        // Fetch live balance
        await refreshAsync()

        guard !Task.isCancelled else { return }

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
            // Multi-demo: Dot-Navigation zwischen Demo-Slots erlauben
            if isMultiDemo {
                let count = MultibankingStore.shared.slots.count
                nav.onSwitchToIndex = count > 1
                    ? { [weak self] i in Task { await self?.switchToSlot(index: i) } } : nil
            } else {
                nav.onSwitchToIndex = nil
            }
            return
        }
        let store = MultibankingStore.shared
        let idx   = store.activeIndex
        let count = store.slots.count
        nav.onPrevAccount = nil
        nav.onNextAccount = count > 1
            ? { [weak self] in Task { await self?.switchToSlot(index: (idx + 1) % count) } } : nil
        nav.onAddAccount  = nil
        nav.onSwitchToIndex = count > 1
            ? { [weak self] i in Task { await self?.switchToSlot(index: i) } } : nil
        nav.prevAccountLogo = nil
        nav.nextAccountLogo = nil
        nav.prevAccountBrandId = nil
        nav.nextAccountBrandId = nil
        nav.prevAccountCurrency = nil
        nav.nextAccountCurrency = nil
        nav.prevAccountNickname = nil
        nav.nextAccountNickname = nil
        if count > 1 {
            let nextSlot = store.slots[(idx + 1) % count]
            let brand = BankLogoAssets.resolve(displayName: nextSlot.displayName, logoID: nextSlot.logoId, iban: nextSlot.iban)
            BankLogoStore.shared.preload(brand: brand)
            nav.nextAccountLogo = BankLogoStore.shared.image(for: brand)
            nav.nextAccountBrandId = brand?.id
            nav.nextAccountCurrency = nextSlot.currency
            nav.nextAccountNickname = nextSlot.nickname
        }
    }

    /// Pushes the current slot's resolved logo image directly into txVM so the
    /// balance card in the transaction panel updates imperatively (not via @ObservedObject timing).
    @MainActor private func updateTxPanelLogoImage() {
        guard !demoMode else { return }
        let brand = BankLogoAssets.resolve(
            displayName: txVM.connectedBankDisplayName,
            logoID: txVM.connectedBankLogoID,
            iban: txVM.connectedBankIBAN
        )
        if let img = BankLogoStore.shared.image(for: brand) {
            txVM.connectedBankLogoImage = img
        }
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
                    options: options,
                    slotId: YaxiService.activeSlotId,
                    connectionIdKeySnapshot: YaxiService.connectionIdKey
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
                logoId: bank.logoId,
                nickname: wizard.collectedNickname
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
                options: options,
                slotId: YaxiService.activeSlotId,
                connectionIdKeySnapshot: YaxiService.connectionIdKey
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
                let legacySlot = BankSlot(id: "legacy", iban: normalizedIBAN, displayName: bank.displayName, logoId: bank.logoId, nickname: wizard.collectedNickname)
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
            self.setDemoSingle()
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
        formatter.timeZone = TimeZone.current
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
        options: SetupConnectOptions,
        slotId: String = "legacy",
        connectionIdKeySnapshot: String = "simplebanking.yaxi.connectionId"
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

            let warmupFetchSetting = BankSlotSettingsStore.load(slotId: slotId).fetchDays
            let warmupDays = warmupFetchSetting > 0 ? warmupFetchSetting : 60
            let warmupFrom = setupWarmupFromDate(days: warmupDays)

            // Build finalBank from pre-discovered connectionId + selected bank name
            let storedConnectionId = UserDefaults.standard.string(forKey: connectionIdKeySnapshot) ?? ""
            let finalBank = DiscoveredBank(
                id: storedConnectionId,
                displayName: fallbackName.isEmpty ? "Bank" : fallbackName,
                logoId: nil,
                credentials: YaxiService.loadStoredCredentials(slotId: slotId),
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

    @objc private func reconnectBank() {
        let alert = NSAlert()
        alert.messageText = t("Bank neu verbinden?", "Reconnect bank?")
        alert.informativeText = t(
            "Die Verbindung zur Bank wird zurückgesetzt. Beim nächsten Abruf musst Du Dich erneut mit TAN/PIN identifizieren. Kontodaten, IBAN und Einstellungen bleiben erhalten.",
            "The connection to the bank will be reset. You'll need to re-authenticate with TAN/PIN on the next refresh. Account data, IBAN, and settings will be preserved."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("Neu verbinden", "Reconnect"))
        alert.addButton(withTitle: t("Abbrechen", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let slotId = YaxiService.activeSlotId
        Task { @MainActor [weak self] in
            await YaxiService.sessionStore.clearAll(slotId: slotId)
            AppLogger.log("reconnectBank: cleared sessions + connectionData for slot \(slotId.prefix(8))", category: "Support")
            self?.refresh()
        }
    }
    
    @objc private func showSettings() {
        settingsPanel?.show()
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updateChecker?.checkForUpdates()
    }

    private func setupGlobalHotkey() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "globalHotkeyEnabled") as? Bool ?? true
        let rawKeyCode = defaults.integer(forKey: "globalHotkeyKeyCode")
        let keyCode = rawKeyCode > 0 ? rawKeyCode : 1
        let rawModifiers = defaults.integer(forKey: "globalHotkeyModifiers")
        let modifiers = rawModifiers > 0 ? rawModifiers : 4352

        if enabled {
            GlobalHotkeyManager.shared.register(keyCode: keyCode, carbonModifiers: modifiers)
            GlobalHotkeyManager.shared.onTriggered = { @Sendable [weak self] in
                // Hotkey always opens the flyout regardless of the configured click mode
                // (mouseOver-mode would otherwise be a no-op for the hotkey).
                MainActor.assumeIsolated { self?.showBalanceFlyout() }
            }
        } else {
            GlobalHotkeyManager.shared.unregister()
        }
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

private struct FlyoutSlotItem {
    var logo: NSImage?
    var brandId: String?
    var balanceText: String
    var isNegative: Bool
    var barColor: Color
    var nickname: String?
}

/// Liquid-glass backdrop — blurs the desktop behind the popover (behindWindow).
private struct FlyoutVibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

private struct StatusBalanceFlyoutCardView: View {
    let balanceText: String
    let balanceValue: Double?
    let thresholds: BalanceSignalThresholds
    let isDefaultTheme: Bool
    let forcedColorScheme: ColorScheme?
    var bankLogoImage: NSImage? = nil
    var bankLogoBrandId: String? = nil
    var balanceFetchedAt: Date? = nil
    var onDoubleTap: (() -> Void)? = nil
    var onHoverChanged: ((Bool) -> Void)? = nil
    var currency: String? = nil
    var nickname: String? = nil
    var bankName: String? = nil
    var rippleTrigger: Int = 0
    var unifiedSlots: [FlyoutSlotItem]? = nil
    var unifiedTotalBalance: Double? = nil
    var greenZoneFraction: Double = 0     // 0...1, balance / referenceIncome ("Bin ich im grünen Bereich?")
    var dispoLimit: Int = 0               // overdraft limit in € for dispo-mode ring
    @AppStorage("greenZoneRingEnabled") private var greenZoneRingEnabled: Bool = true
    @AppStorage("greenZoneShowDispo") private var greenZoneShowDispo: Bool = true
    @ObservedObject private var freezeState = FreezeState.shared
    // Dot indicators — all slots regardless of mode
    var allSlots: [FlyoutSlotItem]? = nil
    var activeSlotIndex: Int = 0
    var isUnifiedMode: Bool = false
    var onSwitchToIndex: ((Int) -> Void)? = nil
    var onActivateUnified: (() -> Void)? = nil
    var leftToPayAmount: Double? = nil
    var salaryDay: Int = 1                 // effective salary day for sub-metrics
    var salaryToleranceBefore: Int = 0     // darf N Tage früher kommen (z.B. 4)
    var salaryToleranceAfter: Int = 0      // darf N Tage später kommen (z.B. 1)

    @Environment(\.colorScheme) private var environmentColorScheme

    private var activeColorScheme: ColorScheme {
        forcedColorScheme ?? environmentColorScheme
    }

    private var hasDots: Bool { (allSlots?.count ?? 0) > 1 }

    private static let freezeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    private func freezeBalanceText(_ value: Double) -> String {
        Self.freezeFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value)) €"
    }

    private static let leftToPayFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    private func leftToPayLabel(_ amount: Double) -> String {
        let formatted = Self.leftToPayFormatter.string(from: NSNumber(value: amount))
            ?? "\(Int(amount)) €"
        return L10n.t("Noch offen: \(formatted)", "Still to pay: \(formatted)")
    }

    @AppStorage("balanceSubtitleStyle.flyout") private var flyoutSubtitleStyle: Int = 0

    @ViewBuilder
    private var leftToPaySubtitle: some View {
        // Unified-Mode: leftToPay ist pro-Slot aggregiert → Sub-Metrics würden gegen
        // einen einzelnen Gehaltstag rechnen und wären fachlich inkonsistent.
        BalanceSubtitleSwitch(
            balance: balanceValue,
            leftToPayAmount: leftToPayAmount,
            salaryDay: salaryDay,
            salaryToleranceBefore: salaryToleranceBefore,
            salaryToleranceAfter: salaryToleranceAfter,
            style: $flyoutSubtitleStyle,
            forceClassic: isUnifiedMode
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if unifiedSlots != nil {
                    unifiedCard
                } else if isDefaultTheme {
                    defaultThemeCard
                } else {
                    legacyCard
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, hasDots ? 2 : 14)
            .onTapGesture(count: 2) { onDoubleTap?() }
            // Ripple only on the balance card, not the dot row
            .rippleEffect(trigger: rippleTrigger, defaultOrigin: CGPoint(x: 310, y: 130))

            // Account dot indicators
            if hasDots, let slots = allSlots {
                HStack(spacing: 8) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { idx, item in
                        let isActive = !isUnifiedMode && idx == activeSlotIndex
                        Button {
                            guard !isActive else { return }
                            onSwitchToIndex?(idx)
                        } label: {
                            Capsule()
                                .fill(isActive ? item.barColor : Color(NSColor.tertiaryLabelColor))
                                .frame(width: isActive ? 24 : 8, height: 8)
                                .animation(.easeInOut(duration: 0.3), value: isActive)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // "Alle Konten" dot → shows unified aggregated view in flyout
                    let unifiedActive = isUnifiedMode
                    Button {
                        guard !unifiedActive else { return }
                        onActivateUnified?()
                    } label: {
                        Capsule()
                            .fill(unifiedActive ? Color(NSColor.secondaryLabelColor) : Color(NSColor.tertiaryLabelColor))
                            .frame(width: unifiedActive ? 24 : 8, height: 8)
                            .animation(.easeInOut(duration: 0.3), value: unifiedActive)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 348, height: hasDots ? 192 : 170)
        .background(freezeState.isActive ? Color.freezePanelBackground : Color.panelBackground)
        .preferredColorScheme(forcedColorScheme)
        .onHover { hovering in onHoverChanged?(hovering) }
    }

    /// Renders the header line in the flyout, replacing the old "Kontostand …" timestamp.
    /// Format: "{displayName} · {hour} Uhr" (DE) / "{displayName} · {hour}:00" (EN).
    /// - `displayName` = nickname if set, otherwise `bankName`.
    /// - If no fetch timestamp is available, only the name is shown.
    private func formatBankHeader(date: Date?) -> String {
        let name: String = {
            if let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty {
                return nick
            }
            if let bn = bankName?.trimmingCharacters(in: .whitespacesAndNewlines), !bn.isEmpty {
                return bn
            }
            return L10n.t("Kontostand", "Balance")
        }()
        guard let date else { return name }
        let hour = Calendar.current.component(.hour, from: date)
        return L10n.t("\(name) · \(hour) Uhr", "\(name) · \(hour):00")
    }

    private var unifiedCard: some View {
        let slots = unifiedSlots ?? []
        let glassColor = activeColorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.50)
        let borderColor = activeColorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.40)

        // Determine unified header: "Alle Konten · 8 Uhr" (mirrors bank name + time in defaultThemeCard)
        let headerText: String = {
            if let date = balanceFetchedAt {
                let hour = Calendar.current.component(.hour, from: date)
                return L10n.t("Alle Konten · \(hour) Uhr", "All Accounts · \(hour):00")
            }
            return L10n.t("Alle Konten", "All Accounts")
        }()

        return VStack(alignment: .leading, spacing: 8) {
            // Header row — mirrors defaultThemeCard: icon + text + Spacer
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                Text(headerText)
                    .font(.system(size: 14))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                Spacer()
            }

            // Balance row — same HStack structure as defaultThemeCard
            // Right side: mini account bar stack replaces GreenZoneRing (same 72pt height)
            HStack(alignment: .balanceTextCenter, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(balanceText)
                        .font(.system(size: 30, weight: .bold, design: .default))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .alignmentGuide(.balanceTextCenter) { d in d.height / 2 }
                    leftToPaySubtitle
                }
                Spacer()
                // Mini account bars — same 72pt height as GreenZoneRing
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(Array(slots.prefix(4).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 5) {
                            if let img = item.logo {
                                let invert = activeColorScheme == .dark && BankLogoAssets.isDark(brandId: item.brandId ?? "")
                                Group {
                                    if invert {
                                        Image(nsImage: img).resizable().scaledToFit()
                                            .frame(width: 14, height: 14)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                            .colorInvert()
                                    } else {
                                        Image(nsImage: img).resizable().scaledToFit()
                                            .frame(width: 14, height: 14)
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                }
                            } else {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(item.barColor.opacity(0.40))
                                    .frame(width: 14, height: 14)
                            }
                            Text(item.balanceText)
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundColor(item.isNegative ? Color(hex: "C4614D") : Color(NSColor.secondaryLabelColor))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(width: 72, height: 72, alignment: .center)
                .alignmentGuide(.balanceTextCenter) { d in d.height / 2 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(glassColor)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.primary.opacity(0.10), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var defaultThemeCard: some View {
        let level = BalanceSignal.classify(balance: balanceValue, thresholds: thresholds)
        let style = BalanceSignal.style(for: level)
        let displayBalance = balanceValue == nil ? "--,-- €" : balanceText
        let glassColor = activeColorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.50)
        let borderColor = activeColorScheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.40)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let img = bankLogoImage {
                    let invertActive = activeColorScheme == .dark && BankLogoAssets.isDark(brandId: bankLogoBrandId ?? "")
                    if invertActive {
                        Image(nsImage: img)
                            .resizable().scaledToFit()
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .colorInvert()
                    } else {
                        Image(nsImage: img)
                            .resizable().scaledToFit()
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                } else {
                    Image(systemName: "wallet.pass")
                        .font(.system(size: 16))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                if freezeState.isActive {
                    Text(L10n.t("fiktiver Kontostand", "fictional balance"))
                        .font(.system(size: 14))
                        .foregroundColor(.cyan.opacity(0.8))
                } else {
                    Text(formatBankHeader(date: balanceFetchedAt))
                        .font(.system(size: 14))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Spacer()
            }

            HStack(alignment: .balanceTextCenter, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // Real balance is always the primary 30pt number. Freeze projection
                    // moves to a subtitle below — a what-if should not look like the truth.
                    Text(displayBalance)
                        .font(.system(size: 30, weight: .bold, design: .default))
                        .foregroundColor(style.amountColor)
                        .alignmentGuide(.balanceTextCenter) { d in d.height / 2 }

                    if freezeState.isActive && freezeState.monthlyAmount > 0 {
                        let freezeBalance = (balanceValue ?? 0) + freezeState.monthlyAmount
                        Text(L10n.t(
                            "~\(freezeBalanceText(freezeBalance)) wenn nichts abgeht",
                            "~\(freezeBalanceText(freezeBalance)) if nothing is charged"
                        ))
                        .font(.system(size: 14))
                        .foregroundColor(.cyan.opacity(0.9))
                        .lineLimit(1)
                    } else {
                        leftToPaySubtitle
                    }
                }
                Spacer()
                if greenZoneRingEnabled {
                    // GreenRing always reflects the real balance — the freeze projection
                    // is side-information, not a new truth about your position.
                    GreenZoneRing(fraction: greenZoneFraction, balance: balanceValue, dispoLimit: dispoLimit, showDispo: greenZoneShowDispo)
                        .alignmentGuide(.balanceTextCenter) { d in d.height / 2 }
                }
            }
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
                            colors: [freezeState.isActive
                                ? Color.cyan.opacity(0.12)
                                : style.gradientBaseColor.opacity(0.10), .clear],
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
        let balColor: Color = (balanceValue ?? 0) < 0 ? .expenseRed : ((balanceValue ?? 0) > 0 ? .incomeGreen : .primary)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "creditcard")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                Text(formatBankHeader(date: balanceFetchedAt))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .center, spacing: 12) {
                Text(displayBalance)
                    .font(.system(size: 30, weight: .bold, design: .default))
                    .foregroundColor(balColor)
                Spacer()
                if greenZoneRingEnabled {
                    GreenZoneRing(fraction: greenZoneFraction, balance: balanceValue, dispoLimit: dispoLimit, showDispo: greenZoneShowDispo)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground)
        )
    }
}

