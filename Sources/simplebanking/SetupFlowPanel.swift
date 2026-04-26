import AppKit
import Foundation
import Routex

enum SetupProgress: Sendable {
    case discoveringBank
    case requestingApproval
    case fetchingBalance
    case requestingTransactionApproval
    case fetchingTransactions
    case savingCredentials

    var displayText: String {
        switch self {
        case .discoveringBank: return L10n.t("Bank wird gesucht…", "Searching for bank…")
        case .requestingApproval: return L10n.t("Freigabe angefordert…", "Approval requested…")
        case .fetchingBalance: return L10n.t("Kontostand wird abgerufen…", "Fetching balance…")
        case .requestingTransactionApproval: return L10n.t("Umsätze werden geladen…", "Loading transactions…")
        case .fetchingTransactions: return L10n.t("Umsätze werden geladen…", "Loading transactions…")
        case .savingCredentials: return L10n.t("Daten werden gespeichert…", "Saving data…")
        }
    }

    var subtitle: String {
        switch self {
        case .requestingApproval:
            return L10n.t("Banking-App öffnen und Freigabe bestätigen", "Open your banking app and confirm the approval")
        default:
            return L10n.t("Bitte warten…", "Please wait…")
        }
    }

    var iconName: String {
        switch self {
        case .requestingApproval: return "bell.circle.fill"
        case .fetchingBalance: return "arrow.triangle.2.circlepath.circle.fill"
        case .requestingTransactionApproval: return "arrow.triangle.2.circlepath"
        default: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
}

struct SetupConnectOptions: Sendable {
    var diagnosticsEnabled: Bool = false
    var onProgress: (@Sendable (SetupProgress) -> Void)?
    var onPickAccount: (@Sendable ([Routex.Account]) async -> [Routex.Account]?)?
}

struct SetupConnectActionError: LocalizedError {
    let message: String
    let diagnosticsLogURL: URL?

    var errorDescription: String? {
        message
    }
}

enum SetupWizardOutcome {
    case realBanking(masterPassword: String, bank: DiscoveredBank)
    case demoMode
    case cancelled
}

@MainActor
final class SetupWizardPanel: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    typealias ConnectAction = @Sendable (CredentialsPanel.Result, String?, SetupConnectOptions, String) async throws -> DiscoveredBank

    private enum Step {
        case welcome
        case masterPassword
        case bankSearch
        case credentials
        case connecting
        case accountPicker
        case onboarding(page: Int)
    }

    private struct ButtonRow {
        let stack: NSStackView
        let back: NSButton
        let primary: NSButton
    }

    private let panel: NSPanel
    private let rootStack = NSStackView()
    private let connectAction: ConnectAction
    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 520
    private let fieldWidth: CGFloat = 380

    private var step: Step = .welcome
    private var selectedConnection: ConnectionInfo?          // selected YAXI bank
    private var filteredConnections: [ConnectionInfo] = []   // live search results
    private var completedBank: DiscoveredBank?
    private var connectTask: Task<Void, Never>?
    private var discoverTask: Task<Void, Never>? = nil
    private var searchDebounceTask: Task<Void, Never>? = nil
    private var discoverResult: DiscoveredBank? = nil
    private var hasFailedOnce: Bool = false
    private var diagnosticsLoggingEnabled: Bool = false
    private var latestDiagnosticsLogURL: URL?

    // Wizard-specific state
    private var collectedMasterPassword: String? = nil
    private var existingMasterPassword: String? = nil  // non-nil when adding a second account
    private var outcome: SetupWizardOutcome = .cancelled
    var collectedNickname: String? = nil              // optional per-account short label
    private weak var nicknameTextField: NSTextField?

    // Master password step controls
    private let masterPassField = NSSecureTextField(string: "")
    private let masterConfirmField = NSSecureTextField(string: "")
    private let masterMatchLabel = NSTextField(labelWithString: "")
    private weak var masterNextBtn: NSButton?
    private var strengthBars: [NSView] = []

    // Reused controls for state persistence across step transitions.
    private let bankSearchField = NSSearchField(string: "")
    private let bankPopup = NSPopUpButton()
    private let credentialsStatusLabel = NSTextField(labelWithString: "")
    private let searchHelperLabel = NSTextField(labelWithString: "")
    private let selectedBankLabel = NSTextField(labelWithString: "")
    private let selectedBankChipView = NSView()
    private let selectedBankChipLabel = NSTextField(labelWithString: "")
    private let ibanField = NSTextField(string: "")
    private let userField = NSTextField(string: "")
    private let passField = NSSecureTextField(string: "")
    private let rememberToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let approvalSpinner = NSProgressIndicator()
    private let approvalTitleLabel = NSTextField(labelWithString: "")
    private let approvalSubtitleLabel = NSTextField(labelWithString: "")
    private let approvalIconView = NSImageView()
    private let successSubtitleLabel = NSTextField(labelWithString: "")
    private let diagnosticsToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let diagnosticsPrivacyLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnosticsDeliveryLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnosticsLogPathLabel = NSTextField(labelWithString: "")
    private let diagnosticsOpenFolderButton = NSButton(title: "", target: nil, action: nil)
    private weak var searchContinueButton: NSButton?
    private let discoverSpinner = NSProgressIndicator()
    private var autocompletePanel: NSPanel?
    private var autocompleteTable: NSTableView?

    // IBAN live-detection UI
    private let ibanDetectedRow = NSStackView()
    private let ibanDetectedIcon = NSImageView()
    private let ibanDetectedLabel = NSTextField(labelWithString: "")
    private var ibanPreviewBank: DiscoveredBank? = nil
    private var isFormattingIBAN = false

    // Progress bar
    private let progressBarFill = NSView()
    private var progressBarFillWidthConstraint: NSLayoutConstraint?

    // IBAN not-found mail button
    private let ibanNotFoundMailButton = NSButton(title: "", target: nil, action: nil)

    // Account picker step
    private var accountPickerAccounts: [Routex.Account] = []
    private var accountPickerContinuation: CheckedContinuation<[Routex.Account]?, Never>?
    private var accountPickerCheckboxes: [NSButton] = []

    init(connectAction: @escaping ConnectAction, existingMasterPassword: String? = nil) {
        self.connectAction = connectAction
        self.collectedMasterPassword = existingMasterPassword
        self.existingMasterPassword = existingMasterPassword

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "simplebanking"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.minSize = NSSize(width: panelWidth, height: panelHeight)
        panel.maxSize = NSSize(width: panelWidth, height: panelHeight)

        super.init()
        panel.delegate = self

        setupBaseLayout()
        setupControlDefaults()
        // Ist ein Passwort bereits vorhanden, Welcome- und Passwort-Schritt überspringen
        render(step: existingMasterPassword != nil ? .bankSearch : .welcome)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func runModal() -> SetupWizardOutcome {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        if response == .stop {
            return outcome
        }
        return .cancelled
    }

    func windowWillClose(_ notification: Notification) {
        if case .connecting = step { return }
        if case .accountPicker = step {
            let cont = accountPickerContinuation
            accountPickerContinuation = nil
            cont?.resume(returning: nil)
        }
        NSApp.stopModal(withCode: .abort)
    }

    private func setupBaseLayout() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        // App-Icon-Header (Branding, persistent über alle Setup-Steps).
        // AppIconLoader hat 3-stufige Fallback-Chain — funktioniert auch wenn
        // LaunchServices die App noch nicht registriert hat (direkter
        // Bundle-Disk-Read als letzter Fallback).
        let brandHeader = NSStackView()
        brandHeader.orientation = .horizontal
        brandHeader.spacing = 10
        brandHeader.alignment = .centerY
        brandHeader.edgeInsets = NSEdgeInsets(top: 16, left: 40, bottom: 0, right: 40)
        brandHeader.translatesAutoresizingMaskIntoConstraints = false

        let brandIcon = NSImageView()
        if let icon = AppIconLoader.load() {
            brandIcon.image = icon
        }
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        brandIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        brandIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let brandLabel = NSTextField(labelWithString: "simplebanking")
        brandLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        brandLabel.textColor = .secondaryLabelColor

        brandHeader.addArrangedSubview(brandIcon)
        brandHeader.addArrangedSubview(brandLabel)

        content.addSubview(brandHeader)

        rootStack.orientation = .vertical
        rootStack.spacing = 12
        rootStack.alignment = .leading
        rootStack.edgeInsets = NSEdgeInsets(top: 16, left: 40, bottom: 32, right: 40)
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(rootStack)

        NSLayoutConstraint.activate([
            // Brand-Header oben fixed
            brandHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            brandHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            brandHeader.topAnchor.constraint(equalTo: content.topAnchor, constant: 3),
            // RootStack darunter
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: brandHeader.bottomAnchor),
            rootStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Thin progress bar at very top of content
        let progressTrack = NSView()
        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor.separatorColor.cgColor
        progressTrack.translatesAutoresizingMaskIntoConstraints = false

        progressBarFill.wantsLayer = true
        progressBarFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBarFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressBarFill)
        content.addSubview(progressTrack)

        NSLayoutConstraint.activate([
            progressTrack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressTrack.topAnchor.constraint(equalTo: content.topAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 3),
            progressBarFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressBarFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressBarFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])
        progressBarFillWidthConstraint = progressBarFill.widthAnchor.constraint(equalToConstant: 0)
        progressBarFillWidthConstraint?.isActive = true
    }

    private func setupControlDefaults() {
        // Master password fields
        masterPassField.placeholderString = L10n.t("Mindestens 6 Zeichen", "At least 6 characters")
        masterPassField.font = .systemFont(ofSize: 14)
        masterPassField.bezelStyle = .roundedBezel
        masterPassField.isEditable = true
        masterPassField.isSelectable = true
        masterPassField.isEnabled = true
        masterPassField.translatesAutoresizingMaskIntoConstraints = false

        masterConfirmField.placeholderString = L10n.t("Passwort erneut eingeben", "Repeat password")
        masterConfirmField.font = .systemFont(ofSize: 14)
        masterConfirmField.bezelStyle = .roundedBezel
        masterConfirmField.isEditable = true
        masterConfirmField.isSelectable = true
        masterConfirmField.isEnabled = true
        masterConfirmField.translatesAutoresizingMaskIntoConstraints = false

        masterMatchLabel.font = .systemFont(ofSize: 11)
        masterMatchLabel.isHidden = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMasterConfirmChanged(_:)),
            name: NSControl.textDidChangeNotification,
            object: masterConfirmField
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMasterPassChanged(_:)),
            name: NSControl.textDidChangeNotification,
            object: masterPassField
        )

        // Bank search fields
        bankSearchField.delegate = self
        bankSearchField.placeholderString = L10n.t("Bank suchen…", "Search bank…")
        bankSearchField.sendsSearchStringImmediately = true
        bankSearchField.font = .systemFont(ofSize: 14)
        bankSearchField.isEditable = true
        bankSearchField.isSelectable = true
        bankSearchField.isEnabled = true
        bankSearchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([bankSearchField.widthAnchor.constraint(equalToConstant: fieldWidth)])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onSearchFieldChanged(_:)),
            name: NSControl.textDidChangeNotification,
            object: bankSearchField
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onIBANFieldChanged(_:)),
            name: NSControl.textDidChangeNotification,
            object: ibanField
        )

        bankPopup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([bankPopup.widthAnchor.constraint(equalToConstant: fieldWidth)])

        // Bank chip view (shown under popup after selection)
        selectedBankChipView.wantsLayer = true
        selectedBankChipView.layer?.cornerRadius = 6
        selectedBankChipView.layer?.borderWidth = 1
        selectedBankChipView.isHidden = true
        selectedBankChipView.translatesAutoresizingMaskIntoConstraints = false

        let chipIcon = NSImageView()
        chipIcon.image = NSImage(systemSymbolName: "building.columns", accessibilityDescription: nil)
        chipIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        chipIcon.contentTintColor = .controlAccentColor
        chipIcon.translatesAutoresizingMaskIntoConstraints = false
        chipIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        chipIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        chipIcon.setContentHuggingPriority(.required, for: .horizontal)

        selectedBankChipLabel.font = .systemFont(ofSize: 12, weight: .medium)
        selectedBankChipLabel.textColor = .controlAccentColor
        selectedBankChipLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let chipCheck = NSImageView()
        chipCheck.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        chipCheck.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        chipCheck.contentTintColor = .systemGreen
        chipCheck.translatesAutoresizingMaskIntoConstraints = false
        chipCheck.widthAnchor.constraint(equalToConstant: 16).isActive = true
        chipCheck.heightAnchor.constraint(equalToConstant: 16).isActive = true
        chipCheck.setContentHuggingPriority(.required, for: .horizontal)

        let chipStack = NSStackView(views: [chipIcon, selectedBankChipLabel, chipCheck])
        chipStack.orientation = .horizontal
        chipStack.spacing = 6
        chipStack.alignment = .centerY
        chipStack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        chipStack.translatesAutoresizingMaskIntoConstraints = false

        selectedBankChipView.addSubview(chipStack)
        NSLayoutConstraint.activate([
            chipStack.leadingAnchor.constraint(equalTo: selectedBankChipView.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: selectedBankChipView.trailingAnchor),
            chipStack.topAnchor.constraint(equalTo: selectedBankChipView.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: selectedBankChipView.bottomAnchor),
        ])

        searchHelperLabel.font = .systemFont(ofSize: 12)
        searchHelperLabel.textColor = .secondaryLabelColor
        searchHelperLabel.lineBreakMode = .byTruncatingTail
        searchHelperLabel.maximumNumberOfLines = 1

        selectedBankLabel.font = .systemFont(ofSize: 22, weight: .bold)
        selectedBankLabel.alignment = .center
        selectedBankLabel.lineBreakMode = .byTruncatingTail
        selectedBankLabel.maximumNumberOfLines = 1

        ibanField.placeholderString = "IBAN"
        userField.placeholderString = L10n.t("Dein Banking-Benutzername", "Your banking username")
        passField.placeholderString = L10n.t("Deine Online-Banking PIN", "Your online banking PIN")
        [ibanField, userField, passField].forEach {
            $0.font = .systemFont(ofSize: 14)
            $0.bezelStyle = .roundedBezel
            $0.isEditable = true
            $0.isSelectable = true
            $0.isEnabled = true
            $0.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                $0.heightAnchor.constraint(equalToConstant: 32),
                $0.widthAnchor.constraint(equalToConstant: fieldWidth),
            ])
        }

        rememberToggle.state = .on

        credentialsStatusLabel.font = .systemFont(ofSize: 12)
        credentialsStatusLabel.textColor = .secondaryLabelColor
        credentialsStatusLabel.alignment = .left
        credentialsStatusLabel.lineBreakMode = .byWordWrapping
        credentialsStatusLabel.maximumNumberOfLines = 0
        credentialsStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        credentialsStatusLabel.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        credentialsStatusLabel.isHidden = true

        approvalSpinner.style = .spinning
        approvalSpinner.controlSize = .regular
        approvalSpinner.isDisplayedWhenStopped = false

        approvalTitleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        approvalTitleLabel.alignment = .center

        approvalSubtitleLabel.font = .systemFont(ofSize: 14)
        approvalSubtitleLabel.textColor = .secondaryLabelColor
        approvalSubtitleLabel.alignment = .center

        approvalIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        approvalIconView.contentTintColor = .labelColor

        successSubtitleLabel.font = .systemFont(ofSize: 14)
        successSubtitleLabel.alignment = .center
        successSubtitleLabel.textColor = .secondaryLabelColor
        successSubtitleLabel.maximumNumberOfLines = 2
        successSubtitleLabel.lineBreakMode = .byWordWrapping

        diagnosticsToggle.title = L10n.t("Neu versuchen mit Diagnoselogging", "Retry with diagnostic logging")
        diagnosticsToggle.state = diagnosticsLoggingEnabled ? .on : .off
        diagnosticsToggle.target = self
        diagnosticsToggle.action = #selector(onDiagnosticsToggleChanged)

        diagnosticsPrivacyLabel.stringValue = L10n.t("Es werden keine persönlichen Daten gespeichert.", "No personal data is stored.")
        diagnosticsPrivacyLabel.font = .systemFont(ofSize: 12)
        diagnosticsPrivacyLabel.textColor = .secondaryLabelColor
        diagnosticsPrivacyLabel.maximumNumberOfLines = 2
        diagnosticsPrivacyLabel.lineBreakMode = .byWordWrapping

        diagnosticsDeliveryLabel.stringValue = L10n.t("Log-Datei wird im Log-Ordner abgelegt und muss manuell versendet werden.", "Log file is saved in the log folder and must be sent manually.")
        diagnosticsDeliveryLabel.font = .systemFont(ofSize: 12)
        diagnosticsDeliveryLabel.textColor = .secondaryLabelColor
        diagnosticsDeliveryLabel.maximumNumberOfLines = 3
        diagnosticsDeliveryLabel.lineBreakMode = .byWordWrapping

        diagnosticsLogPathLabel.font = .systemFont(ofSize: 11)
        diagnosticsLogPathLabel.textColor = .secondaryLabelColor
        diagnosticsLogPathLabel.lineBreakMode = .byTruncatingMiddle
        diagnosticsLogPathLabel.maximumNumberOfLines = 1

        diagnosticsOpenFolderButton.title = L10n.t("Log-Ordner öffnen", "Open log folder")
        diagnosticsOpenFolderButton.bezelStyle = .rounded
        diagnosticsOpenFolderButton.target = self
        diagnosticsOpenFolderButton.action = #selector(onOpenDiagnosticsFolder)

        discoverSpinner.style = .spinning
        discoverSpinner.controlSize = .small
        discoverSpinner.isDisplayedWhenStopped = false
        discoverSpinner.translatesAutoresizingMaskIntoConstraints = false
        discoverSpinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        discoverSpinner.heightAnchor.constraint(equalToConstant: 14).isActive = true

        ibanDetectedIcon.image = NSImage(systemSymbolName: "building.columns.circle.fill", accessibilityDescription: nil)
        ibanDetectedIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        ibanDetectedIcon.contentTintColor = .controlAccentColor
        ibanDetectedIcon.translatesAutoresizingMaskIntoConstraints = false
        ibanDetectedIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        ibanDetectedIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        ibanDetectedIcon.setContentHuggingPriority(.required, for: .horizontal)

        ibanDetectedLabel.font = .systemFont(ofSize: 13, weight: .medium)
        ibanDetectedLabel.textColor = .controlAccentColor
        ibanDetectedLabel.lineBreakMode = .byTruncatingTail

        ibanDetectedRow.orientation = .horizontal
        ibanDetectedRow.spacing = 6
        ibanDetectedRow.alignment = .centerY
        ibanDetectedRow.addArrangedSubview(ibanDetectedIcon)
        ibanDetectedRow.addArrangedSubview(ibanDetectedLabel)
        ibanDetectedRow.isHidden = true

        ibanNotFoundMailButton.title = L10n.t("Bank fehlt? Melden →", "Bank missing? Report →")
        ibanNotFoundMailButton.isBordered = false
        ibanNotFoundMailButton.bezelStyle = .inline
        ibanNotFoundMailButton.font = .systemFont(ofSize: 12)
        ibanNotFoundMailButton.contentTintColor = .controlAccentColor
        ibanNotFoundMailButton.target = self
        ibanNotFoundMailButton.action = #selector(openSupportMail)
        ibanNotFoundMailButton.isHidden = true
    }

    private func clearRootContent() {
        let views = rootStack.arrangedSubviews
        views.forEach { view in
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func updateProgressBar(step: Step) {
        let fraction: CGFloat
        switch step {
        case .welcome: fraction = 0
        case .masterPassword: fraction = 0.14
        case .bankSearch: fraction = 0.28
        case .credentials: fraction = 0.42
        case .connecting: fraction = 0.57
        case .accountPicker: fraction = 0.57
        case .onboarding(let page):
            switch page {
            case 0: fraction = existingMasterPassword != nil ? 1.0 : 0.71
            case 1: fraction = 0.85
            case 2: fraction = 1.0
            default: fraction = 0
            }
        }
        progressBarFillWidthConstraint?.constant = panelWidth * fraction
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            progressBarFill.animator().layoutSubtreeIfNeeded()
        }
    }

    private func render(step: Step) {
        hideAutocompletePanel()
        self.step = step
        updateProgressBar(step: step)
        clearRootContent()

        switch step {
        case .connecting, .accountPicker:
            panel.standardWindowButton(.closeButton)?.isEnabled = false
        default:
            panel.standardWindowButton(.closeButton)?.isEnabled = true
        }

        switch step {
        case .welcome:
            renderWelcomeStep()
        case .masterPassword:
            renderMasterPasswordStep()
        case .bankSearch:
            renderSearchStep()
        case .credentials:
            renderCredentialsStep()
        case .connecting:
            renderConnectingStep()
        case .accountPicker:
            renderAccountPickerStep()
        case .onboarding(let page):
            renderOnboardingPage(page)
        }

    }

    // MARK: - Welcome

    private func renderWelcomeStep() {
        rootStack.alignment = .centerX
        rootStack.spacing = 12

        let iconBox = iconContainer(size: 64, cornerRadius: 16, bg: NSColor(white: 0.5, alpha: 0.12), icon: "eurosign", iconSize: 28, tint: .labelColor)

        let title = NSTextField(labelWithString: "simplebanking")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center

        let tagline = NSTextField(labelWithString: t("Dein Kontostand. Immer sichtbar.", "Your balance. Always visible."))
        tagline.font = .systemFont(ofSize: 14, weight: .medium)
        tagline.textColor = NSColor.labelColor.withAlphaComponent(0.8)
        tagline.alignment = .center

        let body = NSTextField(wrappingLabelWithString: t("Keine App öffnen, kein Login – einfach hingucken. Dein Kontostand lebt in der Menüleiste.", "No app to open, no login – just look. Your balance lives in the menu bar."))
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let connectButton = primaryButton(title: t("Jetzt verbinden", "Connect now"), action: #selector(onWelcomeConnect))
        connectButton.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        let demoButton = outlineButton(title: t("Demo-Modus starten", "Start demo mode"), action: #selector(onWelcomeDemo))
        demoButton.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(iconBox)
        rootStack.addArrangedSubview(title)
        rootStack.addArrangedSubview(tagline)
        rootStack.addArrangedSubview(body)
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(connectButton)
        rootStack.addArrangedSubview(demoButton)

        rootStack.setCustomSpacing(16, after: iconBox)
        rootStack.setCustomSpacing(4, after: title)
        rootStack.setCustomSpacing(6, after: tagline)
        rootStack.setCustomSpacing(24, after: body)
        rootStack.setCustomSpacing(8, after: connectButton)
    }

    // MARK: - Master Password

    private func renderMasterPasswordStep() {
        rootStack.alignment = .leading
        rootStack.spacing = 12

        let iconBox = iconContainer(size: 40, cornerRadius: 12, bg: NSColor(white: 0.5, alpha: 0.12), icon: "lock.fill", iconSize: 18, tint: .labelColor)

        let title = NSTextField(labelWithString: t("Schütze deine Daten.", "Protect your data."))
        title.font = .systemFont(ofSize: 19, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: t("Dein Master-Passwort verschlüsselt deine Bank-Zugangsdaten im Keychain.", "Your master password encrypts your bank credentials in the Keychain."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        masterPassField.placeholderString = t("Mindestens 6 Zeichen", "At least 6 characters")
        masterConfirmField.placeholderString = t("Passwort erneut eingeben", "Repeat password")
        masterPassField.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        masterConfirmField.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        // Strength bar
        let barWidth = (fieldWidth - 18) / 4
        strengthBars = (0..<4).map { _ in
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.layer?.backgroundColor = NSColor.separatorColor.cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: barWidth).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
            return bar
        }
        let strengthStack = NSStackView(views: strengthBars)
        strengthStack.orientation = .horizontal
        strengthStack.spacing = 6
        strengthStack.alignment = .centerY
        updateStrengthUI()

        masterMatchLabel.isHidden = masterConfirmField.stringValue.isEmpty

        let info = infoBox(icon: "info.circle", t("Wir speichern dein Passwort nicht – also gut merken. Bei Verlust müssen die Daten neu eingerichtet werden.", "We don't store your password – remember it well. If lost, you'll need to set up everything again."))

        let buttonRow = horizontalButtons(
            backTitle: t("Zurück", "Back"),
            backAction: #selector(onMasterPasswordBack),
            primaryTitle: t("Weiter", "Continue"),
            primaryAction: #selector(onMasterPasswordContinue),
            primaryEnabled: false
        )
        masterNextBtn = buttonRow.primary
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(iconBox)
        rootStack.addArrangedSubview(title)
        rootStack.addArrangedSubview(subtitle)
        rootStack.addArrangedSubview(masterPassField)
        rootStack.addArrangedSubview(strengthStack)
        rootStack.addArrangedSubview(masterConfirmField)
        rootStack.addArrangedSubview(masterMatchLabel)
        rootStack.addArrangedSubview(info)
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(buttonRow.stack)

        rootStack.setCustomSpacing(14, after: iconBox)
        rootStack.setCustomSpacing(4, after: title)
        rootStack.setCustomSpacing(16, after: subtitle)
        rootStack.setCustomSpacing(6, after: masterPassField)
        rootStack.setCustomSpacing(8, after: strengthStack)
        rootStack.setCustomSpacing(6, after: masterConfirmField)
        rootStack.setCustomSpacing(12, after: masterMatchLabel)
        rootStack.setCustomSpacing(16, after: info)

        // Tab chain
        masterPassField.nextKeyView = masterConfirmField
        masterConfirmField.nextKeyView = buttonRow.primary
        buttonRow.primary.nextKeyView = buttonRow.back
        buttonRow.back.nextKeyView = masterPassField
        panel.initialFirstResponder = masterPassField
        DispatchQueue.main.async { [weak self] in
            self?.panel.makeFirstResponder(self?.masterPassField)
        }
    }

    private func updateStrengthUI() {
        let count = masterPassField.stringValue.count
        let colors: [NSColor]
        switch count {
        case 0:
            colors = Array(repeating: NSColor.separatorColor, count: 4)
        case 1...3:
            colors = [.systemRed, .separatorColor, .separatorColor, .separatorColor]
        case 4...5:
            colors = [.systemOrange, .systemOrange, .separatorColor, .separatorColor]
        case 6...7:
            colors = [.systemYellow, .systemYellow, .systemYellow, .separatorColor]
        default:
            colors = Array(repeating: NSColor.systemGreen, count: 4)
        }
        for (i, bar) in strengthBars.enumerated() {
            bar.layer?.backgroundColor = colors[i].cgColor
        }

        let pass = masterPassField.stringValue
        let confirm = masterConfirmField.stringValue
        let ready = pass.count >= 6 && !confirm.isEmpty && pass == confirm
        masterNextBtn?.isEnabled = ready
    }

    // MARK: - Bank Search

    private func renderSearchStep() {
        rootStack.alignment = .leading
        rootStack.spacing = 12

        discoverSpinner.stopAnimation(nil)

        let iconBox = iconContainer(size: 40, cornerRadius: 12, bg: NSColor(white: 0.5, alpha: 0.12), icon: "building.2.fill", iconSize: 18, tint: .labelColor)

        let title = NSTextField(labelWithString: t("Welche Bank nutzt du?", "Which bank do you use?"))
        title.font = .systemFont(ofSize: 19, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: t("Tippe den Namen deiner Bank ein.", "Type the name of your bank."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let statusRow = NSStackView(views: [discoverSpinner, searchHelperLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        let yaxiInfo = infoBox(icon: "lock.shield.fill", t("Sicher & privat via YAXI Open Banking.\nNiemand außer dir sieht deine Zugangsdaten, Umsätze oder deinen Kontostand.\n\nNur Lesezugriff. Keine Überweisungen.", "Secure & private via YAXI Open Banking.\nNo one but you ever sees your credentials, transactions, or balance.\n\nRead-only access. No transfers."))

        let hasConn = selectedConnection != nil
        let buttonRow = horizontalButtons(
            backTitle: t("Zurück", "Back"),
            backAction: #selector(onSearchBack),
            primaryTitle: t("Weiter", "Continue"),
            primaryAction: #selector(onSearchContinue),
            primaryEnabled: hasConn
        )
        searchContinueButton = buttonRow.primary
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(iconBox)
        rootStack.addArrangedSubview(title)
        rootStack.addArrangedSubview(subtitle)
        if let conn = selectedConnection {
            bankSearchField.stringValue = conn.displayName
        }
        rootStack.addArrangedSubview(bankSearchField)
        // Always in the stack — updateBankChip() controls isHidden.
        // This allows autocompleteSelectionChanged() to show it without re-rendering the step.
        updateBankChip()
        rootStack.addArrangedSubview(selectedBankChipView)
        rootStack.addArrangedSubview(statusRow)
        rootStack.addArrangedSubview(yaxiInfo)
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(buttonRow.stack)

        rootStack.setCustomSpacing(14, after: iconBox)
        rootStack.setCustomSpacing(4, after: title)
        rootStack.setCustomSpacing(16, after: subtitle)
        rootStack.setCustomSpacing(8, after: bankSearchField)
        rootStack.setCustomSpacing(8, after: selectedBankChipView)
        rootStack.setCustomSpacing(12, after: statusRow)
        rootStack.setCustomSpacing(16, after: yaxiInfo)

        bankSearchField.nextKeyView = buttonRow.primary
        buttonRow.primary.nextKeyView = buttonRow.back
        buttonRow.back.nextKeyView = bankSearchField
        panel.initialFirstResponder = bankSearchField
        DispatchQueue.main.async { [weak self] in
            self?.panel.makeFirstResponder(self?.bankSearchField)
        }
    }

    // MARK: - Credentials

    private func renderCredentialsStep() {
        rootStack.alignment = .leading
        rootStack.spacing = 12

        let pageTitle = NSTextField(labelWithString: t("Fast geschafft.", "Almost there."))
        pageTitle.font = .systemFont(ofSize: 19, weight: .semibold)

        let subtitle = NSTextField(labelWithString: t("Deine Online-Banking Zugangsdaten", "Your online banking credentials"))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let creds = discoverResult?.credentials
        let needsUserId = creds == nil || creds!.full || creds!.userId
        let needsPassword = creds == nil || creds!.full

        let userLabel = discoverResult?.userIdLabel ?? "Anmeldename / Leg.-ID"
        userField.placeholderString = needsUserId ? t("Dein Banking-Benutzername", "Your banking username") : ""
        userField.isHidden = !needsUserId
        passField.placeholderString = needsPassword ? t("Deine Online-Banking PIN", "Your online banking PIN") : ""
        passField.isHidden = !needsPassword

        var fieldViews: [NSView] = []
        if needsUserId {
            let userGroup = NSStackView(views: [sectionLabel(userLabel), iconField("person", userField)])
            userGroup.orientation = .vertical
            userGroup.spacing = 6
            userGroup.alignment = .leading
            fieldViews.append(userGroup)
        }
        if needsPassword {
            let passGroup = NSStackView(views: [sectionLabel(t("PIN / Passwort", "PIN / Password")), iconField("lock", passField)])
            passGroup.orientation = .vertical
            passGroup.spacing = 6
            passGroup.alignment = .leading
            fieldViews.append(passGroup)
        }

        if let advice = discoverResult?.advice, !advice.isEmpty {
            let adviceLabel = NSTextField(wrappingLabelWithString: advice)
            adviceLabel.font = .systemFont(ofSize: 12)
            adviceLabel.textColor = .secondaryLabelColor
            adviceLabel.translatesAutoresizingMaskIntoConstraints = false
            adviceLabel.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            fieldViews.append(adviceLabel)
        }

        // Credentials are always saved (required for auto-refresh).
        // Show as a static info line instead of a toggle to avoid misleading the user.
        let credStorageInfo = NSTextField(labelWithString: t(
            "🔒 Zugangsdaten werden verschlüsselt gespeichert (AES-256)",
            "🔒 Credentials are stored encrypted (AES-256)"
        ))
        credStorageInfo.font = .systemFont(ofSize: 11)
        credStorageInfo.textColor = .secondaryLabelColor
        fieldViews.append(credStorageInfo)

        fieldViews.append(credentialsStatusLabel)
        credentialsStatusLabel.isHidden = credentialsStatusLabel.stringValue.isEmpty

        let fields = NSStackView(views: fieldViews)
        fields.orientation = .vertical
        fields.spacing = 14
        fields.alignment = .leading

        let securityInfo = infoBox(icon: "checkmark.shield.fill", t("Deine Bank-Zugangsdaten werden im Keychain verschlüsselt (AES-256). Umsätze werden lokal in einer SQLite-DB zwischengespeichert (für Offline-Zugriff via CLI/MCP). Für Kontoabfragen verbindet sich die App mit YAXI. Der optionale KI-Chat sendet Daten an Anthropic.", "Your bank credentials are encrypted in the Keychain (AES-256). Transactions are cached locally in a SQLite DB (for offline CLI/MCP access). For account queries, the app connects to YAXI. The optional AI chat sends data to Anthropic."), tint: .systemGreen)

        let buttonRow = horizontalButtons(
            backTitle: t("Zurück", "Back"),
            backAction: #selector(onCredentialsBack),
            primaryTitle: t("Verbinden", "Connect"),
            primaryAction: #selector(onCredentialsConnect),
            primaryEnabled: true
        )
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(pageTitle)
        rootStack.addArrangedSubview(subtitle)
        rootStack.addArrangedSubview(fields)
        rootStack.addArrangedSubview(securityInfo)
        if hasFailedOnce {
            rootStack.addArrangedSubview(makeDiagnosticsSection())
        }
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(buttonRow.stack)
        rootStack.setCustomSpacing(4, after: pageTitle)
        rootStack.setCustomSpacing(16, after: subtitle)
        rootStack.setCustomSpacing(12, after: fields)
        rootStack.setCustomSpacing(16, after: securityInfo)

        let firstField: NSTextField? = needsUserId ? userField : (needsPassword ? passField : nil)
        if needsUserId { userField.nextKeyView = needsPassword ? passField : buttonRow.primary }
        passField.nextKeyView = buttonRow.primary
        buttonRow.primary.nextKeyView = buttonRow.back
        buttonRow.back.nextKeyView = firstField ?? buttonRow.primary
        panel.initialFirstResponder = firstField
        DispatchQueue.main.async { [weak self] in
            guard let self, let first = firstField else { return }
            self.panel.makeFirstResponder(first)
        }
    }

    // MARK: - Connecting

    private func renderConnectingStep() {
        rootStack.alignment = .centerX

        let initial: SetupProgress = .discoveringBank
        approvalIconView.image = NSImage(systemSymbolName: initial.iconName, accessibilityDescription: "Setup")
        approvalTitleLabel.stringValue = initial.displayText
        approvalSubtitleLabel.stringValue = initial.subtitle

        let spacerTop = NSView()
        spacerTop.heightAnchor.constraint(equalToConstant: 18).isActive = true

        approvalSpinner.startAnimation(nil)

        let cancelButton = NSButton(title: t("Verbindung abbrechen", "Cancel connection"), target: self, action: #selector(onCancelConnection))
        cancelButton.bezelStyle = .inline
        cancelButton.font = .systemFont(ofSize: 12)

        let spacerBottom = NSView()
        spacerBottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true

        [spacerTop, approvalIconView, approvalTitleLabel, approvalSubtitleLabel, approvalSpinner, cancelButton, spacerBottom].forEach {
            rootStack.addArrangedSubview($0)
        }
        rootStack.setCustomSpacing(12, after: approvalSpinner)
    }

    // MARK: - Account Picker

    private func renderAccountPickerStep() {
        approvalSpinner.stopAnimation(nil)
        rootStack.alignment = .leading
        rootStack.spacing = 16

        // Sort: Girokonto (current) first — that's what this app is designed for.
        // Others follow in a sensible order; within each type keep original API order.
        let typePriority: (Routex.AccountType?) -> Int = { type in
            switch type {
            case .current:   return 0
            case .savings:   return 1
            case .callMoney: return 2
            case .card:      return 3
            default:         return 4
            }
        }
        accountPickerAccounts = accountPickerAccounts.sorted { typePriority($0.type) < typePriority($1.type) }

        let titleLabel = NSTextField(labelWithString: t("Konten auswählen", "Choose accounts"))
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let subtitleLabel = NSTextField(wrappingLabelWithString: t(
            "Wähle die Konten, die Du in simplebanking sehen möchtest. Für die meisten Nutzer reicht das Girokonto.",
            "Choose which accounts to include. For most users the checking account is sufficient."
        ))
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.preferredMaxLayoutWidth = fieldWidth

        accountPickerCheckboxes = []
        let checkboxStack = NSStackView()
        checkboxStack.orientation = .vertical
        checkboxStack.alignment = .leading
        checkboxStack.spacing = 8

        for (index, account) in accountPickerAccounts.enumerated() {
            let iban = account.iban?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let owner = account.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let display = account.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let product = account.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let currency = account.currency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let typeLabel: String = {
                switch account.type {
                case .current:   return t("Girokonto", "Checking")
                case .savings:   return t("Sparkonto", "Savings")
                case .callMoney: return t("Tagesgeld", "Call money")
                case .card:      return t("Kreditkarte", "Credit card")
                default: return ""
                }
            }()
            var parts: [String] = []
            if !typeLabel.isEmpty { parts.append(typeLabel) }
            if !display.isEmpty { parts.append(display) }
            if !product.isEmpty && product != display { parts.append(product) }
            if !owner.isEmpty && owner != display { parts.append(owner) }
            if !currency.isEmpty { parts.append(currency) }
            if !iban.isEmpty { parts.append(iban) }
            let title = parts.isEmpty
                ? t("Konto \(index + 1)", "Account \(index + 1)")
                : parts.joined(separator: " · ")
            let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            // Pre-select only Girokonten (current); unknown type also gets pre-selected
            // since we can't tell what it is — better to include than to miss the main account.
            checkbox.state = (account.type == .current || account.type == nil) ? .on : .off
            checkboxStack.addArrangedSubview(checkbox)
            accountPickerCheckboxes.append(checkbox)
        }

        let checkboxContainer: NSView
        if accountPickerAccounts.count > 4 {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.documentView = checkboxStack
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            checkboxStack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                checkboxStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
                checkboxStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
                checkboxStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            ])
            scrollView.heightAnchor.constraint(equalToConstant: 120).isActive = true
            scrollView.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            checkboxContainer = scrollView
        } else {
            checkboxContainer = checkboxStack
        }

        let continueBtn = primaryButton(title: t("Weiter", "Continue"), action: #selector(onAccountPickerContinue))
        continueBtn.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        let cancelBtn = NSButton(title: t("Abbrechen", "Cancel"), target: self, action: #selector(onAccountPickerCancel))
        cancelBtn.bezelStyle = .inline
        cancelBtn.font = .systemFont(ofSize: 12)

        [titleLabel, subtitleLabel, checkboxContainer, continueBtn, cancelBtn].forEach {
            rootStack.addArrangedSubview($0)
        }
        rootStack.setCustomSpacing(8, after: subtitleLabel)
    }

    @objc private func onAccountPickerContinue() {
        let selected = accountPickerCheckboxes.enumerated().compactMap { (i, btn) in
            btn.state == .on ? (accountPickerAccounts.indices.contains(i) ? accountPickerAccounts[i] : nil) : nil
        }
        let cont = accountPickerContinuation
        accountPickerContinuation = nil
        if selected.isEmpty {
            cont?.resume(returning: nil)
        } else {
            render(step: .connecting)
            cont?.resume(returning: selected)
        }
    }

    @objc private func onAccountPickerCancel() {
        let cont = accountPickerContinuation
        accountPickerContinuation = nil
        cont?.resume(returning: nil)
        // connectTask will throw .cancelled → handleConnectFailure → back to credentials
    }

    private func updateProgress(_ progress: SetupProgress) {
        approvalIconView.image = NSImage(systemSymbolName: progress.iconName, accessibilityDescription: "Setup")
        approvalTitleLabel.stringValue = progress.displayText
        approvalSubtitleLabel.stringValue = progress.subtitle
    }

    // MARK: - Onboarding

    private func renderOnboardingPage(_ page: Int) {
        approvalSpinner.stopAnimation(nil)

        let totalPages = 3
        guard page >= 0 && page < totalPages else { return }

        switch page {
        case 0:
            renderOnboardingPage0()
        case 1:
            renderOnboardingPage1()
        case 2:
            renderOnboardingPage2()
        default:
            break
        }
    }

    private func renderOnboardingPage0() {
        rootStack.alignment = .centerX
        rootStack.spacing = 12

        let iconBox = iconContainer(size: 56, cornerRadius: 28, bg: NSColor.systemGreen.withAlphaComponent(0.1), icon: "checkmark.circle.fill", iconSize: 24, tint: .systemGreen)

        let titleLabel = NSTextField(labelWithString: t("Geschafft.", "Done."))
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.alignment = .center

        let bankName = completedBank?.displayName ?? "Bank"
        let bankConnected = NSTextField(labelWithString: "\(bankName) \(t("verbunden", "connected"))")
        bankConnected.font = .systemFont(ofSize: 13, weight: .medium)
        bankConnected.textColor = NSColor.labelColor.withAlphaComponent(0.8)
        bankConnected.alignment = .center

        let body = NSTextField(wrappingLabelWithString: t("Ab jetzt siehst du deinen Kontostand direkt in der Menüleiste.", "From now on, your balance is visible directly in the menu bar."))
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center

        let tipBox = infoBox(icon: "lightbulb.fill", t("Tipp: Klick auf den Kontostand in der Menüleiste, um deine Umsätze zu durchsuchen.", "Tip: Click on your balance in the menu bar to browse your transactions."))

        // Nickname field
        let nicknameLabel = NSTextField(labelWithString: t("Kurzname (optional)", "Nickname (optional)"))
        nicknameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nicknameLabel.textColor = .secondaryLabelColor

        let nicknameField = NSTextField(string: collectedNickname ?? "")
        nicknameField.placeholderString = t("z.B. Privat, Reisen, USD…", "e.g. Personal, Travel, USD…")
        nicknameField.font = .systemFont(ofSize: 13)
        nicknameField.isBezeled = true
        nicknameField.bezelStyle = .roundedBezel
        nicknameField.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        self.nicknameTextField = nicknameField

        let isAddingAccount = existingMasterPassword != nil
        let nextTitle = isAddingAccount ? t("Fertig", "Done") : t("Weiter", "Continue")
        let nextBtn = primaryButton(title: nextTitle, action: #selector(onOnboardingNext(_:)))
        nextBtn.tag = 0
        nextBtn.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(iconBox)
        rootStack.addArrangedSubview(titleLabel)
        rootStack.addArrangedSubview(bankConnected)
        rootStack.addArrangedSubview(body)
        if !isAddingAccount {
            rootStack.addArrangedSubview(tipBox)
        }
        rootStack.addArrangedSubview(nicknameLabel)
        rootStack.addArrangedSubview(nicknameField)
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(nextBtn)

        rootStack.setCustomSpacing(16, after: iconBox)
        rootStack.setCustomSpacing(4, after: titleLabel)
        rootStack.setCustomSpacing(6, after: bankConnected)
        rootStack.setCustomSpacing(20, after: body)
        if !isAddingAccount {
            rootStack.setCustomSpacing(20, after: tipBox)
        }
        rootStack.setCustomSpacing(4, after: nicknameLabel)
        rootStack.setCustomSpacing(16, after: nicknameField)
    }

    private func renderOnboardingPage1() {
        rootStack.alignment = .leading
        rootStack.spacing = 12

        let titleLabel = NSTextField(labelWithString: t("Alles im Überblick.", "Everything at a glance."))
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: t("So holst du das Beste aus simplebanking heraus.", "Get the most out of simplebanking."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let f1 = featureRow(icon: "cursorarrow.rays", title: t("Ein Klick auf deinen Kontostand", "One click on your balance"), body: t("Alle Umsätze sofort durchsuchbar und filterbar.", "All transactions instantly searchable and filterable."))
        let f2 = featureRow(icon: "arrow.clockwise", title: t("Automatische Updates", "Automatic updates"), body: t("Immer aktuell, ohne dass du etwas tun musst.", "Always up to date, without any effort."))
        let f3 = featureRow(icon: "ellipsis", title: t("Rechtsklick für mehr", "Right-click for more"), body: t("Einstellungen, Sperre, Demo-Modus – alles erreichbar.", "Settings, lock, demo mode – all accessible."))

        let features = NSStackView(views: [f1, f2, f3])
        features.orientation = .vertical
        features.spacing = 14
        features.alignment = .leading

        let buttonRow = horizontalButtons(
            backTitle: t("Zurück", "Back"),
            backAction: #selector(onOnboardingBack),
            primaryTitle: t("Weiter", "Continue"),
            primaryAction: #selector(onOnboardingNext(_:)),
            primaryEnabled: true
        )
        buttonRow.primary.tag = 1
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(titleLabel)
        rootStack.addArrangedSubview(subtitle)
        rootStack.addArrangedSubview(features)
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(buttonRow.stack)

        rootStack.setCustomSpacing(4, after: titleLabel)
        rootStack.setCustomSpacing(20, after: subtitle)
        rootStack.setCustomSpacing(20, after: features)
    }

    private func renderOnboardingPage2() {
        rootStack.alignment = .leading
        rootStack.spacing = 12

        let titleLabel = NSTextField(labelWithString: t("100 % sicher. 100 % lokal.", "100% secure. 100% local."))
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: t("Deine Finanzdaten gehören nur dir.", "Your financial data belongs only to you."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let f1 = featureRow(icon: "checkmark.shield.fill", title: t("Bank-Zugangsdaten verschlüsselt", "Bank credentials encrypted"), body: t("Login + Passwort verschlüsselt im Keychain. Umsätze als lokaler Cache (für CLI/MCP).", "Login + password encrypted in the Keychain. Transactions kept as local cache (for CLI/MCP)."))
        let f2 = featureRow(icon: "touchid", title: t("Touch ID verfügbar", "Touch ID available"), body: t("Einmal einrichten, dann ohne Passwort entsperren.", "Set up once, then unlock without a password."))
        let f3 = featureRow(icon: "wifi.slash", title: t("Keine Cloud", "No cloud"), body: t("Wir schicken nichts ins Internet. Alles bleibt hier.", "We send nothing to the internet. Everything stays here."))

        let features = NSStackView(views: [f1, f2, f3])
        features.orientation = .vertical
        features.spacing = 14
        features.alignment = .leading

        let pills = pillsRow(["Open Banking", "Open Source", "macOS native"])

        let buttonRow = horizontalButtons(
            backTitle: t("Zurück", "Back"),
            backAction: #selector(onOnboardingBack),
            primaryTitle: t("Los geht's!", "Let's go!"),
            primaryAction: #selector(onOnboardingNext(_:)),
            primaryEnabled: true
        )
        buttonRow.primary.tag = 2
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(titleLabel)
        rootStack.addArrangedSubview(subtitle)
        rootStack.addArrangedSubview(features)
        rootStack.addArrangedSubview(pills)
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(buttonRow.stack)

        rootStack.setCustomSpacing(4, after: titleLabel)
        rootStack.setCustomSpacing(20, after: subtitle)
        rootStack.setCustomSpacing(14, after: features)
        rootStack.setCustomSpacing(20, after: pills)
    }

    // MARK: - Helpers

    private func t(_ de: String, _ en: String) -> String {
        L10n.t(de, en)
    }

    private func flexSpacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        return v
    }

    private func iconContainer(size: CGFloat, cornerRadius: CGFloat, bg: NSColor, icon: String, iconSize: CGFloat, tint: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = bg.cgColor
        container.layer?.cornerRadius = cornerRadius
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size),
            container.heightAnchor.constraint(equalToConstant: size)
        ])
        let img = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
        img.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        img.contentTintColor = tint
        img.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(img)
        NSLayoutConstraint.activate([
            img.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            img.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func primaryButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .regularSquare
        btn.isBordered = true
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        btn.keyEquivalent = "\r"
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return btn
    }

    private func outlineButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .regularSquare
        btn.isBordered = true
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        btn.layer?.borderWidth = 1
        btn.layer?.borderColor = NSColor.separatorColor.cgColor
        btn.layer?.backgroundColor = NSColor.clear.cgColor
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return btn
    }

    private func horizontalButtons(
        backTitle: String,
        backAction: Selector,
        primaryTitle: String,
        primaryAction: Selector,
        primaryEnabled: Bool
    ) -> ButtonRow {
        let half = (fieldWidth - 8) / 2

        let back = outlineButton(title: backTitle, action: backAction)
        back.widthAnchor.constraint(equalToConstant: half).isActive = true

        let primary = primaryButton(title: primaryTitle, action: primaryAction)
        primary.widthAnchor.constraint(equalToConstant: half).isActive = true
        primary.isEnabled = primaryEnabled

        let stack = NSStackView(views: [back, primary])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return ButtonRow(stack: stack, back: back, primary: primary)
    }

    private func iconField(_ systemName: String, _ field: NSTextField) -> NSView {
        for c in field.constraints where c.firstAttribute == .width && c.secondItem == nil {
            c.isActive = false
        }
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        img.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        img.contentTintColor = .placeholderTextColor
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 16).isActive = true
        img.heightAnchor.constraint(equalToConstant: 16).isActive = true
        img.setContentHuggingPriority(.required, for: .horizontal)
        img.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [img, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        return row
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func infoBox(icon: String = "info.circle", _ text: String, tint: NSColor = .secondaryLabelColor) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.08).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        container.layer?.borderWidth = 0.5
        container.translatesAutoresizingMaskIntoConstraints = false

        let img = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        img.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        img.contentTintColor = tint
        img.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([img.widthAnchor.constraint(equalToConstant: 16), img.heightAnchor.constraint(equalToConstant: 16)])

        let lbl = NSTextField(wrappingLabelWithString: text)
        lbl.font = .systemFont(ofSize: 11)
        lbl.textColor = .secondaryLabelColor

        let inner = NSStackView(views: [img, lbl])
        inner.orientation = .horizontal
        inner.spacing = 8
        inner.alignment = .top
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        container.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        return container
    }

    private func featureRow(icon: String, title: String, body: String) -> NSView {
        let iconBox = iconContainer(size: 40, cornerRadius: 12, bg: NSColor(white: 0.5, alpha: 0.12), icon: icon, iconSize: 18, tint: .labelColor)

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.font = .systemFont(ofSize: 13, weight: .semibold)

        let bodyLbl = NSTextField(wrappingLabelWithString: body)
        bodyLbl.font = .systemFont(ofSize: 12)
        bodyLbl.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLbl, bodyLbl])
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading

        let row = NSStackView(views: [iconBox, textStack])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    private func pillsRow(_ labels: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        for label in labels {
            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 12
            pill.layer?.borderColor = NSColor.separatorColor.cgColor
            pill.layer?.borderWidth = 0.5
            pill.translatesAutoresizingMaskIntoConstraints = false

            let lbl = NSTextField(labelWithString: label)
            lbl.font = .systemFont(ofSize: 11, weight: .medium)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
                lbl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
                lbl.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
                lbl.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
            ])
            stack.addArrangedSubview(pill)
        }
        return stack
    }

    private func updateBankChip() {
        if let conn = selectedConnection {
            selectedBankChipLabel.stringValue = conn.displayName
            selectedBankChipView.isHidden = false
            selectedBankChipView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            selectedBankChipView.isHidden = true
        }
    }

    // MARK: - Actions: Welcome

    @objc private func onWelcomeConnect() {
        render(step: .masterPassword)
    }

    @objc private func onWelcomeDemo() {
        outcome = .demoMode
        NSApp.stopModal(withCode: .stop)
    }

    // MARK: - Actions: Master Password

    @objc private func onMasterPassChanged(_ notification: Notification) {
        updateMasterMatchLabel()
        updateStrengthUI()
    }

    @objc private func onMasterConfirmChanged(_ notification: Notification) {
        updateMasterMatchLabel()
        updateStrengthUI()
    }

    private func updateMasterMatchLabel() {
        let pass = masterPassField.stringValue
        let confirm = masterConfirmField.stringValue
        guard !confirm.isEmpty else {
            masterMatchLabel.isHidden = true
            return
        }
        masterMatchLabel.isHidden = false
        if pass == confirm {
            masterMatchLabel.stringValue = "✓ \(t("Passwörter stimmen überein", "Passwords match"))"
            masterMatchLabel.textColor = .systemGreen
        } else {
            masterMatchLabel.stringValue = "✗ \(t("Passwörter stimmen nicht überein", "Passwords do not match"))"
            masterMatchLabel.textColor = .systemRed
        }
    }

    @objc private func onMasterPasswordBack() {
        render(step: .welcome)
    }

    @objc private func onMasterPasswordContinue() {
        let pass = masterPassField.stringValue
        let confirm = masterConfirmField.stringValue
        guard pass.count >= 4 else {
            masterMatchLabel.stringValue = "✗ \(t("Mindestens 6 Zeichen", "At least 6 characters"))"
            masterMatchLabel.textColor = .systemRed
            masterMatchLabel.isHidden = false
            NSSound.beep()
            return
        }
        guard pass == confirm else {
            masterMatchLabel.stringValue = "✗ \(t("Passwörter stimmen nicht überein", "Passwords do not match"))"
            masterMatchLabel.textColor = .systemRed
            masterMatchLabel.isHidden = false
            NSSound.beep()
            return
        }
        collectedMasterPassword = pass
        render(step: .bankSearch)
    }

    // MARK: - Actions: Bank Search

    @objc private func onSearchFieldChanged(_ notification: Notification) {
        liveSearchBanks()
    }

    private func autocompleteSelectionChanged() {
        guard let table = autocompleteTable else { return }
        let idx = table.selectedRow
        guard idx >= 0, idx < filteredConnections.count else { return }
        selectedConnection = filteredConnections[idx]
        bankSearchField.stringValue = filteredConnections[idx].displayName
        updateBankChip()
        hideAutocompletePanel()
        searchContinueButton?.isEnabled = true
    }

    @objc private func autocompleteTableDoubleClick() {
        autocompleteSelectionChanged()
    }

    private func liveSearchBanks() {
        let query = bankSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            filteredConnections = []
            hideAutocompletePanel()
            return
        }

        searchDebounceTask?.cancel()
        searchDebounceTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // 400 ms debounce
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }

            let results = await YaxiService.searchBanks(query: query)
            guard !Task.isCancelled else { return }

            Self.enqueueOnMainRunLoop { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard case .bankSearch = self.step else { return }
                    self.filteredConnections = results
                    guard !results.isEmpty else {
                        self.hideAutocompletePanel()
                        return
                    }
                    self.autocompleteTable?.reloadData()
                    self.autocompleteTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.showAutocompletePanel()
                }
            }
        }
    }

    private func showAutocompletePanel() {
        // Build panel on first use
        if autocompletePanel == nil {
            let tableView = NSTableView()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bank"))
            column.isEditable = false
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.rowHeight = 28
            tableView.dataSource = self
            tableView.delegate = self
            tableView.doubleAction = #selector(autocompleteTableDoubleClick)
            tableView.target = self
            tableView.focusRingType = .none
            tableView.translatesAutoresizingMaskIntoConstraints = false
            autocompleteTable = tableView

            let scrollView = NSScrollView()
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder

            let acPanel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            acPanel.level = .popUpMenu
            acPanel.isOpaque = false
            acPanel.hasShadow = true
            acPanel.contentView = scrollView
            acPanel.backgroundColor = .controlBackgroundColor
            autocompletePanel = acPanel
        }

        autocompleteTable?.reloadData()

        // Position below bankSearchField in screen coordinates
        guard let fieldWindow = bankSearchField.window,
              let screenFrame = bankSearchField.window?.convertToScreen(
                bankSearchField.convert(bankSearchField.bounds, to: nil)
              ) else { return }

        let rowCount = min(filteredConnections.count, 7)
        let acPanelHeight = CGFloat(rowCount) * 28 + 4
        let panelFrame = NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY - acPanelHeight - 2,
            width: screenFrame.width,
            height: acPanelHeight
        )

        autocompletePanel?.setFrame(panelFrame, display: false)

        if autocompletePanel?.parent == nil {
            fieldWindow.addChildWindow(autocompletePanel!, ordered: .above)
        }
        autocompletePanel?.orderFront(nil)
    }

    private func hideAutocompletePanel() {
        guard let acPanel = autocompletePanel, acPanel.isVisible else { return }
        acPanel.parent?.removeChildWindow(acPanel)
        acPanel.orderOut(nil)
    }

    // MARK: - NSTableViewDataSource

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { filteredConnections.count }
    }

    // MARK: - NSTableViewDelegate

    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            let conn = filteredConnections[row]
            let cell = NSTextField(labelWithString: conn.displayName)
            cell.font = .systemFont(ofSize: 13)
            cell.lineBreakMode = .byTruncatingTail
            return cell
        }
    }

    nonisolated func tableViewSelectionDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let event = NSApp.currentEvent else { return }
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
                autocompleteSelectionChanged()
            default:
                break
            }
        }
    }

    // MARK: - NSTextFieldDelegate (keyboard navigation)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === bankSearchField,
              let table = autocompleteTable,
              let acPanel = autocompletePanel, acPanel.isVisible else { return false }

        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            let next = min(table.selectedRow + 1, filteredConnections.count - 1)
            table.selectRowIndexes(IndexSet(integer: max(next, 0)), byExtendingSelection: false)
            table.scrollRowToVisible(max(next, 0))
            return true
        case #selector(NSResponder.moveUp(_:)):
            let prev = max(table.selectedRow - 1, 0)
            table.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            table.scrollRowToVisible(prev)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            autocompleteSelectionChanged()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideAutocompletePanel()
            return true
        default:
            return false
        }
    }

    @objc private func onSearchBack() {
        render(step: .masterPassword)
    }

    @objc private func onSearchContinue() {
        guard let conn = selectedConnection else { return }

        searchContinueButton?.isEnabled = false
        discoverSpinner.startAnimation(nil)
        searchHelperLabel.stringValue = ""

        // Build DiscoveredBank from the already-selected ConnectionInfo
        discoverResult = DiscoveredBank(
            id: conn.id,
            displayName: conn.displayName,
            logoId: conn.logoId,
            credentials: DiscoveredBankCredentials(
                full: conn.credentials.full,
                userId: conn.credentials.userId,
                none: conn.credentials.none
            ),
            userIdLabel: conn.userId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            advice: conn.advice?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )

        discoverTask?.cancel()
        discoverTask = Task.detached(priority: .userInitiated) { [weak self, conn] in
            guard let self else { return }
            // Preserve session tokens so YAXI can reuse an existing recurring consent
            // (push TAN instead of full browser redirect on re-connect).
            await YaxiService.clearConnectionDataKeepingSessions()
            guard !Task.isCancelled else { return }
            YaxiService.storeConnectionInfo(conn)
            Self.enqueueOnMainRunLoop { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.discoverSpinner.stopAnimation(nil)
                    self.render(step: .credentials)
                }
            }
        }
    }

    @objc private func onIBANFieldChanged(_ notification: Notification) {
        guard !isFormattingIBAN else { return }

        let raw = ibanField.stringValue
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        // Format IBAN as groups of 4 (DE89 3704 0044 ...)
        var formatted = ""
        for (i, ch) in raw.enumerated() {
            if i > 0 && i % 4 == 0 { formatted += " " }
            formatted += String(ch)
        }
        isFormattingIBAN = true
        ibanField.stringValue = formatted
        isFormattingIBAN = false

        // Reset detection if IBAN changed
        if raw.count < 15 {
            ibanPreviewBank = nil
            ibanDetectedRow.isHidden = true
            ibanNotFoundMailButton.isHidden = true
            discoverTask?.cancel()
            searchHelperLabel.stringValue = ""
            searchContinueButton?.isEnabled = false
        } else {
            ibanNotFoundMailButton.isHidden = true
            triggerLiveIBANPreview(iban: raw)
        }
    }

    private func triggerLiveIBANPreview(iban: String) {
        discoverTask?.cancel()
        ibanDetectedRow.isHidden = true
        ibanPreviewBank = nil
        ibanNotFoundMailButton.isHidden = true
        searchContinueButton?.isEnabled = false
        discoverSpinner.startAnimation(nil)
        searchHelperLabel.stringValue = L10n.t("Bank wird erkannt…", "Detecting bank…")
        searchHelperLabel.textColor = .secondaryLabelColor

        discoverTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Debounce: wait for typing to settle
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }

            let bank = await YaxiService.previewBank(iban: iban)
            guard !Task.isCancelled else { return }

            Self.enqueueOnMainRunLoop { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.discoverSpinner.stopAnimation(nil)
                    if let bank {
                        self.ibanPreviewBank = bank
                        self.ibanDetectedLabel.stringValue = "\(bank.displayName) \(L10n.t("erkannt", "detected"))"
                        self.ibanDetectedRow.isHidden = false
                        self.searchHelperLabel.stringValue = ""
                        self.ibanNotFoundMailButton.isHidden = true
                        self.searchContinueButton?.isEnabled = true
                    } else {
                        self.ibanPreviewBank = nil
                        self.ibanDetectedRow.isHidden = true
                        self.searchHelperLabel.stringValue = L10n.t("Ungültige IBAN – bitte prüfen", "Invalid IBAN – please check")
                        self.searchHelperLabel.textColor = .secondaryLabelColor
                        self.ibanNotFoundMailButton.isHidden = false
                        self.searchContinueButton?.isEnabled = false
                    }
                }
            }
        }
    }

    @objc private func openYaxiWebsite() {
        NSWorkspace.shared.open(URL(string: "https://yaxi.tech")!)
    }

    @objc private func openSupportMail() {
        NSWorkspace.shared.open(URL(string: "mailto:support@simplebanking.de?subject=IBAN")!)
    }

    // MARK: - Actions: Credentials

    @objc private func onCredentialsBack() {
        credentialsStatusLabel.stringValue = ""
        credentialsStatusLabel.isHidden = true
        discoverResult = nil
        render(step: .bankSearch)
    }

    @objc private func onCredentialsConnect() {
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue

        AppLogger.log(
            "SetupUI connect tapped userLen=\(user.count) passLen=\(pass.count)",
            category: "SetupUI"
        )

        credentialsStatusLabel.stringValue = ""
        credentialsStatusLabel.isHidden = true

        let bankName = discoverResult?.displayName ?? selectedConnection?.displayName
        let payload = CredentialsPanel.Result(
            iban: "",
            userId: user,
            password: pass,
            bankName: bankName
        )
        let options = SetupConnectOptions(
            diagnosticsEnabled: diagnosticsLoggingEnabled
        )
        beginConnection(with: payload, selectedBankName: bankName, options: options)
    }

    private func beginConnection(
        with payload: CredentialsPanel.Result,
        selectedBankName: String?,
        options: SetupConnectOptions
    ) {
        guard let masterPassword = collectedMasterPassword else { return }

        AppLogger.log(
            "SetupUI beginConnection selectedBank=\(selectedBankName ?? "-") diagnostics=\(options.diagnosticsEnabled)",
            category: "SetupUI"
        )
        render(step: .connecting)
        let action = connectAction
        connectTask?.cancel()

        var optionsWithProgress = options
        optionsWithProgress.onProgress = { [weak self] progress in
            Self.enqueueOnMainRunLoop { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.updateProgress(progress)
                }
            }
        }
        optionsWithProgress.onPickAccount = { [weak self] accounts in
            return await withCheckedContinuation { (cont: CheckedContinuation<[Routex.Account]?, Never>) in
                Self.enqueueOnMainRunLoop { [weak self] in
                    guard let self else {
                        cont.resume(returning: nil)
                        return
                    }
                    MainActor.assumeIsolated {
                        self.accountPickerAccounts = accounts
                        self.accountPickerContinuation = cont
                        self.render(step: .accountPicker)
                    }
                }
            }
        }

        connectTask = Task.detached(priority: .userInitiated) { [weak self] in
            AppLogger.log("SetupUI connect task started", category: "SetupUI")
            do {
                AppLogger.log("SetupUI connectAction invoke", category: "SetupUI")
                let bank = try await action(payload, selectedBankName, optionsWithProgress, masterPassword)
                AppLogger.log("SetupUI connectAction success bank=\(bank.displayName)", category: "SetupUI")
                guard !Task.isCancelled else { return }
                Self.enqueueOnMainRunLoop { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.handleConnectSuccess(bank, masterPassword: masterPassword)
                    }
                }
            } catch is CancellationError {
                AppLogger.log("SetupUI connect task cancelled", category: "SetupUI", level: "WARN")
                return
            } catch {
                let setupError = error as? SetupConnectActionError
                let message = setupError?.message ?? error.localizedDescription
                let diagnosticsLogURL = setupError?.diagnosticsLogURL
                AppLogger.log("SetupUI connectAction failed error=\(message)", category: "SetupUI", level: "ERROR")
                guard !Task.isCancelled else { return }
                Self.enqueueOnMainRunLoop { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.handleConnectFailure(message: message, diagnosticsLogURL: diagnosticsLogURL)
                    }
                }
            }
        }
    }

    // MARK: - Actions: Connecting

    @objc private func onCancelConnection() {
        connectTask?.cancel()
        render(step: .credentials)
    }

    // MARK: - Actions: Onboarding

    @objc private func onOnboardingBack() {
        guard case .onboarding(let page) = step else { return }
        if page > 0 {
            render(step: .onboarding(page: page - 1))
        }
    }

    @objc private func onOnboardingNext(_ sender: NSButton) {
        guard case .onboarding(let page) = step else { return }
        // Save nickname from page 0
        if page == 0 {
            let text = nicknameTextField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            collectedNickname = text.isEmpty ? nil : text
        }
        // Second-account flow: only page 0, then done
        let totalPages = existingMasterPassword != nil ? 1 : 3
        if page < totalPages - 1 {
            render(step: .onboarding(page: page + 1))
        } else {
            // Last page: done
            if let pw = collectedMasterPassword, let bank = completedBank {
                outcome = .realBanking(masterPassword: pw, bank: bank)
            }
            NSApp.stopModal(withCode: .stop)
        }
    }

    // MARK: - Connect Result Handling

    nonisolated private static func enqueueOnMainRunLoop(_ block: @escaping () -> Void) {
        // NSApp.runModal() runs the run loop in NSModalPanelRunLoopMode.
        // Neither CFRunLoopPerformBlock(commonModes) nor DispatchQueue.main.async
        // fire in that mode — both are registered for common modes only.
        // RunLoop.perform(inModes:block:) fires once in the first matching mode,
        // so including .modalPanel ensures callbacks reach the main thread during
        // the modal session.
        RunLoop.main.perform(inModes: [.default, .modalPanel], block: block)
    }

    private func handleConnectSuccess(_ bank: DiscoveredBank, masterPassword: String) {
        hasFailedOnce = false
        latestDiagnosticsLogURL = nil
        completedBank = bank
        collectedMasterPassword = masterPassword
        // Always show page 0 (success + nickname input) — for second account it's the only page.
        render(step: .onboarding(page: 0))
    }

    private func handleConnectFailure(message: String, diagnosticsLogURL: URL?) {
        hasFailedOnce = true
        if let diagnosticsLogURL {
            latestDiagnosticsLogURL = diagnosticsLogURL
        }
        approvalSpinner.stopAnimation(nil)
        var displayMessage = message
        if diagnosticsLogURL != nil {
            displayMessage += "\n\(t("Diagnoseprotokoll wurde erstellt.", "Diagnostic log has been created."))"
        }
        credentialsStatusLabel.stringValue = displayMessage
        credentialsStatusLabel.textColor = .systemRed
        credentialsStatusLabel.isHidden = false
        render(step: .credentials)
    }

    // MARK: - Diagnostics

    private func makeDiagnosticsSection() -> NSView {
        diagnosticsToggle.state = diagnosticsLoggingEnabled ? .on : .off

        let title = NSTextField(labelWithString: t("Fehlerdiagnose", "Error diagnostics"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        if let latestDiagnosticsLogURL {
            diagnosticsLogPathLabel.stringValue = "\(t("Letztes Protokoll", "Latest log")): \(latestDiagnosticsLogURL.lastPathComponent)"
            diagnosticsLogPathLabel.isHidden = false
        } else {
            diagnosticsLogPathLabel.stringValue = ""
            diagnosticsLogPathLabel.isHidden = true
        }

        diagnosticsOpenFolderButton.isEnabled = FileManager.default.fileExists(atPath: AppLogger.logDirectoryURL.path)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(diagnosticsToggle)
        stack.addArrangedSubview(diagnosticsPrivacyLabel)
        stack.addArrangedSubview(diagnosticsDeliveryLabel)
        if !diagnosticsLogPathLabel.isHidden {
            stack.addArrangedSubview(diagnosticsLogPathLabel)
        }
        stack.addArrangedSubview(diagnosticsOpenFolderButton)
        return stack
    }

    @objc private func onDiagnosticsToggleChanged() {
        diagnosticsLoggingEnabled = diagnosticsToggle.state == .on
    }

    @objc private func onOpenDiagnosticsFolder() {
        let rootDir = AppLogger.logDirectoryURL
        // Try to select the latest log file directly; fall back to opening the root folder.
        if let latestDiagnosticsLogURL,
           FileManager.default.fileExists(atPath: latestDiagnosticsLogURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([latestDiagnosticsLogURL])
        } else if FileManager.default.fileExists(atPath: rootDir.path) {
            NSWorkspace.shared.open(rootDir)
        } else {
            // Create directory so it can be opened.
            try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(rootDir)
        }
    }
}

// MARK: - Backward-compatibility typealias
typealias SetupFlowPanel = SetupWizardPanel
