import AppKit
import SwiftUI

// MARK: - InitialSetupExtensionSheet
//
// 5-Schritte-Folge-Wizard, der NACH dem ersten erfolgreichen Bank-Connect
// einmalig läuft. Sammelt häufig übersehene Settings (Gehaltstag, Dispo,
// App-Schutz, Dock-Mode, MCP) damit der User die App nicht suboptimal nutzt.
//
// Strikt opt-in: jeder Schritt überspringbar, X-Close beendet die Tour.
// Wird nie zweimal angezeigt — Flag `simplebanking.initialWizardCompleted`
// wird BEVOR die Sheet öffnet gesetzt (siehe BalanceBar).
//
// Add-Bank-Pfad triggert diesen Wizard NICHT — die Insertion-Stelle in
// BalanceBar liegt im First-Setup-Outcome-Branch.

@MainActor
final class InitialSetupExtensionPanel: NSObject, NSWindowDelegate {

    private let panel: NSPanel
    private let slotId: String
    private let requestMasterPassword: () -> String?

    init(slotId: String, requestMasterPassword: @escaping () -> String? = { nil }) {
        self.slotId = slotId
        self.requestMasterPassword = requestMasterPassword
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "simplebanking — Einrichtung abschließen"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.minSize = NSSize(width: 480, height: 560)
        panel.maxSize = NSSize(width: 480, height: 560)
        super.init()
        panel.delegate = self
    }

    func runModal() {
        let view = InitialSetupExtensionSheet(
            slotId: slotId,
            requestMasterPassword: requestMasterPassword,
            onClose: { [weak self] in
                guard let self else { return }
                NSApp.stopModal()
            }
        )
        let host = NSHostingView(rootView: view)
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

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in NSApp.stopModal() }
        return true
    }
}

// MARK: - SwiftUI sheet

@MainActor
struct InitialSetupExtensionSheet: View {

    let slotId: String
    var requestMasterPassword: () -> String? = { nil }
    let onClose: () -> Void

    @State private var currentStep: Int = 0
    @State private var passwordSetupError: String? = nil

    /// Wird nur eingeblendet, wenn das Lizenz-System scharf ist, das Feature
    /// sichtbar ist und der User noch nicht lizenziert ist. Sonst bleibt der
    /// Wizard bei 5 Schritten.
    private var shouldShowTransferUpsell: Bool {
        LicenseConfig.licensingEnabled
            && FeatureFlags.transferMoneyEnabled
            && !LicenseManager.shared.isLicensed
    }

    private var totalSteps: Int {
        shouldShowTransferUpsell ? 6 : 5
    }

    // Step 1 — Gehaltstag
    @State private var salaryDayPreset: Int = 0   // 0=Anfang, 1=Mitte, 2=Individuell
    @State private var salaryDayCustom: Int = 1

    // Step 2 — Dispo
    @State private var dispoEnabled: Bool = false
    @State private var dispoLimitInput: String = ""

    // Step 3 — App-Schutz
    @State private var passwordRequired: Bool = true

    // Step 4 — Darstellung
    @State private var dockModeEnabled: Bool = false

