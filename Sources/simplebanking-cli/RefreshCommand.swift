import ArgumentParser
import Foundation

/// Triggert die laufende Menüleisten-App, einen Refresh über YAXI auszuführen.
/// Der CLI hat keine Routex-Dependency und kann nicht selbst gegen die Bank
/// auth'en (TAN-Flow → Terminal ungeeignet). Stattdessen: IPC via
/// `DistributedNotificationCenter` an die App, die den Abruf macht.
/// Wir pollen danach den Outcome-Marker und geben je Status einen anderen Text
/// aus — damit "✓ Aktualisiert" nur dann erscheint, wenn tatsächlich ein
/// Bankabruf durchgelaufen ist.
struct RefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Fordert die laufende simplebanking-App zum Refresh auf (Bank-Abruf)."
    )

    /// Bank-Refreshes (insbesondere Sparkasse mit Consent-Re-Auth) können
    /// >60 s dauern; Default deshalb konservativ auf 180 s.
    @Option(name: .shortAndLong, help: "Max. Wartezeit in Sekunden (Default: 180).")
    var timeout: Int = 180

    @Flag(name: .long, help: "Keine Fortschritts-Ausgabe, nur Exit-Code.")
    var quiet = false

    func run() throws {
        let isTTY = ANSIColor.isTTY()

        // Snapshot vor Trigger: Outcome-Timestamp (bevorzugt) bzw. Legacy-Marker.
        // Wir pollen später auf Änderung dieses Werts.
        let outcomeBefore = DataReader.lastRefreshOutcome()?.timestamp
        let legacyBefore = DataReader.lastRefreshTimestamp()

        if !quiet { print(ANSIColor.dim("Refresh angefordert…")) }

        let name = Notification.Name("tech.yaxi.simplebanking.cli.refreshRequested")
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true
        )

        let start = Date()
        let deadline = start.addingTimeInterval(TimeInterval(timeout))
        var appResponded = false  // first signal: Outcome-Marker hat sich geändert

        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let elapsed = Int(Date().timeIntervalSince(start))

            if let outcome = DataReader.lastRefreshOutcome(),
               outcome.timestamp != outcomeBefore {
                // App hat den Versuch abgeschlossen → ehrlicher Status-Output.
                if !quiet {
                    if isTTY { print("\r\u{001B}[2K", terminator: "") }
                    if !appResponded {
                        print(ANSIColor.dim("App hat geantwortet."))
                    }
                    renderOutcome(outcome, elapsed: elapsed)
                }
                switch outcome.status {
                case .success: return
                case .locked:  throw ExitCode(4)
                case .failed:  throw ExitCode(5)
                }
            }

            // Fallback für ältere App-Builds ohne Outcome-Marker: wenn sich nur
            // der Legacy-Timestamp bumpt, reporten wir das pauschal.
            if DataReader.lastRefreshOutcome() == nil,
               let current = DataReader.lastRefreshTimestamp(),
               current != legacyBefore {
                if !quiet {
                    if isTTY { print("\r\u{001B}[2K", terminator: "") }
                    print(ANSIColor.green("✓ Refresh durchgelaufen") + ANSIColor.dim(" (\(elapsed)s, Status unbekannt)"))
                }
                return
            }

            if !quiet && isTTY {
                print("\r\u{001B}[2K" + ANSIColor.dim("Cache geprüft, warte auf Bankabruf… \(elapsed)s"), terminator: "")
                fflush(stdout)
            }
        }

        // Timeout: Outcome-Marker hat sich innerhalb des Fensters nicht geändert.
        if !quiet {
            if isTTY { print("\r\u{001B}[2K", terminator: "") }
            print(ANSIColor.red("✗ Timeout nach \(timeout)s — keine Antwort der App."))
            print(ANSIColor.dim("  Mögliche Ursachen: App nicht gestartet, hängender TAN-Dialog,"))
            print(ANSIColor.dim("  oder Bank-Abruf dauert länger. Mit --timeout N erhöhen."))
        }
        throw ExitCode(1)
    }

    private func renderOutcome(_ outcome: DataReader.RefreshOutcome, elapsed: Int) {
        switch outcome.status {
        case .success:
            print(ANSIColor.green("✓ Bankabruf erfolgreich") + ANSIColor.dim(" (\(elapsed)s)"))
        case .locked:
            print(ANSIColor.yellow("⚠ App gesperrt — kein Bankabruf ausgeführt"))
            print(ANSIColor.dim("  Öffne simplebanking und gib das Master-Passwort ein, dann erneut versuchen."))
        case .failed:
            let tail = outcome.detail.map { ": \($0)" } ?? ""
            print(ANSIColor.red("✗ Bankabruf fehlgeschlagen\(tail)") + ANSIColor.dim(" (\(elapsed)s)"))
        }
    }
}
