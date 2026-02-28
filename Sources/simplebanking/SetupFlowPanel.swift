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
        case .discoveringBank: return "Bank wird gesucht…"
        case .requestingApproval: return "Freigabe angefordert"
        case .requestingTransactionApproval: return "Transaktionen freigeben"
        case .fetchingTransactions: return "Umsätze werden geladen…"
        case .savingCredentials: return "Daten werden gespeichert…"
        }
    }

    var subtitle: String {
        switch self {
        case .requestingApproval:
            return "Push-TAN bestätigen (1/2)"
        case .requestingTransactionApproval:
            return "Push-TAN bestätigen (2/2)"
        default:
            return "Bitte warten…"
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
    private let fieldWidth: CGFloat = 400

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
    private let rememberToggle = NSButton(checkboxWithTitle: "Login-Daten merken", target: nil, action: nil)
    private let approvalSpinner = NSProgressIndicator()
    private let approvalTitleLabel = NSTextField(labelWithString: "")
    private let approvalSubtitleLabel = NSTextField(labelWithString: "")
    private let approvalIconView = NSImageView()
    private let successSubtitleLabel = NSTextField(labelWithString: "")
    private let diagnosticsToggle = NSButton(checkboxWithTitle: "Neu versuchen mit Diagnoselogging", target: nil, action: nil)
    private let diagnosticsPrivacyLabel = NSTextField(wrappingLabelWithString: "Es werden keine persönlichen Daten gespeichert.")
    private let diagnosticsDeliveryLabel = NSTextField(wrappingLabelWithString: "Log-Datei wird im Log-Ordner abgelegt und muss manuell versendet werden.")
    private let diagnosticsLogPathLabel = NSTextField(labelWithString: "")
    private let diagnosticsOpenFolderButton = NSButton(title: "Log-Ordner öffnen", target: nil, action: nil)
    private weak var searchContinueButton: NSButton?
    private let discoverSpinner = NSProgressIndicator()
    private var autocompletePanel: NSPanel?
    private var autocompleteTable: NSTableView?

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
        rootStack.spacing = 14
        rootStack.alignment = .leading
        rootStack.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 24, right: 30)
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: content.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func setupControlDefaults() {
        // Master password fields
        masterPassField.placeholderString = "Passwort eingeben…"
        masterPassField.font = .systemFont(ofSize: 14)
        masterPassField.bezelStyle = .roundedBezel
        masterPassField.isEditable = true
        masterPassField.isSelectable = true
        masterPassField.isEnabled = true
        masterPassField.translatesAutoresizingMaskIntoConstraints = false

        masterConfirmField.placeholderString = "Passwort wiederholen…"
        masterConfirmField.font = .systemFont(ofSize: 14)
        masterConfirmField.bezelStyle = .roundedBezel
        masterConfirmField.isEditable = true
        masterConfirmField.isSelectable = true
        masterConfirmField.isEnabled = true
        masterConfirmField.translatesAutoresizingMaskIntoConstraints = false

        masterMatchLabel.font = .systemFont(ofSize: 12)
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
        bankSearchField.placeholderString = "Bank suchen…"
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
        userField.placeholderString = "Anmeldename / Leg.-ID (falls nötig)"
        passField.placeholderString = "PIN / Passwort (falls nötig)"
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

        diagnosticsToggle.state = diagnosticsLoggingEnabled ? .on : .off
        diagnosticsToggle.target = self
        diagnosticsToggle.action = #selector(onDiagnosticsToggleChanged)

        diagnosticsPrivacyLabel.font = .systemFont(ofSize: 12)
        diagnosticsPrivacyLabel.textColor = .secondaryLabelColor
        diagnosticsPrivacyLabel.maximumNumberOfLines = 2
        diagnosticsPrivacyLabel.lineBreakMode = .byWordWrapping

        diagnosticsDeliveryLabel.font = .systemFont(ofSize: 12)
        diagnosticsDeliveryLabel.textColor = .secondaryLabelColor
        diagnosticsDeliveryLabel.maximumNumberOfLines = 3
        diagnosticsDeliveryLabel.lineBreakMode = .byWordWrapping

        diagnosticsLogPathLabel.font = .systemFont(ofSize: 11)
        diagnosticsLogPathLabel.textColor = .secondaryLabelColor
        diagnosticsLogPathLabel.lineBreakMode = .byTruncatingMiddle
        diagnosticsLogPathLabel.maximumNumberOfLines = 1

        diagnosticsOpenFolderButton.bezelStyle = .rounded
        diagnosticsOpenFolderButton.target = self
        diagnosticsOpenFolderButton.action = #selector(onOpenDiagnosticsFolder)

        discoverSpinner.style = .spinning
        discoverSpinner.controlSize = .small
        discoverSpinner.isDisplayedWhenStopped = false
        discoverSpinner.translatesAutoresizingMaskIntoConstraints = false
        discoverSpinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        discoverSpinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
    }

    private func clearRootContent() {
        let views = rootStack.arrangedSubviews
        views.forEach { view in
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func render(step: Step) {
        hideAutocompletePanel()
        self.step = step
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

        let icon = NSImageView()
        if let appIcon = NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName) {
            icon.image = appIcon
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let title = NSTextField(labelWithString: "simplebanking")
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.alignment = .center

        let tagline = NSTextField(labelWithString: "simple banking without the fluff")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center

        let spacerTop = NSView()
        let spacerMid = NSView()
        let spacerBottom = NSView()
        spacerTop.heightAnchor.constraint(equalToConstant: 16).isActive = true
        spacerMid.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        spacerBottom.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let connectButton = primaryButton(title: "Jetzt verbinden", action: #selector(onWelcomeConnect))
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        let demoButton = NSButton(title: "Demo-Modus starten", target: self, action: #selector(onWelcomeDemo))
        demoButton.bezelStyle = .rounded
        demoButton.translatesAutoresizingMaskIntoConstraints = false
        demoButton.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        [spacerTop, icon, title, tagline, spacerMid, connectButton, demoButton, spacerBottom].forEach {
            rootStack.addArrangedSubview($0)
        }
        rootStack.setCustomSpacing(8, after: icon)
        rootStack.setCustomSpacing(4, after: title)
        rootStack.setCustomSpacing(8, after: connectButton)
    }

    // MARK: - Master Password

    private func renderMasterPasswordStep() {
        rootStack.alignment = .leading

        let title = NSTextField(labelWithString: "Sicherheit einrichten")
        title.font = .systemFont(ofSize: 20, weight: .bold)

        let info = NSTextField(wrappingLabelWithString: "Das Master-Passwort schützt deine Daten lokal. Es wird nicht gespeichert — merke es dir gut!")
        info.font = .systemFont(ofSize: 13)
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false
        info.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        let passGroup = NSStackView(views: [sectionLabel("Master-Passwort"), iconField("lock", masterPassField)])
        passGroup.orientation = .vertical
        passGroup.spacing = 6
        passGroup.alignment = .leading

        let confirmGroup = NSStackView(views: [sectionLabel("Passwort bestätigen"), iconField("lock.rotation", masterConfirmField)])
        confirmGroup.orientation = .vertical
        confirmGroup.spacing = 6
        confirmGroup.alignment = .leading

        masterMatchLabel.isHidden = masterConfirmField.stringValue.isEmpty

        let buttonRow = horizontalButtons(
            backTitle: "Zurück",
            backAction: #selector(onMasterPasswordBack),
            primaryTitle: "Weiter",
            primaryAction: #selector(onMasterPasswordContinue),
            primaryEnabled: true
        )
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        [title, info, passGroup, confirmGroup, masterMatchLabel, NSView(), buttonRow.stack].forEach {
            rootStack.addArrangedSubview($0)
        }
        rootStack.setCustomSpacing(4, after: title)
        rootStack.setCustomSpacing(20, after: info)
        rootStack.setCustomSpacing(14, after: passGroup)
        rootStack.setCustomSpacing(8, after: confirmGroup)

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

    // MARK: - Bank Search

    private func renderSearchStep() {
        rootStack.alignment = .leading

        discoverSpinner.stopAnimation(nil)

        let title = NSTextField(labelWithString: "Deine Bank verbinden")
        title.font = .systemFont(ofSize: 20, weight: .bold)

        let subtitle = NSTextField(labelWithString: "Suche Deine Bank und gib Deine IBAN ein, um fortzufahren.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        updateSearchResults()
        updateBankChip()

        let bankSectionLabel = sectionLabel("Bank auswählen")
        let bankGroup = NSStackView(views: [bankSectionLabel, bankSearchField, selectedBankChipView])
        bankGroup.orientation = .vertical
        bankGroup.spacing = 6
        bankGroup.alignment = .leading

        let ibanSectionLabel = sectionLabel("Deine IBAN")
        let ibanRow = iconField("creditcard", ibanField)
        let ibanGroup = NSStackView(views: [ibanSectionLabel, ibanRow])
        ibanGroup.orientation = .vertical
        ibanGroup.spacing = 6
        ibanGroup.alignment = .leading

        let statusRow = NSStackView(views: [discoverSpinner, searchHelperLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        let normalizedIBAN = ibanField.stringValue
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let buttonRow = horizontalButtons(
            backTitle: "Zurück",
            backAction: #selector(onSearchBack),
            primaryTitle: "Weiter",
            primaryAction: #selector(onSearchContinue),
            primaryEnabled: !normalizedIBAN.isEmpty
        )
        searchContinueButton = buttonRow.primary
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        [title, subtitle, bankGroup, ibanGroup, statusRow, NSView(), buttonRow.stack].forEach {
            rootStack.addArrangedSubview($0)
        }
        rootStack.setCustomSpacing(4, after: title)
        rootStack.setCustomSpacing(20, after: subtitle)
        rootStack.setCustomSpacing(18, after: bankGroup)
        rootStack.setCustomSpacing(6, after: ibanGroup)

        bankSearchField.nextKeyView = ibanField
        ibanField.nextKeyView = buttonRow.primary
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
        let bankName = discoverResult?.displayName ?? selectedBank?.displayName ?? "Bank"

        let pageTitle = NSTextField(labelWithString: "Zugangsdaten eingeben")
        pageTitle.font = .systemFont(ofSize: 20, weight: .bold)

        let logo = NSImageView()
        logo.image = NSImage(systemSymbolName: "building.columns.circle.fill", accessibilityDescription: "Bank")
        logo.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        logo.contentTintColor = .labelColor
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 22).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let bankNameLabel = NSTextField(labelWithString: bankName)
        bankNameLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let headerStack = NSStackView(views: [logo, bankNameLabel])
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .centerY

        let creds = discoverResult?.credentials
        let needsUserId = creds == nil || creds!.full || creds!.userId
        let needsPassword = creds == nil || creds!.full

        let userLabel = discoverResult?.userIdLabel ?? "Anmeldename / Leg.-ID"
        userField.placeholderString = needsUserId ? userLabel : ""
        userField.isHidden = !needsUserId
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
            let passGroup = NSStackView(views: [sectionLabel("PIN / Passwort"), iconField("lock", passField)])
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

        fieldViews.append(contentsOf: [rememberToggle, credentialsStatusLabel])
        credentialsStatusLabel.isHidden = credentialsStatusLabel.stringValue.isEmpty

        let fields = NSStackView(views: fieldViews)
        fields.orientation = .vertical
        fields.spacing = 14
        fields.alignment = .leading

        let buttonRow = horizontalButtons(
            backTitle: "Zurück",
            backAction: #selector(onCredentialsBack),
            primaryTitle: "Verbinden",
            primaryAction: #selector(onCredentialsConnect),
            primaryEnabled: true
        )
        buttonRow.stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        rootStack.addArrangedSubview(pageTitle)
        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(fields)
        if hasFailedOnce {
            rootStack.addArrangedSubview(makeDiagnosticsSection())
        }
        rootStack.addArrangedSubview(NSView())
        rootStack.addArrangedSubview(buttonRow.stack)
        rootStack.setCustomSpacing(6, after: pageTitle)
        rootStack.setCustomSpacing(20, after: headerStack)

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

        let cancelButton = NSButton(title: "Verbindung abbrechen", target: self, action: #selector(onCancelConnection))
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
        rootStack.alignment = .centerX

        approvalSpinner.stopAnimation(nil)

        struct OnboardingContent {
            let systemImage: String
            let imageColor: NSColor
            let title: String
            let body: String
            let features: [(icon: String, text: String)]
        }

        let pages: [OnboardingContent] = [
            OnboardingContent(
                systemImage: "checkmark.seal.fill",
                imageColor: .systemGreen,
                title: "Einrichtung abgeschlossen!",
                body: "simplebanking läuft jetzt in deiner Menüleiste.",
                features: []
            ),
            OnboardingContent(
                systemImage: "macwindow.on.rectangle",
                imageColor: .controlAccentColor,
                title: "So funktioniert's",
                body: "",
                features: [
                    ("cursorarrow.click", "Klick auf den Kontostand öffnet die Umsatzliste"),
                    ("arrow.clockwise", "Kontostand wird automatisch aktualisiert"),
                    ("magnifyingglass", "Umsätze durchsuchen, filtern und analysieren"),
                    ("cursorarrow.click.2", "Rechtsklick → Sperren, Einstellungen, Demo-Modus"),
                ]
            ),
            OnboardingContent(
                systemImage: "lock.shield.fill",
                imageColor: .systemIndigo,
                title: "Deine Daten sind sicher",
                body: "",
                features: [
                    ("key.fill", "Master-Passwort verschlüsselt alle Daten lokal"),
                    ("touchid", "Touch ID für schnelles Entsperren aktivierbar"),
                    ("iphone.and.arrow.forward", "Keine Daten in der Cloud – alles bleibt auf deinem Mac"),
                ]
            ),
        ]

        guard page >= 0 && page < pages.count else { return }
        let content = pages[page]

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: content.systemImage, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 56, weight: .semibold)
        icon.contentTintColor = content.imageColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: content.title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.alignment = .center

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        if content.features.isEmpty {
            if let bank = completedBank {
                let bankLabel = NSTextField(labelWithString: "Verbunden mit \(bank.displayName)")
                bankLabel.font = .systemFont(ofSize: 15, weight: .semibold)
                bankLabel.textColor = .controlAccentColor
                bankLabel.alignment = .center
                contentStack.addArrangedSubview(bankLabel)
            }
            let bodyLabel = NSTextField(wrappingLabelWithString: content.body)
            bodyLabel.font = .systemFont(ofSize: 14)
            bodyLabel.textColor = .secondaryLabelColor
            bodyLabel.alignment = .center
            bodyLabel.translatesAutoresizingMaskIntoConstraints = false
            bodyLabel.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            contentStack.addArrangedSubview(bodyLabel)
        } else {
            for feature in content.features {
                let featureIcon = NSImageView()
                featureIcon.image = NSImage(systemSymbolName: feature.icon, accessibilityDescription: nil)
                featureIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                featureIcon.contentTintColor = .controlAccentColor
                featureIcon.translatesAutoresizingMaskIntoConstraints = false
                featureIcon.widthAnchor.constraint(equalToConstant: 20).isActive = true
                featureIcon.heightAnchor.constraint(equalToConstant: 20).isActive = true
                featureIcon.setContentHuggingPriority(.required, for: .horizontal)

                let featureLabel = NSTextField(labelWithString: feature.text)
                featureLabel.font = .systemFont(ofSize: 13)
                featureLabel.textColor = .labelColor
                featureLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

                let row = NSStackView(views: [featureIcon, featureLabel])
                row.orientation = .horizontal
                row.spacing = 10
                row.alignment = .centerY
                contentStack.addArrangedSubview(row)
            }
        }

        // Dot indicator
        let dotRow = NSStackView()
        dotRow.orientation = .horizontal
        dotRow.spacing = 6
        dotRow.alignment = .centerY
        for i in 0..<pages.count {
            let dot = NSView()
            dot.wantsLayer = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dot.layer?.cornerRadius = 3.5
            if i == page {
                dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            } else {
                dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            }
            dotRow.addArrangedSubview(dot)
        }

        // Button row
        let isFirst = page == 0
        let isLast = page == pages.count - 1

        let backBtn = NSButton(title: "← Zurück", target: self, action: #selector(onOnboardingBack))
        backBtn.bezelStyle = .inline
        backBtn.font = .systemFont(ofSize: 13)
        backBtn.isHidden = isFirst

        let primaryTitle = isLast ? "Los geht's!" : "Weiter →"
        let primaryBtn = primaryButton(title: primaryTitle, action: #selector(onOnboardingNext))
        primaryBtn.tag = page

        let spacerBetween = NSView()
        spacerBetween.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bottomButtonStack = NSStackView(views: [backBtn, spacerBetween, primaryBtn])
        bottomButtonStack.orientation = .horizontal
        bottomButtonStack.alignment = .centerY
        bottomButtonStack.spacing = 8
        bottomButtonStack.translatesAutoresizingMaskIntoConstraints = false
        bottomButtonStack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        let spacerContent = NSView()

        [icon, titleLabel, contentStack, spacerContent, dotRow, bottomButtonStack].forEach {
            rootStack.addArrangedSubview($0)
        }
        rootStack.setCustomSpacing(12, after: icon)
        rootStack.setCustomSpacing(14, after: titleLabel)
        rootStack.setCustomSpacing(8, after: dotRow)
    }

    // MARK: - Helpers

    private func primaryButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        return button
    }

    private func horizontalButtons(
        backTitle: String,
        backAction: Selector,
        primaryTitle: String,
        primaryAction: Selector,
        primaryEnabled: Bool
    ) -> ButtonRow {
        let back = NSButton(title: backTitle, target: self, action: backAction)
        back.bezelStyle = .rounded

        let primary = NSButton(title: primaryTitle, target: self, action: primaryAction)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.isEnabled = primaryEnabled

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [back, spacer, primary])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
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
    }

    @objc private func onMasterConfirmChanged(_ notification: Notification) {
        updateMasterMatchLabel()
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
            masterMatchLabel.stringValue = "✓ Passwörter stimmen überein"
            masterMatchLabel.textColor = .systemGreen
        } else {
            masterMatchLabel.stringValue = "✗ Passwörter stimmen nicht überein"
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
            masterMatchLabel.stringValue = "✗ Mindestens 4 Zeichen erforderlich"
            masterMatchLabel.textColor = .systemRed
            masterMatchLabel.isHidden = false
            NSSound.beep()
            return
        }
        guard pass == confirm else {
            masterMatchLabel.stringValue = "✗ Passwörter stimmen nicht überein"
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
        let panelHeight = CGFloat(rowCount) * 28 + 4
        let panelFrame = NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY - panelHeight - 2,
            width: screenFrame.width,
            height: panelHeight
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

        guard !rawIBAN.isEmpty else {
            searchHelperLabel.stringValue = "Bitte IBAN eingeben."
            searchHelperLabel.textColor = .systemOrange
            return
        }

        searchHelperLabel.stringValue = "Bank wird erkannt…"
        searchHelperLabel.textColor = .secondaryLabelColor
        searchContinueButton?.isEnabled = false
        discoverSpinner.startAnimation(nil)

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
                        self.searchHelperLabel.stringValue = "Bank nicht gefunden. IBAN prüfen."
                        self.searchHelperLabel.textColor = .systemRed
                        self.searchContinueButton?.isEnabled = true
                    }
                }
            }
        }
    }

    @objc private func onIBANFieldChanged(_ notification: Notification) {
        let raw = ibanField.stringValue
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        searchContinueButton?.isEnabled = !raw.isEmpty
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
            displayMessage += "\nDiagnoseprotokoll wurde erstellt."
        }
        credentialsStatusLabel.stringValue = displayMessage
        credentialsStatusLabel.textColor = .systemRed
        credentialsStatusLabel.isHidden = false
        render(step: .credentials)
    }

    // MARK: - Diagnostics

    private func makeDiagnosticsSection() -> NSView {
        diagnosticsToggle.state = diagnosticsLoggingEnabled ? .on : .off

        let title = NSTextField(labelWithString: "Fehlerdiagnose")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        if let latestDiagnosticsLogURL {
            diagnosticsLogPathLabel.stringValue = "Letztes Protokoll: \(latestDiagnosticsLogURL.lastPathComponent)"
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
