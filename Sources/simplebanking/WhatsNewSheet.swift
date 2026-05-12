import AppKit
import SwiftUI

// MARK: - WhatsNewSheet
//
// Zeigt eine kuratierte Liste von User-sichtbaren Highlights nach einem
// Versions-Update. Trigger: `CFBundleShortVersionString` ≠ dem persistierten
// `simplebanking.lastSeenWhatsNewVersion`. Wird nicht auf Erst-Installation
// gezeigt — der InitialSetupExtensionSheet handled Onboarding separat.
//
// Highlight-Liste pro Version per Hand kuratiert in `WhatsNewContent.highlights`.

@MainActor
enum WhatsNewTrigger {

    private static let storageKey = "simplebanking.lastSeenWhatsNewVersion"

    /// Liefert true wenn die Sheet beim aktuellen Launch gezeigt werden soll.
    /// Setzt das Flag NICHT — der Caller markiert nach erfolgter Anzeige.
    ///
    /// `isExistingUser`: true wenn dieser Mac bereits Credentials hat, also
    /// kein Erst-Setup. Wichtig für das ALLERERSTE Release mit WhatsNew-Sheet
    /// (1.5.0): bestehende User haben dort auch `lastSeen == nil`, weil
    /// das Feature neu ist. Ohne diese Unterscheidung würde 1.5.0 still
    /// markiert und nie angezeigt.
    static func shouldShowOnLaunch(isExistingUser: Bool) -> Bool {
        guard let current = currentVersion() else { return false }
        let lastSeen = UserDefaults.standard.string(forKey: storageKey)
        if lastSeen == nil {
            if isExistingUser {
                // Bestehende Installation + nie WhatsNew gesehen → das erste
                // Release mit Sheet-Feature. Anzeigen, falls Highlights da sind.
                return WhatsNewContent.highlights(for: current) != nil
            } else {
                // Echter Erst-Setup: Onboarding übernimmt. Flag setzen, damit
                // wir beim ersten Update danach NICHT noch das aktuelle Sheet
                // zeigen (dessen Inhalt der User schon im Setup gesehen hat).
                UserDefaults.standard.set(current, forKey: storageKey)
                return false
            }
        }
        if lastSeen == current { return false }
        return WhatsNewContent.highlights(for: current) != nil
    }

    static func markShown() {
        guard let current = currentVersion() else { return }
        UserDefaults.standard.set(current, forKey: storageKey)
    }

    static func currentVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

@MainActor
final class WhatsNewPanel: NSObject, NSWindowDelegate {

    private let panel: NSPanel
    private let version: String

    init(version: String) {
        self.version = version
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Neu in simplebanking"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.minSize = NSSize(width: 480, height: 540)
        panel.maxSize = NSSize(width: 480, height: 540)
        super.init()
        panel.delegate = self
    }

    func runModal() {
        let view = WhatsNewSheet(
            version: version,
            highlights: WhatsNewContent.highlights(for: version) ?? [],
            onClose: { [weak self] in
                guard self != nil else { return }
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

struct WhatsNewItem: Identifiable {
    let id = UUID()
    let icon: String      // SF Symbol
    let tint: Color
    let title: String
    let description: String
}

@MainActor
struct WhatsNewSheet: View {

    let version: String
    let highlights: [WhatsNewItem]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(highlights) { item in
                        highlightCard(item)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 14)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 480, height: 540)
        .background(Color.panelBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            appIconView
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Neu in simplebanking", "What's new in simplebanking"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.sbTextSecondary)
                Text("Version \(version)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.sbTextPrimary)
            }
            Spacer()
            Button(action: { onClose() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.sbTextSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var appIconView: some View {
        if let icon = AppIconLoader.load() {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
        } else {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 24))
                .foregroundColor(.sbBlueStrong)
                .frame(width: 36, height: 36)
        }
    }

    private func highlightCard(_ item: WhatsNewItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(item.tint.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(item.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sbTextPrimary)
                Text(item.description)
                    .font(.system(size: 12))
                    .foregroundColor(.sbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.sbSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.sbBorder, lineWidth: 0.5)
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: { onClose() }) {
                Text(L10n.t("Loslegen", "Get started"))
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
}

// MARK: - Per-version highlight content

@MainActor
enum WhatsNewContent {

    /// Liefert nil wenn für diese Version keine Highlights kuratiert wurden
    /// — dann zeigt der Trigger keine Sheet (still update).
    static func highlights(for version: String) -> [WhatsNewItem]? {
        switch version {
        case "1.5.0":
            return v150
        default:
            return nil
        }
    }

    private static let v150: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "paperplane.fill",
            tint: .sbBlueStrong,
            title: L10n.t("Geld senden direkt aus der App",
                          "Send money straight from the app"),
            description: L10n.t(
                "SEPA-Überweisungen mit Vorlagen, Favoriten, Sende-Verzögerung als Sicherheitsnetz und optionaler PDF-Quittung per E-Mail an den Empfänger.",
                "SEPA transfers with templates, favorites, send-delay as a safety net, and optional PDF receipt by email to the recipient."
            )
        ),
        WhatsNewItem(
            icon: "doc.on.clipboard",
            tint: .sbGreenStrong,
            title: L10n.t("IBAN aus Zwischenablage",
                          "IBAN from clipboard"),
            description: L10n.t(
                "Kopierst du eine IBAN, erkennt simplebanking sie automatisch und bietet sie beim Senden an — ein Klick zum Einfügen.",
                "Copy an IBAN anywhere, simplebanking detects it and offers to paste it when sending — one click."
            )
        ),
        WhatsNewItem(
            icon: "sparkles",
            tint: .sbOrangeStrong,
            title: L10n.t("Einrichtungs-Tour",
                          "Setup tour"),
            description: L10n.t(
                "Nach dem ersten Bank-Connect führen wir dich durch fünf Settings: Gehaltstag, Dispo-Limit, App-Schutz, Dock-Modus und KI-Agenten-Freigabe.",
                "After your first bank connect, we walk you through five settings: payday, overdraft, app protection, dock mode, and AI-agent access."
            )
        ),
        WhatsNewItem(
            icon: "stethoscope",
            tint: .sbRedStrong,
            title: L10n.t("Bank-Diagnose-Assistent",
                          "Bank diagnostics assistant"),
            description: L10n.t(
                "Probiert alle Konten einzeln, sammelt Logs + YAXI-Traces und schickt dem Support ein fertiges Mail-Bundle. Hilft, wenn ein Bank-Refresh streikt.",
                "Probes every account, collects logs + YAXI traces, and sends support a ready-made email bundle. For when a bank refresh acts up."
            )
        ),
        WhatsNewItem(
            icon: "bolt.fill",
            tint: .sbBlueStrong,
            title: L10n.t("Schneller bei vielen Umsätzen",
                          "Faster with many transactions"),
            description: L10n.t(
                "Such-, Abo- und Fixkosten-Indizes laufen jetzt im Hintergrund — kein UI-Hänger mehr beim Slot-Wechsel oder nach Auto-Refresh, auch bei 5.000+ Buchungen.",
                "Search, subscription, and fixed-cost indexes now run in the background — no more UI hiccups on slot switch or auto-refresh, even at 5,000+ transactions."
            )
        ),
    ]
}