    // Step 5 — MCP / KI-Agenten
    @State private var enableMCP: Bool = false
    @State private var mcpStatusMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 480, height: 560)
        .background(Color.panelBackground)
        .onAppear { initializeFromExistingState() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.t("Schritt \(currentStep + 1) von \(totalSteps)",
                        "Step \(currentStep + 1) of \(totalSteps)"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.sbTextSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.sbBorder)
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.sbBlueStrong)
                        .frame(width: geo.size.width * CGFloat(currentStep + 1) / CGFloat(totalSteps))
                        .animation(.easeInOut(duration: 0.2), value: currentStep)
                }
            }
            .frame(height: 3)
            Spacer(minLength: 12)
            Button(action: { onClose() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.sbTextSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(L10n.t("Tour überspringen und schließen", "Skip tour and close"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Content per step

    @ViewBuilder
    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                switch currentStep {
                case 0: stepSalary
                case 1: stepDispo
                case 2: stepPassword
                case 3: stepDock
                case 4: stepMCP
                case 5: stepTransferUpsell
                default: EmptyView()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(L10n.t("Zurück", "Back")) {
                if currentStep > 0 { currentStep -= 1 }
            }
            .disabled(currentStep == 0)

            Spacer()

            Button(L10n.t("Überspringen", "Skip")) {
                advance()
            }

            Button(action: { commitAndAdvance() }) {
                Text(primaryButtonLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color.sbBlueStrong)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    // MARK: - Step 1: Gehaltstag

    private var stepSalary: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L10n.t("Wann kommt dein Gehalt?",
                             "When does your salary arrive?"))
            stepDescription(L10n.t(
                "simplebanking erkennt dein Gehalt automatisch und nutzt es z.B. um zu zeigen, wie viel diesen Monat noch übrig ist. Wann erwartest du es typischerweise?",
                "simplebanking auto-detects your salary and uses it to show how much is left this month. When do you typically expect it?"
            ))

            VStack(spacing: 8) {
                salaryCard(0, label: L10n.t("Anfang des Monats", "Start of month"),
                           detail: L10n.t("um den 1. herum", "around the 1st"))
                salaryCard(1, label: L10n.t("Mitte des Monats", "Mid-month"),
                           detail: L10n.t("um den 15. herum", "around the 15th"))
                salaryCard(2, label: L10n.t("Individuell", "Custom"),
                           detail: L10n.t("Tag selbst wählen", "Pick your day"))
                if salaryDayPreset == 2 {
                    HStack {
                        Text(L10n.t("Tag im Monat:", "Day of month:"))
                            .font(.system(size: 12))
                            .foregroundColor(.sbTextSecondary)
                        Stepper(value: $salaryDayCustom, in: 1...31) {
                            Text("\(salaryDayCustom).")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .frame(width: 36, alignment: .leading)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func salaryCard(_ value: Int, label: String, detail: String) -> some View {
        Button(action: { salaryDayPreset = value }) {
            HStack(spacing: 10) {
                Image(systemName: salaryDayPreset == value
                      ? "largecircle.fill.circle"
                      : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(salaryDayPreset == value ? .sbBlueStrong : .sbTextSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.sbTextPrimary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.sbTextSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(salaryDayPreset == value ? Color.sbBlueSoft : Color.sbSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(salaryDayPreset == value ? Color.sbBlueStrong.opacity(0.5) : Color.sbBorder,
                            lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Dispo

    private var stepDispo: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L10n.t("Hast du einen Dispokredit?",
                             "Do you have an overdraft?"))
            stepDescription(L10n.t(
                "Wenn deine Bank dir einen Verfügungsrahmen über dem Guthaben einräumt, kannst du den hier eintragen. simplebanking warnt dich dann, wenn eine Überweisung den Dispo überschreiten würde.",
                "If your bank grants you an overdraft above your balance, enter the limit here. simplebanking will warn you if a transfer would exceed it."
            ))

            Toggle(isOn: $dispoEnabled) {
                Text(L10n.t("Ja, ich habe einen Dispo", "Yes, I have an overdraft"))
                    .font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)
            .padding(.top, 4)

            if dispoEnabled {
                HStack(spacing: 8) {
                    Text(L10n.t("Limit:", "Limit:"))
                        .font(.system(size: 13))
                        .foregroundColor(.sbTextSecondary)
                    TextField("0", text: $dispoLimitInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: dispoLimitInput) { _, new in
                            dispoLimitInput = new.filter { $0.isNumber }
                        }
                    Text("EUR")
                        .font(.system(size: 13))
                        .foregroundColor(.sbTextSecondary)
                    Spacer()
                }
                .padding(.leading, 4)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Step 3: App-Schutz

    private var stepPassword: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L10n.t("App-Schutz aktivieren?",
                             "Enable app protection?"))
            stepDescription(L10n.t(
                "simplebanking kann beim Start nach einem Passwort fragen, damit deine Bank-Zugangsdaten und neue Bankabrufe geschützt sind. Der lokale Umsatzverlauf bleibt unverschlüsselt. Touch ID kannst du danach in den Einstellungen einrichten.",
                "simplebanking can ask for a password on launch to protect your bank credentials and new bank requests. The local transaction history remains unencrypted. You can set up Touch ID in Settings afterwards."
            ))

            Toggle(isOn: $passwordRequired) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Passwort beim Öffnen verlangen",
                                "Require password on launch"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L10n.t("Empfohlen für Mehrbenutzer-Macs.",
                                "Recommended for shared Macs."))
                        .font(.system(size: 11))
                        .foregroundColor(.sbTextSecondary)
                }
            }
            .toggleStyle(.switch)

            if let err = passwordSetupError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.sbRedStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 4: Darstellung

    private var stepDock: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L10n.t("Wie soll simplebanking erscheinen?",
                             "How should simplebanking appear?"))
            stepDescription(L10n.t(
                "simplebanking läuft standardmäßig nur in der Menüleiste — kompakt und unauffällig. Möchtest du zusätzlich ein Dock-Icon und Cmd+Tab-Sichtbarkeit?",
                "simplebanking runs by default only in the menu bar — compact and unobtrusive. Would you like a Dock icon and Cmd+Tab visibility too?"
            ))

            VStack(spacing: 8) {
                dockCard(false,
                         label: L10n.t("Nur Menüleiste", "Menu bar only"),
                         detail: L10n.t("Kompakt — kein Dock-Icon, kein Cmd+Tab",
                                        "Compact — no Dock icon, no Cmd+Tab"))
                dockCard(true,
                         label: L10n.t("Menüleiste + Dock", "Menu bar + Dock"),
                         detail: L10n.t("Klassisches App-Erlebnis mit Dock-Icon",
                                        "Classic app experience with Dock icon"))
            }
        }
    }

    private func dockCard(_ value: Bool, label: String, detail: String) -> some View {
        Button(action: { dockModeEnabled = value }) {
            HStack(spacing: 10) {
                Image(systemName: dockModeEnabled == value
                      ? "largecircle.fill.circle"
                      : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(dockModeEnabled == value ? .sbBlueStrong : .sbTextSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.sbTextPrimary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.sbTextSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(dockModeEnabled == value ? Color.sbBlueSoft : Color.sbSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(dockModeEnabled == value ? Color.sbBlueStrong.opacity(0.5) : Color.sbBorder,
                            lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 5: MCP / KI-Agenten

    private var stepMCP: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Visuell als „optional" markieren
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.sbBlueStrong)
                Text(L10n.t("Optional — nur wenn du KI-Tools nutzt",
                            "Optional — only if you use AI tools"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.3)
                    .foregroundColor(.sbBlueStrong)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.sbBlueSoft))

            stepTitle(L10n.t("Möchtest du simplebanking für lokale KI-Agenten freigeben?",
                             "Allow local AI agents to access simplebanking?"))
            stepDescription(L10n.t(
                "Wenn du Claude Desktop oder andere lokale KI-Tools mit MCP-Support nutzt, kannst du simplebanking als Datenquelle freigeben. Der Agent kann dann Fragen wie 'Wie viel habe ich diesen Monat für Lebensmittel ausgegeben?' direkt beantworten.",
                "If you use Claude Desktop or other local AI tools with MCP support, you can grant simplebanking as a data source. The agent can then directly answer questions like 'How much did I spend on groceries this month?'"
            ))

            // Daten-Hinweis prominenter
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14))
                    .foregroundColor(.sbOrangeStrong)
                Text(L10n.t(
                    "Wichtig: Der MCP-Server läuft lokal und liest nur deinen Cache (Lese-only). Der KI-Client (z.B. Claude Desktop) kann je nach Frage Auszüge an seinen KI-Anbieter weiterreichen, um sie zu beantworten — das hängt also vom gewählten Client ab. Du kannst die Freigabe jederzeit in den Einstellungen widerrufen.",
                    "Important: the MCP server runs locally and only reads your cache (read-only). Depending on the question, the AI client (e.g. Claude Desktop) may forward excerpts to its AI provider — this depends on the chosen client. You can revoke this in Settings any time."
                ))
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.sbOrangeSoft.opacity(0.6))
            )

            Toggle(isOn: $enableMCP) {
                Text(L10n.t("Für lokale KI-Agenten freigeben",
                            "Allow access for local AI agents"))
                    .font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)

            if enableMCP {
                Text(L10n.t(
                    "simplebanking wird in Claude Desktops MCP-Konfiguration eingetragen.",
                    "simplebanking will be registered in Claude Desktop's MCP configuration."
                ))
                    .font(.system(size: 10.5))
                    .foregroundColor(.sbTextSecondary)
                    .padding(.leading, 4)
            }
            if let msg = mcpStatusMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(.sbTextSecondary)
            }
        }
    }

    private var primaryButtonLabel: String {
        if currentStep == 5 {
            return L10n.t("Für \(LicenseConfig.displayPrice) freischalten",
                          "Unlock for \(LicenseConfig.displayPrice)")
        }
        if currentStep == totalSteps - 1 {
            return L10n.t("Fertig", "Done")
        }
        return L10n.t("Weiter", "Next")
    }

    // MARK: - Step 6: Geld senden Upsell (regulärer Preis)

    private var stepTransferUpsell: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(L10n.t("simplesend freischalten?",
                             "Unlock simplesend?"))
            stepDescription(L10n.t(
                "Mit simplesend kannst du direkt aus simplebanking SEPA-Überweisungen auslösen — Empfänger und IBAN werden aus deinen Buchungen vorgeschlagen. Einmalkauf, kein Abo.",
                "simplesend lets you initiate SEPA transfers right from simplebanking — recipients and IBAN are suggested from your transactions. One-time purchase, no subscription."
            ))

            VStack(alignment: .leading, spacing: 10) {
                upsellBullet(icon: "bolt.fill",
                             text: L10n.t("SEPA-Überweisung in 2 Klicks aus deinen Buchungen heraus.",
                                          "SEPA transfer in 2 clicks from your transactions."))
                upsellBullet(icon: "lock.shield.fill",
                             text: L10n.t("TAN-Bestätigung wie gewohnt direkt bei deiner Bank.",
                                          "TAN confirmation directly with your bank."))
                upsellBullet(icon: "checkmark.seal.fill",
                             text: L10n.t("Einmalkauf für \(LicenseConfig.displayPrice). Updates innerhalb von 1.x kostenlos.",
                                          "One-time purchase for \(LicenseConfig.displayPrice). Free updates within 1.x."))
            }

            Text(L10n.t(
                "Ein Klick auf Freischalten öffnet die sichere Checkout-Seite im Browser. Du kannst diesen Schritt jederzeit überspringen und später aus dem Menü kaufen.",
                "Tapping Unlock opens the secure checkout in your browser. You can skip and buy later from the menu."))
                .font(.system(size: 10.5))
                .foregroundColor(.sbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func upsellBullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.sbBlueStrong)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(.sbTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.sbTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepDescription(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(.sbTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func advance() {
        if currentStep < totalSteps - 1 {
            currentStep += 1
        } else {
            onClose()
        }
    }

    private func commitAndAdvance() {
        switch currentStep {
        case 0: commitSalary()
        case 1: commitDispo()
        case 2: commitPassword()
        case 3: commitDock()
        case 4: commitMCP()
        case 5: commitTransferUpsell()   // öffnet Checkout-URL
        default: break
        }
        advance()
    }

    private func commitTransferUpsell() {
        guard LicenseConfig.isConfigured else { return }
        NSWorkspace.shared.open(LicenseConfig.purchaseURL)
    }

    // MARK: - Persistence

    private func initializeFromExistingState() {
        let s = BankSlotSettingsStore.load(slotId: slotId)
        salaryDayPreset = s.salaryDayPreset
        salaryDayCustom = max(1, min(31, s.salaryDay))
        dispoEnabled = s.dispoLimit > 0
        dispoLimitInput = s.dispoLimit > 0 ? String(s.dispoLimit) : ""
        passwordRequired = UserDefaults.standard.object(forKey: "passwordRequired") as? Bool ?? true
        dockModeEnabled = UserDefaults.standard.bool(forKey: "dockModeEnabled")
    }

    private func commitSalary() {
        var s = BankSlotSettingsStore.load(slotId: slotId)
        s.salaryDayPreset = salaryDayPreset
        if salaryDayPreset == 2 { s.salaryDay = salaryDayCustom }
        BankSlotSettingsStore.save(s, slotId: slotId)
    }

    private func commitDispo() {
        var s = BankSlotSettingsStore.load(slotId: slotId)
        s.dispoLimit = dispoEnabled ? (Int(dispoLimitInput) ?? 0) : 0
        BankSlotSettingsStore.save(s, slotId: slotId)
    }

    private func commitPassword() {
        let currentlyRequired = UserDefaults.standard.object(forKey: "passwordRequired") as? Bool ?? true

        if passwordRequired {
            // User wants protection on — alle Auto-Unlock-Spuren entfernen.
            BiometricStore.clearAutoUnlock()
            UserDefaults.standard.set(true, forKey: "passwordRequired")
            return
        }

        // User will Schutz AUS — braucht Auto-Unlock-Eintrag im Keychain,
        // sonst fragt BalanceBar beim nächsten Start trotzdem.
        // commitPassword darf den Toggle nur dann effektiv ausschalten,
        // wenn das Master-Passwort verfügbar ist.
        guard let pw = requestMasterPassword(),
              (try? CredentialsStore.load(masterPassword: pw)) != nil else {
            // Master-Passwort nicht greifbar → Toggle visuell zurücksetzen,
            // damit der User merkt dass nichts passiert ist.
            passwordRequired = currentlyRequired
            passwordSetupError = L10n.t(
                "Konnte Auto-Unlock nicht einrichten — bitte später in den Einstellungen erneut versuchen.",
                "Couldn't set up auto-unlock — please retry later in Settings."
            )
            return
        }

        do {
            try BiometricStore.saveForAutoUnlock(password: pw)
            UserDefaults.standard.set(false, forKey: "passwordRequired")
            passwordSetupError = nil
        } catch {
            passwordRequired = currentlyRequired
            passwordSetupError = L10n.t(
                "Auto-Unlock fehlgeschlagen: \(error.localizedDescription)",
                "Auto-unlock failed: \(error.localizedDescription)"
            )
        }
    }

    private func commitDock() {
        UserDefaults.standard.set(dockModeEnabled, forKey: "dockModeEnabled")
        NotificationCenter.default.post(
            name: Notification.Name("simplebanking.dockModeChanged"),
            object: nil
        )
    }

    private func commitMCP() {
        guard enableMCP else { return }
        autoSetupMCP()
    }

    /// Trägt simplebanking in Claude Desktops MCP-Config ein. Logik analog
    /// `SettingsPanel.autoSetupMCP` (dort bleibt die User-trigger-Variante).
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
            mcpStatusMessage = L10n.t("Bereits eingerichtet.", "Already configured.")
            return
        }

        if let data = existingData, !data.isEmpty {
            let backupURL = configURL.deletingLastPathComponent()
                .appendingPathComponent("claude_desktop_config.backup.json")
            try? data.write(to: backupURL, options: .atomic)
        }

        // Verzeichnis sicherstellen falls Claude Desktop nicht installiert ist
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["simplebanking"] = ["command": mcpPath]
        config["mcpServers"] = servers

        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                     options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: configURL, options: .atomic)) != nil else {
            mcpStatusMessage = L10n.t("Konnte MCP-Konfiguration nicht schreiben.",
                                      "Could not write MCP configuration.")
            return
        }
        mcpStatusMessage = L10n.t("Eingerichtet — Claude Desktop neu starten.",
                                  "Configured — please restart Claude Desktop.")
    }
}
