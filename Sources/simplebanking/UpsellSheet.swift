import SwiftUI
import AppKit

// MARK: - UpsellSheet
//
// Wird gezeigt wenn ein User ohne aktive Lizenz auf „Geld senden…" klickt.
// Erklärt das Feature, zeigt Preis, hat zwei klare Wege:
// 1. „Lizenz kaufen" → Polar-Checkout im Browser
// 2. „Lizenz-Key eingeben" → Sprung in Settings → Über
//
// Für Demo-Modus-User wird der Sheet nicht gezeigt — sie können das
// TransferSheet direkt mit Mock-Result testen (siehe LicenseManager.
// isLicensedOrDemo).

@MainActor
struct UpsellSheet: View {
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @AppStorage("simplesendVisible") private var simplesendVisible: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("simplesend", "simplesend"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(L10n.t("Senden direkt aus simplebanking",
                                "Send directly from simplebanking"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // Feature-Beschreibung
            VStack(alignment: .leading, spacing: 12) {
                bullet(icon: "bolt.fill",
                       title: L10n.t("Schnelle Eingabe", "Fast input"),
                       text: L10n.t(
                        "Empfänger oder IBAN tippen, Vorschläge aus deinen Buchungen, mit Standard-Betrag und Verwendungszweck.",
                        "Type recipient or IBAN, suggestions from your transactions, with default amount and purpose."))
                bullet(icon: "lock.shield.fill",
                       title: L10n.t("Sicher", "Secure"),
                       text: L10n.t(
                        "Zahlungsauslösung über den lizenzierten Open-Banking-Anbieter YAXI. Du bestätigst jede Überweisung direkt bei deiner Bank per SCA. simplebanking erhält keine Zugangsdaten.",
                        "Payment initiation via the licensed open-banking provider YAXI. You confirm every transfer directly with your bank via SCA. simplebanking receives no credentials."))
                bullet(icon: "checkmark.seal.fill",
                       title: L10n.t("Einmal kaufen", "One-time purchase"),
                       text: L10n.t(
                        "\(LicenseConfig.displayPrice) einmalig, kein Abo.",
                        "\(LicenseConfig.displayPrice) one-time, no subscription."))
            }

            Divider()

            // CTA-Buttons
            HStack(spacing: 10) {
                Button(action: openCheckout) {
                    HStack(spacing: 6) {
                        Image(systemName: "cart.fill")
                        Text(L10n.t("Für \(LicenseConfig.displayPrice) freischalten",
                                    "Unlock for \(LicenseConfig.displayPrice)"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(action: {
                    onOpenSettings()
                }) {
                    Text(L10n.t("Lizenz-Key eingeben…",
                                "Enter license key…"))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            // Opt-Out: simplesend komplett ausblenden. Inverted Binding,
            // damit das Storage-Flag positiv bleibt (`simplesendVisible`).
            // .onChange postet die Notification, die BalanceBar live updated.
            Toggle(isOn: Binding(
                get: { !simplesendVisible },
                set: { simplesendVisible = !$0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("simplesend nicht im Footer anzeigen",
                                "Don't show simplesend in the footer"))
                        .font(.system(size: 12))
                    Text(L10n.t("Kann in Einstellungen geändert werden.",
                                "Can be changed in Settings."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .onChange(of: simplesendVisible) { _ in
                NotificationCenter.default.post(
                    name: Notification.Name("simplebanking.simplesendVisibilityChanged"),
                    object: nil
                )
            }

            // Footer-Link
            HStack {
                Spacer()
                Button(L10n.t("Schließen", "Close")) { onClose() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func bullet(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openCheckout() {
        if !LicenseConfig.isConfigured {
            // Wenn die App ohne Konfig gebaut wurde (Dev-Build), zeigen wir
            // einen Hinweis statt einen kaputten Link zu öffnen.
            let alert = NSAlert()
            alert.messageText = L10n.t("Lizenz noch nicht konfiguriert",
                                       "License not yet configured")
            alert.informativeText = L10n.t(
                "Diese Build-Variante hat noch keine Polar-Anbindung. Bitte kontaktiere den Entwickler.",
                "This build has no Polar configuration. Please contact the developer.")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(LicenseConfig.purchaseURL)
    }
}
