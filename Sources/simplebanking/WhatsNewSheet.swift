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
            // Mit sichtbarer Leiste: Bei acht Einträgen sieht man drei auf einmal, und
            // ohne Leiste ist nicht erkennbar, dass darunter noch etwas kommt.
            ScrollView(.vertical, showsIndicators: true) {
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
        case "2.2.2":
            return v222
        case "2.2.1":
            return v221
        case "2.2.0":
            return v220
        case "2.0.9":
            return v209
        case "2.0.7":
            return v207
        case "2.0.6":
            return v206
        case "2.0.5":
            return v205
        case "2.0.3":
            return v203
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

    /// 2.2.2. Eine Karte, ein Fehler — aber einer, der jeden traf, der Historie
    /// importiert hat, und zwar unsichtbar: Es gab keine Fehlermeldung, nur keine
    /// Umsätze. Wer deshalb glaubt, sein Import sei schiefgegangen, soll hier lesen,
    /// dass er es nicht war und was jetzt zu tun ist.
    private static let v222: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "calendar.badge.clock",
            tint: .sbBlueStrong,
            title: L10n.t("Importierte Historie ist jetzt auch zu sehen",
                          "Imported history is now actually visible"),
            description: L10n.t(
                "Wer Umsätze aus MoneyMoney, einer OFX- oder einer CAMT.053-Datei übernommen hat, bekam die richtige Zahl gemeldet — und sah danach trotzdem nur die letzten Wochen. Die Buchungen waren vollständig da; die Liste fragt die Datenbank aber nur so weit zurück, wie ihr Zeitraum reicht, und der blieb beim Import unverändert. Nichts ist dabei verloren gegangen. **Den Import einfach noch einmal starten**: Er bringt nichts Neues herein, zieht den Zeitraum aber auf den Verlauf, der schon liegt — danach steht alles in der Liste, im Export und in der Kategorisierung. Der Abrufzeitraum der Bank bleibt davon unberührt.",
                "If you imported transactions from MoneyMoney, an OFX or a CAMT.053 file, you were told the right number — and then still only saw the last few weeks. The entries were all there; the list only queries the database as far back as its own range reaches, and importing never widened it. Nothing was lost. **Just run the import again**: it brings in nothing new, but widens the range to the history already stored — after that everything shows up in the list, the export and in categorisation. How far back the bank itself is queried is unaffected."
            )
        ),
    ]

    /// 2.2.0. Trägt auch den Inhalt der übersprungenen 2.1.0 — die ist nie
    /// erschienen, also hat sie niemand gesehen, und ein `case "2.1.0"` hätte für
    /// immer ins Leere gezeigt: Kein „Was ist neu"-Fenster, und mit ihm auch nicht
    /// die Newsletter-Anmeldung in dessen Fuß. Nichts wäre fehlgeschlagen, es wäre
    /// nur nichts passiert.
    ///
    /// Dieselbe Auswahlregel wie immer — nur, was jemand auch merkt. Der Kontoname
    /// auf der Kachel und der benannte Schritt in der Einrichtung stehen deshalb
    /// nicht hier: Beides fällt erst auf, wenn man es daneben legt.
    private static let v221: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "square.and.arrow.down",
            tint: .sbBlueStrong,
            title: L10n.t("MoneyMoney-Umstieg auch nachtr\u{00E4}glich",
                          "Switch from MoneyMoney later, too"),
            description: L10n.t(
                "Der Umstieg aus MoneyMoney war bisher Teil der Ersteinrichtung \u{2014} wer simplebanking schon benutzte und seinen Verlauf erst sp\u{00E4}ter mitnehmen wollte, h\u{00E4}tte alles l\u{00F6}schen und neu anlegen m\u{00FC}ssen. Jetzt steht er in **Einstellungen \u{2192} Konten**: ein Blatt f\u{00FC}r alle Konten, weil eine MoneyMoney-Datenbank mit *einem* Kennwort ge\u{00F6}ffnet wird. \u{00DC}bernommen wird nur, was \u{00E4}lter ist als die \u{00E4}lteste Buchung, die das Konto schon hat \u{2014} die vorhandenen Ums\u{00E4}tze bleiben unber\u{00FC}hrt. Konten, die hier nicht verbunden sind, werden mit Grund abgesagt, statt stillschweigend zu fehlen. Das Kennwort wird wie bisher nur zum Entschl\u{00FC}sseln gebraucht und nicht gespeichert.",
                "Importing from MoneyMoney used to be part of first-time setup only \u{2014} if you already used simplebanking and wanted your history later, you would have had to delete everything and start over. It now lives in **Settings \u{2192} Accounts**: one sheet for all accounts, because a MoneyMoney database opens with *one* password. Only entries older than the account's oldest existing booking are imported \u{2014} what is already there stays untouched. Accounts not connected here are declined with a reason instead of quietly missing. The password is still only used to decrypt and is never stored."
            )
        ),
        WhatsNewItem(
            icon: "hourglass",
            tint: .sbBlueStrong,
            title: L10n.t("„Verfügbar“ unter dem Kontostand",
                          "“Available” below your balance"),
            description: L10n.t(
                "Manche Banken — die ING etwa — geben über ihre Schnittstelle nur den **gebuchten** Saldo heraus, zeigen in ihrer eigenen App aber den Stand abzüglich schon vorgemerkter Abbuchungen. Dann stehen zwei Zahlen nebeneinander, und keine ist falsch. simplebanking rechnet die zweite jetzt selbst und zeigt sie als weitere Position im Untertitel unter dem Saldo — im Flyout wie in der Umsatzliste, über dasselbe Symbol wie Fixkosten und Bankgebühren. Sie erscheint nur, wenn etwas vorgemerkt ist. Vorgemerkte **Eingänge** zählen bewusst nicht: Ein erwarteter Betrag ist nicht zugesagt. Die große Zahl bleibt, was die Bank sagt.",
                "Some banks — ING among them — only hand out the **booked** balance over their interface, while their own app shows the balance minus payments that are already pending. Two numbers side by side, and neither is wrong. simplebanking now works out the second one itself and shows it as another position in the subtitle below your balance — in the flyout and in the transaction list, behind the same icon as recurring costs and bank fees. It only appears when something is pending. Pending **incoming** amounts deliberately do not count: money that is expected is not money that is promised. The big number stays what the bank says."
            )
        ),
    ]

    private static let v220: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "square.and.arrow.down",
            tint: .sbBlueStrong,
            title: L10n.t("Umstieg von MoneyMoney \u{2014} in einem Zug",
                          "Switching from MoneyMoney \u{2014} in one go"),
            description: L10n.t(
                "Wer von MoneyMoney kommt, musste bisher mit einem leeren Verlauf anfangen: Die Bank liefert \u{00FC}ber Open Banking nur die letzten 90 Tage, alles davor lag in MoneyMoney und blieb dort. Die Einrichtung bietet den Umstieg jetzt selbst an, wenn sie eine MoneyMoney-Datenbank findet \u{2014} **Konten, der ganze Umsatzverlauf und die erste Ebene deiner Kategorien**, und zwar nur f\u{00FC}r die Konten, die \u{00FC}ber Open Banking \u{00FC}berhaupt erreichbar sind; Depots und Offline-Konten sagt sie ausdr\u{00FC}cklich ab, mit Grund. Deine eigenen Kategorien werden angelegt, nicht auf unsere vierzehn gebogen, und die Kontonamen aus MoneyMoney werden die Kurznamen. Dein MoneyMoney-Kennwort braucht sie zum Entschl\u{00FC}sseln und **speichert es nicht**; gelesen wird nur, nie zur\u{00FC}ckgeschrieben. Importiert wird allein, was \u{00E4}lter ist als der Zeitraum der Bank \u{2014} nichts liegt doppelt.",
                "Switching from MoneyMoney used to mean starting with an empty history: over Open Banking your bank only hands out the last 90 days, and everything before that stayed in MoneyMoney. Setup now offers the switch itself when it finds a MoneyMoney database \u{2014} **accounts, your whole transaction history and the first level of your categories** \u{2014} and only for the accounts that Open Banking can actually reach; portfolios and offline accounts are declined explicitly, with a reason. Your own categories are created rather than squeezed into our fourteen, and your MoneyMoney account names become the nicknames. Your MoneyMoney password is needed to decrypt and is **never stored**; the database is only read, never written back. Only what predates your bank's window is imported \u{2014} nothing lands twice."
            )
        ),
        WhatsNewItem(
            icon: "arrow.down.circle",
            tint: .sbBlueStrong,
            title: L10n.t("Die App sagt selbst, wenn eine neue Fassung da ist",
                          "The app now tells you when a new version is out"),
            description: L10n.t(
                "Bisher prüfte simplebanking nur auf Zuruf \u{2014} Men\u{00FC} \u{2192} \u{201E}Nach Updates suchen\u{2026}\u{201C}. Wer nie nachsah, erfuhr nie von einer Aktualisierung. Liegt jetzt eine neue Fassung bereit, steht rechts neben dem Saldo ein \u{21BB}, und im Flyout erscheint \u{00FC}ber der Karte ein Band mit der Fassungsnummer. **Kein Fenster springt auf**, nichts wird im Hintergrund installiert \u{2014} der Hinweis wartet, bis du hinsiehst. Hat das Konto etwas zu melden, hat das Vorrang: Geld geht vor Software.",
                "Until now simplebanking only checked when asked \u{2014} Menu \u{2192} \u{201C}Check for Updates\u{2026}\u{201D}. Anyone who never looked never heard about an update. When a new version is ready you now get a \u{21BB} next to your balance and a band above the card in the flyout naming the version. **No window pops up**, nothing installs in the background \u{2014} the hint waits until you look. If your account has news, that comes first: money before software."
            )
        ),
        WhatsNewItem(
            icon: "accessibility",
            tint: .sbBlueStrong,
            title: L10n.t("Mit VoiceOver bedienbar",
                          "Usable with VoiceOver"),
            description: L10n.t(
                "Das Men\u{00FC}leisten-Symbol war mit VoiceOver erreichbar, aber nicht bedienbar \u{2014} VO+Leertaste bewirkte nichts, es ging weder Men\u{00FC} noch Fenster auf. *Gemeldet von einem blinden Nutzer, der macOS nur \u{00FC}ber Tastatur und VoiceOver bedient.* Jetzt \u{00F6}ffnet ein Druck ohne Maus das Men\u{00FC}leisten-Men\u{00FC}, und das erreicht neu auch Kontostand, Ums\u{00E4}tze und das Ein- und Ausblenden des Saldos \u{2014} letzteres ging bisher **nur** mit der Maus. Das Symbol sagt \u{201E}simplebanking, Kontostand \u{2026}\u{201C} statt einer nackten Zahl, ein ausgeblendeter Saldo wird **nie** vorgelesen, und rund 50 Symbolkn\u{00F6}pfe, die Kontokacheln und die Wischaktionen in der Umsatzliste tragen jetzt Namen, Zustand und Tastaturweg.",
                "The menu bar item was reachable with VoiceOver but not operable \u{2014} VO+Space did nothing, no menu and no window opened. *Reported by a blind user who drives macOS entirely by keyboard and VoiceOver.* A press without a mouse now opens the menu bar menu, and that menu newly reaches your balance, your transactions and hiding or showing the balance \u{2014} the last of which previously needed the **mouse**. The item announces \u{201C}simplebanking, balance \u{2026}\u{201D} instead of a bare number, a hidden balance is **never** spoken, and some 50 icon buttons, the account tiles and the swipe actions in the transaction list now carry names, state and a keyboard route."
            )
        ),
        WhatsNewItem(
            icon: "calendar.badge.clock",
            tint: .sbBlueStrong,
            title: L10n.t("Dauerauftr\u{00E4}ge kommen von der Bank",
                          "Standing orders now come from your bank"),
            description: L10n.t(
                "\u{201E}Abos & Vertr\u{00E4}ge\u{201C} erkannte Wiederkehr allein an der Vergangenheit und brauchte daf\u{00FC}r mindestens zwei Buchungen \u{2014} ein Dauerauftrag, der erst n\u{00E4}chsten Monat das erste Mal l\u{00E4}uft, war unsichtbar, und bei den \u{00FC}brigen war der Betrag ein Mittelwert. Der Knopf \u{201E}Dauerauftr\u{00E4}ge\u{201C} fragt sie jetzt direkt beim Institut ab, mit vereinbartem Betrag, Takt und **n\u{00E4}chstem** Termin. Der Abruf l\u{00E4}uft nur auf Klick, weil er je nach Bank eine Freigabe kosten kann.",
                "\u{201C}Subscriptions & contracts\u{201D} spotted recurrence only from the past and needed at least two bookings for it \u{2014} a standing order first due next month was invisible, and for the rest the amount was an average. The \u{201C}Standing orders\u{201D} button now asks your bank directly, with the agreed amount, interval and **next** date. It runs on click only, because depending on the bank it can cost an approval."
            )
        ),
        WhatsNewItem(
            icon: "rectangle.and.hand.point.up.left",
            tint: .sbGreenStrong,
            title: L10n.t("Mehr als sieben Konten sind wieder erreichbar",
                          "More than seven accounts are reachable again"),
            description: L10n.t(
                "Ab acht Konten passte die Reihe der Kontosymbole nicht mehr ins Flyout \u{2014} und sie wurde an **beiden** Enden abgeschnitten, unter Umst\u{00E4}nden samt dem gerade aktiven Konto. *Gemeldet von einem Nutzer mit zehn Konten.* Die Reihe l\u{00E4}sst sich jetzt quer scrollen, blendet ihre R\u{00E4}nder aus, wenn etwas \u{00FC}berl\u{00E4}uft, und holt das aktive Konto von selbst in den Blick. Weil nicht jede Maus quer scrollen kann, gibt es den Kontowechsel zus\u{00E4}tzlich im Men\u{00FC} der Men\u{00FC}leiste unter \u{201E}Konto\u{201C} \u{2014} mit Haken am aktiven und \u{201E}Alle Konten\u{201C}.",
                "From eight accounts on, the row of account symbols no longer fitted the flyout \u{2014} and it was cut off at **both** ends, sometimes including the account you were looking at. *Reported by a user with ten accounts.* The row now scrolls sideways, fades its edges when something overflows, and brings the active account into view by itself. Because not every mouse can scroll sideways, switching accounts is also in the menu bar menu under \u{201C}Account\u{201D} \u{2014} with a checkmark on the active one and \u{201C}All accounts\u{201D}."
            )
        ),
        WhatsNewItem(
            icon: "lock.rotation",
            tint: .sbGreenStrong,
            title: L10n.t("Eine abgebrochene Freigabe l\u{00E4}sst sich neu ansto\u{00DF}en",
                          "An interrupted approval can be restarted"),
            description: L10n.t(
                "Wer das Freigabe-Fenster seiner Bank versehentlich schloss, kam bis zum Programmneustart nicht mehr an sein Konto: \u{201E}Aktualisieren\u{201C}, das \u{21BB} und das Herunterziehen der Liste taten nichts, \u{00FC}ber der Umsatzliste stand nur \u{201E}Die Bank wartet noch auf deine Freigabe\u{201C}. Jetzt gibt es **\u{201E}Freigabe neu ansto\u{00DF}en\u{201C}** \u{2014} \u{00FC}ber der Umsatzliste und im Men\u{00FC} der Men\u{00FC}leiste, dort auch bei geschlossener Liste. Ein Klick beendet das Warten und \u{00F6}ffnet eine neue Freigabe; deine Bankverbindung bleibt bestehen, es kostet keinen QR-Scan. Wer das Fenster schlie\u{00DF}t und in der Banking-App best\u{00E4}tigt, bekommt seine Daten wie bisher von selbst.",
                "If you accidentally closed your bank's approval window, your account was unreachable until you quit the app: \u{201C}Refresh\u{201D}, the \u{21BB} and pull-to-refresh did nothing, and the transaction list only said the bank was still waiting for your approval. Now there is **\u{201C}Restart approval\u{201D}** \u{2014} above the transaction list and in the menu bar menu, the latter even when the list is closed. One click ends the wait and opens a fresh approval; your bank connection stays, and it costs no QR scan. Close the window and confirm in your banking app instead, and your data still arrives on its own."
            )
        ),
        WhatsNewItem(
            icon: "wrench.and.screwdriver",
            tint: .sbGreenStrong,
            title: L10n.t("\u{201E}Failed to resume installing update\u{201C} r\u{00E4}umt sich selbst weg",
                          "\u{201C}Failed to resume installing update\u{201D} now clears itself"),
            description: L10n.t(
                "Bleibt von einer fr\u{00FC}heren Aktualisierung ein Fortschritts-Agent zur\u{00FC}ck, meldet er \u{201E}es l\u{00E4}uft bereits eine Installation\u{201C}, kann aber keine Daten dazu liefern \u{2014} und jeder weitere Versuch endet an derselben Stelle. *Gemeldet von einem Nutzer mit 2.0.7; an Signatur und Appcast lag es nachweislich nicht.* Die App erkennt diesen einen Abbruch jetzt selbst, r\u{00E4}umt den Rest weg und pr\u{00FC}ft einmal neu. Andere Abbr\u{00FC}che bleiben unangetastet \u{2014} eine abgelehnte Signatur heilt kein Aufr\u{00E4}umen.",
                "If a progress agent from an earlier update stays behind, it reports \u{201C}an installation is already running\u{201D} but can no longer supply any data for it \u{2014} and every further attempt ends in the same place. *Reported by a user on 2.0.7; it demonstrably was not the signature or the appcast.* The app now recognises this one failure, clears the leftovers and checks once more. Other failures are left alone \u{2014} no amount of cleanup fixes a rejected signature."
            )
        ),
        WhatsNewItem(
            icon: "tag",
            tint: .sbBlueStrong,
            title: L10n.t("Eigene Kategorien",
                          "Your own categories"),
            description: L10n.t(
                "Die 14 Kategorien waren fest \u{2014} nicht umbenennbar, nichts hinzuzuf\u{00FC}gen. *Gemeldet von einem Tester, der von MoneyMoney kommt und dort einen eigenen Kategoriebaum pflegt.* Unter Einstellungen \u{2192} Finanzen \u{2192} **Kategorien** legst Du jetzt eigene an, mit Namen und Symbol, und benennst die eingebauten um. Sie stehen \u{00FC}berall, wo die eingebauten stehen: im Auswahlmen\u{00FC} einer Buchung, in den Regeln, in der Suche, im Monatsbericht, bei `sb` \u{2014} und die KI-Zuordnung kennt sie auch. Bestehende Zuordnungen bleiben erhalten, Umbenennen eingeschlossen.",
                "The 14 categories were fixed \u{2014} no renaming, nothing to add. *Reported by a tester coming from MoneyMoney, where he keeps his own category tree.* Settings \u{2192} Finance \u{2192} **Categories** now lets you add your own, with a name and a symbol, and rename the built-in ones. They appear everywhere the built-in ones do: in a transaction's menu, in your rules, in search, in the monthly report, in `sb` \u{2014} and the AI assignment knows them too. Existing assignments are preserved, renaming included."
            )
        ),
        WhatsNewItem(
            icon: "capsule.fill",
            tint: .sbBlueStrong,
            title: L10n.t("Die Kategorie steht jetzt in der Zeile \u{2014} farbig",
                          "Your category now sits in the row \u{2014} in colour"),
            description: L10n.t(
                "Jede Buchung wird kategorisiert, nur bekam das kaum jemand zu sehen: Die Anzeige war ab Werk **aus**, und eingeschaltet stand sie als graues Etikett unter dem H\u{00E4}ndlernamen. Jetzt ist sie an, und im breiten Fenster steht die Kategorie farbig get\u{00F6}nt direkt neben dem H\u{00E4}ndler \u{2014} zu erkennen, ohne sie zu lesen. Gek\u{00FC}rzt wird der Verwendungszweck, nie die Kapsel; im schmalen Flyout bleibt sie unter dem Namen. Die Palette kennt **kein Gr\u{00FC}n, kein Orange und kein Rot**: Die drei geh\u{00F6}ren deinem Saldo und den Betr\u{00E4}gen, und eine Kapsel in Saldo-Farbe l\u{00E4}se sich als Warnung. Unter Einstellungen \u{2192} Finanzen \u{2192} Kategorien w\u{00E4}hlst du die Farbe je Kategorie selbst, auch f\u{00FC}r die eingebauten. Das Tag-Symbol \u{00FC}ber der Liste schaltet das Ganze wie bisher ab.",
                "Every transaction gets a category, but hardly anyone ever saw one: the display was **off** by default, and switched on it sat below the merchant as a grey label. It is on now, and in the wide window your category sits right next to the merchant in colour \u{2014} recognisable without reading it. The remittance text is what gets truncated, never the capsule; in the narrow flyout it stays below the name. The palette has **no green, no orange and no red**: those three belong to your balance and your amounts, and a capsule in a balance colour would read as a warning. Settings \u{2192} Finance \u{2192} Categories lets you pick the colour per category, the built-in ones included. The tag icon above the list still switches it all off."
            )
        ),
        WhatsNewItem(
            icon: "sidebar.squares.right",
            tint: .sbGreenStrong,
            title: L10n.t("Die Details einer Buchung blieben nicht offen",
                          "A transaction's details would not stay open"),
            description: L10n.t(
                "Ein Klick auf eine Buchung \u{00F6}ffnete die Details \u{2014} und schloss sie im selben Moment wieder. *Gemeldet am 11.11.2026.* Dahinter steckte mehr als ein zuckendes Fenster: Schon das \u{00D6}ffnen schrieb die angezeigte Kategorie als **von Hand gesetzt** in die Datenbank, und die neu aufgebaute Liste riss das Fenster mit. Eine so gesetzte Kategorie ist von einer wirklich gew\u{00E4}hlten nicht mehr zu unterscheiden und folgt keiner Regel mehr. Jetzt wird nur geschrieben, was Du selbst \u{00E4}nderst. Und weil im selben Atemzug gefragt wurde, wo man eigene Kategorien anlegt: Neben \u{201E}Kategorie\u{201C} steht jetzt ein **+**, das genau dorthin f\u{00FC}hrt.",
                "Clicking a transaction opened its details \u{2014} and closed them again in the same instant. *Reported on 11 November 2026.* There was more to it than a flickering window: merely opening it wrote the displayed category into the database as **manually set**, and rebuilding the list tore the window down with it. A category set that way is indistinguishable from one you really chose and no longer follows any rule. Now only what you change yourself is written. And since the same report asked where custom categories are created: next to \u{201C}Category\u{201D} there is now a **+** that leads exactly there."
            )
        ),
        WhatsNewItem(
            icon: "lock.square",
            tint: .sbGreenStrong,
            title: L10n.t("Das TAN-Verfahren l\u{00E4}sst sich festlegen",
                          "You can now pin your TAN method"),
            description: L10n.t(
                "Fragt die Bank, welches Verfahren sie nehmen soll, hat die App diese R\u{00FC}ckfrage immer selbst beantwortet \u{2014} App-Freigabe zuerst, sonst der erste Eintrag. Wer pushTAN registriert hat, aber am Schreibtisch sitzt und chipTAN benutzen will, bekam trotzdem pushTAN, jedes Mal. Unter Einstellungen \u{2192} Konten steht jetzt **TAN-Verfahren**, mit dem, was Deine Bank zuletzt angeboten hat. \u{201E}Automatisch\u{201C} bleibt die Vorgabe \u{2014} wer nichts einstellt, merkt keinen Unterschied. Die Verfahren erscheinen erst, nachdem die Bank einmal danach gefragt hat; vorher kennt die App sie nicht.",
                "When your bank asks which method to use, the app always answered for you \u{2014} app approval first, otherwise the first entry on the list. Anyone with pushTAN registered who was sitting at their desk and wanted chipTAN got pushTAN anyway, every time. Settings \u{2192} Accounts now has **TAN method**, listing what your bank last offered. \u{201C}Automatic\u{201D} stays the default \u{2014} change nothing and nothing changes. The methods only appear once your bank has asked for one; before that the app does not know them."
            )
        )
    ]

    /// 2.0.9. Zehn Punkte, weil 2.0.8 hier mit eingefaltet ist und die Runde lang wurde.
    /// Die Auswahlregel bleibt dieselbe: nur, was jemand auch merkt — eine Überweisung, die
    /// zwei Tage brauchte, ein Kontostand hinter dem der Banking-App, eine Freigabe, zu der
    /// kein Weg mehr führte, eine Buchung, die zweimal dasteht, eine Summe, die um die Hälfte
    /// zu hoch war. Der Rest der Runde ist Innenarbeit und steht im Änderungsprotokoll.
    private static let v209: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "hand.raised",
            tint: .sbBlueStrong,
            title: L10n.t("Keine Bankseite mehr ohne dein Zutun",
                          "No bank page opens without you"),
            description: L10n.t(
                "Ist die Zustimmung einer Bank abgelaufen, sprang bisher ungefragt deren Anmeldeseite auf — beim turnusmäßigen Abruf, beim Programmstart, beim Entsperren. Das ist vorbei: Eine Bankseite geht nur auf, wenn du unmittelbar davor etwas angeklickt hast. Im Hintergrund bleibt der Abruf stehen, du bekommst eine Mitteilung mit dem Namen der Bank, und Saldo und Umsätze bleiben sichtbar. \u{201E}Aktualisieren\u{201C} nimmt den Faden wieder auf.",
                "When a bank's consent had expired, its login page used to open unasked — on the scheduled fetch, at startup, on unlock. No longer: a bank page opens only if you clicked something right before. In the background the fetch simply stops, you get a notification naming the bank, and your balance and transactions stay visible. \u{201C}Refresh\u{201D} picks it up again."
            )
        ),
        WhatsNewItem(
            icon: "bolt.horizontal",
            tint: .sbBlueStrong,
            title: L10n.t("\u{00DC}berweisungen gehen wieder in Echtzeit",
                          "Transfers go out in real time again"),
            description: L10n.t(
                "Jede \u{00DC}berweisung wurde als gew\u{00F6}hnliche SEPA-\u{00DC}berweisung verschickt \u{2014} ein bis zwei Tage \u{2014}, auch bei Banken, die Echtzeit beherrschen; im Aufruf stand das langsame Produkt fest verdrahtet. Jetzt wird Echtzeit versucht und still auf die gew\u{00F6}hnliche \u{00DC}berweisung zur\u{00FC}ckgefallen, wo die Bank sie nicht kann. Wer Echtzeit ausdr\u{00FC}cklich anfordert, bekommt wie bisher eine klare Absage statt einer langsamen Zahlung.",
                "Every transfer went out as an ordinary SEPA transfer \u{2014} one to two days \u{2014} even at banks that do real time; the slow product was hard-wired into the call. Real time is now attempted, falling back silently to the ordinary transfer where the bank cannot do it. Ask for real time explicitly and you still get a clear refusal rather than a slow payment."
            )
        ),
        WhatsNewItem(
            icon: "clock.badge.exclamationmark",
            tint: .sbBlueStrong,
            title: L10n.t("Der Kontostand hing hinter der Banking-App zur\u{00FC}ck",
                          "The balance lagged behind your banking app"),
            description: L10n.t(
                "Liefert eine Bank mehrere Salden, nahm simplebanking den ersten gebuchten \u{2014} bei der Postbank den Tagesabschluss von gestern, w\u{00E4}hrend daneben ein aktuellerer Stand lag. Jetzt entscheidet das Datum: der j\u{00FC}ngste Saldo, der nicht in der Zukunft liegt und keine Dispo-Linie enth\u{00E4}lt. Die Ums\u{00E4}tze waren immer richtig, nur die Zahl dar\u{00FC}ber nicht.",
                "When a bank returns several balances, simplebanking took the first booked one \u{2014} at Postbank yesterday's closing figure, while a more recent one sat right beside it. The date now decides: the newest balance that is not in the future and carries no overdraft line. The transactions were always right; only the figure above them was not."
            )
        ),
        WhatsNewItem(
            icon: "arrow.clockwise.circle",
            tint: .sbGreenStrong,
            title: L10n.t("Freigabe aus der Umsatzliste holen",
                          "Getting an approval from the transaction list"),
            description: L10n.t(
                "Stand \u{201E}Freigabe erforderlich\u{201C} \u{00FC}ber der Umsatzliste, f\u{00FC}hrte von dort kein Weg mehr zur Bank: Das \u{21BB} und das Herunterziehen galten als Hintergrundabruf, und der \u{00F6}ffnet \u{2014} siehe oben \u{2014} bewusst keine Bankseite. Beides z\u{00E4}hlt jetzt als dein Zutun, und die Meldung sagt, dass ein Klick auf Aktualisieren gen\u{00FC}gt.",
                "With \u{201C}Approval required\u{201D} above the transaction list, there was no way from there back to the bank: the \u{21BB} and pull-to-refresh counted as a background fetch, and those \u{2014} see above \u{2014} deliberately open no bank page. Both now count as your own action, and the message says a click on refresh is all it takes."
            )
        ),
        WhatsNewItem(
            icon: "doc.on.doc",
            tint: .sbBlueStrong,
            title: L10n.t("Zwei gleiche Buchungen bleiben zwei",
                          "Two identical bookings stay two"),
            description: L10n.t(
                "Steht dieselbe Buchung zweimal im Abruf — zweimal derselbe Automat, zwei gleiche Tickets —, teilten sich beide Zeilen bisher Notiz, Beleg und Markierung, und was an der zweiten hing, war nicht erreichbar. Jede Zeile hat jetzt ihre eigene Kennung. Betrifft auch den Export und die gemerkten Sparraten; Gemerktes bleibt gemerkt.",
                "When the same booking appears twice in one fetch — the same vending machine, two identical tickets — both rows used to share their note, receipt and flag, and whatever belonged to the second was unreachable. Each row now carries its own identity. This also covers the export and saved savings entries; what you marked stays marked."
            )
        ),
        WhatsNewItem(
            icon: "photo.badge.checkmark",
            tint: .sbGreenStrong,
            title: L10n.t("Ein eigenes Händler-Logo bleibt stehen",
                          "Your own merchant logo stays put"),
            description: L10n.t(
                "Ein Logo, das du selbst gesetzt hast, konnte kurz darauf wieder durch eines aus dem Netz ersetzt werden — manchmal gleich beim Start, ohne dass du etwas getan hattest. Eigene Logos haben jetzt Vorrang. Nebenbei: Die Hamburger Sparkasse trug das Zeichen von comdirect.",
                "A logo you set yourself could be replaced by one from the internet moments later — sometimes right at startup, without you doing anything. Your own logos now take precedence. Also: Hamburger Sparkasse was showing comdirect's mark."
            )
        ),
        WhatsNewItem(
            icon: "calendar.badge.minus",
            tint: .sbGreenStrong,
            title: L10n.t("\u{201E}Noch offen\u{201C} war zu hoch",
                          "\u{201C}Still to pay\u{201D} was too high"),
            description: L10n.t(
                "Drei Dinge rechneten die Summe nach oben. Ein Einkauf \u{00FC}ber PayPal, Klarna oder Mollie wurde als Abo beim Zahlungsdienstleister gez\u{00E4}hlt, wenn im Verwendungszweck kein Shop stand \u{2014} zwei fremde Eink\u{00E4}ufe ergaben so einen \u{201E}monatlichen\u{201C} Posten \u{00FC}ber mehrere hundert Euro. Zwei Buchungen galten als regelm\u{00E4}\u{00DF}ig, auch wenn die Betr\u{00E4}ge um das Doppelte auseinanderlagen; jetzt m\u{00FC}ssen sie nahezu gleich sein. Und ein Abo, dessen Abbuchung schon vor dem laufenden Gehaltszyklus ausblieb, lief ewig weiter mit.",
                "Three things pushed the figure up. A purchase made through PayPal, Klarna or Mollie was counted as a subscription to the payment processor whenever the remittance info named no shop \u{2014} two unrelated purchases could become a \u{201C}monthly\u{201D} item of several hundred euros. Two bookings counted as regular even when the amounts differed by a factor of two; they now have to be near-identical. And a subscription whose charge had already failed to appear before the current salary cycle kept counting forever."
            )
        ),
        WhatsNewItem(
            icon: "textformat.123",
            tint: .sbOrangeStrong,
            title: L10n.t("Zwei Anzeigefehler",
                          "Two display bugs"),
            description: L10n.t(
                "In der Men\u{00FC}leiste sa\u{00DF} der Tausenderpunkt eine Stelle zu weit links \u{2014} aus 12.345 wurde 1.2345, bei siebenstelligen Betr\u{00E4}gen stand sogar ein Punkt vorneweg. Und in den Einstellungen lief Text links aus dem Fenster, sobald eine einzige Zeile zu breit war; sie riss die ganze Spalte mit.",
                "In the menu bar the thousands separator sat one digit too far left \u{2014} 12,345 came out as 1,2345, and seven-digit amounts even started with a separator. And in settings, text ran off the left edge of the window as soon as a single row was too wide; it dragged the whole column along."
            )
        ),
        WhatsNewItem(
            icon: "terminal",
            tint: .sbBlueStrong,
            title: L10n.t("Fixkosten und Abos f\u{00FC}r Assistenten und Terminal",
                          "Fixed costs and subscriptions for assistants and the terminal"),
            description: L10n.t(
                "Claude und andere Assistenten k\u{00F6}nnen jetzt Fixkosten und Abos abfragen, auf der Kommandozeile gibt es daf\u{00FC}r \u{201E}sb fixed\u{201C} und \u{201E}sb subs\u{201C}. Gerechnet wird weiterhin nur in der App \u{2014} beide lesen deren Ergebnis, damit nicht zwei Auswertungen auseinanderlaufen. Und \u{201E}\u{00DC}berweisung vorbereiten\u{201C} ist zur\u{00FC}ck: Es legt eine Zahlung zum Pr\u{00FC}fen an, ohne sie zu senden, und steht mit aktiver simplesend-Lizenz bereit.",
                "Claude and other assistants can now ask for your fixed costs and subscriptions; on the command line that is \u{201C}sb fixed\u{201D} and \u{201C}sb subs\u{201D}. The figures are still computed only in the app \u{2014} both read its result, so two analyses cannot drift apart. And \u{201C}prepare transfer\u{201D} is back: it drafts a payment for you to check without sending it, and is available with an active simplesend licence."
            )
        ),
        WhatsNewItem(
            icon: "externaldrive.badge.exclamationmark",
            tint: .sbOrangeStrong,
            title: L10n.t("Die Sicherung sagt, was sie ausgelassen hat",
                          "The backup says what it left out"),
            description: L10n.t(
                "Sehr große oder unlesbare Belege blieben draußen, gemeldet wurde trotzdem nur \u{201E}Sicherung abgelegt\u{201C} — nach einem Rechnerwechsel fehlten sie dann. Die Meldung nennt jetzt, was nicht mitkam. Lässt sich eine Bankverbindung nicht lesen, bricht die Sicherung ab, statt das Konto stillschweigend zu verlieren. Und das Einspielen prüft vorher, ob der Platz reicht.",
                "Very large or unreadable receipts were left out while the message still said only “Backup saved” — after moving to a new Mac they were missing. The message now names what did not travel. If an account's credentials cannot be read, the backup stops instead of silently losing it. And restoring checks beforehand whether there is enough space."
            )
        ),
    ]

    /// 2.0.7. Ein Fehler, ein Eintrag. Er traf nur, wer ING, bunq, N26 oder Revolut als
    /// allererstes Konto verband — also niemanden, der dieses Fenster liest. Es steht
    /// trotzdem hier, weil jemand es weitergeben können soll.
    private static let v207: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "lock.open.trianglebadge.exclamationmark",
            tint: .sbBlueStrong,
            title: L10n.t("Erste Bank mit Freigabe im Browser ließ sich nicht einrichten",
                          "Connecting a browser-approval bank as your first account failed"),
            description: L10n.t(
                "Wer ING, bunq, N26 oder Revolut als erstes Konto verbinden wollte, sah den Assistenten bei \u{201E}Sicherheitsfreigabe\u{201C} stehenbleiben — kein Browser-Fenster, keine Meldung. Ein zweites Konto hinzuzufügen war nie betroffen. Behoben; der Fehler kam mit 2.0.5 herein.",
                "Anyone connecting ING, bunq, N26 or Revolut as their first account saw the wizard stall at the security approval step — no browser window, no message. Adding a second account was never affected. Fixed; the fault arrived with 2.0.5."
            )
        ),
    ]

    /// 2.0.6. Zwei behobene Fehler, beide in der Ersteinrichtung — also in einem Teil der
    /// App, den die meisten Leser dieses Fensters nie wieder sehen. Trotzdem stehen sie
    /// hier: Wer die Einrichtung abgebrochen hat, weil sie nicht weiterging, soll lesen
    /// können, dass es nicht an ihm lag.
    private static let v206: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "checkmark.circle.badge.questionmark",
            tint: .sbBlueStrong,
            title: L10n.t("Die Ersteinrichtung geht wieder zu Ende",
                          "Setting up your first account works again"),
            description: L10n.t(
                "Der letzte Schritt des Assistenten — die Theme-Auswahl — hatte keinen Knopf zum Bestätigen. Weiter kam man weder mit der Maus noch mit der Tastatur, und weil erst dieser Schritt das Konto wegschreibt, war die ganze Einrichtung danach verloren. Nur die allererste Bankverbindung war betroffen; ein zweites Konto hinzuzufügen überspringt diese Seite. Jetzt stehen dort \u{201E}Zurück\u{201C} und \u{201E}Fertig\u{201C}, und die Eingabetaste bestätigt.",
                "The wizard's last step — choosing a theme — had no button to confirm. Neither mouse nor keyboard got you any further, and since that step is what actually saves the account, the whole setup was lost. Only the very first bank connection was affected; adding a second account skips that page. It now has \u{201C}Back\u{201D} and \u{201C}Done\u{201D}, and Return confirms."
            )
        ),
        WhatsNewItem(
            icon: "circle.lefthalf.filled",
            tint: .sbOrangeStrong,
            title: L10n.t("Dunkelmodus: unlesbare Zeile am Ende der Einrichtung",
                          "Dark mode: an unreadable line at the end of setup"),
            description: L10n.t(
                "Die Zeile, die die verbundene Bank nennt, wurde im Dunkelmodus schwarz auf dunklem Grund gezeichnet. Ursache war eine Systemfarbe, die beim Aufbau des Fensters auf das helle Erscheinungsbild festgelegt wurde und danach nicht mehr mitwechselte.",
                "The line naming the connected bank was drawn black on a dark background in dark mode. A system colour had been pinned to the light appearance while the window was built and stopped adapting after that."
            )
        ),
    ]

    /// 2.0.3. Auswahlregel unverändert: nur, was jemand auch merkt. Der Umstieg auf die
    /// neue Banking-Bibliothek steht deshalb nicht drin — er ist die größte Änderung
    /// dieser Runde und für den Nutzer vollständig unsichtbar.
    private static let v205: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "macwindow.badge.plus",
            tint: .sbBlueStrong,
            title: L10n.t("Bank-Freigabe im eigenen Fenster",
                          "Bank approval in its own window"),
            description: L10n.t(
                "Die Freigabe-Seite der Bank öffnet nicht mehr in Safari, sondern in einem eigenen Fenster ohne Cookies und Verlauf — jeder Durchlauf startet leer. Damit ist der ING-Fehler \u{201E}Request Header Or Cookie Too Large\u{201C} vom Tisch, an dem Umsätze und Neueinrichtungen scheiterten. Wer Safari zurück will: Einstellungen → Allgemein.",
                "The bank's approval page no longer opens in Safari but in its own window without cookies or history — every run starts clean. That settles the ING error \u{201C}Request Header Or Cookie Too Large\u{201D} that blocked transactions and new setups. Prefer Safari? Settings → General."
            )
        ),
        WhatsNewItem(
            icon: "arrow.clockwise",
            tint: .sbGreenStrong,
            title: L10n.t("Aktualisieren wirkt wieder sofort",
                          "Refresh works again, right away"),
            description: L10n.t(
                "Wartete ein Konto auf die Freigabe im Browser, standen bis zu drei Minuten lang alle Konten still — Herunterziehen, das ↻ und der Klick aufs Symbol taten nichts, und nur ein Neustart half. Das Warten bremst jetzt nur noch das Konto, um das es geht.",
                "While one account waited for browser approval, every account stalled for up to three minutes — pull-to-refresh, the ↻ button and clicking the icon did nothing, and only a restart helped. That wait now only holds up the account it belongs to."
            )
        ),
        WhatsNewItem(
            icon: "photo.on.rectangle.angled",
            tint: .sbOrangeStrong,
            title: L10n.t("Schärfere Händler-Logos",
                          "Sharper merchant logos"),
            description: L10n.t(
                "Alte Logos waren winzige Favicons, und die neuen, großen wurden erst beim Zeichnen verkleinert — Kanten fransten aus, „DHL\u{201C} war nicht mehr zu lesen. Jetzt rechnet die App jedes Logo in genau der Pixelzahl, in der es erscheint, und breite Marken wie dm werden nicht mehr angeschnitten.",
                "Old logos were tiny favicons, and the new large ones were only scaled down while drawing — edges frayed and \u{201C}DHL\u{201D} became unreadable. Every logo is now rendered at exactly the pixel size it appears at, and wide marks like dm are no longer cropped."
            )
        ),
    ]

    private static let v203: [WhatsNewItem] = [
        WhatsNewItem(
            icon: "antenna.radiowaves.left.and.right",
            tint: .sbRedStrong,
            title: L10n.t("Verbindung zu den Banken wiederhergestellt",
                          "Bank connections restored"),
            description: L10n.t(
                "Seit dem 21. September meldeten alle Konten \u{201E}offline\u{201C}: Der Schlüssel, mit dem simplebanking sich beim Bankdienst ausweist, war abgelaufen. Diese Version trägt den neuen. Ohne das Update bleibt jede Bank stumm — deshalb steht dieser Punkt ganz oben.",
                "Since September 21 every account reported \u{201C}offline\u{201D}: the key simplebanking uses to identify itself to the banking service had expired. This version carries the new one. Without the update every bank stays silent — which is why this comes first."
            )
        ),
        WhatsNewItem(
            icon: "cursorarrow.click.2",
            tint: .sbBlueStrong,
            title: L10n.t("Doppelklick auf das Menüleisten-Symbol geht wieder",
                          "Double-clicking the menu bar icon works again"),
            description: L10n.t(
                "Auf dem neuen macOS öffnete ein Doppelklick nur das Flyout und schloss es gleich wieder, statt die Umsatzliste zu zeigen. Das System zählt zwei schnelle Klicks dort nicht mehr als einen Doppelklick — simplebanking zählt jetzt selbst.",
                "On the new macOS a double-click only opened the flyout and closed it again instead of showing the transaction list. The system no longer counts two quick clicks there as a double-click — simplebanking now counts for itself."
            )
        ),
        WhatsNewItem(
            icon: "questionmark.circle",
            tint: .sbOrangeStrong,
            title: L10n.t("Überweisung: \u{201E}fehlgeschlagen\u{201C} nur, wenn es sicher ist",
                          "Transfers: \u{201C}failed\u{201D} only when it is certain"),
            description: L10n.t(
                "Brach die Verbindung nach dem Senden ab, meldete die App \u{201E}Senden fehlgeschlagen\u{201C} — obwohl die Bank den Auftrag längst haben konnte. Wer daraufhin erneut sendete, zahlte doppelt. Jetzt heißt es in dem Fall \u{201E}Status unklar\u{201C}, und die Schnellüberweisung bietet keinen Weg zurück ins ausgefüllte Formular.",
                "If the connection dropped after sending, the app reported \u{201C}send failed\u{201D} — even though the bank might already have the order. Anyone who sent again paid twice. It now says \u{201C}status unclear\u{201D} in that case, and the quick transfer offers no way back into the filled-in form."
            )
        ),
        WhatsNewItem(
            icon: "arrow.left.arrow.right",
            tint: .sbGreenStrong,
            title: L10n.t("Umsätze landen im richtigen Konto",
                          "Transactions land in the right account"),
            description: L10n.t(
                "Wer während eines PayPal-Abrufs die Bank wechselte, fand die Umsätze unter der falschen — und beim nächsten Abruf doppelt unter der richtigen. Außerdem bleiben zwei gleiche Buchungen am selben Tag jetzt beide erhalten, und erledigte Vormerkungen verschwinden auch dann, wenn der Abruf sonst nichts Neues bringt.",
                "Switching banks during a PayPal refresh put the transactions under the wrong one — and duplicated them under the right one on the next refresh. Two identical bookings on the same day are now both kept, and settled pending entries disappear even when a refresh brings nothing else new."
            )
        ),
        WhatsNewItem(
            icon: "sparkles",
            tint: .sbBlueStrong,
            title: L10n.t("KI-Kategorisierung läuft wieder",
                          "AI categorization works again"),
            description: L10n.t(
                "Sie sprach ein Claude-Modell an, das Anthropic im Februar abgeschaltet hatte, und verschluckte den Fehler — es sah aus, als würde sie nie starten. Jetzt Claude Haiku 4.5, und jeder Lauf steht im Protokoll.",
                "It called a Claude model Anthropic retired in February and swallowed the error — it looked as if it never started. Now Claude Haiku 4.5, and every run is logged."
            )
        ),
        WhatsNewItem(
            icon: "slider.horizontal.3",
            tint: .sbOrangeStrong,
            title: L10n.t("Menü und Einstellungen aufgeräumt",
                          "Menu and settings tidied up"),
            description: L10n.t(
                "\u{201E}Nach Updates suchen\u{201C} und \u{201E}Beenden\u{201C} stehen jetzt auch in Einstellungen → Allgemein. Diagnose versenden und Logs öffnen liegen im Bank-Diagnose-Fenster, wo sie hingehören. In den Buchungsdetails stehen IBAN und BIC einzeilig mit Kopierknopf, und eine Vorlage in der Schnellüberweisung öffnet nicht mehr die Vorschlagsliste.",
                "\u{201C}Check for updates\u{201D} and \u{201C}Quit\u{201D} now also live in Settings → General. Sending diagnostics and opening logs moved into the Bank Diagnostics window where they belong. Transaction details show IBAN and BIC on one line with a copy button, and picking a template in the quick transfer no longer pops the suggestion list."
            )
        ),
        WhatsNewItem(
            icon: "photo.on.rectangle",
            tint: .sbGreenStrong,
            title: L10n.t("Händler-Logos: mitgelieferte zuerst, Rest von logo.dev",
                          "Merchant logos: bundled first, the rest from logo.dev"),
            description: L10n.t(
                "Die gebündelten Logos werden jetzt vor jedem Netzaufruf genutzt, vier Händler sind neu dabei. Alles andere kommt von logo.dev statt vom Favicon — höchstens drei Abrufe am Tag, 30 Tage gemerkt. Neuer Schalter unter Zugänge, falls du gar keine Händlerdomain ins Netz schicken willst.",
                "Bundled logos are now used before any network request, with four more merchants included. Everything else comes from logo.dev instead of the favicon — at most three requests a day, remembered for 30 days. A new switch under Access if you don't want any merchant domain sent out at all."
            )
        ),
        WhatsNewItem(
            icon: "plus.circle",
            tint: .sbBlueStrong,
            title: L10n.t("Außerdem neu", "Also new"),
            description: L10n.t(
                "Kurzbefehle und Spotlight-Aktionen für Kontostand und Umsätze. Sicherung und Wiederherstellung unter Einstellungen → Konten. Rechnungen mit SEPA-QR-Code aufs Fenster ziehen. Rückholfrist bei Lastschriften. Und simplebanking in Raycast.",
                "Shortcuts and Spotlight actions for balance and transactions. Backup and restore under Settings → Accounts. Drop invoices with a SEPA QR code on the window. Claw-back period for direct debits. And simplebanking in Raycast."
            )
        ),
    ]

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
