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
        VStack(alignment: .leading, spacing: 10) {
            // Nur wer noch nicht eingetragen ist — sonst fragt jedes Update erneut.
            if !NewsletterSignup.hasSubscribed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("Das war neu. Künftig per Mail erfahren?",
                                "That's what's new. Want it by email next time?"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.sbTextPrimary)
                    NewsletterSignupView(source: "whatsnew-\(version)", zeigeUeberschrift: false)
                }
                Divider().opacity(0.4)
            }
            footerButtons
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.panelBackground)
    }

    private var footerButtons: some View {
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
    }
}

// MARK: - Per-version highlight content

@MainActor
enum WhatsNewContent {

    /// Liefert nil wenn für diese Version keine Highlights kuratiert wurden
    /// — dann zeigt der Trigger keine Sheet (still update).
    static func highlights(for version: String) -> [WhatsNewItem]? {
        switch version {
        case "2.0.2":
            return v202
        case "2.0.1":
            return v201
        case "1.5.0":
            return v150
        default:
            return nil
        }
    }

    /// 2.0.2. Dieselbe Auswahlregel wie bei 2.0.1: nur, was jemand auch merkt. Die
    /// beiden neuen Theme-Schlüssel stehen deshalb zusammen in einem Punkt — für einen
    /// Nutzer ohne eigenes Theme ändert sich dadurch nichts, für den Theme-Bauer ist es
    /// der Grund, in THEMES.md zu schauen.
    private static let v202: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "checkmark.shield",
            tint: .sbBlueStrong,
            title: L10n.t("Keine zweite TAN für einen Serverfehler",
                          "No second TAN for a server hiccup"),
            description: L10n.t(
                "Antwortete die Bank mit einem Fehler ohne Begründung, hielt simplebanking die Zustimmung für abgelaufen, warf sie weg und fragte eine neue TAN ab — die dann am selben Fehler scheiterte. Jetzt wird erst unverändert wiederholt; das kostet keine Freigabe.",
                "When the bank returned an error without a reason, simplebanking assumed your consent had expired, discarded it and asked for a fresh TAN — which then failed on the very same error. It now simply retries first, at no cost to you."
            )
        ),
        WhatsNewItem(
            icon: "circle.dotted",
            tint: .sbGreenStrong,
            title: L10n.t("Der Kontoring ist im Flyout zurück",
                          "The account ring is back in the flyout"),
            description: L10n.t(
                "Er war seit 2.0 verschwunden, während die Einstellungen weiter versprachen, dass er „im Flyout und in der Umsatzliste“ erscheint. Beide Fenster folgen jetzt demselben Schalter.",
                "It had been gone since 2.0, while settings kept promising it appears \"in the flyout and the transaction list\". Both windows now follow the same switch."
            )
        ),
        WhatsNewItem(
            icon: "qrcode",
            tint: .sbGreenStrong,
            title: L10n.t("bunq verlangt nicht mehr bei jedem Abruf einen QR-Scan",
                          "bunq no longer asks for a QR scan on every refresh"),
            description: L10n.t(
                "Bei Banken, die im Browser freigegeben werden — bunq, N26, Revolut — warf simplebanking die erteilte Zustimmung nach einem unklaren Serverfehler weg. Anders als bei Banken mit Zugangsdaten wächst sie dort nicht nach: Sie entsteht nur bei der Einrichtung. Einmal verworfen, fing jeder Abruf wieder von vorn an. Bestehende bunq-Verbindungen müssen einmalig neu eingerichtet werden.",
                "For banks approved in the browser — bunq, N26, Revolut — simplebanking discarded your consent after an unclear server error. Unlike with credential-based banks it does not come back: it is only created during setup. Once discarded, every refresh started over. Existing bunq connections need to be set up once more."
            )
        ),
        WhatsNewItem(
            icon: "paintpalette",
            tint: .sbOrangeStrong,
            title: L10n.t("Themes importieren — und mehr Spielraum beim Bauen",
                          "Import themes — and more room to build them"),
            description: L10n.t(
                "Einstellungen → Verhalten → „Theme importieren …“ nimmt eine einzelne .cfg oder ein ZIP mit Hintergrundbild, Logo und Ringgrafik und aktiviert es sofort. Wer selbst baut: Der Kontoring lässt sich weglassen oder durch eine eigene Grafik ersetzen, Textkommandos ziehen keine größeren Schriftgrade mehr nach sich, und die Farbe der Bedien-Symbole ist einstellbar.",
                "Settings → Behaviour → \"Import theme …\" takes a single .cfg or a ZIP with wallpaper, logo and ring graphic, and activates it right away. If you build your own: the account ring can be dropped or replaced by a graphic, text controls no longer drag larger type sizes along, and the colour of the control icons is now yours to set."
            )
        ),
        WhatsNewItem(
            icon: "arrow.up.right",
            tint: .sbBlueStrong,
            title: L10n.t("Neu im Labor: Veränderung neben dem Kontostand",
                          "New in Labs: change next to your balance"),
            description: L10n.t(
                "Klein neben dem Saldo, etwa „▼ 4,2 %“: wie der Kontostand gegenüber demselben Tag im Vormonat steht. Bewusst kalendarisch und nicht „vor 30 Tagen“ — so liegt jeder monatliche Posten wie Gehalt oder Miete genau einmal im Vergleich. Standardmäßig aus, einzuschalten unter Einstellungen → Labor.",
                "Small, next to your balance, like \"▼ 4.2 %\": how it compares to the same day a month ago. Deliberately calendar-based rather than \"30 days ago\" — that way every monthly item like salary or rent falls inside the window exactly once. Off by default; switch it on under Settings → Labs."
            )
        ),
    ]

    /// 2.0.1 ist ein reines Fehlerbehebungs-Release. Aufgenommen wird nur, was jemand
    /// auch gemerkt hat — die Reparaturen an Zustellwegen und Protokollen bleiben
    /// draußen, die interessieren niemanden außerhalb des Codes.
    private static let v201: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "keyboard",
            tint: .sbBlueStrong,
            title: L10n.t("TAN-Eingabe erscheint sofort",
                          "TAN entry shows up right away"),
            description: L10n.t(
                "Bei Banken mit Tipp-TAN kam das Eingabefeld erst, wenn man die Einrichtung abbrach — die TAN war dann abgelaufen. Und im Titel steht jetzt die Bank, die wirklich fragt.",
                "With typed-TAN banks the input field only appeared once you cancelled setup — by then the TAN had expired. And the title now names the bank actually asking."
            )
        ),
        WhatsNewItem(
            icon: "building.columns",
            tint: .sbGreenStrong,
            title: L10n.t("Konten lassen sich wieder entfernen",
                          "Accounts can be removed again"),
            description: L10n.t(
                "Ein abgebrochener Händler-Login hinterließ ein Konto, das sich weder löschen noch zurücksetzen ließ. Beides behoben — und das letzte Konto ist jetzt ebenfalls entfernbar.",
                "An aborted merchant login left behind an account that could neither be deleted nor reset. Both fixed — and the last remaining account can now be removed too."
            )
        ),
        WhatsNewItem(
            icon: "menubar.rectangle",
            tint: .sbOrangeStrong,
            title: L10n.t("Bank-Logo in der Menüleiste",
                          "Bank logo in the menu bar"),
            description: L10n.t(
                "Statt eines €-Platzhalters erscheint das Logo deiner Bank — jetzt für alle 192 Banken aus dem Katalog. Und das Flyout reagiert auf den ersten Klick.",
                "Instead of a € placeholder you get your bank's logo — now for all 192 banks in the catalog. And the flyout responds to the first click."
            )
        ),
    ]

    private static let v150: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "paperplane.fill",
            tint: .sbBlueStrong,
            title: L10n.t("simplesend — direkt aus simplebanking",
                          "simplesend — straight from simplebanking"),
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
