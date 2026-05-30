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
        let drafts = TransferDraftStore.loadAll()
        guard let newest = drafts.first else { return }

        // User-Toggle „MCP-Drafts annehmen" (Default aus — opt-in). Wenn aus:
        // alle Drafts verwerfen und kein Sheet öffnen — verhindert dass ein im
        // Hintergrund laufender MCP-Client (z.B. Claude.app) ungewollt
        // TransferSheets öffnet.
        let mcpDraftsEnabled = (UserDefaults.standard.object(forKey: "mcpDraftsEnabled") as? Bool) ?? false
        guard mcpDraftsEnabled else {
            for d in drafts { TransferDraftStore.consume(id: d.id) }
            return
        }

        // One-shot: löschen sofort, bevor Notification gepostet wird.
        // Sonst könnte ein nachfolgender vnode-Event denselben Draft nochmal
        // einliefern, während BalanceBar das Sheet schon aufmacht.
        TransferDraftStore.consume(id: newest.id)

        // Älteren parallel liegenden Drafts ebenfalls weg — der Nutzer sieht nur
        // den jüngsten. Sind eh nur Edge-Cases (mehrere Aufrufe in 1s).
        for d in drafts.dropFirst() {
            TransferDraftStore.consume(id: d.id)
        }

        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: Self.openSheetNotification,
            object: nil,
            userInfo: [Self.draftUserInfoKey: newest]
        )
    }
}
