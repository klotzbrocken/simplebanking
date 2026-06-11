import SwiftUI
import AppKit

// MARK: - LicenseStartScreen ("simplesend freischalten")
//
// Einheitlicher Freischalt-/Upsell-Dialog für simplesend — gezeigt beim App-Start
// (solange nicht freigeschaltet) UND beim Klick auf „Geld senden" ohne Lizenz.
// Design lt. Handoff `design_handoff_simplesend_unlock`: locker, knapp, mit
// Augenzwinkern. KEIN Lizenz-Key-Feld — die Key-Eingabe lebt in den Einstellungen.

@MainActor
struct LicenseStartScreen: View {
    let onClose: () -> Void
    /// Footer-Checkbox „Ich hab schon (nicht mehr anzeigen)" anzeigen.
    /// Am Start true; beim Klick-auf-simplesend false (dort stattdessen der
    /// „Registrierungsschlüssel"-Link).
    var showDontShowAgain: Bool = true
    /// Nur im App-Aufruf gesetzt: Link „Ich habe einen Registrierungsschlüssel"
    /// → öffnet die Einstellungen (Lizenz-Sektion).
    var onEnterKey: (() -> Void)? = nil

    @AppStorage("licenseScreen.dontShowAgain") private var dontShowAgain = false

    private let accent = Color.sbBlueStrong
    private var borderSoft: Color { Color.sbBorder.opacity(0.6) }
    private var textSubtle: Color { Color(NSColor.tertiaryLabelColor) }

    private struct Feature: Identifiable { let id = UUID(); let emoji: String; let label: String }
    private let features: [Feature] = [
        .init(emoji: "💸", label: "Geld senden direkt aus der App"),
        .init(emoji: "⚡", label: "Schnellüberweisung im Flyout"),
        .init(emoji: "📋", label: "Vorlagen & Empfänger-Vorschläge"),
        .init(emoji: "🔒", label: "Bestätigung bei deiner Bank (SCA)"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            featureCard.padding(.top, 22)
            pricing.padding(.top, 18)
            unlockCTA.padding(.top, 18)
            kofiOption.padding(.top, 11)
            Spacer(minLength: 16)
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sbSurface)
    }

    // MARK: Hero

    private var header: some View {
        HStack(spacing: 13) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable().scaledToFit()
                    .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("simplesend")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.sbTextPrimary)
                Text("Geld senden, direkt aus simplebanking 💸")
                    .font(.system(size: 12.5))
                    .foregroundColor(.sbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Feature-Karte

    private var featureCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(features.enumerated()), id: \.element.id) { idx, f in
                HStack(spacing: 0) {
                    Text(f.emoji)
                        .font(.system(size: 19))
                        .frame(width: 24, alignment: .center)
                    Text(f.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.sbTextPrimary)
                        .padding(.leading, 8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .overlay(alignment: .top) {
                    if idx > 0 { Rectangle().fill(borderSoft).frame(height: 1) }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.sbSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.sbBorder, lineWidth: 1)
                )
        )
    }

    // MARK: Gratis + Preis (kein Button-Look)

    private var pricing: some View {
        VStack(spacing: 3) {
            (Text("Alles andere in simplebanking bleibt ")
                + Text("gratis").foregroundColor(.sbGreenStrong).fontWeight(.bold)
                + Text(" 💚"))
                .font(.system(size: 12.5))
                .foregroundColor(.sbTextSecondary)
            Text("simplesend kostet einmal 15 €, ungefähr eine Pizza 🍕. Kein Abo 😉")
                .font(.system(size: 12.5))
                .foregroundColor(textSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: Option 1 — Freischalten

    private var unlockCTA: some View {
        Button(action: openCheckout) {
            HStack(spacing: 9) {
                Image(systemName: "paperplane").font(.system(size: 15, weight: .semibold))
                Text("Ja, freischalten").font(.system(size: 14.5, weight: .semibold))
                Text("15 €")
                    .font(.system(size: 13, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.20)))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent))
            .shadow(color: accent.opacity(0.32), radius: 9, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: Option 2 — Ko-fi

    private var kofiOption: some View {
        Button(action: openKofi) {
            HStack(spacing: 11) {
                Text("☕").font(.system(size: 19))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nein danke, kein simplesend")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.sbTextPrimary)
                    Text("…aber einen Kaffee geb ich gern aus")
                        .font(.system(size: 11.5))
                        .foregroundColor(.sbTextSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.sbSurfaceSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.sbBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(borderSoft).frame(height: 1)
            HStack(alignment: .center) {
                if showDontShowAgain {
                    Toggle(isOn: $dontShowAgain) {
                        Text("Ich hab schon (nicht mehr anzeigen)")
                            .font(.system(size: 12.5))
                            .foregroundColor(.sbTextSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .toggleStyle(.checkbox)
                    .frame(height: 32)
                } else if let onEnterKey {
                    Button(action: onEnterKey) {
                        Text("Ich habe einen Registrierungsschlüssel")
                            .font(.system(size: 12.5))
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .frame(height: 32)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Text("Schließen")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.sbTextPrimary)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.sbSurfaceSoft)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.sbBorder, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 12)
        }
    }

    // MARK: Actions

    private func openCheckout() {
        if LicenseConfig.isConfigured { NSWorkspace.shared.open(LicenseConfig.purchaseURL) }
        onClose()   // Fenster nach dem Öffnen des Checkouts schließen.
    }

    private func openKofi() {
        if let u = URL(string: "https://ko-fi.com/N4N11K1NC") { NSWorkspace.shared.open(u) }
        onClose()   // Fenster nach dem Öffnen von Ko-fi schließen.
    }
}
