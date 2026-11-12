import Foundation
import AppKit

// MARK: - TransferDraftWatcher
//
// Watcht das transfer-drafts/-Verzeichnis via DispatchSource auf neue Dateien.
// Externe Schreiber (z.B. simplebanking-mcp prepare_transfer) legen JSON-Drafts
// ab; der Watcher liest sie + konsumiert sie + postet
// `simplebanking.openTransferSheet` mit dem Draft im userInfo. BalanceBar
// reagiert wie beim manuellen „Geld senden…"-Menüpunkt und öffnet
// TransferSheet mit Prefill.
//
// Lifecycle: Singleton in BalanceBar.applicationDidFinishLaunching gestartet.
// Auf macOS-Apps mit lebenslangem Singleton brauchen wir kein explizites Stop.

@MainActor
final class TransferDraftWatcher {

    static let shared = TransferDraftWatcher()

    /// Notification mit userInfo["draft"] = TransferDraft. BalanceBar listet schon
    /// auf den Notification-Namen für den UI-Menüpunkt — wir wieder­verwenden ihn.
    static let openSheetNotification = Notification.Name("simplebanking.openTransferSheet")
    /// userInfo-Key für den Draft.
    static let draftUserInfoKey = "draft"

    private var dirHandle: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    // MARK: - Das Reopen, das zur Übernahme gehört
    //
    // Gemeldet am 07.11.2026 von einem Nutzer, der sich eine eigene
    // Raycast-Erweiterung gebaut hat: Sie liest eine im Finder markierte Rechnung aus,
    // legt den Entwurf hier ab und ruft danach `open -g -a simplebanking`. Neben
    // simplesend ging aber auch die Umsatzliste auf, selbst wenn sie zuvor geschlossen
    // war.
    //
    // Nicht `NSApp.activate` weiter unten — das holt die App nach vorn und öffnet kein
    // geschlossenes Fenster. `open -a` schickt an eine **laufende** App ein
    // Reopen-Ereignis, und `applicationShouldHandleReopen` öffnet darauf die
    // Umsatzliste. Das ist die Zusage „Klick aufs Dock-Symbol öffnet die Umsatzliste" —
    // nur klickt im Menüleisten-Betrieb niemand auf ein Dock-Symbol, und das Ereignis
    // kommt trotzdem.
    //
    // Der Nutzer kann sein `open` weglassen, solange die App läuft; muss sie erst
    // starten, kommt das Reopen zwangsläufig. Darum entscheidet die Regel hier.

    /// Wann zuletzt ein Entwurf übernommen wurde.
    private(set) static var letzteUebernahme: Date?

    /// Wie lange nach einer Übernahme ein Reopen noch dazugehört.
    ///
    /// Großzügig gewählt: Zu kurz heißt, der gemeldete Fehler kommt sporadisch zurück;
    /// zu lang heißt, ein Dock-Klick in denselben Sekunden tut nichts — und wer gerade
    /// eine Überweisung vor sich hat, klickt nicht daneben.
    static let reopenFenster: TimeInterval = 5

    /// Gehört dieses Reopen zu einer Entwurfsübernahme?
    ///
    /// `entwurfLiegtAn` fängt die umgekehrte Reihenfolge: Die Erweiterung schreibt die
    /// Datei und ruft dann `open`, aber ob der Wächter oder das Reopen zuerst dran ist,
    /// ist nicht zugesichert. Ohne diese Hälfte wäre der Fehler nur seltener, nicht weg.
    static func gehoertZurEntwurfsuebernahme(uebernahme: Date?,
                                             entwurfLiegtAn: Bool,
                                             jetzt: Date = Date()) -> Bool {
        if entwurfLiegtAn { return true }
        guard let uebernahme else { return false }
        return jetzt.timeIntervalSince(uebernahme) < reopenFenster
    }

    /// Dieselbe Regel, mit dem Zustand von jetzt.
    static func reopenGehoertZuEntwurf(jetzt: Date = Date()) -> Bool {
        gehoertZurEntwurfsuebernahme(
            uebernahme: letzteUebernahme,
            entwurfLiegtAn: !TransferDraftStore.loadAllWithURLs(now: jetzt).isEmpty,
            jetzt: jetzt
        )
    }

    private init() {}

    /// Idempotent — bei zweitem Aufruf passiert nichts.
    func start() {
        guard source == nil else { return }

        // Initial-Scan: holt bei App-Start drafts ab, die vor dem Watcher-Start
        // angelegt wurden (z.B. MCP-Tool wurde aufgerufen während die App nicht
        // lief). Verzögert via Task, damit BalanceBar das showTransferSheet()
        // erst ruft, wenn der Statusbar-Setup durch ist.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            processPendingDrafts()
        }

        // Open vnode handle auf dem Drafts-Dir. Falls noch nicht da, anlegen.
        guard let dir = try? TransferDraftStore.directoryURL() else { return }
        dirHandle = open(dir.path, O_EVTONLY)
        guard dirHandle >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirHandle,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.processPendingDrafts()
        }
        src.setCancelHandler { [weak self] in
            if let h = self?.dirHandle, h >= 0 { close(h) }
        }
        src.resume()
        source = src
    }

    private func processPendingDrafts() {
        let entries = TransferDraftStore.loadAllWithURLs()
        guard let newest = entries.first else { return }

        // User-Toggle „MCP-Drafts annehmen" (Default aus — opt-in). Wenn aus:
        // alle Drafts verwerfen und kein Sheet öffnen — verhindert dass ein im
        // Hintergrund laufender MCP-Client (z.B. Claude.app) ungewollt
        // TransferSheets öffnet.
        // Ohne aktive simplesend-Lizenz gibt es kein `prepare_transfer`. Liegt dann
        // trotzdem eine Datei da, kommt sie nicht von uns — verwerfen.
        guard LicenseManager.shared.isLicensedOrDemo else {
            for e in entries { TransferDraftStore.consume(url: e.url) }
            return
        }
        let mcpDraftsEnabled = (UserDefaults.standard.object(forKey: "mcpDraftsEnabled") as? Bool) ?? false
        guard mcpDraftsEnabled else {
            for e in entries { TransferDraftStore.consume(url: e.url) }
            return
        }

        // One-shot: löschen sofort, bevor Notification gepostet wird.
        // Sonst könnte ein nachfolgender vnode-Event denselben Draft nochmal
        // einliefern, während BalanceBar das Sheet schon aufmacht.
        TransferDraftStore.consume(url: newest.url)

        // Älteren parallel liegenden Drafts ebenfalls weg — der Nutzer sieht nur
        // den jüngsten. Sind eh nur Edge-Cases (mehrere Aufrufe in 1s).
        for e in entries.dropFirst() {
            TransferDraftStore.consume(url: e.url)
        }

        // Vor dem Aktivieren merken: Das Reopen aus dem `open -a` des Erzeugers kann
        // unmittelbar danach eintreffen.
        Self.letzteUebernahme = Date()

        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: Self.openSheetNotification,
            object: nil,
            userInfo: [Self.draftUserInfoKey: newest.draft]
        )
    }
}
