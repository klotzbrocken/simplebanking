import AppKit
import Combine
import Foundation
import Routex
import SwiftUI
import UserNotifications
import ServiceManagement

extension Notification.Name {
    static let slotSettingsChanged = Notification.Name("simplebanking.slotSettingsChanged")
    static let creditLimitToggleChanged = Notification.Name("simplebanking.creditLimitToggleChanged")
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
        
        // App Logo — robust loader mit Fallback-Chain (siehe AppIconLoader).
        if let logoImage = AppIconLoader.load() {
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

/// Randloses Fenster für das aus dem Flyout gezogene Desktop-Widget. Borderless
/// Fenster sind per Default `canBecomeKey == false` → die Quick-Send-Textfelder
/// bekämen keinen Tastaturfokus; deshalb hier überschrieben. Rechtsklick öffnet
/// das Kontextmenü (Vordergrund-Toggle + Schließen).
final class FlyoutWidgetWindow: NSWindow {
    /// Liefert das Kontextmenü beim Rechtsklick (vom AppDelegate gesetzt).
    var contextMenuProvider: (() -> NSMenu)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider?(), let view = contentView {
            let point = view.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil, at: point, in: view)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// Container der Widget-Karte: erkennt Hover (Maus über dem Fenster), um die
/// Steuer-Icons ein-/auszublenden und den Ruhe-Blur zu schalten.
final class FlyoutWidgetContainerView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTrackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        hoverTrackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    @AppStorage("demoMode") private var demoMode: Bool = false
    @AppStorage("demoStyle") private var demoStyle: Int = 0   // 0 = single, 1 = multi, 2 = REWE eBon
    private var isReweDemo: Bool { demoMode && demoStyle == 2 }
    @AppStorage("demoSeed") private var demoSeed: Int = 123456
    @AppStorage("simplesendVisible") private var simplesendVisible: Bool = true
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
    // Menüleiste-Breite ist seit v1.5.0 fest auf "lang"; kein User-Setting mehr.
    // Konstante bleibt damit die `isShort = menubarStyle == 1` Auswertung
    // korrekt zu false reduziert (Compiler optimiert das raus).
    private let menubarStyle: Int = 0
    @AppStorage("balanceMoodEmojiEnabled") private var balanceMoodEmojiEnabled: Bool = false
    @AppStorage("refreshInterval") private var refreshInterval: Int = 240
    @AppStorage("showNotifications") private var showNotifications: Bool = true
    @AppStorage("loadTransactionsOnStart") private var loadTransactionsOnStart: Bool = false
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    /// Mausklick-Tausch wurde in v1.5.0 entfernt — Click-Verhalten ist
    /// fest: Single = Balance-Action, Double = Umsatzliste. Die Konstante
    /// bleibt nur, damit die ehemaligen Branches sich trivial auf die
    /// Default-Pfade reduzieren (Compiler optimiert das raus).
    private let swapClickBehavior: Bool = false
    @AppStorage("showBalanceInMenuBar") private var showBalanceInMenuBar: Bool = false
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

    /// Slots, deren gespeicherte Zugangsdaten die Bank zuletzt abgelehnt hat.
    ///
    /// Solange ein Slot hier steht, läuft für ihn KEIN automatischer Abruf mehr.
    /// Ohne diese Bremse probiert der Refresh-Timer nach einem Passwortwechsel bei
    /// der Bank alle paar Minuten dieselbe falsche PIN — nach drei Fehlversuchen
    /// sperrt die Bank den Online-Zugang. Genau so ist ein Kunde in die Sperre
    /// gelaufen. Aufgehoben wird der Stopp nur durch neue Zugangsdaten
    /// (`changeBankCredentials`) oder einen bewussten manuellen Abruf.
    private var credentialsRejectedSlotIds: Set<String> = []

    /// Incremented on every slot switch. Async tasks capture this at start and bail if it changed.
    private var slotEpoch: Int = 0
    /// Cancellable task for the current slot switch — ensures only the last click wins.
    private var switchTask: Task<Void, Never>?
    private var isHBCICallInFlight: Bool = false    // guard against concurrent HBCI calls (balance + transactions)
    private var isPayPalCallInFlight: Bool = false  // PayPal-Provider (kein HBCI-Mutex nötig)
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

    /// Legacy-Konstante: BalanceClickMode war früher ein 3-Wege-Picker.
    /// In v1.5.0 reduziert auf zwei Modi (showBalanceInMenuBar Bool).
    /// Der Wert wird nirgendwo mehr ausgewertet, bleibt nur als Konstante
    /// für ehemalige Switch-Pfade die compiler-statisch wegfallen.
    private var activeBalanceClickMode: BalanceClickMode { .flyoutCard }

    private var isMouseOverBalanceMode: Bool { false }

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
        // Demo nutzt dieselbe Logo-Auflösung wie der Normalbetrieb (die Demo-Bank
        // setzt connectedBankLogoID via applySlotToViewModel) → echtes Bank-Icon
        // statt generischem wallet.pass. Fallback (wallet.pass) nur, wenn nichts
        // auflösbar ist.
        if demoMode && connectedBankLogoID.isEmpty
            && !(MultibankingStore.shared.activeSlot?.isReceiptSlot == true)
            && !(MultibankingStore.shared.activeSlot?.isPayPal == true) {
            let img = NSImage(systemSymbolName: "wallet.pass", accessibilityDescription: "Demo")
            img?.isTemplate = true
            return img
        }
        // PayPal + eBon-Slots (REWE/dm/Amazon): MONOCHROMES Template-Logo für die
        // Menüleiste (isTemplate → passt sich Hell/Dunkel an). Farbig bleibt es nur
        // im Flyout/Umsatzliste. Fallback (cart.fill), damit das Status-Item nie
        // null-breit wird.
        if let active = MultibankingStore.shared.activeSlot,
           let source = active.source, active.isReceiptSlot || active.isPayPal {
            if let tpl = MenuBarLogoAssets.forSource(source) {
                return tpl
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let img = NSImage(systemSymbolName: "cart.fill", accessibilityDescription: active.displayName)?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            return img
        }
        // Kein `guard` auf die logoID: `resolve` findet die Marke auch über den
        // Anzeigenamen, und frisch eingerichtete Slots tragen noch keine logoId (sie
        // wird erst nachträglich geheilt). Der frühere Abbruch ließ die Menüleiste
        // deshalb auf den €-Platzhalter fallen, während der Flyout dieselbe Bank
        // längst mit Logo zeigte — dieselben Argumente wie dort, damit auch dasselbe
        // Logo herauskommt.
        let brand = BankLogoAssets.resolve(
            displayName: connectedBankDisplayName,
            logoID: connectedBankLogoID.isEmpty ? nil : connectedBankLogoID,
            iban: nil
        )

        // Bevorzugt die einfarbige Mask-Variante für die Menüleiste. Logos mit
        // eigenem, deckendem Hintergrund (z. B. comdirect: dunkles Quadrat +
        // gelbes „C") werden unter `isTemplate = true` sonst zu einem massiven
        // Block, weil macOS bei Template-Bildern nur den Alpha-Kanal auswertet
        // und die voll deckende Karte komplett einfärbt. Die Mask ist
        // hintergrundlos und rendert als sauberes, hell/dunkel-adaptives Symbol.
        if let brandId = brand?.id,
           BankLogoCache.hasMask(forLogoId: brandId),
           let maskURL = BankLogoCache.url(forLogoId: brandId, mask: true),
           let maskImg = NSImage(contentsOf: maskURL) {
            let sized = maskImg.trimmedToInk(fittingHeight: 16, maxWidth: 32)
            sized.isTemplate = true
            return sized
        }

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
        let store = MultibankingStore.shared
        let slots = store.slots
        guard store.realSlotCount > 1 else { return nil }
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
            let brand = BankLogoAssets.resolve(displayName: slot.displayName, logoID: slot.logoId, iban: slot.isReceiptSlot ? nil : slot.iban)
            BankLogoStore.shared.preload(brand: brand)
            // Händler-/PayPal-Slots: das Marken-Logo direkt nutzen — wird NICHT über
            // BankLogoAssets aufgelöst.
            let logo = slot.brandLogoImage ?? BankLogoStore.shared.image(for: brand)
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
            } else if slot.isReceiptSlot || slot.isPayPal, let c = Color(hex: MerchantWash.brandHex(for: slot.source ?? .rewe)) {
                barColor = c   // Marken-Farbe (REWE/Amazon/dm/PayPal) für den Pillen-Streifen
            } else if let logoId = slot.logoId,
                      let hex = BankLogoAssets.primaryColor(forLogoId: logoId),
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
                nickname: slot.nickname,
                name: slot.displayName
            )
        }
    }

    /// Computes the unified total balance (Double) for the flyout card.
    private func computeUnifiedFlyoutTotal() -> Double? {
        guard txVM.isUnifiedMode else { return nil }
        let store = MultibankingStore.shared
        guard store.realSlotCount > 1 else { return nil }
        let slots = store.slots
        var total = 0.0
        var hasAny = false
        for slot in slots where !slot.isReceiptSlot {
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

        // v1.5.0: `showBalanceInMenuBar` steuert die Breite und den Title:
        //   true  → fest-breite Variante mit voller Saldo-Anzeige
        //   false → variable Breite, nur Icon (+ optional Mood-Emoji)
        // Direkt aus UserDefaults lesen statt aus dem @AppStorage-Wrapper —
        // letzterer kann in NSObject-Klassen außerhalb von SwiftUI veraltete
        // Werte zurückgeben.
        // v1.5.0 — 2 Modi:
        //   showBalanceInMenuBar = true  → feste Breite, voller Saldo-Text
        //   showBalanceInMenuBar = false → variable Breite, nur Icon (+Emoji)
        // Direkt aus UserDefaults lesen (AppStorage in NSObject-Klassen kann
        // veraltete Werte liefern).
        let showBalanceLive = UserDefaults.standard.object(forKey: "showBalanceInMenuBar") as? Bool ?? false
        let isShort = !showBalanceLive
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
            statusItem.length = isShort ? NSStatusItem.variableLength : menubarFixedWidth(logo: logo)
            return
        }

        // Hidden balance — Stimmungs-Emoji bleibt sichtbar wenn aktiviert,
        // sodass User auch ohne Saldotext sehen wie es ums Konto steht.
        if isHiddenBalance && !isHoverRevealingBalance {
            let hiddenEmoji = balanceMoodEmojiEnabled && computeUnifiedBalanceTitle() == nil
                ? currentMoodEmojiPrefix()
                : ""
            if isShort {
                // Short: logo + (optional) emoji, kein Mask-Text
                setButtonTitle(button, logo != nil ? hiddenEmoji : "\(hiddenEmoji)€")
            } else {
                // Long: logo + (optional) emoji + Mask
                setButtonTitle(button, "\(p)\(hiddenEmoji)•••.•• ")
            }
            statusItem.length = isShort ? NSStatusItem.variableLength : menubarFixedWidth(logo: logo)
            return
        }

        // Normal balance (unified sum when in unified mode).
        // Optional Money-Mood-Emoji als Präfix bei Single-Slot-Anzeige; im Unified-
        // Mode ist die Stimmung mehrdeutig (verschiedene Salden), daher kein Emoji.
        let moodEmoji = (balanceMoodEmojiEnabled && computeUnifiedBalanceTitle() == nil)
            ? currentMoodEmojiPrefix()
            : ""
        if isShort {
            // Flyout-Mode: kein Saldo-Text, nur Bank-Icon (+ optional Emoji).
            // Ohne Logo braucht es dasselbe „€" wie im ausgeblendeten Zweig, sonst
            // bleibt das Status-Item vollständig leer — sichtbar wurde das beim
            // Mouse-Over, das aus dem ausgeblendeten Zweig hierher wechselt und den
            // Platzhalter dabei verschwinden ließ.
            setButtonTitle(button, logo != nil ? moodEmoji : "\(moodEmoji)€")
        } else if let unifiedTitle = computeUnifiedBalanceTitle() {
            let indicator = latestTxSigBySlot.contains { id, sig in !sig.isEmpty && sig != lastSeenTxSig(for: id) } ? "  ●" : ""
            setButtonTitle(button, "\(unifiedTitle)\(indicator)")
        } else {
            setButtonTitle(button, "\(p)\(moodEmoji)\(decoratedTitle(lastShownTitle))")
        }
        statusItem.length = isShort ? NSStatusItem.variableLength : menubarFixedWidth(logo: logo)
    }

    /// Liefert das Money-Mood-Emoji für den aktuellen Saldo des aktiven Slots, gefolgt
    /// von einem schmalen Leerzeichen. Leer wenn kein Saldo bekannt oder Toggle aus.
    /// `forceEnabled=true` umgeht den `@AppStorage`-Cache und liest direkt aus
    /// UserDefaults — wichtig in `updateMenuBarButton` wo der Wrapper-Wert
    /// veraltet sein kann.
    private func currentMoodEmojiPrefix(forceEnabled: Bool = false) -> String {
        let enabled = forceEnabled
            || UserDefaults.standard.bool(forKey: "balanceMoodEmojiEnabled")
        guard enabled, let bal = lastBalance else { return "" }
        let slotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        let cfg = BankSlotSettingsStore.load(slotId: slotId)
        let thresholds = BalanceSignal.normalizedThresholds(
            deepOverdraft: cfg.balanceSignalDeepOverdraftThreshold,
            low: cfg.balanceSignalLowUpperBound,
            medium: cfg.balanceSignalMediumUpperBound,
            veryGood: cfg.balanceSignalVeryGoodLowerBound
        )
        let level = BalanceSignal.classify(balance: bal, thresholds: thresholds)
        guard let emoji = BalanceSignal.emoji(for: level) else { return "" }
        return "\(emoji) "
    }

    /// `logo` ist das Bild, das gleich im Status-Item landet. Seit dem Zuschnitt auf die
    /// Tinte sind Logos nicht mehr alle 16 Punkt breit — breite Wortmarken wie bunq
    /// brauchen mehr, sonst schneidet macOS den Saldo hinten ab. Ohne Argument bleibt
    /// es beim bisherigen Vorhalt.
    private func menubarFixedWidth(logo: NSImage? = nil) -> CGFloat {
        let refString = " \(lastShownTitle.isEmpty ? "1.234" : lastShownTitle) "
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        let textWidth = (refString as NSString).size(withAttributes: attrs).width
        // Emoji-Reserve einplanen wenn das Mood-Emoji rendert (kostet ~22 px),
        // sonst schneidet macOS den Saldo ab.
        let emojiEnabled = UserDefaults.standard.bool(forKey: "balanceMoodEmojiEnabled")
        let emojiReserve: CGFloat = emojiEnabled ? 22 : 0
        let logoReserve = max(22, (logo?.size.width ?? 16) + 6)  // Bildbreite + Gap
        return textWidth + emojiReserve + logoReserve
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

    /// Hover-Reveal nur für den klassischen Auto-Hide-Pfad (alter
    /// hideIndex-Mechanismus, isHiddenBalance=true). Im Flyout-Mode soll
    /// der Saldo NICHT per Hover erscheinen — entweder/oder.
    private func revealBalanceOnHoverIfNeeded() {
        guard !locked, isHiddenBalance else { return }
        guard !isHoverRevealingBalance else { return }
        isHoverRevealingBalance = true
        updateStatusBalanceTitle()
        updateHiddenBalanceTooltip()
    }

    private func hideHoverRevealIfNeeded() {
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
        // Menü wird nicht neu gebaut → „Geld senden" beim Slot-Wechsel nachziehen
        // (PayPal/Händler haben kein Konto zum Überweisen).
        refreshSendMoneyMenuItem()
        var resolvedName = slot.displayName
        var resolvedLogo = slot.logoId ?? ""

        // Brand resolution: name takes priority over YAXI's logoId (which can be wrong, e.g. "commerzbank" for C24).
        // Priority: 1) user-visible name → 2) stored logoId → 3) IBAN lookup
        if !resolvedName.isEmpty, let brand = BankLogoAssets.find(byName: resolvedName) {
            resolvedLogo = brand.id
        } else if !resolvedLogo.isEmpty, BankLogoAssets.find(byLogoID: resolvedLogo) != nil {
            // logo is already valid — keep it
        } else if !slot.isReceiptSlot, !slot.iban.isEmpty, let brand = BankLogoAssets.find(byIBAN: slot.iban) {
            if resolvedName.isEmpty { resolvedName = brand.displayName }
            resolvedLogo = brand.id
        }

        // Persist resolved logo/name back to the slot so it's correct on next launch.
        // This auto-heals existing accounts that were set up before the icon fix.
        // WICHTIG: niemals in Demo-Mode schreiben — sonst landen die ephemeren
        // Demo-Slots (z.B. „demo-slot-0") in UserDefaults und überschreiben die
        // echten Slots. Demo-Slots dürfen nur in-memory existieren.
        if !demoMode,
           resolvedLogo != (slot.logoId ?? "") || resolvedName != slot.displayName {
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

    /// Anzeige für einen REWE-Slot: letzter Einkauf als „Saldo" (kein YAXI).
    /// Politur (Eyebrow „Letzter Einkauf", Mini-Warenkorb, Kiste der Einkäufe)
    /// folgt in der UI-Phase. Renutzt den bestehenden Saldo-Anzeigepfad.
    private func applyREWEDisplay(slotId: String) {
        if let r = try? ReweReceiptStore.latest(slotId: slotId) {
            let amount = Double(r.totalCents) / 100.0
            UserDefaults.standard.set(amount, forKey: "simplebanking.cachedBalance.\(slotId)")
            lastBalance = amount
            txVM.currentBalance = formatEURWithCents(amount)
        } else {
            lastBalance = nil
            txVM.currentBalance = nil
        }
        updateStatusBalanceTitle()
        refreshFlyoutIfVisible()
    }

    // MARK: - PayPal (NVP-Provider)

    /// Lädt die PayPal-API-Signatur-Zugangsdaten des Slots (entschlüsselt).
    /// Immer Live: die Sandbox-Option wurde aus dem Setup entfernt. Ein evtl. noch
    /// gesetztes Alt-Flag wird aufgeräumt, damit Bestandsinstallationen nicht
    /// dauerhaft gegen die Sandbox laufen.
    private func paypalCredentials(masterPassword pw: String, slotId: String) -> PayPalService.Credentials? {
        guard let creds = try? CredentialsStore.load(masterPassword: pw),
              let user = creds.paypalUser?.nilIfEmpty,
              let pwd = creds.paypalPwd?.nilIfEmpty,
              let sig = creds.paypalSignature?.nilIfEmpty else { return nil }
        UserDefaults.standard.removeObject(forKey: "simplebanking.paypal.sandbox.\(slotId)")
        return PayPalService.Credentials(user: user, pwd: pwd, signature: sig, sandbox: false)
    }

    /// Schreibt den echten PayPal-Saldo in die Menüleiste/Flyout (Muster wie
    /// `applyREWEDisplay`, aber echter Kontostand).
    private func applyPayPalDisplay(_ bal: Double, slotId: String) {
        UserDefaults.standard.set(bal, forKey: "simplebanking.cachedBalance.\(slotId)")
        lastBalance = bal
        txVM.currentBalance = formatEURWithCents(bal)
        updateStatusBalanceTitle()
        refreshFlyoutIfVisible()
    }

    /// Refresh eines PayPal-Slots: Saldo (GetBalance) + Umsätze (TransactionSearch)
    /// → normale Transaktions-DB. Kein HBCI-Mutex (eigener Provider).
    private func refreshPayPal(slotId: String) async {
        guard !isPayPalCallInFlight else { return }
        isPayPalCallInFlight = true
        defer { isPayPalCallInFlight = false }

        guard let pw = masterPassword else {
            if locked { promptUnlockIfNeeded() }
            txVM.error = "Unlock required"
            return
        }
        guard let creds = paypalCredentials(masterPassword: pw, slotId: slotId) else {
            txVM.error = L10n.t("PayPal-Zugangsdaten fehlen — bitte neu einrichten.",
                                "PayPal credentials missing — please set up again.")
            return
        }
        do {
            let bal = try await PayPalService.fetchBalance(creds: creds)
            applyPayPalDisplay(bal, slotId: slotId)

            let days = BankSlotSettingsStore.load(slotId: slotId).displayDays
            let txs = try await PayPalService.fetchTransactions(days: days, slotId: slotId, creds: creds)
            if !txs.isEmpty {
                let sorted = sortTransactionsNewestFirst(txs)
                try? TransactionsDatabase.upsert(transactions: sorted)
                if let persisted = try? TransactionsDatabase.loadTransactions(days: days) {
                    txVM.transactions = sortTransactionsNewestFirst(persisted)
                    txVM.loadEnrichmentData(bankId: "primary")
                    txVM.resetPaging()
                }
            }
            txVM.error = nil
        } catch {
            txVM.error = error.localizedDescription
            AppLogger.log("PayPal-Refresh fehlgeschlagen: \(error)", category: "PayPal", level: "WARN")
        }
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
    private var dashboardPanel: DashboardPanel?
    private var statusMenu: NSMenu?
    private var balancePopover: NSPopover?
    /// Vollbild-Dim-Overlays (1 pro Screen) + zentriertes Flyout-Fenster für
    /// den Hold-to-Show-Modus. Leben nur während der Hotkey gedrückt ist;
    /// werden in hideCenteredFlyout() animiert entfernt.
    private var centeredFlyoutDimWindows: [NSWindow] = []
    private var centeredFlyoutContentWindow: NSWindow?
    /// Watchdog falls das Released-Event verloren geht (App-Switch via Cmd-Tab,
    /// Hotkey-Driver-Hänger, …). Schließt nach Hard-Timeout.
    private var centeredFlyoutWatchdog: DispatchWorkItem?
    /// Observer, der das Overlay schließt sobald die App den Fokus verliert.
    private var centeredFlyoutResignObserver: NSObjectProtocol?
    /// Verhindert konkurrierende Animationen (z.B. Press → schnelles Release).
    private var centeredFlyoutAnimating: Bool = false
    private var isFlyoutHovered: Bool = false
    private var statusButtonTrackingArea: NSTrackingArea?
    private var isHoverRevealingBalance: Bool = false

    // MARK: Desktop-Widget (aus dem Flyout gezogen)
    /// Das aus dem Menüleisten-Popover herausgezogene, freistehende Flyout-Fenster.
    /// Nil solange kein Widget offen ist. Session-only (keine Neustart-Persistenz).
    private var detachedFlyoutWindow: NSWindow?
    /// Observer, der `detachedFlyoutWindow` beim Schließen des Fensters aufräumt.
    private var detachedFlyoutCloseObserver: NSObjectProtocol?
    /// Host der Widget-Karte — für Live-Refresh (das Fenster nutzt eine Container-
    /// View als contentView, daher kein Zugriff über contentViewController).
    private var detachedFlyoutHost: NSHostingController<StatusBalanceFlyoutCardView>?
    /// Steuer-Icons auf dem Widget (nur bei Hover sichtbar).
    private weak var widgetPinButton: NSButton?
    private weak var widgetCloseButton: NSButton?
    /// Ruhezustand des Widgets: Kontostand wird maskiert (Maus nicht über dem Fenster).
    private var widgetBalanceHidden = false
    /// Event-Monitore für das manuelle Fenster-Dragging (Drop auf den Desktop).
    private var widgetDragMonitors: [Any] = []
    /// Monitor, der einen Drag IRGENDWO auf dem Flyout-Popover erkennt (ganzes
    /// Fenster „greifbar" → Desktop-Widget). Aktiv nur solange das Popover offen ist.
    private var flyoutDetachMonitor: Any?
    private var flyoutDetachStart: NSPoint?
    private static let flyoutWidgetStayOnTopKey = "flyoutWidget.stayOnTop"
    /// Standard: false = normale Fensterebene (umschaltbar per Rechtsklick-Menü).
    private var flyoutWidgetStayOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Self.flyoutWidgetStayOnTopKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.flyoutWidgetStayOnTopKey)
            applyFlyoutWidgetLevel()
        }
    }
    private func applyFlyoutWidgetLevel() {
        detachedFlyoutWindow?.level = flyoutWidgetStayOnTop ? .floating : .normal
    }

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
        // Stabilen MCP-Symlink nach App-Move/Update auf das aktuelle Bundle nachziehen,
        // damit eine bereits geschriebene Claude-Config gültig bleibt (No-op, wenn nicht
        // installiert oder Ziel bereits korrekt).
        MCPInstaller.refreshIfInstalled()
        // Theme-Schriften registrieren, bevor die erste Oberfläche rendert —
        // sonst greift die Schrift des aktiven Themes erst nach einem Neustart.
        ThemeFonts.registerBundledFonts()
        // Ripple standardmäßig an (Aufruf + neue Bewegungen) — direkte
        // UserDefaults.bool-Reads ignorieren den @AppStorage-Default, daher registrieren.
        UserDefaults.standard.register(defaults: ["rippleAlwaysOn": true])
        // Globale credentials.json in die Slot-Datei überführen — sonst dient sie
        // weiter als slot-übergreifender Fallback (siehe CredentialsStore.defaultURL).
        CredentialsStore.migrateLegacyFileIfNeeded()
        YaxiService.migrateCredentialsModelIfNeeded()

        // TAN/SCA state callback → update menu bar and transactions panel
        YaxiService.onTanStateChanged = { [weak self] isPending in
            self?.isTanPending = isPending
            self?.txVM.isTanPending = isPending
            self?.updateMenuBarButton()
        }

        // SCA `.field`-Branch (TAN-Eingabe-Dialog) — Bank verlangt einen
        // Textcode statt Push-Bestätigung. UI lebt in SCAFieldInputSheet.
        YaxiService.fieldInputProvider = { spec, done in
            SCAFieldInputPresenter.present(spec, completion: done)
        }

        // Task 4: Set active slot IDs in all data layers at startup
        let store = MultibankingStore.shared
        if let slot = store.activeSlot {
            SlotContext.activate(slotId: slot.id)
            applySlotToViewModel(slot)
            // Seit Refactor 2026-05-19 ist SessionStore per-slot lazy cached —
            // kein explizites Preload mehr nötig, der erste fetchBalances lädt
            // automatisch den richtigen Slot.
        }

        // Self-Heal: Slots aus Pre-1.5.0-Setups, die durch den Multi-Account-
        // Bug ohne connectionId angelegt wurden, von einem gesunden Sibling
        // im selben Bank-Brand reparieren. Idempotent — wirkt nur wenn was
        // zu reparieren ist (siehe SlotConnectionHealer-Doku).
        SlotConnectionHealer.runOnStartup()

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
        // Fold legacy recurring-correction keys into the unified RecurringAssignments store (once).
        RecurringAssignments.migrateLegacyIfNeeded()
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
            // Menüleisten-Button neu rendern, damit der Money-Mood-Emoji-Toggle
            // (Settings → Verhalten) sofort wirkt, statt erst beim nächsten Refresh.
            self?.updateMenuBarButton()
        }
        NotificationCenter.default.addObserver(forName: .changeBankCredentials, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changeBankCredentials() }
        }
        NotificationCenter.default.addObserver(forName: .creditLimitToggleChanged, object: nil, queue: .main) { [weak self] _ in
            // Automatischer UI-Refresh (kein User-Sync) → kein eBon-Login-Fenster.
            Task { await self?.refreshAsync() }
        }
        // Bankfarben-Toggle (global oder pro Slot) ändert die Flyout-Host-
        // Backing-Layer-Farbe. Beim nächsten makeFlyoutHost zieht der Tint.
        NotificationCenter.default.addObserver(forName: .bankTintChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshFlyoutIfVisible()
        }

        // Register UserDefaults defaults (only apply when key has no stored value).
        // celebrationStyle in v1.5.0 entfernt — Ripple ist die einzige Variante.

        // Unlock on startup if encrypted credentials exist (but not in demo mode)
        if CredentialsStore.exists() && !demoMode {
            let pwRequired = UserDefaults.standard.object(forKey: "passwordRequired") as? Bool ?? true
            if !pwRequired, let autoPw = BiometricStore.loadAutoUnlockPassword() {
                // Auto-unlock without prompt
                if let _ = try? CredentialsStore.load(masterPassword: autoPw) {
                    masterPassword = autoPw
                    locked = false
                    // Sofort aus dem lokalen Cache rechnen, statt auf den Netz-Refresh
                    // zu warten — sonst steht die Zeile unter dem Kontostand beim Start
                    // leer, obwohl die Daten längst auf der Platte liegen.
                    recomputeLeftToPay()
                    Task { await refreshAsync() }
                } else {
                    // Auto-unlock password mismatch → fall back to prompt
                    locked = true
                    deferUnlockPrompt()
                }
            } else {
                locked = true
                deferUnlockPrompt()
            }
        } else if demoMode {
            // Demo mode starts unlocked with demo data
            locked = false
            if demoStyle == 1 { activateMultiDemo() }
            else if demoStyle == 2 { activateReweDemo() }
            else { activateSingleDemo() }
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

        // ── simplesend: Geld senden (Lizenz-Gate + FeatureFlag) ───────────
        // Im Demo-Mode immer sichtbar — auch ohne Tester-Build-Flag,
        // damit das Feature vollständig getestet werden kann.
        // `simplesendVisible` (User-Toggle in Einstellungen → Verhalten + UpsellSheet)
        // wird per Notification live aktualisiert: Item bleibt im Menü, aber `isHidden`
        // schaltet zur Laufzeit. Tag 350 erlaubt das spätere Lookup.
        if FeatureFlags.transferMoneyEnabled || demoMode {
            let sendMoneyItem = NSMenuItem(title: t("simplesend: Geld senden", "simplesend: Send Money"),
                                           action: #selector(sendMoney as () -> Void),
                                           keyEquivalent: "n")
            sendMoneyItem.tag = 350
            sendMoneyItem.target = self
            sendMoneyItem.isHidden = !simplesendVisible || !activeSlotSupportsTransfer
            if let img = NSImage(systemSymbolName: "arrow.up.right.square",
                                 accessibilityDescription: nil) {
                img.isTemplate = true
                sendMoneyItem.image = img
            }
            menu.addItem(sendMoneyItem)
        }

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

        // „Konto hinzufügen" deckt jetzt Bank UND Händler ab (REWE/dm/Amazon werden
        // im Dialog angeboten) — die früheren drei Händler-Menüpunkte entfallen.
        let addBankItem = NSMenuItem(title: t("Konto hinzufügen…", "Add Account…"), action: #selector(connect), keyEquivalent: "b")
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
        demoSingleItem.state = (demoMode && demoStyle == 0) ? .on : .off
        demoSub.addItem(demoSingleItem)

        let demoMultiItem = NSMenuItem(title: t("Multi-Banking", "Multi Banking"), action: #selector(setDemoMulti), keyEquivalent: "")
        demoMultiItem.tag = 3013
        demoMultiItem.state = isMultiDemo ? .on : .off
        demoSub.addItem(demoMultiItem)

        let demoReweItem = NSMenuItem(title: t("REWE eBon", "REWE Receipts"), action: #selector(setDemoRewe), keyEquivalent: "")
        demoReweItem.tag = 3014
        demoReweItem.state = isReweDemo ? .on : .off
        demoSub.addItem(demoReweItem)

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

        // v1.5.0: separater "Diagnose aktivieren"-Toggle entfernt — die
        // Bank-Diagnose schaltet Verbose-Logging selbst ein und am Ende
        // wieder aus (siehe DiagnosticSession).

        let diagReportItem = NSMenuItem(title: t("Diagnosebericht versenden…", "Send Diagnostic Report…"), action: #selector(sendDiagnosticReport), keyEquivalent: "")
        diagReportItem.tag = 502
        diagReportItem.target = self
        supportSub.addItem(diagReportItem)

        let bankDiagItem = NSMenuItem(title: t("Bank-Diagnose…", "Bank Diagnostics…"), action: #selector(openBankDiagnostics), keyEquivalent: "")
        bankDiagItem.tag = 506
        bankDiagItem.target = self
        if let img = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: nil) {
            img.isTemplate = true
            bankDiagItem.image = img
        }
        supportSub.addItem(bankDiagItem)

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
            // Pull-to-Refresh UND Header-↻ laufen hier durch (gleicher Spinner).
            // Only open/refresh if the panel is already visible.
            guard let self, self.txPanel?.isVisible == true else { return }
            // eBon-Slot: still im Hintergrund / Fenster nur bei Login.
            if let active = MultibankingStore.shared.activeSlot, active.isReceiptSlot {
                self.syncReceiptSlot(active, allowWindow: true)
                return
            }
            // Gesperrtes Echtkonto → Unlock-Dialog (statt funktionslos).
            if !self.demoMode, CredentialsStore.anyExists(), self.locked || self.masterPassword == nil {
                if self.masterPassword == nil { self.locked = true }
                self.promptUnlockIfNeeded()
                return
            }
            await self.openTransactionsPanel()
        }, onSettings: { [weak self] in
            self?.showSettings()
        }, onOpenDashboard: { [weak self] tab in
            self?.openDashboard(tab: tab)
        })
        updateTxPanelAccountNav()
        settingsPanel = SettingsPanel()

        // SettingsPanel kann den schon entsperrten BalanceBar-PW-Cache nutzen,
        // statt im SettingsPanel ein zweites PW-Modal zu zeigen.
        SettingsPanel.masterPasswordProvider = { [weak self] in self?.requestMasterPassword() }

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
                // Title + Width-Logik liegt in updateMenuBarButton — sonst
                // greift der Mode-Wechsel erst nach App-Restart.
                self.updateMenuBarButton()
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

        // Launch: nur Anzeige aktualisieren. NICHT `refresh()` — das öffnet bei
        // eBon-Slots (REWE/dm) das Login-/Sync-Fenster; ein WKWebView-Fenster mitten
        // im Launch crasht (Autorelease-Pop). Sync passiert nur vom User „angestoßen".
        Task { await refreshAsync() }

        // Preload subscription logos once so the Abos sheet can render icons immediately.
        SubscriptionLogoStore.shared.preloadInitial(displayNames: LogoAssets.allDisplayNames)

        autoStartSetupWizardIfNeeded()
        showWhatsNewIfNeeded()

        // eBon-Slots (REWE/dm/Amazon) beim Start unsichtbar im Hintergrund
        // aktualisieren — verzögert (nie während didFinishLaunching; ein WKWebView
        // mitten im Launch crasht), und nur Anzeige-Update, nie ein Fenster.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.backgroundSyncReceiptSlots()
        }

        setupGlobalHotkey()
        globalHotkeyObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.globalHotkeyChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.setupGlobalHotkey() }

        // „Geld senden…" aus dem TransactionsPanel-Mehr-Menü öffnen.
        // BalanceBar bleibt der zentrale Eintrittspunkt mit Lizenz-Routing.
        // FeatureFlag-gated, aber Demo-Mode bypassed das Flag (Feature-Test).
        // userInfo["draft"] = TransferDraft (z.B. vom MCP-Tool prepare_transfer)
        // → öffnet das Sheet mit vorausgefüllten Feldern + Assistant-Badge.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.openTransferSheet"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard FeatureFlags.transferMoneyEnabled || (self?.demoMode ?? false) else { return }
            let draft = note.userInfo?[TransferDraftWatcher.draftUserInfoKey] as? TransferDraft
            self?.sendMoney(draft: draft)
        }

        // Externe Transfer-Drafts (MCP-Tool prepare_transfer) entgegennehmen.
        TransferDraftWatcher.shared.start()

        // Live-Update: simplesendVisible-Toggle (Einstellungen → Verhalten oder
        // Checkbox im UpsellSheet) blendet den Statusbar-Menüeintrag sofort
        // aus/ein, statt einen App-Restart zu erzwingen. Item ist über tag 350
        // im statusMenu auffindbar.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.simplesendVisibilityChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshSendMoneyMenuItem()
        }

        updateChecker = UpdateChecker()

        // Aufrunden: Banner-Button öffnet den Choice-Sheet (Picker mit
        // Heute/Gestern/Vorgestern/Monat + Abbrechen/Jetzt sparen).
        NotificationCenter.default.addObserver(
            forName: Notification.Name("simplebanking.roundupOpenChoiceSheet"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let slotId = note.userInfo?["slotId"] as? String else { return }
            Task { @MainActor in
                self?.openRoundupChoicePanel(slotId: slotId)
            }
        }
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
        // WAL-Sidecars (db-wal, db-shm) zusammenführen → kleinere Backups.
        TransactionsDatabase.checkpointWAL()
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
        // eBon-Slot (REWE/dm): kein Bank-Refresh/Auto-Sync. „Aktualisieren" stößt
        // manuell das Login-/Sync-Fenster an. Ist man noch eingeloggt, reicht ein
        // Klick auf „synchronisieren" darin.
        if let active = MultibankingStore.shared.activeSlot, active.isReceiptSlot {
            // Erst still im Hintergrund; Fenster nur, wenn ein Login nötig ist.
            syncReceiptSlot(active, allowWindow: true)
            return
        }
        // Gesperrtes / nicht entsperrtes Echtkonto: der manuelle Refresh soll den
        // Unlock-Dialog auslösen (sonst „Unlock required" + funktionsloser Klick).
        // promptUnlockIfNeeded refresht bei Erfolg selbst.
        if !demoMode, CredentialsStore.anyExists(), locked || masterPassword == nil {
            if masterPassword == nil { locked = true }
            promptUnlockIfNeeded()
            return
        }
        // Manual refresh always clears the SCA backoff — user explicitly wants to retry.
        scaBackoffUntil = nil
        Task { await refreshAsync() }
    }

    // MARK: - Geld senden

    private var transferWindow: NSWindow?
    private var upsellWindow: NSWindow?
    private var transferVoucherWindow: NSWindow?
    private var licenseStartWindow: NSWindow?
    private var bankDiagnosticsWindow: NSWindow?
    private var roundupWindow: NSWindow?

    @objc private func sendMoney() {
        sendMoney(draft: nil)
    }

    /// Variante mit optionalem Draft (z.B. vom MCP-Tool prepare_transfer).
    /// Bei gültigem Prefill öffnet das Sheet mit vorausgefüllten Feldern;
    /// fehlerhafte/unparsbare Drafts werden mit Logger-Hinweis ignoriert
    /// (Sheet bleibt leer, statt mit Mülldaten zu öffnen).
    func sendMoney(draft: TransferDraft?) {
        var prefill: TransferRequest? = nil
        var prefillSource: String? = nil
        if let d = draft {
            do {
                prefill = try TransferDraftStore.makeRequest(from: d)
                prefillSource = d.source
            } catch {
                AppLogger.log("Transfer-Draft \(d.id) verworfen: \(error)",
                              category: "Transfer", level: "WARN")
            }
        }
        if demoMode {
            showTransferSheet(prefill: prefill, prefillSource: prefillSource)
            return
        }
        if LicenseConfig.licensingEnabled, !LicenseManager.shared.isLicensed {
            showUpsellSheet()
        } else {
            showTransferSheet(prefill: prefill, prefillSource: prefillSource)
        }
    }

    private func showUpsellSheet() {
        if let existing = upsellWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Derselbe Freischalt-Screen wie am Start — hier kontextbezogen ohne
        // „nicht mehr anzeigen"-Checkbox (nur Schließen).
        let sheet = LicenseStartScreen(
            onClose: { [weak self] in
                self?.upsellWindow?.close()
                self?.upsellWindow = nil
            },
            showDontShowAgain: false,
            onEnterKey: { [weak self] in
                self?.upsellWindow?.close()
                self?.upsellWindow = nil
                // Lizenz-Sektion lebt im Über-Tab.
                UserDefaults.standard.set(5, forKey: "settingsLastTab")
                self?.showSettings()
            }
        )
        let host = NSHostingController(rootView: sheet)
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "simplesend"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 520))
        window.minSize = NSSize(width: 460, height: 520)
        window.maxSize = NSSize(width: 460, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        upsellWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openBankDiagnostics() {
        if let existing = bankDiagnosticsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let sheet = DiagnosticAssistantSheet(
            requestMasterPassword: { [weak self] in self?.requestMasterPassword() },
            onClose: { [weak self] in
                self?.bankDiagnosticsWindow?.close()
                self?.bankDiagnosticsWindow = nil
            }
        )
        let host = NSHostingController(rootView: sheet)
        let window = NSWindow(contentViewController: host)
        window.title = L10n.t("Bank-Diagnose", "Bank Diagnostics")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 540, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        bankDiagnosticsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showTransferSheet(prefill: TransferRequest? = nil,
                                   prefillSource: String? = nil,
                                   onTransferSucceeded: ((TransferRequest) -> Void)? = nil) {
        if let existing = transferWindow, existing.isVisible {
            // Bereits offenes Sheet bekommt keinen nachträglichen Prefill —
            // sonst würden gerade getippte Werte überschrieben. Stattdessen
            // schließen und mit Prefill neu öffnen wenn ein Draft da ist.
            if prefill != nil {
                existing.close()
                transferWindow = nil
            } else {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }
        let sheet = TransferSheet(
            requestMasterPassword: { [weak self] in self?.requestMasterPassword() },
            onClose: { [weak self] in
                self?.transferWindow?.close()
                self?.transferWindow = nil
            },
            onSwitchSlot: { [weak self] idx in
                Task { await self?.switchToSlot(index: idx) }
            },
            prefill: prefill,
            prefillSource: prefillSource,
            onTransferSucceeded: onTransferSucceeded
        )

        // NSPanel mit identischem Chrome wie das TransactionsPanel — damit
        // beide Fenster nebeneinander dieselbe Höhe + Titelbar-Optik haben.
        // Title-Visibility hidden + transparent + unifiedCompact-Toolbar
        // matched die Chrome-Höhe.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.t("simplesend", "simplesend")
        // Title sichtbar lassen — User wollte den Header in die Titlebar,
        // nicht doppelt im Content.
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(name: nil) { appearance in
            let theme = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? theme.panelDarkColor
                : theme.panelLightColor
        }
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        if #available(macOS 11.0, *) {
            panel.toolbarStyle = .unifiedCompact
        }
        panel.collectionBehavior = [.fullScreenNone, .managed]

        // Leere NSToolbar anhängen — sorgt dafür dass die Chrome-Höhe exakt
        // dem TransactionsPanel matched (unifiedCompact braucht eine Toolbar
        // um seine kompakte Höhe zu rendern).
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("simplebanking.transfer.toolbar"))
        toolbar.showsBaselineSeparator = false
        panel.toolbar = toolbar

        // Initial: 620 content. Wenn das TransactionsPanel offen ist, gleich
        // unten die FRAME-Höhe identisch matchen — TransactionsPanel hat
        // unifiedCompact + Toolbar-Items, was die Chrome-Höhe vergrößert.
        // Mit Frame-Match auf gleichen total-height-Wert wird der Höhenunterschied
        // vollständig neutralisiert.
        panel.setContentSize(NSSize(width: 480, height: 620))
        panel.minSize = NSSize(width: 480, height: 480)
        panel.maxSize = NSSize(width: 480, height: 1200)

        // HostingView via Auto-Layout in einem Container — gleich wie TransactionsPanel.
        let host = NSHostingView(rootView: sheet)
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(host)
        panel.contentView = content
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        panel.isReleasedWhenClosed = false

        // Frame-Höhe exakt an Umsatzfenster matchen, wenn dieses sichtbar ist.
        // Macht jede Chrome-Differenz (unifiedCompact-Toolbar in TxPanel vs.
        // bare Titlebar bei uns) irrelevant.
        if let tx = txPanel, tx.isVisible {
            let target = tx.frame.height
            var frame = panel.frame
            frame.size.height = target
            panel.setFrame(frame, display: false)
        }

        positionTransferWindow(panel)
        transferWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Aufrunden / Spartopf

    func openRoundupChoicePanel(slotId: String) {
        if let existing = roundupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let bankIdForSheet = demoMode ? "demo" : "primary"
        let sheet = RoundupChoiceSheet(
            slotId: slotId,
            bankId: bankIdForSheet,
            onCancel: { [weak self] in
                self?.roundupWindow?.close()
                self?.roundupWindow = nil
            },
            onTransfer: { [weak self] amountCents, rangeLabel, recipientName, recipientIban, fromDate, toDate in
                guard let self else { return }
                self.roundupWindow?.close()
                self.roundupWindow = nil
                guard amountCents > 0 else { return }
                self.openTransferSheetForRoundupChoice(
                    slotId: slotId,
                    amountCents: amountCents,
                    rangeLabel: rangeLabel,
                    recipientName: recipientName,
                    recipientIban: recipientIban,
                    fromDate: fromDate,
                    toDate: toDate
                )
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.t("Aufrunden", "Round-up")
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(name: nil) { appearance in
            let theme = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? theme.panelDarkColor
                : theme.panelLightColor
        }
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenNone, .managed]

        let host = NSHostingView(rootView: sheet)
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(host)
        panel.contentView = content
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        panel.isReleasedWhenClosed = false
        panel.center()
        roundupWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openTransferSheetForRoundupChoice(
        slotId: String,
        amountCents: Int,
        rangeLabel: String,
        recipientName: String,
        recipientIban: String,
        fromDate: String,
        toDate: String
    ) {
        let amount = Decimal(amountCents) / 100
        let bankId = demoMode ? "demo" : "primary"
        let present: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                let request = try TransferRequest(
                    creditorName: recipientName,
                    creditorIban: recipientIban,
                    amountEUR: amount,
                    remittance: L10n.t("Aufgerundet (\(rangeLabel))", "Round-up (\(rangeLabel))")
                )
                self.showTransferSheet(prefill: request, prefillSource: "roundup") { _ in
                    // Erst nach erfolgreicher Ausführung finalisieren, damit derselbe
                    // Betrag nicht erneut überwiesen werden kann: Pots als `transferred`
                    // markieren UND den Zeitraum als bezahlt festhalten (deckt auch
                    // Buchungen ohne Pot-Zeile ab → keine Doppelauszahlung).
                    do {
                        try RoundupStore.markRangeTransferred(slotId: slotId, from: fromDate, to: toDate, bankId: bankId)
                    } catch {
                        AppLogger.log("Roundup-Finalisierung fehlgeschlagen (slot=\(slotId), \(fromDate)…\(toDate)): \(error.localizedDescription)",
                                      category: "Roundup", level: "ERROR")
                    }
                    do {
                        try RoundupStore.recordPayout(slotId: slotId, from: fromDate, to: toDate, amountCents: amountCents, bankId: bankId)
                    } catch {
                        AppLogger.log("Roundup-Payout-Record fehlgeschlagen (slot=\(slotId)): \(error.localizedDescription)",
                                      category: "Roundup", level: "ERROR")
                    }
                    RoundupViewState.shared.refreshAfterPayout()
                }
            } catch {
                AppLogger.log("Roundup-Choice TransferRequest fehlgeschlagen: \(error.localizedDescription)",
                              category: "Roundup", level: "ERROR")
            }
        }

        // Quellkonto festschreiben: falls der Nutzer zwischen Choice-Panel und Transfer
        // das Konto gewechselt hat, vor dem Öffnen zurück auf den Spar-Slot wechseln —
        // sonst würde vom falschen Konto gesendet, während die Pots von A finalisiert werden.
        if (MultibankingStore.shared.activeSlot?.id ?? "") != slotId,
           let idx = MultibankingStore.shared.slots.firstIndex(where: { $0.id == slotId }) {
            Task { @MainActor in
                await self.switchToSlot(index: idx)
                present()
            }
        } else {
            present()
        }
    }

    /// Positioniert das Transfer-Window: wenn das Umsatzfenster offen ist,
    /// direkt rechts daneben (oder links, falls rechts kein Platz). Sonst
    /// klassisch zentriert. Bottom-Kante matched die des Umsatzfensters.
    private func positionTransferWindow(_ window: NSWindow) {
        guard let tx = txPanel, tx.isVisible else {
            window.center()
            return
        }
        let txFrame = tx.frame
        let gap: CGFloat = 8
        let myWidth = window.frame.width
        let originY = txFrame.minY

        // Den Bildschirm wählen, auf dem das Umsatzfenster liegt — wichtig
        // für Multi-Monitor-Setups.
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(txFrame.origin) }
                           ?? NSScreen.main)?.visibleFrame ?? .zero

        // Versuch 1: rechts vom txPanel
        let rightX = txFrame.maxX + gap
        if rightX + myWidth <= screenFrame.maxX {
            window.setFrameOrigin(NSPoint(x: rightX, y: originY))
            return
        }
        // Versuch 2: links vom txPanel
        let leftX = txFrame.minX - gap - myWidth
        if leftX >= screenFrame.minX {
            window.setFrameOrigin(NSPoint(x: leftX, y: originY))
            return
        }
        // Fallback: nichts passt nebeneinander → zentrieren
        window.center()
    }

    /// Liefert das Master-Passwort: erst aus dem in-memory-Cache (BalanceBar
    /// ist nach Touch-ID-Unlock im Besitz), sonst aus BiometricStore-Auto-
    /// Unlock-Cache, sonst nil. TransferSheet kann dann selbst entscheiden,
    /// ob es modal nachfragt.
    fileprivate func requestMasterPassword() -> String? {
        if let pw = masterPassword { return pw }
        if let auto = BiometricStore.loadAutoUnlockPassword(),
           (try? CredentialsStore.load(masterPassword: auto)) != nil {
            return auto
        }
        return nil
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

            // suppressTransactionsFetch=true: refreshAsync() darf nicht zusätzlich
            // den impliziten TX-Fetch starten, sonst rennen zwei parallel gegen den
            // HBCI-Mutex. Der Pflicht-Fetch passiert direkt danach sequentiell.
            await refreshAsync(suppressTransactionsFetch: true)
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
        if wasMulti { tearDownDemoSlots() }
        demoStyle = 0
        demoMode = true
        demoSeed = Int.random(in: 1...Int.max)
        txVM.anthropicApiKey = nil
        txVM.connectedBankIBAN = nil
        txVM.leftToPayAmount = nil   // drop stale live value
        activateSingleDemo()
        rebuildMenuTitleForDemoMode()
        recomputeLeftToPay()
    }

    /// Baut den Single-Demo-Slot. Wählt EINE zufällige Bank-Marke — deren Farbe
    /// gibt das Streifen-/Karten-Design vor (BankTintProvider liest die Slot-`logoId`).
    /// Ohne echten Brand am aktiven Slot bliebe der Streifen im Demo unsichtbar,
    /// weil `BankTintProvider.hex(for:)` ohne logoId/customColor `nil` liefert.
    private func activateSingleDemo() {
        backupSlotsForDemo()
        // Bankmarke aus einem ABGELEITETEN Seed ziehen, damit der Saldo unten direkt aus
        // `demoSeed` kommt — identisch zum Refresh-Pfad. Sonst verbraucht der Marken-Draw
        // den Seed vor dem Saldo-Draw → Anzeige/Cache (und Transfer-Hartgrenze) divergieren.
        var brandSeed = UInt64(truncatingIfNeeded: demoSeed) ^ 0xD1B54A32D192ED03
        let brands = BankLogoAssets.brands
        let demoSlot: BankSlot
        if brands.isEmpty {
            demoSlot = BankSlot(id: "demo-slot-0", iban: "DE00000000000000000000",
                                displayName: "Demo-Bank", logoId: nil)
        } else {
            let idx = max(0, min(brands.count - 1, Int(FakeData.nextDouble(&brandSeed) * Double(brands.count))))
            let brand = brands[idx]
            demoSlot = BankSlot(id: "demo-slot-0", iban: "DE00000000000000000000",
                                displayName: brand.displayName, logoId: brand.id)
        }
        MultibankingStore.shared.injectDemoSlots([demoSlot])

        var seed = UInt64(truncatingIfNeeded: demoSeed)
        let fake = FakeData.demoBalance(seed: &seed)
        UserDefaults.standard.set(fake, forKey: "simplebanking.cachedBalance.\(demoSlot.id)")
        lastShownTitle = formatEURNoDecimals(String(format: "%.2f", fake))
        lastBalance = fake
        txVM.currentBalance = formatEURWithCents(fake)
        applyBalanceDisplayModeConstraints()
        // Spiegelt Brand (Logo/Name) + Streifen-Quelle (Slot-logoId) ins ViewModel.
        applySlotToViewModel(demoSlot)
        updateStatusBalanceTitle()
        updateMenuBarButton()
        statusItem.button?.toolTip = "🎭 Demo-Modus: Single-Banking"
    }

    /// Sichert die echten Slots vor dem Injizieren ephemerer Demo-Slots.
    /// Defensiv: zeigt der Store bereits Demo-Slots (unsauberer Zustand), erst
    /// sauber von Disk laden — sonst persistiert das Teardown später Demo-Daten.
    private func backupSlotsForDemo() {
        let currentSlots = MultibankingStore.shared.slots
        let storeLooksDemo = currentSlots.contains { $0.id.hasPrefix("demo-slot-") }
        if storeLooksDemo {
            MultibankingStore.shared.reloadFromDisk()
        }
        demoPreviousSlots = MultibankingStore.shared.slots
        demoPreviousActiveIndex = MultibankingStore.shared.activeIndex
        demoPreviousUnifiedMode = UserDefaults.standard.bool(forKey: "unifiedModeEnabled")
    }

    @objc private func setDemoMulti() {
        let wasMulti = isMultiDemo
        if wasMulti { tearDownDemoSlots() }
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
        if MultibankingStore.shared.slots.contains(where: { $0.id.hasPrefix("demo-slot-") }) {
            tearDownDemoSlots()
        }
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
        // tearDownDemoSlots restores MultibankingStore.slots, but the static
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
            // User verlässt Demo ohne je ein echtes Konto eingerichtet zu haben
            // → den Setup-Wizard direkt anstoßen, damit Menü-Icon, Saldo und
            // 2FA-Prompt nicht erst nach manuellem Rechtsklick passieren.
            // `autoStartSetupWizardIfNeeded` ist One-Shot pro Launch und hat
            // beim Start wegen `demoMode` early-returned — kann jetzt sauber laufen.
            autoStartSetupWizardIfNeeded()
        }
    }

    @objc private func randomizeDemo() {
        demoSeed = Int.random(in: 1...Int.max)
        guard demoMode else { return }
        if isMultiDemo {
            tearDownDemoSlots()
            activateMultiDemo()
        } else if isReweDemo {
            tearDownDemoSlots()
            activateReweDemo()
        } else {
            tearDownDemoSlots()
            activateSingleDemo()
        }
        Task { await refreshAsync() }
    }

    private func activateMultiDemo() {
        backupSlotsForDemo()

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

        // Active-Slot ins ViewModel spiegeln, damit der Flyout sofort die richtige Bank-Logo
        // zeigt. Ohne diesen Call sieht der erste Open in Multi-Demo nur einen wallet.pass-
        // Fallback bis der User die Banken durchklickt.
        if let activeDemo = MultibankingStore.shared.activeSlot ?? demoSlots.first {
            applySlotToViewModel(activeDemo)
        }
    }

    // MARK: - REWE eBon Demo

    @objc private func setDemoRewe() {
        if demoMode { tearDownDemoSlots() }
        demoStyle = 2
        demoMode = true
        demoSeed = Int.random(in: 1...Int.max)
        txVM.anthropicApiKey = nil
        txVM.connectedBankIBAN = nil
        txVM.leftToPayAmount = nil
        activateReweDemo()
        rebuildMenuTitleForDemoMode()
    }

    /// Baut einen REWE-eBon-Demo-Slot mit Fake-Bons (zeigt die komplette eBon-UI:
    /// Flyout-Karte, Kategorien-Ring, Einkaufsliste, „Was kaufst du ein?").
    private func activateReweDemo() {
        backupSlotsForDemo()
        let slot = BankSlot(id: "demo-slot-rewe", iban: "", displayName: "REWE",
                            logoId: "rewe", currency: "EUR", source: .rewe)
        MultibankingStore.shared.injectDemoSlots([slot])
        // Fake-Bons in den Receipt-Store schreiben — die eBon-UI liest daraus.
        let receipts = FakeData.demoReweReceipts(slotId: slot.id, seed: UInt64(truncatingIfNeeded: demoSeed))
        try? ReweReceiptStore.deleteAll(slotId: slot.id)
        try? ReweReceiptStore.upsert(receipts)
        applySlotToViewModel(slot)
        applyREWEDisplay(slotId: slot.id)   // Saldo = letzter Einkauf
        updateStatusBalanceTitle()
        updateMenuBarButton()
        statusItem.button?.toolTip = "🎭 Demo-Modus: REWE eBon"
    }

    /// Räumt injizierte Demo-Slots (Single = `demo-slot-0`, Multi = 0..2,
    /// REWE = `demo-slot-rewe`) ab und stellt die echten Slots wieder her.
    private func tearDownDemoSlots() {
        for i in 0..<3 {
            UserDefaults.standard.removeObject(forKey: "simplebanking.cachedBalance.demo-slot-\(i)")
            BankSlotSettingsStore.delete(slotId: "demo-slot-\(i)")
        }
        // REWE-eBon-Demo: Cache + Fake-Bons löschen.
        UserDefaults.standard.removeObject(forKey: "simplebanking.cachedBalance.demo-slot-rewe")
        try? ReweReceiptStore.deleteAll(slotId: "demo-slot-rewe")
        // Wenn das in-memory Backup leer/korrupt ist, fällt restoreDemoSlots
        // intern auf reloadFromDisk() zurück. UserDefaults bleibt die
        // Source-of-Truth, weil injectDemoSlots nichts persistiert.
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
            // Nach Unlock nur Anzeige aktualisieren — kein eBon-Login-Fenster.
            Task { await self.refreshAsync() }
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

    /// Verhindert, dass die App im Dock-Mode (`.regular`) automatisch
    /// beendet, sobald das letzte Fenster schließt. simplebanking ist
    /// primär eine Menüleisten-App — Cmd-Q ist der einzige Beenden-Weg.
    /// Ohne diesen Override würde z.B. das Voucher-Sheet → externe URL
    /// öffnen → Fenster schließen → App quit auslösen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
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

        // Support submenu — Tag 501 (Diagnose aktivieren) wurde in v1.5.0
        // entfernt; Bank-Diagnose-Sheet schaltet Logging selbst.
        if let supportItem = menu.item(withTag: 500), let sub = supportItem.submenu {
            supportItem.title = t("Support", "Support")
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

    /// Schiebt den Unlock-Modal auf die nächste Main-Loop-Iteration, statt ihn
    /// synchron aus `applicationDidFinishLaunching` zu starten.
    ///
    /// Grund: `promptUnlockIfNeeded()` öffnet via `NSApp.runModal(for:)` einen
    /// verschachtelten Modal-Run-Loop. Wird der noch *innerhalb* von
    /// didFinishLaunching gestartet — also bevor der reguläre App-Run-Loop läuft —
    /// kann das `MasterPasswordPanel` (floating `.accessory`-App, kein Dock) unter
    /// macOS 26 nicht Key werden: der User sieht kein Panel, die App steckt für
    /// immer in `runModal` fest („App tut nichts / kein Menüleisten-Icon"), und der
    /// Rest des Setups (Menü, Watcher) läuft nie. Durch das Deferral ist der
    /// Run-Loop garantiert aktiv, wenn das Panel erscheint, und didFinishLaunching
    /// läuft vollständig durch.
    private func deferUnlockPrompt() {
        Task { @MainActor in
            self.promptUnlockIfNeeded()
        }
    }

    private func promptUnlockIfNeeded() {
        guard locked else { return }
        guard !isPromptingUnlock else { return }  // prevent modal stacking during nested event loop
        isPromptingUnlock = true  // Ownership dieses Flags liegt jetzt hier; die Helfer
                                  // (showPasswordUnlockPanel / der Biometrie-Task) geben es
                                  // frei — NICHT erneut guard-en, sonst bailt der Helfer sofort.
        showLockIcon()

        // Touch ID ZUERST — und zwar VOR jedem Modal-Panel. `NSApp.runModal` pumpt die
        // Runloop im Modal-Mode, in dem weder `DispatchQueue.main` noch Swift-Concurrency
        // laufen; ein Touch-ID-Prompt aus dem Panel heraus bliebe hängen. Hier läuft der
        // async Keychain-Read in der normalen Runloop → der Systemprompt erscheint sofort.
        if BiometricStore.isAvailable && BiometricStore.hasSavedPassword {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let pw = try await BiometricStore.loadPassword(reason: "simplebanking entsperren")
                    self.isPromptingUnlock = false
                    self.completeUnlock(password: pw, setupBiometric: false)
                } catch {
                    // Biometrie abgebrochen/fehlgeschlagen → Passwort-Panel als Fallback,
                    // ohne erneuten (im Modal wirkungslosen) Touch-ID-Button. Flag bleibt
                    // gesetzt; showPasswordUnlockPanel gibt es via defer frei.
                    self.showPasswordUnlockPanel(suppressBiometricButton: true)
                }
            }
            return
        }

        // Keine gespeicherte Biometrie → direkt Passwort-Panel (bietet ggf. Enrollment an).
        showPasswordUnlockPanel(suppressBiometricButton: false)
    }

    /// Zeigt das Passwort-Entsperr-Panel (Modal). Getrennt von `promptUnlockIfNeeded`,
    /// damit der Touch-ID-Pfad davor async laufen kann. **Erwartet, dass der Aufrufer
    /// `isPromptingUnlock` bereits gesetzt hat** — gibt es hier via defer wieder frei.
    private func showPasswordUnlockPanel(suppressBiometricButton: Bool) {
        defer { isPromptingUnlock = false }
        guard locked else { return }

        // MasterPasswordPanel ist ein nonactivating .floating-Panel → wird Key ohne
        // App-Aktivierung (macOS 26 aktiviert Accessory-Apps nicht mehr).
        NSApp.activate(ignoringOtherApps: true)

        let panel = MasterPasswordPanel(isUnlock: true, suppressBiometricButton: suppressBiometricButton)
        let result = panel.runModalWithResult()

        switch result {
        case .password(let pw):
            completeUnlock(password: pw, setupBiometric: false)

        case .passwordSetupBiometric(let pw):
            // „Touch ID einrichten" geklickt → nach erfolgreichem Unlock direkt aktivieren.
            completeUnlock(password: pw, setupBiometric: true)

        case .reset:
            // Delete all credentials and reset app state
            performSecurityReset()

        case .cancelled:
            // User cancelled - stay locked
            locked = true
            showLockIcon()
        }
    }

    /// Verifiziert das Master-Passwort und entsperrt. `setupBiometric=true` (vom
    /// „Touch ID einrichten"-Button) aktiviert Touch ID direkt; sonst wird es nur
    /// einmalig angeboten.
    private func completeUnlock(password pw: String, setupBiometric: Bool) {
        do {
            if demoMode {
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
            failedAttempts = 0
            balancePopover?.performClose(nil)
            hideLockIcon()
            applyBalanceDisplayModeConstraints()

            if setupBiometric {
                // Nutzer hat „Touch ID einrichten" explizit geklickt → direkt aktivieren
                // (kein zusätzlicher Nachfrage-Alert). dismissed/Fehler regelt der Helfer.
                enableBiometric(password: pw)
            } else {
                // Touch ID einmalig anbieten nach manuellem Unlock
                offerBiometricEnrollmentIfNeeded(password: pw)
            }

            statusItem.button?.title = t("Lädt…", "Loading…")
            // Aus dem lokalen Cache rechnen, bevor der Netz-Refresh anläuft.
            recomputeLeftToPay()
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                await refreshAsync()
            }
        } catch {
            failedAttempts += 1
            if resetAttemptsLimit > 0 && failedAttempts >= resetAttemptsLimit {
                performSecurityReset()
                return
            }
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
            if let iconPath = Bundle.main.path(forResource: "app_icon", ofType: "png"),
               let icon = NSImage(contentsOfFile: iconPath) {
                alert.icon = icon
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
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
            enableBiometric(password: password)   // dismissed nur bei Erfolg, Fehler-Alert inklusive
        } else {
            biometricOfferDismissed = true
        }
    }

    /// Aktiviert Touch ID. `biometricOfferDismissed` wird NUR bei erfolgreichem Save
    /// gesetzt; schlägt das Speichern fehl, kommt eine kurze Meldung und das Angebot
    /// bleibt offen (dismissed=false).
    @discardableResult
    private func enableBiometric(password: String) -> Bool {
        do {
            try BiometricStore.save(password: password)
            biometricOfferDismissed = true
            return true
        } catch {
            AppLogger.log("Touch ID save failed: \(error.localizedDescription)", category: "Biometric", level: "WARN")
            let errorAlert = NSAlert()
            errorAlert.messageText = t("Touch ID konnte nicht aktiviert werden", "Touch ID could not be enabled")
            errorAlert.informativeText = t("Bitte versuche es erneut oder aktiviere Touch ID später in den Einstellungen unter „Sicherheit\".", "Please try again, or enable Touch ID later in Settings under \"Security\".")
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
            return false
        }
    }

    private func performSecurityReset() {
        // Delete all credentials, DB files, attachments (all slots)
        CredentialsStore.deleteAllData()
        BiometricStore.clear()
        BiometricStore.clearAutoUnlock()
        biometricOfferDismissed = false
        let allSlotIds = MultibankingStore.shared.slots.map { $0.id } + ["legacy"]

        // Reset UserDefaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        // NACH dem Domain-Wipe: Die Slot-Liste lebt zusätzlich im Speicher und schriebe
        // sich beim nächsten `save()` ungefragt zurück — das Konto wäre trotz
        // Zurücksetzen wieder da.
        MultibankingStore.shared.removeAllSlots()
        
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
        
        // Asynchrone Aufräumarbeiten — die Erfolgsmeldung kommt ERST danach, sonst
        // verspricht der Dialog etwas, das noch läuft.
        Task { @MainActor in
            for slotId in allSlotIds {
                await YaxiService.clearSessionData(forSlotId: slotId)
            }
            CredentialsStore.activeSlotId = "legacy"
            // Händler-Logins (REWE/dm/Amazon) liegen im geteilten WebKit-Store und
            // werden weder von deleteAllData() noch von removePersistentDomain erfasst.
            await MerchantSession.clearAll()

            let alert = NSAlert()
            alert.messageText = t("simplebanking wurde zurückgesetzt", "simplebanking has been reset")
            alert.informativeText = t("Alle Zugangsdaten und Einstellungen wurden gelöscht.",
                                      "All credentials and settings have been deleted.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
        // v1.5.0: 2 Modi.
        //   showBalanceInMenuBar = true  → Saldo permanent sichtbar, Click → kein Flyout.
        //   showBalanceInMenuBar = false → nur Bank-Icon, Click → Flyout-Karte.
        if showBalanceInMenuBar {
            return
        }
        showBalanceFlyout()
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
    /// Datum der jüngsten erkannten Gehalts-Gutschrift ≤ today. Nur EXPLIZITE
    /// Signale (SALA-Purpose oder GEHALT/LOHN im Verwendungszweck) — bewusst keine
    /// „größter Eingang"-Heuristik, die den Zyklus fälschlich verschieben könnte.
    /// Spiegelt die Signal-Logik aus `PaycheckRightZoneView.detectedIncome`.
    nonisolated private static func mostRecentSalaryArrival(
        in txs: [TransactionsResponse.Transaction], today: Date
    ) -> Date? {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: today)
        func txDate(_ tx: TransactionsResponse.Transaction) -> Date? {
            let d = tx.bookingDate ?? tx.valueDate ?? ""
            guard d.count >= 10 else { return nil }
            let parts = d.prefix(10).split(separator: "-")
            guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let day = Int(parts[2])
            else { return nil }
            return cal.date(from: DateComponents(year: y, month: m, day: day)).map { cal.startOfDay(for: $0) }
        }
        var best: Date? = nil
        for tx in txs {
            guard tx.parsedAmount > 0, let d = txDate(tx), d <= todayStart else { continue }
            guard isSalaryCredit(purposeCode: tx.purposeCode,
                                 remittance: (tx.remittanceInformation ?? []).joined(separator: " "),
                                 additional: tx.additionalInformation) else { continue }
            if best == nil || d > best! { best = d }
        }
        return best
    }

    /// Ist diese Gutschrift ein Gehaltseingang?
    ///
    /// **Warum das genau sein muss:** der erkannte Eingang verschiebt den Zyklusstart
    /// (`LeftToPayCalculator.cycleBounds`). Wird eine beliebige Gutschrift Mitte des
    /// Monats fälschlich als Gehalt gewertet, gelten alle davor bereits gebuchten
    /// Fixkosten wieder als „noch nicht in diesem Zyklus gebucht" — und „Noch offen"
    /// zählt sie ein zweites Mal.
    ///
    /// Vorher stand hier `rem.contains("LOHN")`: eine **LOHN**STEUER-ERSTATTUNG (eine
    /// Gutschrift, die viele einmal im Jahr bekommen) löste damit genau diesen Fehler
    /// aus. Auch `WordMatch.atWordStart` hilft hier nicht — „LOHNSTEUER" beginnt mit
    /// „LOHN". Deshalb:
    ///
    /// 1. `purposeCode == "SALA"` ist der ISO-Code für Gehalt und eindeutig — er
    ///    genügt allein und wird nicht durch Textregeln entwertet.
    /// 2. Textregeln greifen nur am Wortanfang (damit „GEHALTSZAHLUNG" zählt) und
    ///    nur, wenn kein Ausschlussbegriff vorkommt.
    ///
    /// Die Fehlerkosten sind bewusst asymmetrisch behandelt: ein **falsch positiver**
    /// Treffer verfälscht die angezeigte Zahl, ein **falsch negativer** fällt lediglich
    /// auf den in den Einstellungen konfigurierten Gehaltstag zurück — also auf das,
    /// was der Nutzer ohnehin angegeben hat. Im Zweifel lieber nicht erkennen.
    nonisolated static func isSalaryCredit(purposeCode: String?, remittance: String,
                                           additional: String?) -> Bool {
        if (purposeCode?.uppercased() ?? "") == "SALA" { return true }

        let text = (remittance + " " + (additional ?? "")).uppercased()
        // Keine Gehaltszahlungen, obwohl sie mit einem Gehaltswort beginnen.
        let exclusions = ["LOHNSTEUER", "LOHNERSATZ", "LOHNPFAEND", "LOHNPFÄND",
                          "GEHALTSPFAEND", "GEHALTSPFÄND", "KURZARBEITERGELD"]
        if exclusions.contains(where: { WordMatch.atWordStart(text, $0) }) { return false }

        return ["GEHALT", "LOHN", "BEZUEGE", "BEZÜGE", "SALAER", "SALÄR"]
            .contains { WordMatch.atWordStart(text, $0) }
    }

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
            var cycleEndForDisplay: Date? = nil   // gleicher Zyklus für die Untertitel-Anzeige

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
                    // Zyklusstart = nominaler Gehaltstag, ODER das TATSÄCHLICHE
                    // Gehalts-Eingangsdatum, falls das Gehalt diesen Monat real (auch
                    // früher) einging. Nur ein echter Geldeingang schaltet den Zyklus
                    // um — nicht schon das Toleranzfenster davor. Dadurch zählt z.B.
                    // das am 1. gezahlte Haushaltsgeld vor dem Gehalt (15.) korrekt
                    // als "diesen Zyklus erledigt" und fliegt aus "Noch offen".
                    let salaryArrival = Self.mostRecentSalaryArrival(in: history, today: Date())
                    let (cycS, cycE) = LeftToPayCalculator.cycleBounds(
                        salaryDay: cfg.effectiveSalaryDay,
                        today: Date(),
                        actualSalaryArrival: salaryArrival
                    )
                    AppLogger.log(
                        "leftToPay cycle slot=\(slot) salaryDay=\(cfg.effectiveSalaryDay) salaryArrival=\(salaryArrival.map { "\($0)" } ?? "none") cStart=\(cycS) cEnd=\(cycE)",
                        category: "LeftToPay"
                    )
                    if !isUnified { cycleEndForDisplay = cycE }   // Single-Slot: Datum für Untertitel
                    let counted = LeftToPayCalculator.countedPayments(
                        payments: payments,
                        cycleStart: cycS,
                        cycleEnd: cycE
                    )
                    // Diagnose: jeder Posten, der in "Noch offen" einfließt — damit
                    // sich eine zu hohe Summe nachvollziehen/zuordnen lässt.
                    for c in counted {
                        AppLogger.log(
                            "leftToPay item slot=\(slot) '\(c.merchant)' avg=\(String(format: "%.2f", c.averageAmount)) freq=\(c.frequency) last=\(c.lastDate) conf=\(String(format: "%.2f", c.confidence)) occ=\(c.occurrences) months=\(c.months)",
                            category: "LeftToPay"
                        )
                    }
                    total += counted.reduce(0) { $0 + $1.averageAmount }
                }
            }

            AppLogger.log(
                "leftToPay: demo=\(isDemo) multi=\(isMulti) unified=\(isUnified) activeIdx=\(activeIdx) sawAny=\(sawAny) total=\(String(format: "%.2f", total))",
                category: "LeftToPay"
            )
            await MainActor.run { [weak self] in
                self?.txVM.leftToPayAmount = sawAny ? total : nil
                self?.txVM.leftToPayCycleEnd = cycleEndForDisplay
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
            AppLogger.log("popoverWillClose qsOpen=\(flyoutQuickSendOpen)", category: "Flyout")
            flyoutClosedByClickAt = Date()
            flyoutQuickSendOpen = false
            removeFlyoutDetachMonitor()
        }
    }

    /// Solange der Quick-Send-Drawer offen ist, KEIN System-Dismiss zulassen
    /// (Klick außerhalb, App-Deaktivierung, auch performClose der Auto-Hide). Der
    /// User soll das Überweisungsformular in Ruhe ausfüllen können. Geschlossen
    /// wird dann gezielt: Drawer einklappen (Chevron) oder nach erfolgreichem
    /// Versand (onQuickSendSent setzt flyoutQuickSendOpen vorher auf false).
    nonisolated func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Früher: `!flyoutQuickSendOpen` — das Flyout ließ sich bei offenem
        // Schnellüberweisungs-Drawer gar nicht schließen (erst Drawer zu, dann Flyout).
        // Das war in der Praxis lästiger als der Schutz wert; ein halb ausgefülltes
        // Formular ist schnell neu getippt, SCA/Bestätigung liegen ohnehin dahinter.
        true
    }

    // MARK: - Flyout → Desktop-Widget (Drag-to-detach)

    /// Guard: verhindert Mehrfach-Präsentation während eines einzelnen Drags
    /// (AppKit pollt `popoverShouldDetach` wiederholt).
    private var pendingWidgetPresentation = false

    /// Der Nutzer zieht das Popover weg → Desktop-Widget. AppKit VOLLENDET
    /// natives Detach bei Statusbar-Popovers nicht (weder `popoverDidDetach` noch
    /// ein Detach-Fenster bleiben stehen — verifiziert per Logging). Deshalb
    /// unterbinden wir das native Detach (return false, damit AppKit auch kein
    /// eigenes Fenster baut) und nutzen den Aufruf nur als Signal, um das Widget
    /// SELBST als eigenständiges Fenster zu präsentieren.
    // Natives AppKit-Detach wird NICHT genutzt (bei Statusbar-Popovers unzuverlässig)
    // — stattdessen erkennt `flyoutDetachMonitor` einen Drag irgendwo auf dem Flyout.
    nonisolated func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    /// Installiert den Drag-Monitor, der das GANZE Flyout greifbar macht: ein
    /// Links-Drag > 6 px irgendwo im Popover-Fenster löst das Abdocken zum
    /// Desktop-Widget aus (reiner Klick bleibt Klick → Pillen/Buttons funktionieren).
    private func installFlyoutDetachMonitor() {
        removeFlyoutDetachMonitor()
        flyoutDetachStart = nil
        flyoutDetachMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged]
        ) { [weak self] event in
            guard let self else { return event }
            // NSEvent ist nicht Sendable → nur Sendable-Werte in die MainActor-Closure.
            let type = event.type
            let loc = NSEvent.mouseLocation
            var swallow = false
            MainActor.assumeIsolated {
                guard let popover = self.balancePopover, popover.isShown,
                      self.detachedFlyoutWindow == nil,
                      let popWindow = popover.contentViewController?.view.window,
                      popWindow.frame.contains(loc) else {
                    if type == .leftMouseDown { self.flyoutDetachStart = nil }
                    return
                }
                // Bei offenem Schnellüberweisungs-Drawer nur oberhalb davon abdocken:
                // im Formular ist ein Drag eine Text-Auswahl, kein Abdock-Wunsch.
                // Der Drawer sitzt am unteren Rand des Popovers.
                if self.flyoutQuickSendOpen,
                   loc.y < popWindow.frame.minY + QuickSendDrawerView.totalDrawerHeight {
                    if type == .leftMouseDown { self.flyoutDetachStart = nil }
                    return
                }
                switch type {
                case .leftMouseDown:
                    self.flyoutDetachStart = loc
                case .leftMouseDragged:
                    if let start = self.flyoutDetachStart, !self.pendingWidgetPresentation,
                       hypot(loc.x - start.x, loc.y - start.y) > 6 {
                        self.pendingWidgetPresentation = true
                        self.flyoutDetachStart = nil
                        self.removeFlyoutDetachMonitor()
                        self.balancePopover?.close()
                        self.showFlyoutWidget(at: loc, startDragTracking: true)
                        self.pendingWidgetPresentation = false
                        swallow = true   // kein Tap auf Pille/Button durchreichen
                    }
                default: break
                }
            }
            return swallow ? nil : event
        }
    }

    private func removeFlyoutDetachMonitor() {
        if let m = flyoutDetachMonitor { NSEvent.removeMonitor(m); flyoutDetachMonitor = nil }
        flyoutDetachStart = nil
    }

    /// Baut die randlose Fenster-Hülle für das Desktop-Widget — identisch zum
    /// zentrierten Hold-to-Show-Flyout (`showCenteredFlyout`), das die Karte
    /// pixelgenau ohne Fenster-Chrome rendert. Da WIR das Fenster präsentieren
    /// (kein AppKit-Detach), bleibt es dank `hidesOnDeactivate=false` sichtbar.
    private func makeFlyoutWidgetWindow(size: NSSize) -> FlyoutWidgetWindow {
        let window = FlyoutWidgetWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.level = flyoutWidgetStayOnTop ? .floating : .normal
        return window
    }

    /// Präsentiert das Flyout als eigenständiges Desktop-Widget an `dropPoint`
    /// (obere-linke Ecke, innerhalb der sichtbaren Bildschirmfläche gehalten).
    /// Frischer `buildFlyoutHost` als contentViewController → voll verdrahtet und
    /// von `refreshFlyoutIfVisible` live aktualisiert.
    private func showFlyoutWidget(at dropPoint: NSPoint, startDragTracking: Bool = false) {
        guard detachedFlyoutWindow == nil else { return }

        let result = buildFlyoutHost(onDoubleTap: { [weak self] in
            Task { await self?.openTransactionsPanel() }
        })
        result.host.sizingOptions = []
        // Widget-Kennung setzen: nur die freigestellte Karte bekommt den CRT-Effekt.
        var widgetRoot = result.host.rootView
        widgetRoot.isDetachedWidget = true
        result.host.rootView = widgetRoot
        let size = flyoutContentSize(hasDots: result.hasDots)
        let window = makeFlyoutWidgetWindow(size: size)

        // Container-View statt contentViewController: trägt Hover-Tracking (Icons +
        // Blur) und die Steuer-Icons. Der Host wird für den Live-Refresh separat in
        // `detachedFlyoutHost` gehalten.
        let container = FlyoutWidgetContainerView(frame: NSRect(origin: .zero, size: size))
        let hostView = result.host.view
        hostView.frame = container.bounds
        hostView.autoresizingMask = [.width, .height]
        // Gerundete Ecken + dezenter Rahmen am Host-Layer (wie Centered-Flyout).
        hostView.wantsLayer = true
        hostView.layer?.cornerRadius = 10
        hostView.layer?.masksToBounds = true
        hostView.layer?.borderWidth = 0.5
        hostView.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(hostView)

        // Steuer-Icons oben rechts (nur bei Hover sichtbar), oben-rechts verankert.
        let pin = makeWidgetIconButton(
            symbol: flyoutWidgetStayOnTop ? "pin.fill" : "pin",
            help: L10n.t("Immer im Vordergrund", "Always on top"),
            action: #selector(toggleFlyoutWidgetStayOnTop))
        let close = makeWidgetIconButton(
            symbol: "xmark",
            help: L10n.t("Schließen", "Close"),
            action: #selector(closeFlyoutWidget))
        let btnSize: CGFloat = 20, pad: CGFloat = 6, gap: CGFloat = 4
        close.frame = NSRect(x: size.width - pad - btnSize, y: size.height - pad - btnSize, width: btnSize, height: btnSize)
        pin.frame = NSRect(x: close.frame.minX - gap - btnSize, y: close.frame.minY, width: btnSize, height: btnSize)
        pin.autoresizingMask = [.minXMargin, .minYMargin]
        close.autoresizingMask = [.minXMargin, .minYMargin]
        pin.isHidden = true
        close.isHidden = true
        container.addSubview(pin)
        container.addSubview(close)
        widgetPinButton = pin
        widgetCloseButton = close

        container.onHoverChanged = { [weak self] hovering in self?.setWidgetHovered(hovering) }
        window.contentView = container
        detachedFlyoutHost = result.host
        window.contextMenuProvider = { [weak self] in
            self?.makeFlyoutWidgetMenu() ?? NSMenu()
        }

        // Position: Cursor horizontal mittig, knapp unter der Oberkante — so
        // „greift" der übergebene Drag das Fenster dort, wo die Maus schon ist.
        // Innerhalb der sichtbaren Fläche halten (Notch/Menubar/Dock ausgeschlossen).
        let screen = NSScreen.screens.first(where: { $0.frame.contains(dropPoint) }) ?? NSScreen.main
        var topLeft = NSPoint(x: dropPoint.x - size.width / 2, y: dropPoint.y + 20)
        if let visible = screen?.visibleFrame {
            let maxX = max(visible.minX, visible.maxX - size.width)
            let minY = visible.minY + size.height
            topLeft.x = min(max(topLeft.x, visible.minX), maxX)
            topLeft.y = min(max(topLeft.y, minY), visible.maxY)
        }
        window.setFrameTopLeftPoint(topLeft)

        detachedFlyoutWindow = window
        detachedFlyoutCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.cleanupDetachedFlyout() }
        }
        applyFlyoutWidgetLevel()
        window.makeKeyAndOrderFront(nil)
        // Anfangszustand aus tatsächlicher Cursor-Position ableiten (Tracking-Area
        // feuert kein mouseEntered, wenn die Maus beim Erzeugen schon drin ist).
        setWidgetHovered(window.frame.contains(NSEvent.mouseLocation))

        // Echtes Drag & Drop: solange die Maustaste noch gedrückt ist, das Fenster
        // dem Cursor folgen lassen bis losgelassen wird. `performDrag` funktioniert
        // nur während der Live-Verarbeitung eines mouseDown (nicht asynchron), daher
        // manuelles Tracking per Event-Monitor.
        if startDragTracking, NSEvent.pressedMouseButtons != 0 {
            startWidgetDragTracking(window: window)
        }
    }

    /// Manuelles Fenster-Dragging: verschiebt `window` mit dem Cursor bis zum
    /// nächsten mouseUp. Lokaler + globaler Monitor, damit das Ziehen auch über
    /// fremde Fenster/den Desktop hinweg funktioniert.
    private func startWidgetDragTracking(window: NSWindow) {
        stopWidgetDragTracking()
        let mouse = NSEvent.mouseLocation
        let origin = window.frame.origin
        let grab = NSSize(width: mouse.x - origin.x, height: mouse.y - origin.y)
        let move: () -> Void = { [weak window] in
            guard let window else { return }
            let m = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: m.x - grab.width, y: m.y - grab.height))
        }
        let localDrag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { e in move(); return e }
        let localUp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] e in
            self?.stopWidgetDragTracking(); return e
        }
        let globalDrag = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { _ in move() }
        let globalUp = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.stopWidgetDragTracking()
        }
        widgetDragMonitors = [localDrag, localUp, globalDrag, globalUp].compactMap { $0 }
    }

    private func stopWidgetDragTracking() {
        for m in widgetDragMonitors { NSEvent.removeMonitor(m) }
        widgetDragMonitors = []
    }

    /// Kontextmenü des Desktop-Widgets: Vordergrund-Toggle + Schließen.
    private func makeFlyoutWidgetMenu() -> NSMenu {
        let menu = NSMenu()
        let onTop = NSMenuItem(
            title: L10n.t("Immer im Vordergrund", "Always on top"),
            action: #selector(toggleFlyoutWidgetStayOnTop), keyEquivalent: "")
        onTop.target = self
        onTop.state = flyoutWidgetStayOnTop ? .on : .off
        menu.addItem(onTop)
        menu.addItem(.separator())
        let close = NSMenuItem(
            title: L10n.t("Schließen", "Close"),
            action: #selector(closeFlyoutWidget), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)
        return menu
    }

    /// Kleiner runder Icon-Button für die Widget-Steuerung (Pin / Schließen).
    private func makeWidgetIconButton(symbol: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.toolTip = help
        return button
    }

    /// Hover-Zustand: Steuer-Icons ein-/ausblenden + Kontostand-Maske schalten
    /// (im Ruhezustand — Maus NICHT über dem Widget — wird nur der Saldo durch
    /// `•••.•• €` ersetzt, damit er nicht lesbar ist; bei Hover echter Betrag).
    private func setWidgetHovered(_ hovering: Bool) {
        widgetPinButton?.isHidden = !hovering
        widgetCloseButton?.isHidden = !hovering
        widgetBalanceHidden = !hovering
        refreshFlyoutIfVisible()   // wendet die Maske im Widget-Zweig an
    }

    @objc private func toggleFlyoutWidgetStayOnTop() {
        flyoutWidgetStayOnTop.toggle()
        widgetPinButton?.image = NSImage(
            systemSymbolName: flyoutWidgetStayOnTop ? "pin.fill" : "pin",
            accessibilityDescription: L10n.t("Immer im Vordergrund", "Always on top"))
    }

    @objc private func closeFlyoutWidget() {
        detachedFlyoutWindow?.close()   // löst willClose → cleanupDetachedFlyout aus
    }

    private func cleanupDetachedFlyout() {
        stopWidgetDragTracking()
        if let obs = detachedFlyoutCloseObserver {
            NotificationCenter.default.removeObserver(obs)
            detachedFlyoutCloseObserver = nil
        }
        detachedFlyoutHost = nil
        widgetPinButton = nil
        widgetCloseButton = nil
        detachedFlyoutWindow = nil
    }

    // MARK: - Quick-Send (Flyout-Drawer)

    /// Ob der Quick-Send-Drawer im Flyout gerade aufgeklappt ist. Treibt die
    /// Popover-/Overlay-Höhe an allen drei Berechnungsstellen.
    private var flyoutQuickSendOpen = false

    /// Opt-in (`quickSendEnabled`) — Sichtbarkeit des Papierfliegers. Die Lizenz-
    /// Prüfung erfolgt wie in der Umsatzliste erst beim KLICK (Upsell), nicht über
    /// die Sichtbarkeit — siehe `quickSendFlyoutNeedsUnlock`.
    private var quickSendFlyoutAvailable: Bool {
        guard activeSlotSupportsTransfer else { return false }
        guard FeatureFlags.transferMoneyEnabled || demoMode else { return false }
        // Demo zeigt alle Features — Quick-Send ohne Labs-Toggle.
        if demoMode { return true }
        // Default an: nur ein explizit gesetztes `false` blendet den Papierflieger aus.
        return (UserDefaults.standard.object(forKey: "quickSendEnabled") as? Bool) ?? true
    }

    /// `true`, wenn simplesend noch nicht freigeschaltet ist → Klick auf den
    /// Papierflieger öffnet das UpsellSheet statt des Drawers (wie `sendMoney()`).
    private var quickSendFlyoutNeedsUnlock: Bool {
        guard !demoMode else { return false }
        return LicenseConfig.licensingEnabled && !LicenseManager.shared.isLicensed
    }

    /// Popover-/Overlay-Größe inkl. evtl. offenem Quick-Send-Drawer.
    private func flyoutContentSize(hasDots: Bool) -> NSSize {
        let base: CGFloat = hasDots ? 178 : 140
        let extra: CGFloat = flyoutQuickSendOpen ? QuickSendDrawerView.totalDrawerHeight : 0
        return NSSize(width: 348, height: base + extra)
    }

    /// Vom Drawer-Toggle gerufen — fährt die aktive Flyout-Präsentation hoch/runter.
    fileprivate func setFlyoutQuickSendOpen(_ open: Bool) {
        flyoutQuickSendOpen = open
        let hasDots = flyoutHasDots
        let size = flyoutContentSize(hasDots: hasDots)
        if let popover = balancePopover, popover.isShown {
            // Solange der Drawer offen ist, bleibt das Flyout offen+aktiv, damit man
            // das Formular in Ruhe ausfüllen kann — kein Auto-Dismiss bei Klick
            // außerhalb / App-Wechsel (.applicationDefined). Beim Zuklappen wieder
            // .semitransient, damit die reine Saldo-Karte normal verschwindet.
            popover.behavior = open ? .applicationDefined : .semitransient
            // EINZIGE Timeline: NSPopover animiert die contentSize-Änderung (animates
            // == true). Der SwiftUI-Inhalt ist statisch (Drawer immer voll gerendert,
            // oben verankert) — das Fenster wächst nach unten und gibt ihn frei.
            popover.contentSize = size
        }
        // App nach vorn holen, damit die Textfelder des Drawers sofort Tastaturfokus
        // bekommen (Menüleisten-App ist .accessory). Aktivierung in den NÄCHSTEN
        // Runloop verschieben: beim allerersten Flyout-Öffnen ist die App noch
        // inaktiv, und eine sofortige Aktivierung kollidiert mit dem laufenden
        // Klick-Event und verwirft das gerade gezeigte Popover. `behavior` ist hier
        // schon .applicationDefined, das Flyout bleibt also offen.
        if open {
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
        if let content = centeredFlyoutContentWindow {
            var frame = content.frame
            let delta = size.height - frame.size.height
            frame.size = size
            frame.origin.y -= delta   // oben verankert nach unten wachsen lassen
            content.animator().setFrame(frame, display: true)
        }
        if let widget = detachedFlyoutWindow {
            var frame = widget.frame
            let delta = size.height - frame.size.height
            frame.size = size
            frame.origin.y -= delta   // oben verankert nach unten wachsen lassen
            widget.animator().setFrame(frame, display: true)
        }
    }

    /// Baut Credentials (Demo: leer) und sendet über denselben Pfad wie
    /// `TransferSheet`. SCA wird vollständig in `YaxiService.sendTransfer`
    /// behandelt.
    fileprivate func performQuickSend(_ request: TransferRequest, sourceSlotId: String) async -> TransferOutcome {
        // Quellkonto-Kontext: das beim Review eingefrorene Konto muss noch das aktive sein —
        // sonst würde eine unter Konto A bestätigte Überweisung von Konto B ausgeführt.
        guard (MultibankingStore.shared.activeSlot?.id ?? "legacy") == sourceSlotId else {
            return TransferOutcome(
                ok: false, scaRequired: false, error: "slot-changed",
                userMessage: L10n.t("Quellkonto hat sich geändert — Überweisung abgebrochen.",
                                    "Source account changed — transfer cancelled."),
                mayHaveBeenExecuted: false)
        }
        // Saldo/Dispo erneut für das Quellkonto prüfen (nur bei bekanntem gecachten Saldo —
        // gleiche Hartgrenze wie TransferSheet, kein Fehl-Block bei unbekanntem Saldo).
        if let cached = UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(sourceSlotId)") as? Double {
            let dispo = Decimal(BankSlotSettingsStore.load(slotId: sourceSlotId).dispoLimit)
            if request.amountEUR > Decimal(cached) + dispo {
                return TransferOutcome(
                    ok: false, scaRequired: false, error: "limit",
                    userMessage: L10n.t("Betrag übersteigt den verfügbaren Rahmen (inkl. Dispo).",
                                        "Amount exceeds the available limit (incl. overdraft)."),
                    mayHaveBeenExecuted: false)
            }
        }
        let userId: String
        let password: String
        if demoMode {
            userId = ""
            password = ""
        } else {
            guard let pw = requestMasterPassword() else {
                return TransferOutcome(
                    ok: false, scaRequired: false, error: "locked",
                    userMessage: L10n.t("Bitte zuerst die App entsperren.",
                                        "Please unlock the app first."),
                    mayHaveBeenExecuted: false)
            }
            do {
                let creds = try CredentialsStore.load(masterPassword: pw)
                userId = creds.userId
                password = creds.password
            } catch {
                return TransferOutcome(
                    ok: false, scaRequired: false, error: "bad-password",
                    userMessage: L10n.t("Falsches Master-Passwort.", "Wrong master password."),
                    mayHaveBeenExecuted: false)
            }
        }
        do {
            return try await YaxiService.sendTransfer(request: request,
                                                      userId: userId,
                                                      password: password)
        } catch {
            return TransferOutcome(
                ok: false, scaRequired: false, error: error.localizedDescription,
                userMessage: error.localizedDescription, mayHaveBeenExecuted: false)
        }
    }

    /// Verdrahtet die Quick-Send-Closures auf einen frisch gebauten Flyout-RootView.
    /// Setzt die eBon-Flyout-Karte (Letzter Einkauf + Mini-Warenkorb), wenn der
    /// aktive Slot ein eBon-Slot (REWE/dm) ist. No-op sonst. An beiden rootView-Bau-
    /// Stellen aufgerufen (buildFlyoutHost + refreshFlyoutIfVisible).
    /// Setzt die PayPal-Untertitel-Daten (letzte Buchung + Monatsausgaben) auf den
    /// Flyout-Root. Nur für PayPal-Slots.
    private func applyPayPalFlyout(to rootView: inout StatusBalanceFlyoutCardView) {
        guard !txVM.isUnifiedMode,
              MultibankingStore.shared.activeSlot?.isPayPal == true else { return }
        rootView.isPayPalCard = true
        if let last = txVM.transactions.first {
            let amt = last.amount.flatMap { Double($0.amount) } ?? 0
            let name = (last.creditor?.name ?? last.debtor?.name ?? "").trimmingCharacters(in: .whitespaces)
            let amtStr = formatEURWithCents(abs(amt))
            rootView.paypalLastBooking = name.isEmpty ? amtStr : "\(amtStr) · \(name)"
        }
        let cal = Calendar.current, now = Date()
        let ym = String(format: "%04d-%02d", cal.component(.year, from: now), cal.component(.month, from: now))
        let spend = txVM.transactions
            .filter { ($0.bookingDate ?? "").hasPrefix(ym) }
            .compactMap { $0.amount.flatMap { Double($0.amount) } }
            .filter { $0 < 0 }
            .reduce(0, +)
        rootView.paypalMonthSpend = formatEURWithCents(abs(spend))
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "LLLL"
        rootView.paypalMonthLabel = f.string(from: now)
    }

    private func applyREWEFlyout(to rootView: inout StatusBalanceFlyoutCardView) {
        // Im Aggregat-Modus KEIN Händler-Layout (sonst blieben REWE-Farbe + Ring
        // stehen, obwohl „Alle Konten" aktiv ist).
        guard !txVM.isUnifiedMode,
              let active = MultibankingStore.shared.activeSlot, active.isReceiptSlot else { return }
        rootView.reweMode = true
        rootView.reweSource = active.source ?? .rewe
        rootView.reweBudgetEuro = BankSlotSettingsStore.load(slotId: active.id).merchantMonthlyBudget
        rootView.bankLogoImage = active.receiptLogoImage
        rootView.bankName = active.receiptBrandName
        rootView.reweNeedsLogin = Self.receiptNeedsLogin(active.id)

        let all = (try? ReweReceiptStore.all(slotId: active.id)) ?? []
        // Header-Uhrzeit = letzter Sync (fetchedAt des neuesten Bons).
        if let latestFetched = all.first?.fetchedAt {
            rootView.balanceFetchedAt = ISO8601DateFormatter().date(from: latestFetched)
        }
        // Einkäufe Monat/Jahr/Vorjahr (cancelled ausgenommen).
        let cal = Calendar.current
        let now = Date()
        let yearNum = cal.component(.year, from: now)
        let ym = String(format: "%04d-%02d", yearNum, cal.component(.month, from: now))
        let y = String(format: "%04d", yearNum)
        let ly = String(format: "%04d", yearNum - 1)
        rootView.reweMonthTotalCents = all.filter { !$0.cancelled && $0.timestamp.hasPrefix(ym) }.reduce(0) { $0 + $1.totalCents }
        rootView.reweYearTotalCents = all.filter { !$0.cancelled && $0.timestamp.hasPrefix(y) }.reduce(0) { $0 + $1.totalCents }
        let lastYearReceipts = all.filter { !$0.cancelled && $0.timestamp.hasPrefix(ly) }
        rootView.reweLastYearTotalCents = lastYearReceipts.reduce(0) { $0 + $1.totalCents }
        rootView.reweHasLastYear = !lastYearReceipts.isEmpty
        rootView.reweLastYearLabel = ly
        let monthFmt = DateFormatter()
        monthFmt.locale = Locale(identifier: "de_DE")
        monthFmt.dateFormat = "LLLL"
        rootView.reweMonthLabel = monthFmt.string(from: now)
        rootView.reweYearLabel = y
        // Kategorien-Ring: Top-4 des letzten Bons + dessen Datum.
        if let last = all.first {
            rootView.reweRingSegments = ReceiptCategoryRing.segments(forItems: last.items, source: active.source ?? .rewe)
            rootView.reweLastReceiptDate = ISO8601DateFormatter().date(from: last.timestamp)
                ?? parseReceiptDate(last.timestamp)
        }
    }

    /// Robustes Datum aus einem Bon-Timestamp (ISO oder „yyyy-MM-dd…").
    private func parseReceiptDate(_ ts: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(ts.prefix(10)))
    }

    private func applyQuickSendWiring(to rootView: inout StatusBalanceFlyoutCardView) {
        rootView.quickSendAvailable = quickSendFlyoutAvailable
        rootView.quickSendNeedsUnlock = quickSendFlyoutNeedsUnlock
        rootView.onQuickSendUpsell = { [weak self] in
            self?.balancePopover?.performClose(nil)
            self?.hideCenteredFlyout()
            self?.showUpsellSheet()
        }
        rootView.onQuickSendAddTemplate = { [weak self] in
            // Flyout schließen + Einstellungen am Konten-Tab öffnen und direkt zum
            // Vorlagen-Editor scrollen (nicht nur den Tab wählen).
            self?.balancePopover?.performClose(nil)
            self?.hideCenteredFlyout()
            UserDefaults.standard.set(1, forKey: "settingsLastTab")              // Konten
            UserDefaults.standard.set(true, forKey: "settingsScrollToQuickSend") // Backup für Erst-Öffnung
            self?.showSettings()
            // Notification für ein bereits offenes Settings-Fenster (onAppear feuert dort nicht).
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openQuickSendTemplates, object: nil)
            }
        }
        rootView.onQuickSendToggle = { [weak self] open in
            self?.setFlyoutQuickSendOpen(open)
        }
        rootView.quickSendPerform = { [weak self] request, sourceSlotId in
            await self?.performQuickSend(request, sourceSlotId: sourceSlotId)
                ?? TransferOutcome(ok: false, scaRequired: false, error: "unavailable",
                                   userMessage: nil, mayHaveBeenExecuted: false)
        }
        rootView.onQuickSendSent = { [weak self] in
            // Nach erfolgreichem Versand das Flyout schließen — leicht verzögert,
            // damit der eingeklappte Übergang noch sichtbar ist.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self?.balancePopover?.performClose(nil)
                self?.hideCenteredFlyout()
            }
        }
    }

    /// Wash-Farbe am oberen Kartenrand (dort wo der Popover-Pfeil ansetzt) für den
    /// aktuellen Slot — Money-Heat (Bank) bzw. Marken-Wash (Händler).
    private func currentFlyoutWashTopNSColor() -> NSColor {
        let dark = (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if let slot = MultibankingStore.shared.activeSlot, slot.isReceiptSlot {
            return NSColor(MerchantWash.colors(for: slot.source ?? .rewe).top)
        }
        let slotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        let cfg = BankSlotSettingsStore.load(slotId: slotId)
        let thresholds = BalanceSignal.normalizedThresholds(
            deepOverdraft: cfg.balanceSignalDeepOverdraftThreshold,
            low: cfg.balanceSignalLowUpperBound,
            medium: cfg.balanceSignalMediumUpperBound,
            veryGood: cfg.balanceSignalVeryGoodLowerBound)
        let level = BalanceSignal.classify(balance: lastBalance, thresholds: thresholds)
        let style = BalanceSignal.style(for: level)
        return NSColor(BalanceWash.colors(level: level, style: style, dark: dark).top)
    }

    /// Färbt die Popover-„Nase" (Pfeil) im Wash-Ton. AppKit bietet dafür keine
    /// offizielle API — best-effort über den Layer der privaten Rahmen-View
    /// (sicher: kein KVC, kein Crash-Risiko; wirkt nur, wenn die View einen Layer hat).
    /// Kennung der eingehängten Hintergrundfläche, damit sie beim Nachtönen
    /// wiedergefunden statt gestapelt wird.
    private static let flyoutArrowTintIdentifier = NSUserInterfaceItemIdentifier("flyoutArrowTint")

    /// Färbt die Sprechblase des Popovers — inklusive der Nase.
    ///
    /// Vorher stand hier `frameView.layer?.backgroundColor = …`, und genau das
    /// funktioniert nicht: Der Rahmen-View des Popovers zeichnet seinen eigenen
    /// Blasen-Hintergrund ÜBER sein Layer, weshalb nur die Nase weiß blieb — die
    /// Fläche darunter deckte ohnehin der SwiftUI-Inhalt ab, deshalb fiel es dort
    /// nicht auf.
    ///
    /// Stattdessen wird eine eigene Fläche als UNTERSTE Subview des Rahmen-Views
    /// eingehängt. Der Rahmen-View beschneidet seine Subviews auf die Blasenform,
    /// also bekommt die Nase die Farbe mit, ohne dass ein Rechteck entsteht.
    private func tintFlyoutPopoverArrow() {
        guard let window = balancePopover?.contentViewController?.view.window,
              let frameView = window.contentView?.superview else { return }

        let tint: NSView
        if let existing = frameView.subviews.first(where: { $0.identifier == Self.flyoutArrowTintIdentifier }) {
            tint = existing
        } else {
            let view = NSView(frame: frameView.bounds)
            view.identifier = Self.flyoutArrowTintIdentifier
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            frameView.addSubview(view, positioned: .below, relativeTo: nil)
            tint = view
        }
        tint.layer?.backgroundColor = currentFlyoutSurfaceNSColor().cgColor
    }

    /// Die Farbe, mit der die Flyout-Karte oben abschließt — bei aktivem Theme die
    /// flache Theme-Fläche, sonst der obere Money-Heat-Ton.
    ///
    /// Die frühere Fassung kannte nur den Money-Heat und hätte bei einem aktiven Theme
    /// eine Nase in fremder Farbe erzeugt.
    private func currentFlyoutSurfaceNSColor() -> NSColor {
        // Mit Wallpaper: die Durchschnittsfarbe der oberen Bildkante. In den Zipfel der
        // Sprechblase lässt sich kein Bild zeichnen — er wird flächig getönt. Nähme man
        // hier weiter die flache Theme-Farbe, stäche die Nase unter einem Wallpaper
        // heraus, so wie sie vor dieser Tönung weiß geblieben ist.
        if let kante = ThemeChrome.wallpaperTopEdgeColor { return kante }
        if ThemeManager.shared.currentTheme.isDefault == false {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ThemeManager.shared.currentTheme.surfaceColor(dark: dark)
        }
        return currentFlyoutWashTopNSColor()
    }

    private func showBalanceFlyout() {
        guard let button = statusItem?.button else { return }

        if balancePopover?.isShown == true {
            balancePopover?.performClose(nil)
            return
        }

        // Beim Öffnen des Flyouts den Aufrunden-/Sparmodus verlassen → normales
        // Saldo-Flyout statt der Roundup-Hero-Card.
        if RoundupViewState.shared.isActive {
            RoundupViewState.shared.deactivate()
        }

        let popover = balancePopover ?? NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self

        let result = buildFlyoutHost(onDoubleTap: { [weak self] in
            self?.balancePopover?.performClose(nil)
            Task { await self?.openTransactionsPanel() }
        })
        let host = result.host
        // WICHTIG: Größe wird über popover.contentSize gesteuert, NICHT über die
        // SwiftUI-Fitting-Size. Der SwiftUI-Root ist immer voll hoch (Card + Drawer)
        // und oben verankert (`maxHeight:.infinity, alignment:.top`); das Popover-
        // Fenster clippt den Überhang. Beim Aufklappen wächst NUR das Fenster nach
        // unten (NSPopover animiert) und gibt den bereits gezeichneten Drawer frei —
        // der Inhalt deckt das Fenster in JEDER Zwischengröße vollständig (oben
        // verankert), daher kein Zentrieren der Card und kein Freiliegen des roten
        // Host-Layers während der Animation.
        host.sizingOptions = []
        let hasDots = result.hasDots
        flyoutQuickSendOpen = false   // frisch geöffnetes Flyout startet eingeklappt
        popover.contentSize = flyoutContentSize(hasDots: hasDots)
        popover.contentViewController = host
        balancePopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Die App läuft als `.accessory` und ist beim Klick aufs Status-Item nicht
        // aktiv. Das Popover erscheint dann zwar, sein Fenster wird aber nicht zum
        // Key-Window — der erste Klick hinein aktiviert nur die App und erreicht das
        // Steuerelement darunter nicht. Genau das war das doppelte Klicken beim
        // Bankwechsel. Beide Aufrufer (Status-Item-Klick und Hotkey) sind ausdrückliche
        // Nutzeraktionen, das Aktivieren nimmt also niemandem ungefragt den Fokus.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        installFlyoutDetachMonitor()   // ganzes Flyout per Drag greifbar (#4)
        // Pfeil/Nase im Wash-Ton (nächster Runloop: Popover-Fenster existiert dann).
        DispatchQueue.main.async { [weak self] in self?.tintFlyoutPopoverArrow() }

        // "Noch offen" aus dem lokalen 90-Tage-Cache neu berechnen (kein Bank-Call) —
        // hält den Wert frisch und schreibt bei aktivem Logging die Posten-
        // Aufschlüsselung ins Log, auch ohne erfolgreichen Refresh.
        recomputeLeftToPay()

        // Pending Error-Report ggf. nachholen wenn der User das Flyout öffnet
        // (= User ist explizit in der App). Activation-Notification deckt
        // App-Re-Focus ab, aber wenn die App schon im Vordergrund war und der
        // User nur ans Statusbar-Icon klickt, gibt's keine Activation.
        ErrorReportStore.shared.flushIfPending()

        // If auto-hide is enabled, close the flyout after the same delay.
        let flyoutDelay: TimeInterval? = hideIndex == 1 ? 2 : hideIndex == 2 ? 5 : hideIndex == 3 ? 10 : hideIndex == 4 ? 20 : nil
        if let delay = flyoutDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.balancePopover?.isShown == true else { return }
                // Quick-Send-Drawer offen → Flyout offen lassen (Formular ausfüllen);
                // erst weiter prüfen, sobald er wieder zu ist.
                if self.flyoutQuickSendOpen || self.isFlyoutHovered {
                    self.deferFlyoutCloseUntilMouseLeaves()
                    return
                }
                self.balancePopover?.performClose(nil)
            }
        }
    }

    /// Verfügbarer Saldo für die Flyout-Sub-Zeile: gebuchter (bereits dispo-bereinigter) Saldo
    /// abzüglich vorgemerkter Lastschriften (ohne vorgemerkte Eingänge). Gibt `nil` zurück, wenn
    /// es keine vorgemerkten Lastschriften gibt (→ keine Sub-Zeile) oder im Unified-Mode
    /// (Currency-Mix wäre fachlich inkonsistent).
    private func computeFlyoutAvailableBalance(isUnified: Bool) -> Double? {
        guard !isUnified, let booked = lastBalance else { return nil }
        guard AvailableBalance.pendingDebitSum(txVM.transactions) < -0.005 else { return nil }
        return AvailableBalance.compute(adjustedBooked: booked, pendingTx: txVM.transactions)
    }

    /// Baut den Flyout-Host samt aller State-Injection. Wird vom Popover-
    /// und vom Centered-Hold-Pfad benutzt — `onDoubleTap` ist Caller-spezifisch
    /// (Popover closed via performClose, Centered via hideCenteredFlyout).
    private func buildFlyoutHost(onDoubleTap: @escaping () -> Void) -> (host: NSHostingController<StatusBalanceFlyoutCardView>, hasDots: Bool) {
        let isUnified = txVM.isUnifiedMode && (!demoMode || isMultiDemo)
            && MultibankingStore.shared.realSlotCount > 1
        let balanceText = isUnified
            ? (computeUnifiedFlyoutBalanceText() ?? "--,-- €")
            : (lastBalance.map(formatEURWithCents) ?? "--,-- €")
        let activeSlotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        let activeSlotCfg = BankSlotSettingsStore.load(slotId: activeSlotId)
        let thresholds = BalanceSignal.normalizedThresholds(
            deepOverdraft: activeSlotCfg.balanceSignalDeepOverdraftThreshold,
            low: activeSlotCfg.balanceSignalLowUpperBound,
            medium: activeSlotCfg.balanceSignalMediumUpperBound,
            veryGood: activeSlotCfg.balanceSignalVeryGoodLowerBound
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
        rootView.leftToPayCycleEnd = txVM.leftToPayCycleEnd
        let subMetricsSettings = BankSlotSettingsStore.load(
            slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy"
        )
        rootView.salaryDay = subMetricsSettings.effectiveSalaryDay
        rootView.salaryToleranceBefore = subMetricsSettings.salaryDayToleranceBefore
        rootView.salaryToleranceAfter = subMetricsSettings.salaryDayToleranceAfter
        rootView.onDoubleTap = onDoubleTap
        rootView.onHoverChanged = { [weak self] hovering in
            self?.isFlyoutHovered = hovering
        }
        if isUnified {
            rootView.unifiedSlots = computeFlyoutSlots()
            rootView.unifiedTotalBalance = computeUnifiedFlyoutTotal()
        } else {
            if demoMode && !isMultiDemo {
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
            if MultibankingStore.shared.activeSlot?.isPayPal == true {
                rootView.bankLogoImage = PayPalLogoAsset.image
                rootView.bankLogoBrandId = nil
                if (rootView.nickname ?? "").isEmpty { rootView.bankName = "PayPal" }
            }
        }
        applyREWEFlyout(to: &rootView)
        applyPayPalFlyout(to: &rootView)
        let rippleAlwaysOn = UserDefaults.standard.bool(forKey: "rippleAlwaysOn")
        let hasUnseenTx = latestTxSigBySlot.contains { slotId, sig in !sig.isEmpty && sig != lastSeenTxSig(for: slotId) }
        if rippleAlwaysOn || hasUnseenTx {
            // Bei jedem Öffnen frisch hochzählen, damit der Ripple zuverlässig neu feuert.
            flyoutRippleTrigger += 1
            rootView.rippleTrigger = flyoutRippleTrigger
        }
        if txVM.transactions.isEmpty {
            let slotSettings = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy")
            let daysToUse = slotSettings.displayDays
            if demoMode {
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
        rootView.availableBalance = computeFlyoutAvailableBalance(isUnified: isUnified)
        applyFlyoutDots(to: &rootView)
        applyQuickSendWiring(to: &rootView)
        let hasDots = flyoutHasDots
        let host = NSHostingController(rootView: rootView)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = BankTintProvider.currentTintNSColor()?.cgColor
            ?? NSColor.windowBackgroundColor.cgColor
        return (host, hasDots)
    }

    // MARK: - Centered Hold-to-Show Flyout

    /// Hard-Timeout falls das Hotkey-Released-Event verloren geht.
    private static let centeredFlyoutMaxHoldSeconds: TimeInterval = 30

    /// Window-Level für Content: ein Tick über dem Dim, damit die Z-Order
    /// nicht von der `orderFront`-Reihenfolge abhängt.
    private static let centeredFlyoutDimLevel = NSWindow.Level.popUpMenu
    private static let centeredFlyoutContentLevel = NSWindow.Level(
        rawValue: NSWindow.Level.popUpMenu.rawValue + 1
    )

    /// Sichtbarkeits-Sentinel — Quelle der Wahrheit ist das Content-Window,
    /// nicht die `flyoutHoldCenterEnabled`-Preference (die kann sich live ändern
    /// während das Overlay noch offen ist).
    fileprivate var isCenteredFlyoutVisible: Bool {
        centeredFlyoutContentWindow != nil || !centeredFlyoutDimWindows.isEmpty
    }

    /// Zeigt das Flyout zentriert auf dem Mauszeiger-Screen mit verdunkeltem
    /// Hintergrund auf ALLEN Screens. Wird vom Global-Hotkey gerufen wenn
    /// Setting `flyoutHoldCenterEnabled == true` ist. Re-Entry while open:
    /// no-op (Hotkey-Auto-Repeat).
    fileprivate func showCenteredFlyout() {
        guard !isCenteredFlyoutVisible, !centeredFlyoutAnimating else { return }
        balancePopover?.performClose(nil)                       // Modi exklusiv

        let primaryScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let primaryFrame = primaryScreen?.frame else { return }

        // Reduce-Transparency / Increase-Contrast respektieren — dichteres Dim
        // statt halbtransparenter Verdunklung.
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let targetDimAlpha: CGFloat = (reduceTransparency || increaseContrast) ? 0.85 : 0.62

        // Dim auf ALLEN Screens (Multi-Monitor — sonst bleibt der Rest hell).
        for screen in NSScreen.screens {
            let dim = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            dim.level = Self.centeredFlyoutDimLevel
            dim.backgroundColor = NSColor.black
            dim.isOpaque = false
            dim.hasShadow = false
            dim.ignoresMouseEvents = false
            dim.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            dim.isReleasedWhenClosed = false
            dim.alphaValue = 0    // wird im Fade hochanimiert
            let clickRecognizer = NSClickGestureRecognizer(
                target: self, action: #selector(centeredFlyoutDimClicked)
            )
            dim.contentView?.addGestureRecognizer(clickRecognizer)
            dim.setFrame(screen.frame, display: true)
            centeredFlyoutDimWindows.append(dim)
        }

        // Content
        let result = buildFlyoutHost(onDoubleTap: { [weak self] in
            self?.hideCenteredFlyout()
            Task { await self?.openTransactionsPanel() }
        })
        // Anders als beim Popover steuert hier das NSWindow die Größe selbst
        // (manuelles setFrame in setFlyoutQuickSendOpen) — preferredContentSize würde
        // das Auto-Resizing übernehmen und mit der Top-Verankerung kollidieren.
        result.host.sizingOptions = []
        let contentHeight: CGFloat = result.hasDots ? 178 : 140
        let contentWidth: CGFloat = 348
        let content = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        content.level = Self.centeredFlyoutContentLevel
        content.isOpaque = false
        content.backgroundColor = .clear
        content.hasShadow = true
        content.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        content.isReleasedWhenClosed = false
        content.contentViewController = result.host
        content.alphaValue = 0    // wird im Fade hochanimiert

        // NSPopover-ähnliche Optik: gerundete Ecken + dezenter Rahmen am
        // Host-Layer. `masksToBounds=true` clipped die SwiftUI-Inhalte sauber.
        // `wantsLayer` muss VORHER stehen — ohne Layer liefen die Zuweisungen
        // unten still ins Leere (der Widget-Pfad macht es korrekt).
        result.host.view.wantsLayer = true
        result.host.view.layer?.cornerRadius = 10
        result.host.view.layer?.masksToBounds = true
        result.host.view.layer?.borderWidth = 0.5
        result.host.view.layer?.borderColor = NSColor.separatorColor.cgColor

        // Innerhalb visibleFrame zentrieren — `visibleFrame` schließt Notch
        // und Menubar bereits aus, damit das Flyout nicht hinter dem Notch
        // landet wenn der Screen sehr klein ist (Stage Manager / 13"-MBP).
        let visible = primaryScreen?.visibleFrame ?? primaryFrame
        let cx = visible.midX - contentWidth / 2
        let cy = visible.midY - contentHeight / 2
        // Größe MIT setzen, nicht nur den Ursprung: `contentViewController` lässt das
        // Fenster seine Größe vom Hosting-Controller übernehmen, und der liefert wegen
        // `sizingOptions = []` und der `Color.clear`-Wurzel (kein Ideal-Maß) 0×0 — das
        // im `contentRect` gesetzte Maß wird dabei verworfen. Ergebnis war ein
        // sichtbares, deckendes, aber nulldimensionales Fenster: man sah nur das Dim.
        content.setFrame(
            NSRect(x: cx, y: cy, width: contentWidth, height: contentHeight),
            display: false
        )

        centeredFlyoutContentWindow = content
        for dim in centeredFlyoutDimWindows { dim.orderFront(nil) }
        content.orderFront(nil)

        // Fade-In: Dim auf targetDimAlpha, Content auf 1.0
        centeredFlyoutAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for dim in centeredFlyoutDimWindows {
                dim.animator().alphaValue = targetDimAlpha
            }
            content.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.centeredFlyoutAnimating = false
            }
        })

        installCenteredFlyoutObservers()
        installCenteredFlyoutBankCycleHotkeys()
        scheduleCenteredFlyoutWatchdog()
    }

    /// Schließt Dim + Content mit Fade-Out. Idempotent.
    fileprivate func hideCenteredFlyout() {
        guard isCenteredFlyoutVisible else { return }

        // Observer + Watchdog + Cycle-Hotkeys sofort entfernen — egal wie
        // wir hier reinkommen.
        removeCenteredFlyoutObservers()
        removeCenteredFlyoutBankCycleHotkeys()
        centeredFlyoutWatchdog?.cancel()
        centeredFlyoutWatchdog = nil

        let dimsToClose = centeredFlyoutDimWindows
        let contentToClose = centeredFlyoutContentWindow
        centeredFlyoutDimWindows = []
        centeredFlyoutContentWindow = nil

        centeredFlyoutAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for dim in dimsToClose { dim.animator().alphaValue = 0 }
            contentToClose?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                for dim in dimsToClose { dim.orderOut(nil) }
                contentToClose?.orderOut(nil)
                self?.centeredFlyoutAnimating = false
            }
        })
    }

    @objc private func centeredFlyoutDimClicked() {
        hideCenteredFlyout()
    }

    /// Schließt das Overlay, wenn die App den Fokus verliert (Cmd-Tab etc.).
    /// Sonst bleibt es als zombie-Layer über fremden Apps hängen.
    private func installCenteredFlyoutObservers() {
        removeCenteredFlyoutObservers()  // idempotent
        centeredFlyoutResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.hideCenteredFlyout() }
        }
    }

    private func removeCenteredFlyoutObservers() {
        if let obs = centeredFlyoutResignObserver {
            NotificationCenter.default.removeObserver(obs)
            centeredFlyoutResignObserver = nil
        }
    }

    /// Hard-Timeout — falls Released-Event verloren ging (Hotkey-Driver-Hänger,
    /// Cmd-Tab während gedrückt, …), schließt das Overlay nach 30s.
    private func scheduleCenteredFlyoutWatchdog() {
        centeredFlyoutWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.hideCenteredFlyout() }
        }
        centeredFlyoutWatchdog = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.centeredFlyoutMaxHoldSeconds,
            execute: item
        )
    }

    /// Registriert ←/→-Hotkeys mit denselben Modifiern wie der konfigurierte
    /// Flyout-Hotkey, solange das Centered-Overlay sichtbar ist. Nur wenn
    /// Multibanking eingerichtet ist (>1 Slot) — sonst kein Cycle nötig.
    /// Carbon-Hotkeys brauchen keine Accessibility-Permissions, im Gegensatz
    /// zu einem globalen NSEvent-Monitor.
    private func installCenteredFlyoutBankCycleHotkeys() {
        guard MultibankingStore.shared.slots.count > 1 else { return }
        let defaults = UserDefaults.standard
        let flyoutModifiers = defaults.integer(forKey: "globalHotkeyModifiers") > 0
            ? defaults.integer(forKey: "globalHotkeyModifiers") : 4352   // ⌃⌘
        // keyCodes: 123 = ←, 124 = →
        GlobalHotkeyManager.shared.register(keyCode: 123, carbonModifiers: flyoutModifiers, role: .cycleBankPrev)
        GlobalHotkeyManager.shared.register(keyCode: 124, carbonModifiers: flyoutModifiers, role: .cycleBankNext)
    }

    private func removeCenteredFlyoutBankCycleHotkeys() {
        GlobalHotkeyManager.shared.unregister(role: .cycleBankPrev)
        GlobalHotkeyManager.shared.unregister(role: .cycleBankNext)
    }

    /// Wechselt zur vorherigen (-1) oder nächsten (+1) Bank, wenn das
    /// Centered-Flyout offen ist und Multibanking eingerichtet ist.
    /// Wraps am Ende (modulo). No-op außerhalb des Centered-Modus.
    private func cycleCenteredFlyoutBank(direction: Int) {
        guard isCenteredFlyoutVisible else { return }
        let store = MultibankingStore.shared
        let count = store.slots.count
        guard count > 1 else { return }
        let next = ((store.activeIndex + direction) % count + count) % count
        txVM.unifiedModeEnabled = false
        Task { [weak self] in
            await self?.switchToSlot(index: next)
            await MainActor.run { self?.refreshFlyoutIfVisible() }
        }
        // Sofortiger Refresh — slots/dots-Indikator springt direkt, auch
        // bevor die Bank-Daten async geladen sind. Der zweite Refresh oben
        // aktualisiert dann den Balance-Text nach erfolgter Slot-Aktivierung.
        refreshFlyoutIfVisible()
    }

    /// Polls until the mouse leaves the flyout, then closes it.
    private func deferFlyoutCloseUntilMouseLeaves() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.balancePopover?.isShown == true else { return }
            // Solange der Quick-Send-Drawer offen ist (oder die Maus drin ist), nicht
            // schließen — weiter pollen, bis beides nicht mehr zutrifft.
            if self.flyoutQuickSendOpen || self.isFlyoutHovered {
                self.deferFlyoutCloseUntilMouseLeaves()
            } else {
                self.balancePopover?.performClose(nil)
            }
        }
    }

    /// Updates the flyout card in-place after a slot switch, without closing/reopening.
    /// Aktualisiert sowohl das Status-Item-Popover als auch das zentrierte
    /// Hold-Overlay, je nachdem was gerade sichtbar ist.
    private func refreshFlyoutIfVisible() {
        let popoverHost: NSHostingController<StatusBalanceFlyoutCardView>? = {
            guard let p = balancePopover, p.isShown else { return nil }
            return p.contentViewController as? NSHostingController<StatusBalanceFlyoutCardView>
        }()
        let centeredHost = centeredFlyoutContentWindow?.contentViewController
            as? NSHostingController<StatusBalanceFlyoutCardView>
        let widgetHost = detachedFlyoutHost
        guard popoverHost != nil || centeredHost != nil || widgetHost != nil else { return }
        let store = MultibankingStore.shared
        let idx = store.activeIndex
        let count = store.slots.count
        let isUnified = txVM.isUnifiedMode && (!demoMode || isMultiDemo)
            && MultibankingStore.shared.realSlotCount > 1
        let balanceText = isUnified
            ? (computeUnifiedFlyoutBalanceText() ?? "--,-- €")
            : (lastBalance.map(formatEURWithCents) ?? "--,-- €")
        let refreshSlotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        let refreshSlotCfg = BankSlotSettingsStore.load(slotId: refreshSlotId)
        let thresholds = BalanceSignal.normalizedThresholds(
            deepOverdraft: refreshSlotCfg.balanceSignalDeepOverdraftThreshold,
            low: refreshSlotCfg.balanceSignalLowUpperBound,
            medium: refreshSlotCfg.balanceSignalMediumUpperBound,
            veryGood: refreshSlotCfg.balanceSignalVeryGoodLowerBound
        )
        var rootView = StatusBalanceFlyoutCardView(
            balanceText: balanceText,
            balanceValue: lastBalance,
            thresholds: thresholds,
            isDefaultTheme: themeId == ThemeManager.defaultThemeID,
            forcedColorScheme: configuredColorScheme()
        )
        rootView.leftToPayAmount = txVM.leftToPayAmount
        rootView.leftToPayCycleEnd = txVM.leftToPayCycleEnd
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
            if MultibankingStore.shared.activeSlot?.isPayPal == true {
                rootView.bankLogoImage = PayPalLogoAsset.image
                rootView.bankLogoBrandId = nil
                if (rootView.nickname ?? "").isEmpty { rootView.bankName = "PayPal" }
            }
        }
        applyREWEFlyout(to: &rootView)
        applyPayPalFlyout(to: &rootView)
        rootView.rippleTrigger = flyoutRippleTrigger
        rootView.greenZoneFraction = computeGreenZoneFraction()
        rootView.dispoLimit = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").dispoLimit
        rootView.availableBalance = computeFlyoutAvailableBalance(isUnified: isUnified)
        applyFlyoutDots(to: &rootView)
        applyQuickSendWiring(to: &rootView)
        let hasDots = flyoutHasDots
        let newSize = flyoutContentSize(hasDots: hasDots)

        if let popover = balancePopover, popover.isShown {
            popover.contentSize = newSize
            tintFlyoutPopoverArrow()   // Pfeil-Ton bei Slot-/Wash-Wechsel aktualisieren
        }
        popoverHost?.rootView = rootView

        if let content = centeredFlyoutContentWindow, let centeredHost {
            // Re-Center bei Größenänderung — sonst springt das Window am
            // Ankerpunkt (0,0 origin) statt mittig.
            var frame = content.frame
            if frame.size != newSize,
               let screen = NSScreen.screens.first(where: {
                   $0.frame.intersects(frame)
               }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                frame.size = newSize
                frame.origin.x = visible.midX - newSize.width / 2
                frame.origin.y = visible.midY - newSize.height / 2
                content.setFrame(frame, display: true)
            }
            centeredHost.rootView = rootView
        }

        if let widget = detachedFlyoutWindow, let widgetHost {
            // Oben verankert nach unten wachsen lassen — Widget-Position beibehalten
            // (kein Re-Center wie beim zentrierten Flyout).
            if widget.frame.size != newSize {
                var frame = widget.frame
                let delta = newSize.height - frame.size.height
                frame.size = newSize
                frame.origin.y -= delta
                widget.setFrame(frame, display: true)
            }
            // Ruhezustand: nur den Kontostand maskieren (Wert-Semantik → betrifft
            // Popover/Centered oben nicht).
            var widgetView = rootView
            widgetView.balanceTextOverride = widgetBalanceHidden ? hiddenBalanceMaskTitle() : nil
            // Flag beim Live-Refresh erhalten — sonst verliert das Widget den
            // CRT-Effekt beim nächsten Daten-Update.
            widgetView.isDetachedWidget = true
            widgetHost.rootView = widgetView
        }
    }

    /// Kann vom aktiven Slot überwiesen werden? eBon-Slots (REWE/dm/Amazon) haben gar
    /// kein Konto, PayPal ist bei uns ein reiner Lese-Zugang (NVP: Saldo + Umsätze).
    /// Gilt für ALLE Sende-Einstiege: Flyout-Papierflieger, Umsatzlisten-Button und
    /// Menüeintrag — sonst öffnet man ein Überweisungsfenster für ein Konto, von dem
    /// gar nicht überwiesen werden kann.
    var activeSlotSupportsTransfer: Bool {
        guard let slot = MultibankingStore.shared.activeSlot else { return true }
        return !slot.isReceiptSlot && !slot.isPayPal
    }

    /// Blendet den Menüeintrag „Geld senden" passend zum aktiven Slot ein/aus. Das Menü
    /// wird nicht neu gebaut, daher muss der Eintrag bei jedem Slot-Wechsel nachgezogen
    /// werden (Tag 350).
    private func refreshSendMoneyMenuItem() {
        statusMenu?.item(withTag: 350)?.isHidden = !simplesendVisible || !activeSlotSupportsTransfer
    }

    /// EINZIGE Quelle für „das Flyout hat eine Footer-Zeile" (Konto-Pillen +
    /// Papierflieger). Host-Größe und View-Rendering MÜSSEN dieselbe Bedingung nutzen —
    /// sonst dimensioniert der Host das Popover kleiner als die View zeichnet und der
    /// Footer wird samt Senden-Button abgeschnitten (unterer Rand „fehlt").
    private var flyoutHasDots: Bool { MultibankingStore.shared.slots.count >= 1 }

    /// Populates dot-indicator data on a flyout rootView.
    private func applyFlyoutDots(to rootView: inout StatusBalanceFlyoutCardView) {
        let store = MultibankingStore.shared
        // Früher zusätzlich `(!demoMode || isMultiDemo)`: im Single-Bank-Demo blieb
        // `allSlots` dadurch nil → `hasDots` false → die komplette Footer-Zeile fehlte,
        // inklusive Papierflieger. Damit war Simplesend im Demo-Flyout unerreichbar.
        // Demo verhält sich jetzt wie eine echte Einzelbank (eine aktive Pille + Senden).
        guard store.slots.count >= 1 else { return }
        rootView.allSlots = computeFlyoutSlots()
        rootView.activeSlotIndex = store.activeIndex
        rootView.isUnifiedMode = txVM.isUnifiedMode
        rootView.canAggregate = store.realSlotCount > 1
        rootView.onSwitchToIndex = { [weak self] i in
            guard let self else { return }
            self.txVM.unifiedModeEnabled = false
            Task { await self.switchToSlot(index: i) }
        }
        rootView.onActivateUnified = { [weak self] in
            guard let self else { return }
            self.txVM.unifiedModeEnabled = true
            self.refreshFlyoutIfVisible()
            // @AppStorage-Propagation greift beim synchronen Rebuild manchmal noch
            // nicht → zweiter Refresh im nächsten Runloop, damit es beim ERSTEN Klick
            // wirkt (sonst brauchte es zwei Klicks).
            DispatchQueue.main.async { [weak self] in self?.refreshFlyoutIfVisible() }
        }
    }

    @objc private func showTransactions() {
        Task { await openTransactionsPanel() }
    }

    /// Refresht den Kontostand und triggert optional einen TX-Fetch.
    ///
    /// `suppressTransactionsFetch`: wenn true, wird der implizite TX-Fetch
    /// auch bei `loadTransactionsOnStart=true` übersprungen. Der Caller ist
    /// dann verantwortlich, selbst `checkNewBookings` aufzurufen. Wichtig
    /// für `refreshFromCLI()`, das den TX-Fetch sequentiell selbst macht —
    /// sonst rennen zwei TX-Fetches parallel gegen den HBCI-Mutex.
    private func refreshAsync(suppressTransactionsFetch: Bool = false) async {
        // eBon-Slot (REWE/dm): kein YAXI/HBCI. Anzeige kommt aus lokal gespeicherten Bons.
        if let active = MultibankingStore.shared.activeSlot, active.isReceiptSlot {
            applyREWEDisplay(slotId: active.id)
            return
        }
        // PayPal: eigener API-Provider (NVP), kein YAXI/HBCI. Echter Saldo + echte
        // Umsätze in die normale DB → normale Umsatzliste.
        if let active = MultibankingStore.shared.activeSlot, active.isPayPal {
            await refreshPayPal(slotId: active.id)
            return
        }
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
            // Cache mit demselben Wert füllen wie activateSingleDemo (beide aus `demoSeed`),
            // damit Anzeige und gecachter Saldo (→ Transfer-Hartgrenze) übereinstimmen.
            if let sid = MultibankingStore.shared.activeSlot?.id {
                UserDefaults.standard.set(fake, forKey: "simplebanking.cachedBalance.\(sid)")
            }
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
                // ziehen wir den Dispo ab. Primärer Auslöser ist der API-Flag
                // `creditLimitIncluded` aus der YAXI/Routex-Response; die per-Slot-Einstellung
                // bleibt als Override für Banken, die den Flag falsch oder gar nicht melden.
                let slotSettings = BankSlotSettingsStore.load(slotId: YaxiService.activeSlotId)
                let rawParsed = AmountParser.parse(booked.amount)
                let bankReportsIncluded = (booked.creditLimitIncluded == true)
                UserDefaults.standard.set(
                    bankReportsIncluded,
                    forKey: "simplebanking.bankReportsCreditLimitIncluded.\(YaxiService.activeSlotId)"
                )
                let adjustedBalance = BalanceAdjustment.computeAdjustedBalance(
                    raw: rawParsed,
                    apiFlag: booked.creditLimitIncluded,
                    userOverride: slotSettings.creditLimitIncluded,
                    dispoLimit: slotSettings.dispoLimit
                )
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
                // CLI-Refresh setzt suppressTransactionsFetch=true und macht den TX-Fetch
                // sequentiell selbst, sonst rennen zwei TX-Fetches parallel gegen den
                // HBCI-Mutex und einer endet als „bank busy".
                if loadTransactionsOnStart, !suppressTransactionsFetch {
                    Task { await checkNewBookings(userId: userId, password: password) }
                }

                recomputeLeftToPay()
                // Offenes Dashboard auch bei reinem Saldo-Refresh aktualisieren (Auto-
                // Umsatzabruf ist Default aus → sonst bliebe der Dashboard-Saldo veraltet).
                refreshDashboardIfOpen()
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
        // eBon-Slot (REWE/dm): dasselbe Umsatz-Panel (BalanceBar + Liste + Footer),
        // aber mit eBon-Balance-Card + Einkaufsliste (im Panel via receiptActive-
        // Zweig). Kein Bank-Fetch.
        if MultibankingStore.shared.activeSlot?.isReceiptSlot == true {
            // Händler-Slots brauchen keinen Bank-Unlock — einen evtl. stehen
            // gebliebenen „Unlock required"-Fehler eines vorher aktiven Bank-Slots
            // löschen, sonst erscheint er unter den Händler-Pillen.
            txVM.error = nil
            txPanel?.show()
            return
        }
        // PayPal: kein YAXI-Fetch. Panel zeigen, Umsätze aus der normalen DB laden
        // (die normale Liste rendert sie) und über den eigenen Provider refreshen.
        if let active = MultibankingStore.shared.activeSlot, active.isPayPal {
            txPanel?.show()
            let days = BankSlotSettingsStore.load(slotId: active.id).displayDays
            if let cached = try? TransactionsDatabase.loadTransactions(days: days), !cached.isEmpty {
                txVM.transactions = sortTransactionsNewestFirst(cached)
                txVM.resetPaging()
            }
            await refreshPayPal(slotId: active.id)
            return
        }
        let epochAtStart = slotEpoch
        txPanel?.show()
        // „Noch offen"/„verfügbar bis" aus dem lokalen 90-Tage-Cache berechnen —
        // wie beim Flyout. Ohne diesen Aufruf blieb die Zeile unter dem Kontostand
        // leer, bis irgendwann ein Netz-Refresh durchlief oder das Flyout geöffnet
        // wurde; wer direkt die Umsatzliste öffnete, sah gar nichts. Kein Bank-Call.
        recomputeLeftToPay()
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
        let daysToPreview = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").displayDays
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

        let slotSettings = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy")
        let fetchDaysSetting = slotSettings.fetchDays
        let daysToFetch = fetchDaysSetting > 0 ? fetchDaysSetting : 60
        // Auto-Sync bleibt bei `fetchDays` (90-Cap), aber die UI darf alles zeigen,
        // was nach einem Deep-Sync-Import in der DB liegt.
        let displayDays = max(daysToFetch, slotSettings.lastImportedDays ?? 0)
        // Do not force 365-day network sync on each panel open, because this can
        // repeatedly trigger SCA/TAN at some banks. Historical data remains in SQLite.
        let syncDays = daysToFetch
        let from = isoDateDaysAgo(syncDays)
        let to = Self.iso8601UTCFormatter.string(from: Date())

        txVM.fromDate = isoDateDaysAgo(displayDays)
        txVM.toDate = to

        var cachedTransactions: [TransactionsResponse.Transaction] = []
        var confettiTransactions: [TransactionsResponse.Transaction] = []
        do {
            cachedTransactions = try TransactionsDatabase.loadTransactions(days: displayDays)
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
            // Pull-to-Refresh und Panel-Open holen Balance UND Transactions, aber
            // strikt sequentiell. Parallel via `async let` würde zwei gleichzeitige
            // HBCI-Requests auf dieselbe Bank-Connection feuern — FinTS-Banken (Volksbank,
            // Genossenschaftsbanken, viele Sparkassen) sind dialog-orientiert und
            // antworten dann mit „Fehlender Dialogkontext". Genau aus diesem Grund
            // schützt `isHBCICallInFlight` (refreshAsync :2658-2675) andere Aufruf-
            // Pfade gegeneinander — innerhalb desselben Pfads müssen wir die Calls
            // ebenfalls serialisieren. Balance zuerst (ist schnell ~1-3s), Transactions
            // danach (~5-30s) — UX gefühlt gleich, weil der Saldo früh sichtbar wird.
            let balancesResp = try? await YaxiService.fetchBalances(userId: userId, password: password)
            guard slotEpoch == epochAtStart else {
                txVM.isLoading = false
                return
            }

            // Balance sofort anwenden — User sieht den frischen Saldo bevor Transactions
            // (langsamerer Call) zurückkommen. Selbe Logik wie in refreshAsync. Best-effort:
            // bei Fehler Balance einfach überspringen, Transaktionen-Anzeige bleibt davon
            // unberührt.
            if let bResp = balancesResp, bResp.ok, let booked = bResp.booked {
                let slotSettings = BankSlotSettingsStore.load(slotId: YaxiService.activeSlotId)
                let rawParsed = AmountParser.parse(booked.amount)
                let bankReportsIncluded = (booked.creditLimitIncluded == true)
                UserDefaults.standard.set(
                    bankReportsIncluded,
                    forKey: "simplebanking.bankReportsCreditLimitIncluded.\(YaxiService.activeSlotId)"
                )
                let adjustedBalance = BalanceAdjustment.computeAdjustedBalance(
                    raw: rawParsed,
                    apiFlag: booked.creditLimitIncluded,
                    userOverride: slotSettings.creditLimitIncluded,
                    dispoLimit: slotSettings.dispoLimit
                )
                let roundedNoDecimals = adjustedBalance.rounded()
                lastShownTitle = Self.eurWholeNumberFormatter.string(
                    from: NSNumber(value: roundedNoDecimals)
                ) ?? "0"
                lastBalance = adjustedBalance
                txVM.currentBalance = formatEURWithCents(lastBalance ?? 0)
                txVM.currentBalanceFetchedAt = Date()
                if !booked.currency.isEmpty {
                    if !demoMode {
                        MultibankingStore.shared.updateCurrency(booked.currency, forSlotId: YaxiService.activeSlotId)
                    }
                    txVM.connectedBankCurrency = booked.currency
                }
                if let balance = lastBalance {
                    UserDefaults.standard.set(balance, forKey: "simplebanking.cachedBalance.\(YaxiService.activeSlotId)")
                }
                applyBalanceDisplayModeConstraints()
                updateStatusBalanceTitle()
            }

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
                    let persistedTransactions = try TransactionsDatabase.loadTransactions(days: displayDays)
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
                // ERST HIER liegen die Buchungen in der DB. Die anderen
                // `recomputeLeftToPay()`-Aufrufe (Panel-Öffnen, Saldo-Refresh)
                // laufen alle VOR diesem Punkt und rechnen deshalb bei einer frisch
                // eingerichteten Bank noch gegen eine leere Historie → `nil` → die
                // Zeile unter dem Kontostand bleibt leer. Sichtbar wurde sie bis
                // hierher erst durch einen Bank-Wechsel, weil der als einziger
                // Pfad nach dem Befüllen neu rechnete.
                recomputeLeftToPay()
            } else {
                noteCredentialRejectionIfNeeded(resp.error ?? resp.userMessage)
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
            noteCredentialRejectionIfNeeded(Self.yaxiUserMessage(error) ?? error.localizedDescription)
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

        // Zugangsdaten-Ablehnung gewinnt über jede andere Meldung — auch über
        // „Offline, zeige gespeicherte Umsätze". Sonst sieht der Nutzer nur einen
        // harmlosen Offline-Hinweis, während im Hintergrund die Sperre droht.
        if txVM.errorNeedsCredentialUpdate {
            txVM.error = t(
                "Die Bank lehnt die gespeicherten Zugangsdaten ab. Automatischer Abruf gestoppt, damit die Bank den Zugang nicht sperrt.",
                "The bank rejected the stored credentials. Automatic refresh stopped so the bank does not lock your access."
            )
        }

        txVM.isLoading = false
        if !didTriggerInitialConfetti {
            maybeTriggerTransactionsConfetti(transactions: confettiTransactions, currentBalance: self.lastBalance)
        }

        // Offenes Dashboard mit dem frischen Snapshot (Saldo + Transaktionen) spiegeln —
        // sonst bleibt es nach einem normalen Refresh stale (kein Slot-Wechsel = kein apply).
        // Epoche ist hier valide (Guards bei 4200/4232).
        refreshDashboardIfOpen()

        // AI categorization — fire-and-forget, silent on error, reloads from DB when done.
        // Re-load nutzt `displayDays`, damit nach einem Deep-Sync-Import auch die kategorisierten
        // Transactions außerhalb der `fetchDays`-Range in der UI auftauchen.
        let pwForCategorization = pw
        let epochForCategorization = slotEpoch
        let daysForCategorization = displayDays
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
                        self.refreshDashboardIfOpen()
                    }
                }
            } else {
                if let updated = try? TransactionsDatabase.loadTransactions(days: daysForCategorization), !updated.isEmpty {
                    await MainActor.run {
                        guard self.slotEpoch == epochForCategorization else { return }
                        self.txVM.transactions = self.sortTransactionsNewestFirst(updated)
                        self.refreshDashboardIfOpen()
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
        txVM.rippleTrigger += 1
    }

    private func triggerInitialConfettiIfNeeded() -> Bool {
        guard !confettiInitialShown else { return false }
        confettiInitialShown = true
        txVM.rippleTrigger += 1
        return true
    }

    private func checkNewBookings(userId: String, password: String) async {
        // HBCI-Guard: parallel zu einem laufenden Bank-Dialog würde
        // YaxiService.fetchTransactions "Fehlender Dialogkontext" bei
        // Sparkasse/Volksbank auslösen. Beispiel-Trigger: `sb refresh` startet
        // refreshAsync (das wegen busy früh-returnt + retry queued) und ruft
        // dann uns hier — ohne diesen Guard würden wir den parallelen Call
        // trotzdem feuern. CLI bekommt outcome=failed, ehrlich.
        guard !isHBCICallInFlight else {
            AppLogger.log("checkNewBookings: HBCI call already in flight, skipping",
                          category: "Network", level: "WARN")
            recordCLIRefreshError("Refresh läuft bereits")
            return
        }
        isHBCICallInFlight = true
        defer { isHBCICallInFlight = false }

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

    /// Phase-3a-Beta: öffnet das REWE-Login-/Sync-Fenster. Legt NOCH KEINEN Slot
    /// an — speichert die Bons unter Test-Slot "rewe-beta", um den In-App-Sync
    /// zu verifizieren, ohne die bestehende Konto-UI zu berühren.
    @objc private func openREWEBeta() {
        DispatchQueue.main.async { [weak self] in
            let store = MultibankingStore.shared
            let slotId: String
            let createdNow: Bool
            if let existing = store.slots.first(where: { $0.isREWE }) {
                slotId = existing.id
                createdNow = false
            } else {
                let slot = BankSlot.makeREWE()
                // Nicht-aktiv + kein Aggregat-Zwang → kein destabilisierendes
                // Re-Render der aktiven Bank-Ansicht mitten in der Session.
                store.addSlot(slot, makeActive: false, autoUnified: false)
                slotId = slot.id
                createdNow = true
            }
            self?.presentREWELogin(slotId: slotId, removeIfNeverSynced: createdNow)
        }
    }

    /// Öffnet das REWE-Login-/Sync-Fenster (manuell angestoßen — kein Auto-Sync).
    /// Nach erfolgreichem Sync: Anzeige + Panel-Liste aktualisieren.
    /// `removeIfNeverSynced` gilt nur für einen Slot, den dieser Aufruf gerade erst
    /// angelegt hat: Bricht der Nutzer den Login ab, ohne dass je ein Sync gelang,
    /// verschwindet er wieder. Sonst bliebe ein Konto zurück, das nie eingerichtet
    /// wurde — gemeldet am 29.07., inklusive der Folge, dass es als einziges Konto
    /// nicht mehr löschbar war.
    private func presentREWELogin(slotId: String, removeIfNeverSynced: Bool = false) {
        REWEAuthWebView.present(slotId: slotId, onSynced: { [weak self] result in
            AppLogger.log("REWE sync: listed=\(result.listed) matched=\(result.matched) stored=\(result.stored)",
                          category: "REWE")
            if MultibankingStore.shared.activeSlot?.id == slotId {
                self?.applyREWEDisplay(slotId: slotId)
            }
            AppDelegate.setReceiptNeedsLogin(slotId, false)
            NotificationCenter.default.post(name: .reweReceiptsChanged, object: nil)
        }, onDismissed: { didSync in
            // Fenster zu, nie ein Sync gelungen und der Slot stammt aus genau diesem
            // Aufruf → wieder entfernen. `removeSlot` räumt Bons, Cookies und
            // per-Slot-Daten gleich mit ab.
            guard removeIfNeverSynced, !didSync else { return }
            AppLogger.log("Händler-Login abgebrochen — angelegten Slot wieder entfernt",
                          category: "Setup")
            MultibankingStore.shared.removeSlot(id: slotId)
        })
    }

    /// Phase-3a-Beta: öffnet das dm-Login-/Sync-Fenster (analog zu REWE). Legt
    /// einen dm-eBon-Slot an (nicht-aktiv, kein Aggregat-Zwang), falls keiner da ist.
    @objc private func openDMBeta() {
        DispatchQueue.main.async { [weak self] in
            let store = MultibankingStore.shared
            let slotId: String
            let createdNow: Bool
            if let existing = store.slots.first(where: { $0.isDM }) {
                slotId = existing.id
                createdNow = false
            } else {
                let slot = BankSlot.makeDM()
                store.addSlot(slot, makeActive: false, autoUnified: false)
                slotId = slot.id
                createdNow = true
            }
            self?.presentDMLogin(slotId: slotId, removeIfNeverSynced: createdNow)
        }
    }

    /// Öffnet das dm-Login-/Sync-Fenster (manuell angestoßen — kein Auto-Sync).
    /// `removeIfNeverSynced` gilt nur für einen Slot, den dieser Aufruf gerade erst
    /// angelegt hat: Bricht der Nutzer den Login ab, ohne dass je ein Sync gelang,
    /// verschwindet er wieder. Sonst bliebe ein Konto zurück, das nie eingerichtet
    /// wurde — gemeldet am 29.07., inklusive der Folge, dass es als einziges Konto
    /// nicht mehr löschbar war.
    private func presentDMLogin(slotId: String, removeIfNeverSynced: Bool = false) {
        DMAuthWebView.present(slotId: slotId, onSynced: { [weak self] result in
            AppLogger.log("dm sync: listed=\(result.listed) detailed=\(result.detailed) stored=\(result.stored)",
                          category: "DM")
            if MultibankingStore.shared.activeSlot?.id == slotId {
                self?.applyREWEDisplay(slotId: slotId)
            }
            AppDelegate.setReceiptNeedsLogin(slotId, false)
            NotificationCenter.default.post(name: .dmReceiptsChanged, object: nil)
            NotificationCenter.default.post(name: .reweReceiptsChanged, object: nil)
        }, onDismissed: { didSync in
            // Fenster zu, nie ein Sync gelungen und der Slot stammt aus genau diesem
            // Aufruf → wieder entfernen. `removeSlot` räumt Bons, Cookies und
            // per-Slot-Daten gleich mit ab.
            guard removeIfNeverSynced, !didSync else { return }
            AppLogger.log("Händler-Login abgebrochen — angelegten Slot wieder entfernt",
                          category: "Setup")
            MultibankingStore.shared.removeSlot(id: slotId)
        })
    }

    /// Phase-3a-Beta: öffnet das Amazon-Login-/Import-Fenster. Legt einen
    /// Amazon-Bestell-Slot an (nicht-aktiv, kein Aggregat-Zwang), falls keiner da ist.
    @objc private func openAmazonBeta() {
        DispatchQueue.main.async { [weak self] in
            let store = MultibankingStore.shared
            let slotId: String
            let createdNow: Bool
            if let existing = store.slots.first(where: { $0.isAmazon }) {
                slotId = existing.id
                createdNow = false
            } else {
                let slot = BankSlot.makeAmazon()
                store.addSlot(slot, makeActive: false, autoUnified: false)
                slotId = slot.id
                createdNow = true
            }
            self?.presentAmazonLogin(slotId: slotId, removeIfNeverSynced: createdNow)
        }
    }

    /// Öffnet das Amazon-Login-/Import-Fenster (manuell angestoßen — kein Auto-Sync).
    /// `removeIfNeverSynced` gilt nur für einen Slot, den dieser Aufruf gerade erst
    /// angelegt hat: Bricht der Nutzer den Login ab, ohne dass je ein Sync gelang,
    /// verschwindet er wieder. Sonst bliebe ein Konto zurück, das nie eingerichtet
    /// wurde — gemeldet am 29.07., inklusive der Folge, dass es als einziges Konto
    /// nicht mehr löschbar war.
    private func presentAmazonLogin(slotId: String, removeIfNeverSynced: Bool = false) {
        AmazonAuthWebView.present(slotId: slotId, onSynced: { [weak self] result in
            AppLogger.log("amazon sync: scraped=\(result.scraped) stored=\(result.stored)", category: "Amazon")
            if MultibankingStore.shared.activeSlot?.id == slotId {
                self?.applyREWEDisplay(slotId: slotId)
            }
            AppDelegate.setReceiptNeedsLogin(slotId, false)
            NotificationCenter.default.post(name: .reweReceiptsChanged, object: nil)
        }, onDismissed: { didSync in
            // Fenster zu, nie ein Sync gelungen und der Slot stammt aus genau diesem
            // Aufruf → wieder entfernen. `removeSlot` räumt Bons, Cookies und
            // per-Slot-Daten gleich mit ab.
            guard removeIfNeverSynced, !didSync else { return }
            AppLogger.log("Händler-Login abgebrochen — angelegten Slot wieder entfernt",
                          category: "Setup")
            MultibankingStore.shared.removeSlot(id: slotId)
        })
    }

    // MARK: - eBon Hintergrund-Sync (unsichtbar, gespeicherte Sitzung)

    /// Synchronisiert einen eBon-Slot zuerst **unsichtbar im Hintergrund** (offscreen
    /// WebView, gespeicherte Login-Sitzung). Schlägt das fehl (Login nötig/Timeout)
    /// und `allowWindow` ist true, wird das sichtbare Login-Fenster geöffnet.
    /// „Login fällig" pro eBon-Slot (Hintergrund-Sync scheiterte am abgelaufenen Login).
    static func receiptNeedsLogin(_ slotId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "simplebanking.receiptNeedsLogin.\(slotId)")
    }
    static func setReceiptNeedsLogin(_ slotId: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: "simplebanking.receiptNeedsLogin.\(slotId)")
        NotificationCenter.default.post(name: .reweReceiptsChanged, object: nil)
    }

    private func syncReceiptSlot(_ slot: BankSlot, allowWindow: Bool) {
        let slotId = slot.id
        let source = slot.source ?? .rewe
        // REWE: Cloudflare-Turnstile (Mensch-Prüfung) lässt sich headless NICHT lösen.
        // Hintergrund-Versuche verbrennen nur die cf_clearance → Turnstile käme dann
        // bei JEDEM Öffnen. Daher REWE ausschließlich im sichtbaren Fenster, und im
        // Hintergrund (allowWindow=false) gar nicht anfassen.
        if source == .rewe {
            if allowWindow { presentREWELogin(slotId: slotId) }
            return
        }
        let done: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            // „Login fällig"-Status festhalten: Hintergrund-Sync scheitert still, wenn
            // die gespeicherte Sitzung abgelaufen ist → eBon-Karte zeigt dann den Hinweis.
            Self.setReceiptNeedsLogin(slotId, !ok)
            if ok {
                if MultibankingStore.shared.activeSlot?.id == slotId { self.applyREWEDisplay(slotId: slotId) }
                NotificationCenter.default.post(name: .reweReceiptsChanged, object: nil)
            } else if allowWindow {
                switch source {
                case .amazon: self.presentAmazonLogin(slotId: slotId)
                case .dm: self.presentDMLogin(slotId: slotId)
                default: self.presentREWELogin(slotId: slotId)
                }
            }
        }
        switch source {
        case .amazon: AmazonAuthWebView.presentHeadless(slotId: slotId, onFinished: done)
        case .dm: DMAuthWebView.presentHeadless(slotId: slotId, onFinished: done)
        default: REWEAuthWebView.presentHeadless(slotId: slotId, onFinished: done)
        }
    }

    /// Beim App-Start: alle eBon-Slots still im Hintergrund aktualisieren —
    /// KEIN Fenster (auch nicht bei abgelaufenem Login; dann bleibt die alte Anzeige).
    func backgroundSyncReceiptSlots() {
        for slot in MultibankingStore.shared.slots where slot.isReceiptSlot {
            syncReceiptSlot(slot, allowWindow: false)
        }
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

    /// Zeigt nach einem Versions-Update einmalig kuratierte Highlights.
    /// - Wird NICHT bei Erst-Installation gezeigt (Onboarding handled das).
    /// - Wird NICHT gezeigt, wenn der User noch im Setup-Flow ist
    ///   (`autoStartSetupWizardIfNeeded` triggert oben — eines von beiden).
    /// - Setzt den Flag immer wenn die Sheet geöffnet wurde — kein erneutes
    ///   Erscheinen bei mid-flow-Cancel.
    private func showWhatsNewIfNeeded() {
        guard !demoMode else { return }
        let existingUser = CredentialsStore.exists()
        guard existingUser else { return }   // Erst-Installation → setup wizard übernimmt

        let willShowWhatsNew = WhatsNewTrigger.shouldShowOnLaunch(isExistingUser: existingUser)
            && WhatsNewTrigger.currentVersion() != nil

        // Launch-Settle-Delay analog zum Setup-Wizard, damit die Sheet
        // nicht mitten ins Status-Item-Setup fällt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if willShowWhatsNew, let version = WhatsNewTrigger.currentVersion() {
                WhatsNewTrigger.markShown()
                let panel = WhatsNewPanel(version: version)
                panel.runModal()
            }
            // Direkt nach (oder anstelle von) WhatsNew einmalig den
            // Launch-Voucher für „Geld senden" anbieten.
            self.showTransferVoucherIfNeeded(existingUser: existingUser)
            // Kauf-/Freischalt-Screen bei jedem Start (bis lizenziert oder abgehakt).
            self.showLicenseStartScreenIfNeeded()
        }
    }

    /// Zeigt den Kauf-/Freischalt-Screen beim Start — solange simplesend nicht
    /// freigeschaltet ist und der User „nicht mehr anzeigen" nicht gehakt hat.
    /// Nutzer mit bereits gespeichertem Lizenz-Key werden NICHT genervt (sie
    /// revalidieren async; `hasStoredLicenseKey` ist synchron true).
    private func showLicenseStartScreenIfNeeded() {
        guard !demoMode else { return }
        // Test-Schalter: `defaults write … forceLicenseStartScreen -bool YES` zeigt
        // den Screen unabhängig vom Lizenzstatus (zum Prüfen, ohne die Lizenz anzufassen).
        let force = UserDefaults.standard.bool(forKey: "forceLicenseStartScreen")
        // Zweiter Test-Schalter: erzwingt die APP-Aufruf-Variante (Link statt Checkbox).
        let forceAppCall = UserDefaults.standard.bool(forKey: "forceLicenseStartScreenAppCall")
        if !force && !forceAppCall {
            guard LicenseConfig.licensingEnabled else { return }
            guard !LicenseManager.shared.isLicensed else { return }
            guard !LicenseManager.shared.hasStoredLicenseKey else { return }
            guard !UserDefaults.standard.bool(forKey: "licenseScreen.dontShowAgain") else { return }
        }

        if let existing = licenseStartWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let screen = LicenseStartScreen(
            onClose: { [weak self] in
                self?.licenseStartWindow?.close()
                self?.licenseStartWindow = nil
            },
            showDontShowAgain: !forceAppCall,
            onEnterKey: forceAppCall ? { [weak self] in
                self?.licenseStartWindow?.close()
                self?.licenseStartWindow = nil
                UserDefaults.standard.set(5, forKey: "settingsLastTab")
                self?.showSettings()
            } : nil
        )
        let host = NSHostingController(rootView: screen)
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "simplesend"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 520))
        window.minSize = NSSize(width: 460, height: 520)
        window.maxSize = NSSize(width: 460, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        licenseStartWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Einmaliger Post-Update-Voucher fürs neue „Geld senden"-Modul.
    /// Bedingungen:
    ///  - Demo-Mode aus
    ///  - bestehende Installation (sonst übernimmt der Setup-Wizard
    ///    mit seinem regulären Upsell-Schritt)
    ///  - Licensing-System scharf, Feature sichtbar
    ///  - keine aktive Lizenz
    ///  - noch nie gezeigt
    /// Das „shown"-Flag wird BEVOR die Sheet öffnet gesetzt, damit ein
    /// schnelles Schließen / Abstürzen keine Wiederholung triggert.
    private func showTransferVoucherIfNeeded(existingUser: Bool) {
        guard !demoMode else { return }
        guard existingUser else { return }
        guard LicenseConfig.licensingEnabled else { return }
        guard FeatureFlags.transferMoneyEnabled else { return }
        guard !LicenseManager.shared.isLicensed else { return }
        // Race-Schutz: wenn ein Lizenz-Key bereits im Keychain liegt
        // (oder DEBUG-Masterode aktiv), zeigen wir den Voucher nicht.
        // `isLicensed` kann beim Launch noch false sein, weil die Polar-
        // Revalidation async läuft — `hasStoredLicenseKey` ist synchron.
        guard !LicenseManager.shared.hasStoredLicenseKey else { return }
        // Voucher-Aktion zeitlich begrenzt — nach dem Ablauf bleibt nur
        // das reguläre UpsellSheet, das beim Klick auf „Geld senden" kommt.
        guard LicenseConfig.isVoucherActive else { return }

        let shownKey = "simplebanking.transferVoucher.shown.v1"
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        UserDefaults.standard.set(true, forKey: shownKey)

        let sheet = TransferVoucherSheet(
            onClose: { [weak self] in
                self?.transferVoucherWindow?.close()
                self?.transferVoucherWindow = nil
            },
            onLater: { [weak self] in
                self?.transferVoucherWindow?.close()
                self?.transferVoucherWindow = nil
            }
        )
        let host = NSHostingController(rootView: sheet)
        let window = NSWindow(contentViewController: host)
        window.title = L10n.t("Neu: simplesend", "New: simplesend")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        transferVoucherWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func autoStartSetupWizardIfNeeded() {
        guard !didTriggerAutoSetupThisLaunch else { return }
        guard !demoMode else { return }
        // anyExists() statt exists(): ein aktiver REWE-Slot (ohne eigene Credentials)
        // darf die Ersteinrichtung nicht auslösen, wenn ein Bank-Slot eingerichtet ist.
        guard !CredentialsStore.anyExists() else { return }

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

        // Switch active slot in all data layers. SessionStore-Cache ist
        // per-slot lazy (Refactor 2026-05-19) — der nachfolgende refreshAsync
        // greift automatisch auf den richtigen Slot-State zu.
        SlotContext.activate(slotId: slot.id)
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
        let bootstrapDays = BankSlotSettingsStore.load(slotId: MultibankingStore.shared.activeSlot?.id ?? "legacy").displayDays
        if let cached = try? TransactionsDatabase.loadTransactions(days: bootstrapDays), !cached.isEmpty {
            txVM.transactions = sortTransactionsNewestFirst(cached)
            txVM.resetPaging()
        }

        // Offenes Dashboard sofort auf den neuen Slot umstellen (cached Snapshot).
        refreshDashboardIfOpen()

        // leftToPay-Subzeile sofort aus der DB-Historie neu berechnen, sonst zeigt
        // die Subzeile nach dem Switch nur das Icon, bis der Netz-Refresh durch ist.
        recomputeLeftToPay()

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

        // Offenes Dashboard mit den frischen Netzwerk-Daten des neuen Slots nachziehen.
        refreshDashboardIfOpen()

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
        // Kleiner Aktualisieren-Button für eBon-Slots: erst still im Hintergrund,
        // Fenster nur wenn ein Login nötig ist.
        nav.onReceiptRefresh = { [weak self] in
            guard let self, let slot = MultibankingStore.shared.activeSlot, slot.isReceiptSlot else { return }
            self.syncReceiptSlot(slot, allowWindow: true)
        }
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
        SlotContext.activate(slotId: newSlot.id)

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
                // Sync: connectionId + credModel-Keys SOFORT setzen, damit ein direkt
                // nachgelagerter Refresh nicht in „no connectionId yet" rennt.
                // Async-Teil (SessionStore connectionData + sessions) läuft danach im Task.
                YaxiService.copyConnectionStateKeys(fromSlotId: primarySlotId, toSlotId: extraSlotId)
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
            SlotContext.activate(slotId: newSlot.id)

            updateTxPanelAccountNav()
            applySlotToViewModel(finalSlot)   // uses name-first brand resolution (logo + name)
            statusItem.button?.toolTip = t("Verbunden mit \(bank.displayName)", "Connected to \(bank.displayName)")
            Task { await self.refreshAsync() }

        case .merchant(let source):
            // WICHTIG: den vor dem Wizard aktivierten leeren Bank-Slot NICHT aktiv
            // lassen — sonst hängt die App auf einem nie gespeicherten Slot-Kontext.
            SlotContext.activate(slotId: previousSlot?.id ?? "legacy")
            Self.rollBackSetupSlot(newSlot.id)
            connectMerchant(source)

        case .demoMode, .cancelled:
            // Vorherigen Slot wiederherstellen
            let restoreId = previousSlot?.id ?? "legacy"
            SlotContext.activate(slotId: restoreId)
            Self.rollBackSetupSlot(newSlot.id)
            if let prev = previousSlot {
                MultibankingStore.shared.setActive(index: MultibankingStore.shared.slots.firstIndex(where: { $0.id == prev.id }) ?? 0)
                applySlotToViewModel(prev)
            }
        }
    }

    /// Nimmt die vorläufige Slot-ID einer abgebrochenen Einrichtung zurück.
    ///
    /// „Konto hinzufügen" aktiviert die neue ID **vor** dem Assistenten, damit
    /// `performSetupConnection` alles unter den richtigen Schlüsseln ablegt. Bricht der
    /// Nutzer ab, wurde bisher nur der vorherige Slot wieder aktiviert — geschrieben
    /// waren aber schon connectionId, Bankname, Credential-Modell, YAXI-Session samt
    /// connectionData und je nach Fortschritt eine Credentials-Datei. Die blieben liegen,
    /// unsichtbar in der Kontenliste und damit für den Nutzer nicht löschbar.
    ///
    /// Bewusst nur in den **abschließenden** Zweigen des Assistenten: Ein einzelner
    /// fehlgeschlagener Verbindungsversuch lässt das Fenster offen, und der nächste
    /// Versuch arbeitet mit derselben ID weiter (im HVB-Protokoll gut zu sehen — der
    /// Kunde tippte neun Sekunden nach dem Fehler erneut auf „Verbinden"). Ein Aufräumen
    /// pro Versuch würde genau diesen Wiederholungsversuch zerstören.
    ///
    /// Ein Slot, der es in den Store geschafft hat, wird nie angefasst — dann war die
    /// Einrichtung erfolgreich und die ID gehört zu einem echten Konto.
    nonisolated private static func rollBackSetupSlot(_ slotId: String) {
        guard slotId != "legacy" else { return }
        MainActor.assumeIsolated {
            guard !MultibankingStore.shared.slots.contains(where: { $0.id == slotId }) else { return }
            AppLogger.log("Einrichtung abgebrochen — vorläufigen Slot \(slotId.prefix(8)) samt Verbindungsdaten entfernt",
                          category: "Setup")
            MultibankingStore.purgePerSlotData(slotId: slotId)
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
        SlotContext.activate(slotId: "legacy")

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
                    // Sync: connectionId + credModel-Keys SOFORT setzen, damit ein direkt
                    // nachgelagerter Refresh nicht in „no connectionId yet" rennt.
                    // Async-Teil (SessionStore connectionData + sessions) läuft danach im Task.
                    YaxiService.copyConnectionStateKeys(fromSlotId: "legacy", toSlotId: extraSlotId)
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
            // 5-Schritte-Folge-Wizard nach allererstem Bank-Connect (nur einmal).
            // Liegt absichtlich VOR promptAddAnotherAccount damit der User die
            // Settings vor dem evtl. nächsten Bank-Setup gesehen hat.
            runInitialSetupExtensionIfNeeded(slotId: "legacy")
            // After first-time setup: offer to add a second account
            promptAddAnotherAccount()
        case .merchant(let source):
            SlotContext.activate(slotId: "legacy")
            connectMerchant(source)
        case .demoMode:
            self.setDemoSingle()
        case .cancelled:
            break
        }
    }

    /// PayPal einrichten: API-Signatur-Zugangsdaten abfragen, Slot anlegen,
    /// verschlüsselt speichern und ersten Refresh auslösen.
    @objc private func openPayPalSetup() {
        guard let pw = masterPassword else {
            let a = NSAlert()
            a.messageText = L10n.t("App-Schutz nötig", "App protection required")
            a.informativeText = L10n.t(
                "Richte zuerst ein Bankkonto bzw. ein App-Passwort ein — dann können die PayPal-Zugangsdaten verschlüsselt gespeichert werden.",
                "Set up a bank account or app password first — then PayPal credentials can be stored encrypted.")
            a.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.t("PayPal verbinden", "Connect PayPal")
        alert.informativeText = L10n.t(
            "Erzeuge bei PayPal unter Kontoeinstellungen → API-Zugriff → NVP/SOAP → API-Signatur die drei Werte und trage sie hier ein.\n\n⚠️ Private PayPal-Konten nutzen eine veraltete Schnittstelle, die PayPal künftig abschalten kann.",
            "In PayPal under 'Account Settings → API access → NVP/SOAP → API signature' generate the three values and paste them here.\n\n⚠️ Personal PayPal accounts use a deprecated interface that PayPal may disable in the future.")
        alert.addButton(withTitle: L10n.t("Verbinden", "Connect"))
        alert.addButton(withTitle: L10n.t("Abbrechen", "Cancel"))
        // Dritter Button = Hilfe. Öffnet die FAQ, ohne den Dialog zu schließen (Schleife
        // unten) — die bereits eingegebenen Werte bleiben erhalten (gleiche Alert-Instanz).
        alert.addButton(withTitle: L10n.t("Wo bekomme ich das?", "Where do I get this?"))

        func mkLabel(_ s: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 10); l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 0, y: y, width: 340, height: 13)
            return l
        }
        let userField = NSTextField(frame: NSRect(x: 0, y: 92, width: 340, height: 22))
        let pwdField = NSSecureTextField(frame: NSRect(x: 0, y: 44, width: 340, height: 22))
        let sigField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        // Container endet direkt über dem obersten Label — die frühere Sandbox-Checkbox
        // ist entfernt (PayPal-Zugänge sind produktiv).
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 130))
        container.addSubview(mkLabel("API Username", y: 114)); container.addSubview(userField)
        container.addSubview(mkLabel("API Password", y: 66)); container.addSubview(pwdField)
        container.addSubview(mkLabel("API Signature", y: 22)); container.addSubview(sigField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = userField

        var resp = alert.runModal()
        while resp == .alertThirdButtonReturn {
            if let url = URL(string: "https://www.simplebanking.de/paypalapi") {
                NSWorkspace.shared.open(url)
            }
            resp = alert.runModal()
        }
        guard resp == .alertFirstButtonReturn else { return }
        // Robust gegen Copy-&-Paste-Artefakte: ALLE Whitespaces/Zeilenumbrüche
        // entfernen (API-Zugangsdaten enthalten nie Leerzeichen).
        func clean(_ s: String) -> String { s.components(separatedBy: .whitespacesAndNewlines).joined() }
        let user = clean(userField.stringValue)
        let pwd = clean(pwdField.stringValue)
        let sig = clean(sigField.stringValue)
        guard !user.isEmpty, !pwd.isEmpty, !sig.isEmpty else { return }

        let slot = BankSlot.makePayPal()
        MultibankingStore.shared.addSlot(slot, makeActive: true, autoUnified: false)
        SlotContext.activate(slotId: slot.id)

        var creds = (try? CredentialsStore.load(masterPassword: pw))
            ?? StoredCredentials(iban: "", userId: "", password: "")
        creds.paypalUser = user; creds.paypalPwd = pwd; creds.paypalSignature = sig
        do { try CredentialsStore.save(creds, masterPassword: pw) }
        catch { AppLogger.log("PayPal-Credentials speichern fehlgeschlagen: \(error)", category: "PayPal", level: "WARN") }

        Task { await refreshPayPal(slotId: slot.id) }
    }

    /// Öffnet das Login-/Sync-Fenster für einen im „Konto hinzufügen"-Dialog
    /// gewählten Händler (legt den Slot wie die früheren Beta-Menüpunkte an).
    private func connectMerchant(_ source: SlotSource) {
        switch source {
        case .rewe:   openREWEBeta()
        case .dm:     openDMBeta()
        case .amazon: openAmazonBeta()
        case .paypal: openPayPalSetup()
        case .yaxi:   break
        }
    }
    
    /// Zeigt nach dem allerersten Bank-Connect einen 5-Schritte-Folge-Wizard
    /// (Gehaltstag, Dispo, App-Schutz, Dock-Mode, MCP). Wird nur einmal
    /// gezeigt — Flag wird BEVOR die Sheet öffnet gesetzt damit der User
    /// nicht genervt wird wenn er die Sheet schließt ohne durchzulaufen.
    /// Add-Account-Pfad ruft diese Funktion nicht auf (separater Branch).
    private func runInitialSetupExtensionIfNeeded(slotId: String) {
        let key = "simplebanking.initialWizardCompleted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let panel = InitialSetupExtensionPanel(
            slotId: slotId,
            requestMasterPassword: { [weak self] in self?.requestMasterPassword() }
        )
        panel.runModal()
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

    /// Notbremse gegen die Konto-Sperre: lehnt die Bank die gespeicherten
    /// Zugangsdaten ab, wird der automatische Abruf für diesen Slot gestoppt.
    /// Ein Timer, der im Minutentakt dieselbe falsche PIN schickt, führt sonst
    /// binnen weniger Versuche zur Sperrung des Online-Bankings.
    private func noteCredentialRejectionIfNeeded(_ message: String?) {
        guard let message, Self.isLikelyCredentialError(message) else { return }
        let slotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        txVM.errorNeedsCredentialUpdate = true
        guard !credentialsRejectedSlotIds.contains(slotId) else { return }
        credentialsRejectedSlotIds.insert(slotId)
        timer?.invalidate()
        timer = nil
        AppLogger.log(
            "Zugangsdaten abgelehnt für Slot \(slotId.prefix(8)) — Auto-Refresh gestoppt (Sperrschutz)",
            category: "Auth", level: "WARN"
        )
    }

    /// Hebt den Sperrschutz auf, sobald neue Zugangsdaten hinterlegt wurden.
    private func clearCredentialRejection(slotId: String) {
        guard credentialsRejectedSlotIds.remove(slotId) != nil else { return }
        txVM.errorNeedsCredentialUpdate = false
        setupRefreshTimer()
    }

    /// Deutet die Fehlermeldung der Bank auf falsche Zugangsdaten hin?
    ///
    /// Kurze bzw. mehrdeutige Tokens werden nur als ganzes Wort geprüft: „pin"
    /// steckt sonst in „mapping"/„shipping", „wrong" in Sätzen ohne Auth-Bezug.
    /// Seit dem Sperrschutz hat ein Fehlalarm Folgen — er stoppt den Auto-Sync.
    /// Die langen, eindeutigen Begriffe dürfen weiterhin auch in Komposita
    /// treffen („Passwort" in „Passwortfehler", „Legitimations…").
    nonisolated static func isLikelyCredentialError(_ message: String) -> Bool {
        let text = message.lowercased()
        if WordMatch.containsAnyWord(text, ["pin", "wrong", "unauthorized", "credentials"]) {
            return true
        }
        return text.contains("passwort") ||
            text.contains("password") ||
            text.contains("anmeldename") ||
            text.contains("legitimations") ||
            text.contains("zugangsdaten")
    }

    /// `succeeded` entscheidet, ob ein zurückgekehrter Wert auch ein Erfolg ist.
    /// Ein Schritt kann ohne Fehler zurückkehren und trotzdem gescheitert sein —
    /// `fetchBalances` liefert dafür `ok == false`, und die Prüfung darauf steht erst
    /// hinter diesem Aufruf. Die Diagnosedatei meldete deshalb „success" für genau den
    /// Schritt, an dem die Einrichtung starb (HypoVereinsbank, 29.07.). Ohne Angabe
    /// bleibt es beim bisherigen Verhalten: zurückgekehrt heißt gelungen.
    nonisolated private static func runSetupStepWithTimeout<T: Sendable>(
        step: String,
        timeout: TimeInterval = 60,
        logger: SetupDiagnosticsLogger?,
        succeeded: @escaping @Sendable (T) -> Bool = { _ in true },
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

                do {
                    guard let result = try await group.next() else {
                        throw SetupFlowError.authenticationFailed("Einrichtung wurde unterbrochen.")
                    }
                    group.cancelAll()
                    while let _ = try? await group.next() {}
                    return result
                } catch {
                    group.cancelAll()
                    while let _ = try? await group.next() {}
                    // Parent-Cancellation (z.B. Setup-Fenster/Sheet geschlossen):
                    // sauber als CancellationError werfen — NICHT als Step-Fehler,
                    // sonst maskiert der Timeout-Sleep das echte Ergebnis und es
                    // landet als „Verbindungsprüfung fehlgeschlagen" beim User.
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    throw error
                }
            }
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger?.log(step: step,
                        event: succeeded(value) ? "success" : "failure",
                        details: ["duration_ms": String(durationMs)])
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

        // SCA-Methode an die Fortschritts-UI durchreichen: `handleSCA` (tief in
        // YaxiService, ohne Zugriff auf `options`) meldet field vs. decoupled, wir
        // übersetzen das in den passenden Setup-Text. Nach dem Connect wieder lösen.
        let onProgress = options.onProgress
        YaxiService.scaMethodReporter = { hint in
            onProgress?(hint == .fieldInput ? .enteringCode : .requestingApproval)
        }
        defer { YaxiService.scaMethodReporter = nil }

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

            // Step 1: accounts() — löst die SCA aus. Methode (Tipp-TAN vs. Push-Freigabe)
            // ist hier noch unbekannt → neutraler Text; `handleSCA` meldet via
            // `scaMethodReporter` den Typ, sobald er feststeht (.enteringCode/.requestingApproval).
            // Liefert IBAN + connectionData für alle weiteren Aufrufe (recurring consent).
            // Redirect-Flows (z.B. Sparkasse): Nutzer muss sich auf Bank-Website einloggen
            // und SCA bestätigen. Server pollt bis zu 600 s — Swift-Timeout muss größer sein.
            options.onProgress?(.authenticating)
            AppLogger.log("Setup step warmup_accounts", category: "Setup")
            let discoveredAccounts = try await runSetupStepWithTimeout(step: "warmup_accounts", timeout: 720, logger: diagnosticsLogger) {
                try await YaxiService.fetchAccounts(
                    userId: result.userId, password: result.password,
                    callSource: .setupWarmup
                )
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
            let warmupBalances = try await runSetupStepWithTimeout(step: "warmup_balances", timeout: 300, logger: diagnosticsLogger,
                                                                      succeeded: { $0.ok }) {
                try await YaxiService.fetchBalances(
                    userId: result.userId,
                    password: result.password,
                    callSource: .setupWarmup
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
            var warmupTransactions = try await runSetupStepWithTimeout(step: "warmup_transactions", timeout: 720, logger: diagnosticsLogger,
                                                                          succeeded: { $0.ok == true }) {
                try await YaxiService.fetchTransactions(
                    userId: result.userId,
                    password: result.password,
                    from: warmupFrom,
                    callSource: .setupWarmup
                )
            }

            if !(warmupTransactions.ok ?? false) {
                try await runSetupStepWithTimeout(step: "clear_session_retry", logger: diagnosticsLogger) {
                    // Nur Sessions löschen, connectionData behalten:
                    // Ohne connectionData kennt die Bank das Gerät nicht und schickt
                    // keinen Push-TAN – sie fällt auf interaktive TAN zurück.
                    await YaxiService.clearSessionsKeepingConnectionData()
                }
                _ = try await runSetupStepWithTimeout(step: "warmup_balances_retry", timeout: 720, logger: diagnosticsLogger,
                                                                 succeeded: { $0.ok }) {
                    try await YaxiService.fetchBalances(
                        userId: result.userId, password: result.password,
                        callSource: .setupWarmup
                    )
                }
                warmupTransactions = try await runSetupStepWithTimeout(step: "warmup_transactions_retry", timeout: 720, logger: diagnosticsLogger,
                                                                     succeeded: { $0.ok == true }) {
                    try await YaxiService.fetchTransactions(
                        userId: result.userId,
                        password: result.password,
                        from: warmupFrom,
                        callSource: .setupWarmup
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
        } catch is CancellationError {
            // Abbruch (Fenster/Sheet geschlossen) ist KEIN Fehler → roh weiterreichen,
            // damit SetupFlowPanels `catch is CancellationError` es still behandelt
            // (statt „Verbindungsprüfung fehlgeschlagen: …CancellationError").
            AppLogger.log("Setup performSetupConnection cancelled", category: "Setup")
            diagnosticsLogger?.finish(success: false, error: "cancelled")
            throw CancellationError()
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
            "Die Verbindung zur Bank wird zurückgesetzt. Beim nächsten Abruf musst Du Dich erneut mit TAN/PIN identifizieren. Kontodaten, IBAN und Einstellungen bleiben erhalten.\n\nHat sich Dein Online-Banking-Passwort geändert, wähle „Zugangsdaten ändern“ — sonst meldet sich die App weiter mit dem alten Passwort an und die Bank sperrt den Zugang.",
            "The connection to the bank will be reset. You'll need to re-authenticate with TAN/PIN on the next refresh. Account data, IBAN, and settings will be preserved.\n\nIf your online banking password changed, choose “Change credentials” — otherwise the app keeps signing in with the old password and the bank will lock your access."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("Zugangsdaten ändern", "Change credentials"))
        alert.addButton(withTitle: t("Abbrechen", "Cancel"))
        alert.addButton(withTitle: t("Nur Verbindung zurücksetzen", "Only reset connection"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            changeBankCredentials()
        case .alertThirdButtonReturn:
            resetBankConnection()
        default:
            return
        }
    }

    /// Setzt nur die Session/Freigabe zurück (unveränderte Zugangsdaten).
    private func resetBankConnection() {
        let slotId = YaxiService.activeSlotId
        Task { @MainActor [weak self] in
            await YaxiService.sessionStore.clearAll(slotId: slotId)
            AppLogger.log("reconnectBank: cleared sessions + connectionData for slot \(slotId.prefix(8))", category: "Support")
            self?.refresh()
        }
    }

    /// Hinterlegt neue Online-Banking-Zugangsdaten für den aktiven Slot.
    ///
    /// Vorher gab es dafür **keinen** Weg außer Konto löschen und neu anlegen
    /// (mit Verlust der lokalen Historie). „Bank neu verbinden" hat nur die
    /// Session verworfen und sofort wieder mit dem alten Passwort angemeldet —
    /// nach einem Passwortwechsel bei der Bank führte genau das zur Sperre.
    @objc func changeBankCredentials() {
        if locked { promptUnlockIfNeeded() }
        guard let pw = masterPassword else { return }

        let slot = MultibankingStore.shared.activeSlot
        guard slot?.isReceiptSlot != true, slot?.source != .paypal else {
            let a = NSAlert()
            a.messageText = t("Nicht für dieses Konto", "Not available for this account")
            a.informativeText = t(
                "Zugangsdaten lassen sich nur für Bankkonten ändern. Händler- und PayPal-Konten werden über ihren eigenen Einrichtungsdialog verbunden.",
                "Credentials can only be changed for bank accounts. Merchant and PayPal accounts use their own setup dialog."
            )
            a.runModal()
            return
        }

        let existing = try? CredentialsStore.load(masterPassword: pw)

        let alert = NSAlert()
        alert.messageText = t("Zugangsdaten ändern", "Change credentials")
        alert.informativeText = t(
            "Anmeldename und PIN/Passwort Deines Online-Bankings. Sie werden verschlüsselt auf diesem Mac gespeichert. Umsätze, Auswertungen und Einstellungen bleiben vollständig erhalten.",
            "Login name and PIN/password of your online banking. They are stored encrypted on this Mac. Transactions, reports and settings are fully preserved."
        )
        alert.addButton(withTitle: t("Speichern & verbinden", "Save & connect"))
        alert.addButton(withTitle: t("Abbrechen", "Cancel"))

        func mkLabel(_ s: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 10); l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 0, y: y, width: 340, height: 13)
            return l
        }
        let userField = NSTextField(frame: NSRect(x: 0, y: 44, width: 340, height: 22))
        userField.stringValue = existing?.userId ?? ""
        let pwdField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 82))
        container.addSubview(mkLabel(t("Anmeldename / Kontonummer", "Login name / account number"), y: 66))
        container.addSubview(userField)
        container.addSubview(mkLabel(t("PIN / Passwort", "PIN / password"), y: 22))
        container.addSubview(pwdField)
        alert.accessoryView = container
        // Der Anmeldename ist vorbefüllt — der Fokus gehört ins leere PIN-Feld.
        alert.window.initialFirstResponder = pwdField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let userId = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = pwdField.stringValue
        guard !userId.isEmpty, !password.isEmpty else { return }

        var creds = existing ?? StoredCredentials(iban: "", userId: "", password: "")
        creds.userId = userId
        creds.password = password
        do {
            try CredentialsStore.save(creds, masterPassword: pw)
        } catch {
            let a = NSAlert()
            a.messageText = t("Speichern fehlgeschlagen", "Saving failed")
            a.informativeText = error.localizedDescription
            a.runModal()
            return
        }

        let slotId = YaxiService.activeSlotId
        clearCredentialRejection(slotId: slotId)
        AppLogger.log("changeBankCredentials: neue Zugangsdaten für Slot \(slotId.prefix(8))", category: "Auth")

        // Session verwerfen, damit die Bank die neuen Daten auch wirklich prüft
        // (eine noch gültige Session würde die geänderte PIN gar nicht sehen).
        Task { @MainActor [weak self] in
            await YaxiService.sessionStore.clearAll(slotId: slotId)
            self?.refresh()
        }
    }
    
    @objc private func showSettings() {
        settingsPanel?.show()
    }

    /// Öffnet das einheitliche Dashboard am gewünschten Tab (löst die fünf Einzel-Sheets ab).
    private func openDashboard(tab: DashboardTab) {
        if dashboardPanel == nil { dashboardPanel = DashboardPanel() }
        let unified = dashboardIsUnified
        dashboardPanel?.show(tab: tab,
                             transactions: txVM.transactions,
                             balance: lastBalance ?? 0,
                             slot: unified ? nil : MultibankingStore.shared.activeSlot,
                             isUnified: unified)
    }

    /// Spiegelt den aktuellen Snapshot (Bank/„Alle Konten" + Saldo + Transaktionen) in ein
    /// bereits offenes Dashboard — no-op, wenn keins offen ist. Wird beim Slot-Wechsel/Refresh
    /// gerufen, damit das Dashboard nicht Bank B zeigt, aber Bank A auswertet.
    private func refreshDashboardIfOpen() {
        let unified = dashboardIsUnified
        dashboardPanel?.refresh(transactions: txVM.transactions,
                                balance: lastBalance ?? 0,
                                slot: unified ? nil : MultibankingStore.shared.activeSlot,
                                isUnified: unified)
    }

    /// Aggregiert das Dashboard gerade mehrere Konten? Gleiches Idiom wie an den
    /// übrigen Unified-Stellen (z.B. Saldo-Aggregation): Unified nur außerhalb des
    /// Single-Demo (im Multi-Demo aber erlaubt).
    private var dashboardIsUnified: Bool {
        txVM.isUnifiedMode && (!demoMode || isMultiDemo)
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updateChecker?.checkForUpdates()
    }

    private func setupGlobalHotkey() {
        let defaults = UserDefaults.standard

        // Flyout-Hotkey (legacy seit 1.x — default ⌃⌘S)
        let flyoutEnabled = defaults.object(forKey: "globalHotkeyEnabled") as? Bool ?? true
        let flyoutKeyCode = defaults.integer(forKey: "globalHotkeyKeyCode") > 0
            ? defaults.integer(forKey: "globalHotkeyKeyCode") : 1
        let flyoutModifiers = defaults.integer(forKey: "globalHotkeyModifiers") > 0
            ? defaults.integer(forKey: "globalHotkeyModifiers") : 4352

        if flyoutEnabled {
            GlobalHotkeyManager.shared.register(keyCode: flyoutKeyCode, carbonModifiers: flyoutModifiers, role: .flyout)
            GlobalHotkeyManager.shared.onTriggered = { @Sendable [weak self] in
                // Hotkey always opens the flyout regardless of the configured click mode
                // (mouseOver-mode would otherwise be a no-op for the hotkey).
                // Hold-to-Show-Modus: zentriert + Dim statt Popover am Status-Item.
                MainActor.assumeIsolated {
                    if UserDefaults.standard.bool(forKey: "flyoutHoldCenterEnabled") {
                        self?.showCenteredFlyout()
                    } else {
                        self?.showBalanceFlyout()
                    }
                }
            }
            GlobalHotkeyManager.shared.onTriggerReleased = { @Sendable [weak self] in
                // Release schließt das zentrierte Overlay, wenn eines offen ist.
                // Wir checken den tatsächlichen Sichtbarkeits-Status statt die
                // Preference: so funktioniert das Release auch nach einem
                // Live-Toggle des Settings, und der Popover-Modus bleibt
                // toggle-basiert (no-op beim Release).
                MainActor.assumeIsolated {
                    if self?.isCenteredFlyoutVisible == true {
                        self?.hideCenteredFlyout()
                    }
                }
            }
        } else {
            GlobalHotkeyManager.shared.unregister(role: .flyout)
        }

        // Refresh-Hotkey (neu seit 1.4.0 — default ⌃⌘R, opt-in).
        // Macht systemweit dasselbe wie das Menüleisten-„Aktualisieren" + ⌘R im Panel.
        let refreshEnabled = defaults.object(forKey: "globalRefreshHotkeyEnabled") as? Bool ?? false
        let refreshKeyCode = defaults.integer(forKey: "globalRefreshHotkeyKeyCode") > 0
            ? defaults.integer(forKey: "globalRefreshHotkeyKeyCode") : 15  // R
        let refreshModifiers = defaults.integer(forKey: "globalRefreshHotkeyModifiers") > 0
            ? defaults.integer(forKey: "globalRefreshHotkeyModifiers") : 4352  // ⌃⌘

        if refreshEnabled {
            GlobalHotkeyManager.shared.register(keyCode: refreshKeyCode, carbonModifiers: refreshModifiers, role: .refresh)
            GlobalHotkeyManager.shared.onRefreshTriggered = { @Sendable [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else {
            GlobalHotkeyManager.shared.unregister(role: .refresh)
        }

        // Bank-Cycle-Callbacks (←/→) sind permanent gehookt; die Carbon-
        // Registration passiert dynamisch in show/hideCenteredFlyout, damit
        // die Pfeiltasten nur während des Hold-Mode global gegrabbed werden.
        GlobalHotkeyManager.shared.onCycleBankPrev = { @Sendable [weak self] in
            MainActor.assumeIsolated { self?.cycleCenteredFlyoutBank(direction: -1) }
        }
        GlobalHotkeyManager.shared.onCycleBankNext = { @Sendable [weak self] in
            MainActor.assumeIsolated { self?.cycleCenteredFlyoutBank(direction: +1) }
        }
    }

    private func setupRefreshTimer() {
        timer?.invalidate()
        timer = nil
        
        // 0 = Manuell, kein Timer
        guard refreshInterval > 0 else { return }
        
        let interval = TimeInterval(refreshInterval * 60)
        // autoRefresh statt refresh: der periodische Timer darf bei eBon-Slots
        // (REWE/dm) NIEMALS das Login-/Sync-Fenster öffnen (kein Auto-Sync).
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(autoRefresh), userInfo: nil, repeats: true)
    }

    /// Automatischer Refresh (Timer): nur Anzeige aktualisieren. eBon-Slots
    /// öffnen hier KEIN Login-Fenster — das tut nur der manuelle `refresh()`.
    @objc private func autoRefresh() {
        // Sperrschutz: nach abgelehnten Zugangsdaten kein automatischer Versuch mehr.
        // Der manuelle Abruf bleibt erlaubt — das ist eine bewusste Nutzerentscheidung,
        // der Timer dagegen läuft unbeaufsichtigt in die Sperre.
        let slotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"
        guard !credentialsRejectedSlotIds.contains(slotId) else {
            AppLogger.log("Auto-Refresh übersprungen (Zugangsdaten abgelehnt)", category: "Auth")
            return
        }
        Task { await refreshAsync() }
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
    /// Kurzlabel für das Segmented-Control-Segment (Nickname, sonst Bankname).
    var name: String = ""

    /// Monogramm-Fallback (erster Buchstabe) für die Logo-Kachel, wenn kein Bild da ist.
    var monogram: String {
        let base = (nickname?.isEmpty == false ? nickname! : name)
        return String(base.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

/// Konto-Umschalter als Logo-Pillen (Prototyp 3b): aktives Konto als gefüllte,
/// beschriftete Pille (Temperaturfarbe), weitere Konten als kleinere Logo-Pillen.
/// Linksbündig, ohne umschließenden Track. Ersetzt die früheren abstrakten Dots.
private struct FlyoutSlotSegmentedControl: View {
    let slots: [FlyoutSlotItem]
    let activeIndex: Int
    let isUnifiedMode: Bool
    /// Tönung der aktiven Pille = Balance-Temperaturfarbe (folgt dem Kontostand).
    let activeTint: Color
    let colorScheme: ColorScheme
    var onSwitch: (Int) -> Void
    /// Zeigt die „Alle Konten"-Pille (Aggregat) — nur bei ≥2 echten Konten.
    var showUnified: Bool = false
    var onActivateUnified: (() -> Void)? = nil
    /// Während einer aktiven Schnellüberweisung nur die aktive Konto-Pille zeigen
    /// (kein Konto-Wechsel mitten im Transfer, kein „Alle Konten").
    var soloActiveOnly: Bool = false

    private var activeFill: Color {
        // Bei aktivem Theme: gefüllte Pille in einer Ink-Tönung (statt Weiß, das auf der
        // Theme-Fläche fremd wirkt).
        if !ThemeManager.shared.currentTheme.isDefault {
            return Color.themedInk.opacity(colorScheme == .dark ? 0.30 : 0.18)
        }
        return colorScheme == .dark ? Color.white.opacity(0.16) : .white
    }
    private var inactiveFill: Color {
        if !ThemeManager.shared.currentTheme.isDefault {
            return Color.themedInk.opacity(0.08)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    var body: some View {
        // BTX: reine Text-Umschalter statt Pillen mit Bank-Icon (siehe accountDotsBar).
        if !ThemeChrome.glyphControls {
            return AnyView(HStack(spacing: 14) {
                ForEach(Array(slots.enumerated()), id: \.offset) { idx, item in
                    let active = !isUnifiedMode && idx == activeIndex
                    if active || !soloActiveOnly {
                        Text(item.nickname?.isEmpty == false ? item.nickname! : item.name)
                            .font(ThemeFonts.flyoutBody(size: 15))
                            .textCase(.uppercase)
                            .foregroundColor(active ? Color.themedAccent : Color.themedInk.opacity(0.85))
                            .underline(active)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture { if !active { onSwitch(idx) } }
                    }
                }
                if showUnified && !soloActiveOnly {
                    Text(L10n.t("Alle", "All"))
                        .font(ThemeFonts.flyoutBody(size: 15))
                        .textCase(.uppercase)
                        .foregroundColor(isUnifiedMode ? Color.themedAccent : Color.themedInk.opacity(0.85))
                        .underline(isUnifiedMode)
                        .contentShape(Rectangle())
                        .onTapGesture { if !isUnifiedMode { onActivateUnified?() } }
                }
                Spacer(minLength: 0)
            })
        }
        return AnyView(HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { idx, item in
                let active = !isUnifiedMode && idx == activeIndex
                if active {
                    activePill(item)
                } else if !soloActiveOnly {
                    iconPill(item)
                        .contentShape(Capsule())
                        .onTapGesture { onSwitch(idx) }
                }
            }
            if showUnified && !soloActiveOnly {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isUnifiedMode ? activeTint : Color(NSColor.secondaryLabelColor))
                    .frame(width: 26, height: 26)
                    .background(Capsule(style: .continuous).fill(isUnifiedMode ? activeFill : inactiveFill))
                    .contentShape(Capsule())
                    .onTapGesture { if !isUnifiedMode { onActivateUnified?() } }
                    .help(L10n.t("Alle Konten", "All accounts"))
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: activeIndex)
        .animation(.easeInOut(duration: 0.2), value: isUnifiedMode))
    }

    /// Aktive Pille: Logo + Name, gefüllt, Text in Temperaturfarbe.
    private func activePill(_ item: FlyoutSlotItem) -> some View {
        HStack(spacing: 5) {
            logoTile(item, size: 16)
            Text(item.nickname?.isEmpty == false ? item.nickname! : item.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(activeTint)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(activeFill)
                .shadow(color: Color.black.opacity(0.10), radius: 1.5, x: 0, y: 1)
        )
    }

    /// Kleinere Pille für weitere Konten: nur Logo.
    private func iconPill(_ item: FlyoutSlotItem) -> some View {
        logoTile(item, size: 15)
            .padding(5)
            .background(Capsule(style: .continuous).fill(inactiveFill))
    }

    @ViewBuilder
    private func logoTile(_ item: FlyoutSlotItem, size: CGFloat) -> some View {
        if let logo = item.logo {
            Image(nsImage: logo)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(item.barColor)
                .frame(width: size, height: size)
                .overlay(
                    Text(item.monogram)
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundColor(.white)
                )
        }
    }

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
    @AppStorage("balanceMoodEmojiEnabled") private var emojiEnabled: Bool = false
    let balanceText: String
    /// Optionaler Ersatz für den Kontostand (Desktop-Widget-Ruhezustand: Maske).
    var balanceTextOverride: String? = nil
    private var effectiveBalanceText: String { balanceTextOverride ?? balanceText }
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
    /// `true`, wenn diese Karte im freigestellten Desktop-Widget lebt — nur dort
    /// greift das CRT-Easter-Egg (im Popover am Status-Item nicht).
    var isDetachedWidget: Bool = false
    var unifiedTotalBalance: Double? = nil
    var greenZoneFraction: Double = 0     // 0...1, balance / referenceIncome ("Bin ich im grünen Bereich?")
    var dispoLimit: Int = 0               // overdraft limit in € for dispo-mode ring
    @AppStorage("greenZoneRingEnabled") private var greenZoneRingEnabled: Bool = true
    @AppStorage("greenZoneShowDispo") private var greenZoneShowDispo: Bool = true
    // Dot indicators — all slots regardless of mode
    var allSlots: [FlyoutSlotItem]? = nil
    var activeSlotIndex: Int = 0
    var isUnifiedMode: Bool = false
    var canAggregate: Bool = false   // ≥2 echte Konten → „Alle Konten"-Pille im Switcher
    var onSwitchToIndex: ((Int) -> Void)? = nil
    var onActivateUnified: (() -> Void)? = nil
    var leftToPayAmount: Double? = nil
    /// Zyklusende (nächster Gehaltseingang) aus derselben Berechnung wie leftToPay —
    /// überschreibt das vom Toleranz-Default abweichende "bis zum …"-Datum im Untertitel.
    var leftToPayCycleEnd: Date? = nil
    var salaryDay: Int = 1                 // effective salary day for sub-metrics
    var salaryToleranceBefore: Int = 0     // darf N Tage früher kommen (z.B. 4)
    var salaryToleranceAfter: Int = 0      // darf N Tage später kommen (z.B. 1)
    /// "Verfügbar"-Wert (gebucht + vorgemerkte Ausgaben). Nur gesetzt, wenn er vom gebuchten
    /// Saldo abweicht (es also vorgemerkte Lastschriften gibt) — sonst `nil` → keine Sub-Zeile.
    var availableBalance: Double? = nil

    // MARK: REWE eBon-Slot
    /// Wenn true, wird statt der Saldo-Karte die REWE-Karte im Bank-Layout
    /// gezeigt (Header „REWE · Uhrzeit", großer Betrag letzter Einkauf, kein Ring,
    /// darunter Einkäufe Monat/Jahr mit Toggle).
    // MARK: PayPal-Untertitel (Toggle letzte Buchung / Ausgaben diesen Monat)
    var isPayPalCard: Bool = false
    var paypalLastBooking: String? = nil   // "23,99 € McDonald's"
    var paypalMonthSpend: String? = nil    // "312,80 €"
    var paypalMonthLabel: String = ""      // "Juli"
    @State private var paypalSubtitleRange: Int = 0   // 0 = letzte Buchung, 1 = Monatsausgaben

    var reweMode: Bool = false
    /// Quelle des aktiven Receipt-Slots — bestimmt den Marken-Wash (REWE/Amazon/dm).
    var reweSource: SlotSource = .rewe
    /// Monatsbudget in Euro (0 = keins → kein Ausgaben-Heat).
    var reweBudgetEuro: Int = 0
    var reweMonthLabel: String = ""       // "Juni"
    var reweMonthTotalCents: Int = 0
    var reweYearLabel: String = ""        // "2026"
    var reweYearTotalCents: Int = 0
    var reweLastYearLabel: String = ""    // "2025"
    var reweLastYearTotalCents: Int = 0
    var reweHasLastYear: Bool = false     // Vorjahr-State nur, wenn Daten da
    /// Top-4-Warengruppen des letzten Bons (für den Kategorien-Ring).
    var reweRingSegments: [ReceiptRingSegment] = []
    /// Datum des letzten Bons (Ring-Mitte).
    var reweLastReceiptDate: Date? = nil
    /// Hintergrund-Sync scheiterte (Login abgelaufen) → Hinweis statt Uhrzeit.
    var reweNeedsLogin: Bool = false
    /// 0 = Monat, 1 = Jahr, 2 = Vorjahr.
    @State private var reweRange: Int = 0

    // MARK: Quick-Send (Flyout-Drawer)
    /// Vom Host (BalanceBar) gesetzt: ob der Quick-Send-Drawer angeboten wird
    /// (Opt-in + Lizenz/Demo-Gate). false → Toggle-Button bleibt unsichtbar.
    var quickSendAvailable: Bool = false
    /// Meldet dem Host das Auf-/Zuklappen, damit er die Popover-/Overlay-Höhe
    /// animiert mitwachsen lässt.
    var onQuickSendToggle: ((Bool) -> Void)? = nil
    /// Führt den eigentlichen Versand aus (Master-Passwort + SCA im Host). Zweiter
    /// Parameter = eingefrorenes Quellkonto → Host validiert es vor dem Bankaufruf.
    var quickSendPerform: (@MainActor (TransferRequest, String) async -> TransferOutcome)? = nil
    /// Wird nach erfolgreichem Versand gerufen (nachdem die Bestätigung im Drawer
    /// kurz stand) — der Host schließt daraufhin das ganze Flyout.
    var onQuickSendSent: (() -> Void)? = nil
    /// simplesend noch nicht freigeschaltet → Klick öffnet Upsell statt Drawer.
    var quickSendNeedsUnlock: Bool = false

    // MARK: Dokument-Drop (Rechnung aufs Flyout ziehen)
    /// Aus einem gedroppten PDF/Bild erkannte Überweisungsdaten — werden an den
    /// Quick-Send-Drawer durchgereicht.
    @State private var droppedPrefill: TransferClipboardParser.Parsed? = nil
    @State private var isDocumentDropTargeted = false
    @State private var isScanningDroppedDocument = false
    @State private var droppedScanFailed = false

    /// Nimmt eine gedroppte Rechnung an: Textebene bzw. On-device-OCR → Parser →
    /// Quick-Send-Drawer öffnen und vorbefüllen.
    private func handleFlyoutDocumentDrop(_ providers: [NSItemProvider]) -> Bool {
        guard quickSendAvailable, !quickSendNeedsUnlock, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, TransferDocumentScanner.isSupported(url) else { return }
            Task { @MainActor in
                isScanningDroppedDocument = true
                let text = await TransferDocumentScanner.extractText(from: url)
                let parsed = text.map(TransferClipboardParser.parse)
                isScanningDroppedDocument = false
                if let parsed, parsed.isUseful {
                    droppedPrefill = parsed
                    if !showSend {          // Drawer aufklappen, damit man das Ergebnis sieht
                        showSend = true
                        onQuickSendToggle?(true)
                    }
                } else {
                    droppedScanFailed = true
                    try? await Task.sleep(for: .seconds(3))
                    droppedScanFailed = false
                }
            }
        }
        return true
    }

    @ViewBuilder
    private var documentDropOverlay: some View {
        if isDocumentDropTargeted || isScanningDroppedDocument || droppedScanFailed {
            let failed = droppedScanFailed
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(failed ? Color.sbOrangeStrong : Color.sbBlueStrong,
                                  style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill((failed ? Color.sbOrangeSoft : Color.sbBlueSoft).opacity(0.6)))
                VStack(spacing: 6) {
                    if isScanningDroppedDocument {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("Rechnung wird gelesen …", "Reading invoice …"))
                    } else if failed {
                        Image(systemName: "doc.questionmark").font(.system(size: 22, weight: .light))
                        Text(L10n.t("Keine Überweisungsdaten gefunden.", "No transfer details found."))
                    } else {
                        Image(systemName: "doc.text.viewfinder").font(.system(size: 22, weight: .light))
                        Text(L10n.t("Rechnung ablegen", "Drop invoice"))
                    }
                }
                .multilineTextAlignment(.center)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(failed ? .sbOrangeStrong : .sbBlueStrong)
                .padding(.horizontal, 12)
            }
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
    var onQuickSendUpsell: (() -> Void)? = nil
    var onQuickSendAddTemplate: (() -> Void)? = nil
    @State private var showSend: Bool = false

    @Environment(\.colorScheme) private var environmentColorScheme

    private var activeColorScheme: ColorScheme {
        forcedColorScheme ?? environmentColorScheme
    }

    // Pillen-Switcher zeigt sich schon ab EINEM Konto (immer die aktive Pille).
    private var hasDots: Bool { (allSlots?.count ?? 0) >= 1 }

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

    /// "Verfügbar: 1.184,56 €" — nur wenn `availableBalance` gesetzt ist (= es gibt vorgemerkte
    /// Ausgaben). Bewusst eine eigene, ruhige Mini-Zeile statt eines neuen Subtitle-Toggle-Modes.
    private var availableBalanceLine: String? {
        guard let avail = availableBalance else { return nil }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = (currency?.isEmpty == false) ? currency! : "EUR"
        f.maximumFractionDigits = 2
        let formatted = f.string(from: NSNumber(value: avail)) ?? String(format: "%.2f €", avail)
        return L10n.t("Nach Vormerkungen: \(formatted)", "After pending: \(formatted)")
    }

    @ViewBuilder
    private var availableBalanceSubline: some View {
        if let line = availableBalanceLine {
            Text(line)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .lineLimit(1)
                .help(L10n.t(
                    "Gebuchter Saldo abzüglich vorgemerkter Ausgaben (ohne vorgemerkte Eingänge).",
                    "Booked balance minus pending debits (pending credits excluded)."
                ))
        }
    }

    @AppStorage("balanceSubtitleStyle.flyout") private var flyoutSubtitleStyle: Int = 0

    @ObservedObject private var roundupView = RoundupViewState.shared

    /// Quick-Send nur auf der normalen Einzelkonto-Karte — nicht im Aufrunden-
    /// Modus (eigene Card) und nicht im Aggregiert-/Unified-Modus (Empfänger-
    /// Slot wäre mehrdeutig).
    private var quickSendActive: Bool {
        quickSendAvailable && !roundupView.isActive && unifiedSlots == nil
    }

    /// Nur die Default-Theme-Saldo-Karte bekommt den randlosen Temperatur-Wash
    /// (Prototyp 4b): kein Außen-Padding, Wash bis an die Flyout-Kanten. Andere
    /// Karten (Roundup/REWE/Unified/Legacy) behalten ihr klassisches Inset-Layout.
    private var bleedDefaultCard: Bool {
        // Alle Saldo-Karten (Default-Money-Heat, aktive Themes, Händler-Wash, Unified)
        // sind randlos vollflächig. Nur der Roundup-View behält sein Inset-Layout.
        !roundupView.isActive
    }

    /// Hartgrenze für Quick-Send = Saldo + Dispo-Rahmen (gleiche Logik wie `TransferSheet`).
    /// `nil` wenn der Saldo unbekannt ist → keine Sperre.
    private var quickSendAvailableLimit: Decimal? {
        guard let b = balanceValue else { return nil }
        return Decimal(b) + Decimal(dispoLimit)
    }

    /// Höhe des oberen Karten-Bereichs (Saldo-Card + ggf. Konto-Dots). Konstant —
    /// unabhängig davon, ob der Quick-Send-Drawer offen ist. Entspricht der
    /// Basis-Höhe, die der Host (BalanceBar.flyoutContentSize) als Popover-Größe
    /// im eingeklappten Zustand setzt.
    // Prototyp 4b (ringlos): kompaktere Karte. Einzelkonto = reiner Wash-Block (140);
    // Multibanking = Wash-Block + weißer Abstand + Segmented-Control (~178).
    private var cardRegionHeight: CGFloat { hasDots ? 178 : 140 }

    /// 26×26 Toggle in der Kartenkopfzeile: Papierflieger (zu) ↔ Chevron-up (offen, invertiert).
    /// Liegt in-flow am rechten Ende der Header-HStack (nach dem Emoji), damit
    /// es nichts überlappt.
    @ViewBuilder
    private var quickSendToggleButton: some View {
        if quickSendActive {
            Button {
                // simplesend nicht freigeschaltet → wie in der Umsatzliste: Upsell
                // statt Drawer öffnen (Drawer bleibt zu).
                if quickSendNeedsUnlock {
                    onQuickSendUpsell?()
                    return
                }
                // Keine SwiftUI-Höhenanimation: der Drawer ist immer voll gerendert
                // (oben verankert) und wird nur vom wachsenden Popover-Fenster
                // freigegeben. showSend steuert Icon + Interaktion; den Resize macht
                // setFlyoutQuickSendOpen (NSPopover animiert, eine Timeline).
                showSend.toggle()
                onQuickSendToggle?(showSend)
            } label: {
                if !ThemeChrome.glyphControls {
                    // BTX: Textkommando statt Papierflieger, aktiv unterstrichen.
                    Text(L10n.t("Senden", "Send"))
                        .font(ThemeFonts.flyoutBody(size: 15))
                        .textCase(.uppercase)
                        .underline(showSend)
                        .foregroundColor(showSend ? Color.themedAccent : Color.themedInk.opacity(0.75))
                } else {
                // Immer Papierflieger; offen invertiert (heller Flieger auf dunklem
                // Grund). Rahmen in beiden Zuständen, damit der „Geld senden"-Button
                // klar als Button lesbar ist.
                // Prototyp: geschlossener Zustand transparent (nur Icon, kein Kasten);
                // offener Zustand invertiert gefüllt als aktive Affordance.
                Image(systemName: ThemeChrome.symbol(for: .send))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(showSend ? Color.panelBackground : Color.sbTextSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(showSend ? Color.sbTextPrimary : Color.clear)
                    )
                }
            }
            .buttonStyle(.plain)
            .help(L10n.t("Schnellüberweisung", "Quick transfer"))
        }
    }

    /// PayPal-Untertitel: Toggle zwischen letzter Buchung und Monatsausgaben
    /// (ersetzt „Noch offen/Verfügbar", das für PayPal keinen Sinn ergibt).
    @ViewBuilder
    private func paypalSubtitle(detail: Color) -> some View {
        let text: String = paypalSubtitleRange == 0
            ? (paypalLastBooking.map { L10n.t("Letzte Buchung: \($0)", "Last: \($0)") }
                ?? L10n.t("Keine Buchung", "No transaction"))
            : "\(L10n.t("Ausgaben", "Spending")) \(paypalMonthLabel): \(paypalMonthSpend ?? "—")"
        Button {
            paypalSubtitleRange = paypalSubtitleRange == 0 ? 1 : 0
        } label: {
            HStack(spacing: 5) {
                if ThemeChrome.glyphControls {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                }
                Text(text)
                    .font(isDefaultTheme ? .system(size: 12)
                          : ThemeFonts.flyoutBody(size: ThemeChrome.lofi ? 14 : 12))
                    .textCase(ThemeChrome.textCase)
                    .lineLimit(1)
            }
            .foregroundColor(detail)
        }
        .buttonStyle(.plain)
        .help(L10n.t("Tippen: letzte Buchung / Ausgaben diesen Monat",
                     "Tap: last transaction / spending this month"))
    }

    private var leftToPaySubtitle: some View {
        // Im Aufrunden-Modus wird die ganze Flyout-Card durch RoundupSavingsCard
        // ersetzt — dieser Subtitle läuft dann gar nicht.
        // Unified-Mode: leftToPay ist pro-Slot aggregiert → Sub-Metrics würden gegen
        // einen einzelnen Gehaltstag rechnen und wären fachlich inkonsistent.
        let level = BalanceSignal.classify(balance: balanceValue, thresholds: thresholds)
        let style = BalanceSignal.style(for: level)
        let detail = washColors(level: level, style: style, dark: activeColorScheme == .dark).detail
        return BalanceSubtitleSwitch(
            balance: balanceValue,
            leftToPayAmount: leftToPayAmount,
            salaryDay: salaryDay,
            salaryToleranceBefore: salaryToleranceBefore,
            salaryToleranceAfter: salaryToleranceAfter,
            cycleEndOverride: leftToPayCycleEnd,
            style: $flyoutSubtitleStyle,
            forceClassic: isUnifiedMode,
            compact: true,
            detailColor: detail
        )
    }


    /// Der eigentliche Flyout-Inhalt: oberer Karten-Bereich (feste Höhe) + darunter
    /// der Quick-Send-Drawer (feste Höhe). Natürliche Gesamthöhe = Card + Drawer.
    /// Wird im `body` als oben verankertes Overlay über einen fenstergroßen Container
    /// gelegt und auf Fenstergröße geclippt (siehe dort).
    private var flyoutColumn: some View {
        VStack(spacing: 0) {
            // ── Oberer Karten-Bereich — feste Höhe (cardRegionHeight), komplett
            //    statisch. Wird beim Auf-/Zuklappen des Drawers NIE neu layoutet.
            VStack(spacing: 0) {
            Group {
                if roundupView.isActive {
                    RoundupSavingsCard(compact: true)
                } else if reweMode {
                    reweCard
                } else if unifiedSlots != nil {
                    unifiedCard
                } else {
                    // Default = Money-Heat, aktive Themes = flache Theme-Farbe — beide
                    // über dieselbe randlose Full-Bleed-Geometrie (kein Inset/Rahmen mehr).
                    defaultThemeCard
                }
            }
            .padding(.horizontal, bleedDefaultCard ? 0 : 14)
            .padding(.top, bleedDefaultCard ? 0 : 14)
            .padding(.bottom, bleedDefaultCard ? 0 : (hasDots ? 2 : 14))
            .onTapGesture(count: 2) { onDoubleTap?() }
            // Ripple only on the balance card, not the dot row
            .rippleEffect(trigger: rippleTrigger, defaultOrigin: CGPoint(x: 310, y: 130),
                          enabled: ThemeChrome.rippleEnabled)

            // Footer-Zeile: Konto-Pillen (links) + Geld-senden (rechtsbündig, kleiner
            // Randabstand). Der adaptive Segmented Control (Design „4b") ersetzt die Dots.
            if hasDots, let slots = allSlots {
                // Aktive Pille: bei Theme in Ink-Farbe, sonst Balance-Temperaturfarbe.
                let tint = isDefaultTheme
                    ? BalanceSignal.style(for: BalanceSignal.classify(balance: balanceValue, thresholds: thresholds)).amountColor
                    : Color.themedInk
                HStack(spacing: 8) {
                    FlyoutSlotSegmentedControl(
                        slots: slots,
                        activeIndex: activeSlotIndex,
                        isUnifiedMode: isUnifiedMode,
                        activeTint: tint,
                        colorScheme: activeColorScheme,
                        onSwitch: { onSwitchToIndex?($0) },
                        showUnified: canAggregate,
                        onActivateUnified: { onActivateUnified?() },
                        soloActiveOnly: quickSendActive && showSend
                    )
                    quickSendToggleButton
                }
                // Mit CRT-Blende mehr Randabstand — sonst kleben Piles und „Senden"
                // an der Schmucklinie.
                .padding(.horizontal, ThemeChrome.lofi ? 16 : 12)
                .padding(.top, 8)
                .padding(.bottom, ThemeChrome.lofi ? 12 : 9)
            }
            }
            .frame(height: cardRegionHeight, alignment: .top)

            // Quick-Send-Drawer — IMMER voll gerendert (wenn aktiv), feste Höhe. Er
            // wird vom SwiftUI-Layout NICHT animiert. Beim Toggle wächst nur das
            // Popover-Fenster nach unten und gibt den darunter bereits gezeichneten
            // Drawer frei (genau wie `overflow:hidden`/`max-height` im Design-HTML).
            // `.disabled` verhindert Tab-Fokus, solange er (geclippt) verborgen ist.
            if quickSendActive {
                QuickSendDrawerView(
                    performSend: quickSendPerform,
                    availableLimit: quickSendAvailableLimit,
                    sourceSlotId: MultibankingStore.shared.activeSlot?.id ?? "legacy",
                    onClose: {
                        // Wird nur nach erfolgreichem Versand gerufen (Bestätigung
                        // stand schon ~1,5 s). Drawer einklappen + ganzes Flyout zu.
                        showSend = false
                        onQuickSendToggle?(false)
                        onQuickSendSent?()
                    },
                    onAddTemplate: { onQuickSendAddTemplate?() },
                    prefill: droppedPrefill
                )
                .frame(height: QuickSendDrawerView.totalDrawerHeight, alignment: .top)
                .disabled(!showSend)
                .accessibilityHidden(!showSend)
            }
        }
        .frame(width: 348)
    }

    var body: some View {
        // Container = EXAKT die Fenstergröße: `Color.clear` nimmt den angebotenen
        // Platz (Popover-contentSize) voll ein, daher zentriert NSHostingController
        // NICHTS. Der eigentliche Inhalt (`flyoutColumn`, höher als das Fenster) liegt
        // als OBEN verankertes Overlay darauf und wird per `.clipped()` auf die
        // Fenstergröße beschnitten — exakt die `overflow:hidden`-Mechanik des Designs.
        // Geschlossen zeigt das Fenster genau den Karten-Bereich (Drawer ragt unten
        // heraus, abgeschnitten). Beim Klick wächst nur das Popover-Fenster nach unten
        // und gibt den Drawer frei; der obere Bereich bleibt fix und unverändert.
        Color.clear
            .frame(width: 348)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) { flyoutColumn }
            .clipped()
            // Bei aktivem Theme füllt die flache Theme-Farbe auch Footer/Kanten (sonst
            // blitzt am unteren Rand die Default-Panelfarbe durch → „Rahmen").
            // Wallpaper zuunterst, darüber die Farbe (die unter einem Wallpaper
            // durchsichtig wird). Beides in einem ZStack, damit das Bild bis in die
            // Kanten reicht — sonst blitzte am unteren Rand die Panelfarbe durch.
            .background(
                ZStack {
                    ThemeWallpaper(flaeche: .flyout)
                    (roundupView.isActive && !ThemeChrome.lofi) ? Color.roundupPanelBackground
                        : (isDefaultTheme ? Color.panelBackground : Color.themedSurfaceOrClear)
                }
            )
            // Das GANZE Flyout ist Drop-Zone: Rechnung (PDF/Bild) darauf ziehen →
            // Textebene/OCR → Quick-Send-Drawer öffnet sich vorbefüllt.
            .onDrop(of: [.fileURL], isTargeted: $isDocumentDropTargeted) { providers in
                handleFlyoutDocumentDrop(providers)
            }
            .overlay { documentDropOverlay }
            // „Bildschirmrand" (BTX): Overlay innen auf der Fläche — kein Platzverbrauch,
            // keine Verschiebung. Ohne `screenBorder` im Theme passiert hier nichts.
            .overlay {
                if let border = Color.themedScreenBorder {
                    // CRT-Blende wie in der Umsatzliste (die Host-Layer-Rundung
                    // schneidet die Außenkante sauber ab).
                    BTXScreenBezel(color: border, thickness: 5, innerRadius: 11)
                }
            }
            // CRT-Easter-Egg (nur BTX, nur im freigestellten Widget).
            .btxCRTEffect(gate: isDetachedWidget)
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
        // Money-Heat für die Aggregat-Summe: Temperatur des Gesamtsaldos (Schwellen
        // × Kontozahl, damit die Stimmung konsistent zu Einzelkarten bleibt).
        let dark = activeColorScheme == .dark
        let n = max(1, slots.count)
        let scaledThresholds = BalanceSignalThresholds(
            deepOverdraftThreshold: thresholds.deepOverdraftThreshold * Double(n),
            lowUpperBound: thresholds.lowUpperBound * Double(n),
            mediumUpperBound: thresholds.mediumUpperBound * Double(n),
            veryGoodLowerBound: thresholds.veryGoodLowerBound * Double(n)
        )
        // Aggregat bewusst NEUTRAL färben (keine grün/orange-Money-Heat) — die
        // Temperatur springt sonst beim Wechsel Einzelkonto↔Aggregat.
        let uLevel: BalanceSignalLevel = .unknown
        let uStyle = BalanceSignal.style(for: uLevel)
        let wash = washColors(level: uLevel, style: uStyle, dark: dark)

        // Determine unified header: "Alle Konten · 8 Uhr" (mirrors bank name + time in defaultThemeCard)
        let headerText: String = {
            if let date = balanceFetchedAt {
                let hour = Calendar.current.component(.hour, from: date)
                return L10n.t("Alle Konten · \(hour) Uhr", "All Accounts · \(hour):00")
            }
            return L10n.t("Alle Konten", "All Accounts")
        }()

        let themed = !isDefaultTheme
        let lofi = themed && ThemeChrome.lofi
        return VStack(alignment: .leading, spacing: 8) {
            // Header row — mirrors defaultThemeCard: icon + text + Spacer
            HStack(spacing: 8) {
                if lofi {
                    BTXMosaicIcon(category: .sonstiges)
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Text(headerText)
                    .font(themed ? ThemeFonts.flyoutBody(size: lofi ? 15 : 14) : .system(size: 14))
                    .textCase(ThemeChrome.textCase)
                    .foregroundColor(themed ? Color.themedInk.opacity(0.9) : Color(NSColor.secondaryLabelColor))
                Spacer()
            }

            // Nur der Gesamt-Saldo (keine Konten-Aufschlüsselung rechts).
            Text(effectiveBalanceText)
                .font(lofi ? ThemeFonts.flyoutHeading(size: 42, weight: .bold)
                     : themed ? ThemeFonts.flyoutHeading(size: 38, weight: .bold)
                              : .system(size: 38, weight: .bold, design: .default))
                .tracking(lofi ? 1.0 : -0.6)
                .monospacedDigit()
                // Negatives Aggregat auch im Theme in Warnfarbe (BTX-Rot).
                .foregroundColor(themed
                                 ? ((unifiedTotalBalance ?? 0) < 0 ? .themedExpense : .themedInk)
                                 : wash.balance)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .scaleEffect(x: 1, y: lofi ? 1.15 : 1.0, anchor: .leading)
                .frame(height: lofi ? 48 : ThemeFonts.lineHeight(forSize: 38, weight: .bold), alignment: .leading)
            leftToPaySubtitle
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        // Randlose Money-Heat wie die Einzelkonto-Karte (Aggregat-Temperatur);
        // aktives Theme = flache Theme-Fläche.
        .frame(maxWidth: .infinity, maxHeight: hasDots ? nil : .infinity, alignment: .topLeading)
        .background(
            lofi
            ? AnyView(Color.themedSurfaceOrClear)
            : AnyView(LinearGradient(colors: [wash.top, wash.bottom],
                                     startPoint: .topTrailing, endPoint: .bottomLeading))
        )
    }

    private func reweEuro(_ c: Int) -> String { String(format: "%.2f €", Double(c) / 100) }

    /// REWE-Karte im EXAKTEN Bank-Layout (defaultThemeCard-Struktur): Header
    /// (Logo + „REWE · HH Uhr"), großer schwarzer Betrag (= letzter Einkauf),
    /// KEIN Ring, darunter „Einkäufe <Monat>: …" mit Toggle auf Jahr.
    /// 0 = Monat, 1 = Jahr, 2 = Vorjahr. Label + Betrag fürs aktuelle Toggle.
    private var reweRangeLabel: String {
        switch reweRange { case 1: return reweYearLabel; case 2: return reweLastYearLabel; default: return reweMonthLabel }
    }
    private var reweRangeAmount: String {
        switch reweRange { case 1: return reweEuro(reweYearTotalCents); case 2: return reweEuro(reweLastYearTotalCents); default: return reweEuro(reweMonthTotalCents) }
    }
    /// Monat → Jahr → Vorjahr (nur wenn vorhanden) → Monat.
    private func cycleReweRange() {
        if reweRange == 0 { reweRange = 1 }
        else if reweRange == 1 { reweRange = reweHasLastYear ? 2 : 0 }
        else { reweRange = 0 }
    }

    private var reweCard: some View {
        // Marken-Wash (REWE-Rot / Amazon-Orange / dm-Blau) statt Glas — randlos wie
        // die Money-Heat-Karte. Ausgaben-Heat auf der Monatssumme vs. Budget.
        let wash = MerchantWash.colors(for: reweSource)
        let budgetCents = reweBudgetEuro * 100
        let spendLevel = SpendSignal.classify(spentCents: reweMonthTotalCents, budgetCents: budgetCents)
        let heat = SpendSignal.heatColor(spendLevel)
        let showHeat = reweRange == 0 && spendLevel != .noBudget      // Heat nur im Monats-Bereich
        let toggleColor: Color = showHeat ? heat : Color(NSColor.secondaryLabelColor)
        let budgetBadge = reweRange == 0
            ? SpendSignal.badge(spentCents: reweMonthTotalCents, budgetCents: budgetCents, level: spendLevel)
            : nil
        // Struktur bewusst identisch zur Bank-Karte (defaultThemeCard): Header, dann
        // Betrag direkt darunter — damit Name/Betrag beim Wechsel Bank↔Händler NICHT
        // springen. Der Kategorien-Ring liegt als Overlay rechts und treibt die
        // Kartenhöhe NICHT (sonst wäre die Händler-Karte höher → Pillen versetzt).
        let themed = !isDefaultTheme
        let lofi = themed && ThemeChrome.lofi
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // BTX: Warenkorb-Mosaik statt Marken-Logo.
                if themed && !ThemeChrome.merchantLogosEnabled {
                    BTXMosaicIcon(category: .essenAlltag)
                } else if let img = bankLogoImage {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: "cart.fill").font(.system(size: 16))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                if reweNeedsLogin {
                    Text("⚠︎ " + L10n.t("Login erneuern", "Sign in again"))
                        .font(themed ? ThemeFonts.flyoutBody(size: lofi ? 15 : 14) : .system(size: 14))
                        .textCase(ThemeChrome.textCase)
                        .foregroundColor(themed ? .themedExpense : .orange)
                } else {
                    Text(formatBankHeader(date: balanceFetchedAt))
                        .font(themed ? ThemeFonts.flyoutBody(size: lofi ? 15 : 14) : .system(size: 14))
                        .textCase(ThemeChrome.textCase)
                        .foregroundColor(themed ? Color.themedInk.opacity(0.9) : Color(NSColor.secondaryLabelColor))
                }
                Spacer()
            }
            Text(effectiveBalanceText)
                .font(lofi ? ThemeFonts.flyoutHeading(size: 42, weight: .bold)
                     : themed ? ThemeFonts.flyoutHeading(size: 38, weight: .bold)
                              : .system(size: 38, weight: .bold, design: .default))
                .tracking(lofi ? 1.0 : -0.6)
                .foregroundColor(themed ? .themedInk : wash.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .scaleEffect(x: 1, y: lofi ? 1.15 : 1.0, anchor: .leading)
                .frame(height: lofi ? 48 : ThemeFonts.lineHeight(forSize: 38, weight: .bold), alignment: .leading)
            Button { cycleReweRange() } label: {
                HStack(spacing: 6) {
                    if ThemeChrome.glyphControls {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                    }
                    Text("\(L10n.t("Einkäufe", "Purchases")) \(reweRangeLabel): \(reweRangeAmount)")
                        .font(ThemeFonts.rowBody(size: 12, lofiSize: 14))
                        .textCase(ThemeChrome.textCase)
                    if let badge = budgetBadge {
                        Text(badge)
                            .font(ThemeFonts.rowBody(size: 10, weight: .semibold, lofiSize: 12))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(999))
                                    .fill(lofi ? Color.clear : heat.opacity(0.15))
                                    .overlay(
                                        lofi
                                        ? RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(999))
                                            .stroke(Color.themedInk.opacity(0.5), lineWidth: 1)
                                        : nil
                                    )
                            )
                            .foregroundColor(themed ? Color.themedInk.opacity(0.85) : heat)
                    }
                }
                .foregroundColor(themed ? Color.themedInk.opacity(0.85) : toggleColor)
            }
            .buttonStyle(.plain)
            .help(L10n.t("Tippen: Monat / Jahr / Vorjahr", "Tap: month / year / last year"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Ring als Overlay rechts, vertikal an der Betrags-Zeile ausgerichtet.
        .overlay(alignment: .trailing) {
            ReceiptCategoryRing(segments: reweRingSegments, date: reweLastReceiptDate)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        // Randlos: Marken-Wash bis an die Flyout-Kanten (Popover rundet die Ecken);
        // aktives Theme = flache Theme-Fläche.
        .frame(maxWidth: .infinity, maxHeight: hasDots ? nil : .infinity, alignment: .topLeading)
        .background(
            lofi
            ? AnyView(Color.themedSurfaceOrClear)
            : AnyView(LinearGradient(colors: [wash.top, wash.bottom],
                                     startPoint: .topTrailing, endPoint: .bottomLeading))
        )
    }

    /// Temperatur-Wash nach Kontostand (Spezifikation §4, Prototyp 4b/1c): 160°-Verlauf
    /// hinter dem Header/Balance-Block. 3 Zustände, gemappt aus 7 Signal-Leveln.
    /// Light-Mode = exakte Prototyp-Hexes; Dark-Mode = dezente Hue-Tönung.
    private func washColors(level: BalanceSignalLevel, style: BalanceSignalStyle, dark: Bool)
        -> (top: Color, bottom: Color, balance: Color, detail: Color) {
        BalanceWash.colors(level: level, style: style, dark: dark)
    }

    /// Nur der Kontoname (Nickname → Bankname), ohne Zeitanteil.
    private var headerNameOnly: String {
        if let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty { return nick }
        if let bn = bankName?.trimmingCharacters(in: .whitespacesAndNewlines), !bn.isEmpty { return bn }
        return L10n.t("Kontostand", "Balance")
    }
    /// „ · 6 Uhr" (oder leer, wenn kein Zeitstempel).
    private func headerTimeSuffix(_ date: Date?) -> String {
        guard let date else { return "" }
        let hour = Calendar.current.component(.hour, from: date)
        return L10n.t(" · \(hour) Uhr", " · \(hour):00")
    }

    // Prototyp 4b: warmer Temperatur-Wash hinter Balance, KEIN Ring (Datum wandert in
    // die Kopfzeile), Balance groß mit Bühne. Zwei-Ton-Kopfzeile (Name dunkel, Zeit hell).
    private var defaultThemeCard: some View {
        let level = BalanceSignal.classify(balance: balanceValue, thresholds: thresholds)
        let style = BalanceSignal.style(for: level)
        let displayBalance = balanceValue == nil ? "--,-- €" : effectiveBalanceText
        let dark = activeColorScheme == .dark
        let wash = washColors(level: level, style: style, dark: dark)
        // Aktives Theme (nicht Default): Money-Heat AUS → flache Theme-Fläche + Ink +
        // Theme-Schrift. Default: unveränderte Money-Heat.
        let themed = !isDefaultTheme
        let fillTop:    Color = themed ? .themedSurfaceOrClear : wash.top
        let fillBottom: Color = themed ? .themedSurfaceOrClear : wash.bottom
        // Negativer Saldo trägt auch im Theme die Warnfarbe (BTX-Rot).
        let balanceColor: Color = themed
            ? ((balanceValue ?? 0) < 0 ? .themedExpense : .themedInk)
            : wash.balance
        let detailColor:  Color = themed ? Color.themedInk.opacity(0.72) : wash.detail
        let nameColor: Color = themed ? .themedInk
            : (dark ? Color(NSColor.labelColor) : (Color(hex: "1d1d1f") ?? .primary))
        // Demo 2b (Flyout, 420 px): Kontostand 50 px + scaleY(1.15) — NUR Lo-Fi (BTX).
        // Farb-Themes behalten die 38-pt-Metrik; Streckung via scaleEffect am Text.
        let lofi = themed && ThemeChrome.lofi
        let balanceFont: Font = lofi ? ThemeFonts.flyoutHeading(size: 42, weight: .bold)
                              : themed ? ThemeFonts.flyoutHeading(size: 38, weight: .bold)
                                       : .system(size: 38, weight: .bold, design: .default)
        let nameFont: Font = themed ? ThemeFonts.flyoutHeading(size: 14, weight: .semibold)
                                     : .system(size: 14, weight: .semibold)
        let timeFont: Font = themed ? ThemeFonts.flyoutBody(size: 13) : .system(size: 13)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Gleicher 20×20-Platz in jedem Fall — ein Theme ohne Bildmarken (BTX)
                // setzt hier den Mosaik-Block der Kategorie „neutral/Bank".
                if !ThemeChrome.bankLogosEnabled {
                    BTXMosaicIcon(category: .sonstiges)
                } else if let logo = ThemeChrome.globalLogoImage {
                    // Globales Theme-Logo: gilt für ALLE Konten, deshalb ohne die
                    // Marken-Invertierung — die weiß nur bei Banken, wie das Logo
                    // gebaut ist. Für den Dunkelmodus gibt es `logoDark`.
                    Image(nsImage: logo).resizable().scaledToFit()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else if let img = bankLogoImage {
                    BankMark(image: img, brandId: bankLogoBrandId, size: 20,
                             cornerRadius: 5, dark: dark)
                } else {
                    Image(systemName: "wallet.pass")
                        .font(.system(size: 16))
                        .foregroundColor(detailColor)
                }
                (Text(headerNameOnly).font(nameFont).foregroundColor(nameColor)
                 + Text(headerTimeSuffix(balanceFetchedAt)).font(timeFont).foregroundColor(detailColor))
                    .textCase(ThemeChrome.textCase)
                    .lineLimit(1)
                // BTX: blinkendes Telefon-Steuerzeichen neben der Bank (wie Demo-Kopf).
                if themed && !ThemeChrome.glyphControls {
                    BTXBlinkingPhone(size: 13)
                }
                Spacer()
            }

            Text(displayBalance)
                .font(balanceFont)
                .tracking(lofi ? 1.0 : -0.6)
                .foregroundColor(balanceColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // BTX „double height": vertikale Streckung wie das Steuerzeichen (Demo).
                .scaleEffect(x: 1, y: lofi ? 1.15 : 1.0, anchor: .leading)
                // Feste Zeilenhöhe im Lo-Fi-Modus — die Länge des Kontostands darf
                // die Kartenhöhe nie verändern.
                .frame(height: lofi ? 48 : ThemeFonts.lineHeight(forSize: 38, weight: .bold), alignment: .leading)

            if isPayPalCard { paypalSubtitle(detail: detailColor) } else { leftToPaySubtitle }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        // Randlos: Fläche füllt die Karte bis an die Flyout-Kanten (Popover rundet die
        // Ecken). Im Einzelkonto-Modus füllt die Karte die gesamte Popover-Höhe.
        .frame(maxWidth: .infinity, maxHeight: hasDots ? nil : .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [fillTop, fillBottom],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        )
    }
}

