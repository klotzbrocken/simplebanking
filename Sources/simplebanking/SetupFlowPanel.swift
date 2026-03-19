import AppKit
import Foundation

enum SetupProgress: Sendable {
    case discoveringBank
    case requestingApproval
    case requestingTransactionApproval
    case fetchingTransactions
    case savingCredentials

    var displayText: String {
        switch self {
        case .discoveringBank: return L10n.t("Bank wird gesucht…", "Searching for bank…")
        case .requestingApproval: return L10n.t("Freigabe angefordert", "Approval requested")
        case .requestingTransactionApproval: return L10n.t("Transaktionen freigeben", "Approve transactions")
        case .fetchingTransactions: return L10n.t("Umsätze werden geladen…", "Loading transactions…")
        case .savingCredentials: return L10n.t("Daten werden gespeichert…", "Saving data…")
        }
    }

    var subtitle: String {
        switch self {
        case .requestingApproval:
            return L10n.t("Push-TAN bestätigen (1/2)", "Confirm Push-TAN (1/2)")
        case .requestingTransactionApproval:
            return L10n.t("Push-TAN bestätigen (2/2)", "Confirm Push-TAN (2/2)")
        default:
            return L10n.t("Bitte warten…", "Please wait…")
        }
    }

    var iconName: String {
        switch self {
        case .requestingApproval: return "bell.circle.fill"
        case .requestingTransactionApproval: return "arrow.triangle.2.circlepath"
        default: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
}

struct SetupConnectOptions: Sendable {
    var diagnosticsEnabled: Bool = false
    var onProgress: (@Sendable (SetupProgress) -> Void)?
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
    private var selectedBank: BankLogoAssets.BankBrand?
    private var filteredBanks: [BankLogoAssets.BankBrand] = []
    private var completedBank: DiscoveredBank?
    private var connectTask: Task<Void, Never>?
    private var discoverTask: Task<Void, Never>? = nil
    private var discoverResult: DiscoveredBank? = nil
    private var hasFailedOnce: Bool = false
    private var diagnosticsLoggingEnabled: Bool = false
    private var latestDiagnosticsLogURL: URL?

    // Wizard-specific state
    private var collectedMasterPassword: String? = nil
    private var outcome: SetupWizardOutcome = .cancelled

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

    init(connectAction: @escaping ConnectAction) {
        self.connectAction = connectAction

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
        updateSearchResults()
        render(step: .welcome)
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
        NSApp.stopModal(withCode: .abort)
    }

    private func setupBaseLayout() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        rootStack.orientation = .vertical
        rootStack.spacing = 12
        rootStack.alignment = .leading
        rootStack.edgeInsets = NSEdgeInsets(top: 32, left: 40, bottom: 32, right: 40)
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 3),
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
        case .onboarding(let page):
            switch page {
            case 0: fraction = 0.71
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
        case .connecting:
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

        let subtitle = NSTextField(wrappingLabelWithString: t("Dein Master-Passwort verschlüsselt alles auf deinem Mac.", "Your master password encrypts everything on your Mac."))
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
        ibanDetectedRow.isHidden = ibanPreviewBank == nil

        let iconBox = iconContainer(size: 40, cornerRadius: 12, bg: NSColor(white: 0.5, alpha: 0.12), icon: "building.2.fill", iconSize: 18, tint: .labelColor)

        let title = NSTextField(labelWithString: t("Welche Bank nutzt du?", "Which bank do you use?"))
        title.font = .systemFont(ofSize: 19, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: t("Gib deine IBAN ein – wir finden deine Bank automatisch.", "Enter your IBAN – we'll find your bank automatically."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        ibanField.placeholderString = "DE00 0000 0000 0000 0000 00"
        ibanField.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        let statusRow = NSStackView(views: [discoverSpinner, searchHelperLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        let yaxiInfo = infoBox(icon: "info.circle", t("EU Open Banking nach PSD2. simplebanking nutzt YAXI mit echter 1:1-Verbindung ohne Dritte.\n\nNur Lesezugriff. Keine Überweisungen.", "EU Open Banking via PSD2. simplebanking uses YAXI with a direct 1:1 connection, no third parties.\n\nRead-only access. No transfers."))

        let hasBank = ibanPreviewBank != nil
        let buttonRow = horizontalButtons(
            backTitle: t("Zurück", "Back"),
            backAction: #selector(onSearchBack),
            primaryTitle: t("Weiter", "Continue"),
            primaryAction: #selector(onSearchContinue),
            primaryEnabled: hasBank
        )
        searchContinueButton = buttonRow.primary
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(iconBox)
        rootStack.addArrangedSubview(title)
        rootStack.addArrangedSubview(subtitle)
        rootStack.addArrangedSubview(ibanField)
        rootStack.addArrangedSubview(ibanDetectedRow)
        rootStack.addArrangedSubview(ibanNotFoundMailButton)
        rootStack.addArrangedSubview(yaxiInfo)
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(buttonRow.stack)

        rootStack.setCustomSpacing(14, after: iconBox)
        rootStack.setCustomSpacing(4, after: title)
        rootStack.setCustomSpacing(16, after: subtitle)
        rootStack.setCustomSpacing(8, after: ibanField)
        rootStack.setCustomSpacing(8, after: ibanDetectedRow)
        rootStack.setCustomSpacing(12, after: ibanNotFoundMailButton)
        rootStack.setCustomSpacing(16, after: yaxiInfo)

        ibanField.nextKeyView = buttonRow.primary
        buttonRow.primary.nextKeyView = buttonRow.back
        buttonRow.back.nextKeyView = ibanField
        panel.initialFirstResponder = ibanField
        DispatchQueue.main.async { [weak self] in
            self?.panel.makeFirstResponder(self?.ibanField)
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

        rememberToggle.title = t("Zugangsdaten speichern", "Save credentials")
        rememberToggle.font = .systemFont(ofSize: 13, weight: .medium)

        let rememberSublabel = NSTextField(labelWithString: t("Sicher im macOS Keychain verschlüsselt", "Securely encrypted in macOS Keychain"))
        rememberSublabel.font = .systemFont(ofSize: 11)
        rememberSublabel.textColor = .secondaryLabelColor

        let rememberStack = NSStackView(views: [rememberToggle, rememberSublabel])
        rememberStack.orientation = .vertical
        rememberStack.spacing = 2
        rememberStack.alignment = .leading

        fieldViews.append(contentsOf: [rememberStack, credentialsStatusLabel])
        credentialsStatusLabel.isHidden = credentialsStatusLabel.stringValue.isEmpty

        let fields = NSStackView(views: fieldViews)
        fields.orientation = .vertical
        fields.spacing = 14
        fields.alignment = .leading

        let securityInfo = infoBox(icon: "checkmark.shield.fill", t("Verschlüsselte Verbindung via PSD2 – deine Daten werden nie auf unseren Servern gespeichert.", "Encrypted connection via PSD2 – your data is never stored on our servers."), tint: .systemGreen)

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
        buttonRow.primary.nextKeyView = rememberToggle
        rememberToggle.nextKeyView = buttonRow.back
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

        let nextBtn = primaryButton(title: t("Weiter", "Continue"), action: #selector(onOnboardingNext(_:)))
        nextBtn.tag = 0
        nextBtn.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(iconBox)
        rootStack.addArrangedSubview(titleLabel)
        rootStack.addArrangedSubview(bankConnected)
        rootStack.addArrangedSubview(body)
        rootStack.addArrangedSubview(tipBox)
        rootStack.addArrangedSubview(flexSpacer())
        rootStack.addArrangedSubview(nextBtn)

        rootStack.setCustomSpacing(16, after: iconBox)
        rootStack.setCustomSpacing(4, after: titleLabel)
        rootStack.setCustomSpacing(6, after: bankConnected)
        rootStack.setCustomSpacing(20, after: body)
        rootStack.setCustomSpacing(20, after: tipBox)
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

        let f1 = featureRow(icon: "checkmark.shield.fill", title: t("Alles verschlüsselt", "Everything encrypted"), body: t("Deine Daten liegen nur auf deinem Mac – vollständig verschlüsselt.", "Your data stays only on your Mac – fully encrypted."))
        let f2 = featureRow(icon: "touchid", title: t("Touch ID verfügbar", "Touch ID available"), body: t("Einmal einrichten, dann ohne Passwort entsperren.", "Set up once, then unlock without a password."))
        let f3 = featureRow(icon: "wifi.slash", title: t("Keine Cloud", "No cloud"), body: t("Wir schicken nichts ins Internet. Alles bleibt hier.", "We send nothing to the internet. Everything stays here."))

        let features = NSStackView(views: [f1, f2, f3])
        features.orientation = .vertical
        features.spacing = 14
        features.alignment = .leading

        let pills = pillsRow([t("PSD2-konform", "PSD2 compliant"), "Open Source", "macOS native"])

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
        if let bank = selectedBank {
            selectedBankChipLabel.stringValue = bank.displayName
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
        updateSearchResults()
    }

    private func autocompleteSelectionChanged() {
        guard let table = autocompleteTable else { return }
        let idx = table.selectedRow
        guard idx >= 0, idx < filteredBanks.count else { return }
        selectedBank = filteredBanks[idx]
        updateBankChip()
        hideAutocompletePanel()
    }

    @objc private func autocompleteTableDoubleClick() {
        autocompleteSelectionChanged()
    }

    private func updateSearchResults() {
        let query = bankSearchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let all = BankLogoAssets.brands.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        let matches: [BankLogoAssets.BankBrand]
        if query.isEmpty {
            matches = Array(all.prefix(40))
        } else {
            matches = Array(
                all.filter { brand in
                    let display = brand.displayName.lowercased()
                    return display.contains(query) || brand.keywords.contains(where: { $0.contains(query) })
                }.prefix(40)
            )
        }

        filteredBanks = matches

        guard case .bankSearch = step else { return }

        guard !matches.isEmpty else {
            if selectedBank != nil {
                // Bank already selected, just hide panel
            } else {
                selectedBank = nil
                updateBankChip()
            }
            hideAutocompletePanel()
            return
        }

        if let selectedBank, let idx = matches.firstIndex(where: { $0.id == selectedBank.id }) {
            autocompleteTable?.reloadData()
            autocompleteTable?.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else if !query.isEmpty {
            // New query — pre-select first match but don't commit until user picks
            autocompleteTable?.reloadData()
            autocompleteTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            autocompleteTable?.reloadData()
        }

        if query.isEmpty && selectedBank != nil {
            hideAutocompletePanel()
        } else {
            showAutocompletePanel()
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

        let rowCount = min(filteredBanks.count, 7)
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
        MainActor.assumeIsolated { filteredBanks.count }
    }

    // MARK: - NSTableViewDelegate

    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            let name = filteredBanks[row].displayName
            let cell = NSTextField(labelWithString: name)
            cell.font = .systemFont(ofSize: 13)
            cell.lineBreakMode = .byTruncatingTail
            return cell
        }
    }

    nonisolated func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection handled by double-click and keyboard Return
    }

    // MARK: - NSTextFieldDelegate (keyboard navigation)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === bankSearchField,
              let table = autocompleteTable,
              let acPanel = autocompletePanel, acPanel.isVisible else { return false }

        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            let next = min(table.selectedRow + 1, filteredBanks.count - 1)
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
        let rawIBAN = ibanField.stringValue
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !rawIBAN.isEmpty, ibanPreviewBank != nil else { return }

        searchContinueButton?.isEnabled = false
        discoverSpinner.startAnimation(nil)
        searchHelperLabel.stringValue = ""

        discoverTask?.cancel()
        discoverTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            await YaxiService.configureBackend(iban: rawIBAN)
            guard !Task.isCancelled else { return }

            let discovered = await YaxiService.discoverBank()
            guard !Task.isCancelled else { return }

            Self.enqueueOnMainRunLoop { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.discoverSpinner.stopAnimation(nil)
                    if let discovered {
                        self.discoverResult = discovered
                        self.render(step: .credentials)
                    } else {
                        self.searchHelperLabel.stringValue = L10n.t("Ungültige IBAN – bitte prüfen", "Invalid IBAN – please check")
                        self.searchHelperLabel.textColor = .systemRed
                        self.searchContinueButton?.isEnabled = true
                    }
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
        let iban = ibanField.stringValue
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue

        AppLogger.log(
            "SetupUI connect tapped ibanPrefix=\(String(iban.prefix(6))) userLen=\(user.count) passLen=\(pass.count)",
            category: "SetupUI"
        )

        credentialsStatusLabel.stringValue = ""
        credentialsStatusLabel.isHidden = true

        let bankName = discoverResult?.displayName ?? selectedBank?.displayName
        let payload = CredentialsPanel.Result(
            iban: iban,
            userId: user,
            password: pass,
            bankName: bankName
        )
        let options = SetupConnectOptions(
            diagnosticsEnabled: hasFailedOnce && diagnosticsLoggingEnabled
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
        let totalPages = 3
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
