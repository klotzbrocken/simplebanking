import SwiftUI
import AppKit

// MARK: - TransferVoucherSheet
//
// Einmaliger Post-Update-Hinweis auf das in 1.5.0 neue „Geld senden"-Modul
// mit Launch-Voucher: statt LicenseConfig.displayPrice (€15) nur
// LicenseConfig.voucherDisplayPrice (€10).
//
// Wird von BalanceBar nach App-Launch gezeigt, wenn:
//   - LicenseConfig.licensingEnabled == true
//   - FeatureFlags.transferMoneyEnabled == true
//   - bestehender Setup vorhanden (CredentialsStore.exists())
//   - keine aktive Lizenz
//   - `simplebanking.transferVoucher.shown.v1` noch nicht gesetzt
//
// Das „shown"-Flag wird BEIM Öffnen gesetzt, damit Schließen ohne Kauf
// die Anzeige nicht wieder triggert.

@MainActor
struct TransferVoucherSheet: View {
    let onClose: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Neu: simplesend", "New: simplesend"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(L10n.t("Launch-Voucher für bestehende Nutzer",
                                "Launch voucher for existing users"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // Voucher Pricing Banner
            HStack(spacing: 14) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Dein Voucher", "Your voucher"))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(LicenseConfig.displayPrice)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .strikethrough(true, color: .secondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(LicenseConfig.voucherDisplayPrice)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
            )

            // Feature-Beschreibung — kompakter als UpsellSheet
            VStack(alignment: .leading, spacing: 10) {
                bullet(icon: "bolt.fill",
                       text: L10n.t("SEPA-Überweisung in 2 Klicks — Empfänger und Betrag aus deinen Buchungen vorgeschlagen.",
                                    "SEPA transfer in 2 clicks — recipient and amount suggested from your transactions."))
                bullet(icon: "lock.shield.fill",
                       text: L10n.t("TAN wie gewohnt direkt bei deiner Bank. simplebanking sieht keine Bank-Daten.",
                                    "TAN confirmation directly with your bank. simplebanking sees no bank data."))
                bullet(icon: "checkmark.seal.fill",
                       text: L10n.t("Einmalkauf — keine Abo-Falle. Updates innerhalb von 1.x kostenlos.",
                                    "One-time purchase — no subscription. Free updates within 1.x."))
            }

            Divider()

            // CTA-Buttons
            HStack(spacing: 10) {
                Button(action: openCheckout) {
                    HStack(spacing: 6) {
                        Image(systemName: "tag.fill")
                        Text(L10n.t("Für \(LicenseConfig.voucherDisplayPrice) freischalten",
                                    "Unlock for \(LicenseConfig.voucherDisplayPrice)"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(action: { onLater() }) {
                    Text(L10n.t("Später", "Later"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }

            // Footer-Hinweis
            Text(L10n.t(
                "Dieser Hinweis erscheint nur einmal. Du erreichst simplesend jederzeit über das Menü.",
                "This notice appears only once. You can reach simplesend anytime from the menu."))
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 460)
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openCheckout() {
        if !LicenseConfig.isConfigured {
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
        NSWorkspace.shared.open(LicenseConfig.effectiveVoucherPurchaseURL)
        onClose()
    }
}
