import AppKit
import Foundation

// MARK: - Liegt die App doppelt auf dem Rechner?
//
// Gemeldet am 23.09.2026: Eine Aktion aus Spotlight endete mit
//
//     Der Vorgang konnte nicht abgeschlossen werden.
//     (LinkDaemon.ProcessRegistry.Errors-Fehler 0.)
//
// Die Meldung kommt von macOS und nennt die Ursache nicht. Sie lautet: Auf dem Mac
// lagen zwei Kopien von simplebanking, beide bei LaunchServices registriert —
// `/Applications/simplebanking.app` (2.0.3) und eine zweite an anderer Stelle (2.0.5,
// die gerade lief). Spotlight, Kurzbefehle und Raycast sprechen immer die Kopie an,
// die LaunchServices bevorzugt. Läuft eine andere, findet `LinkDaemon` für die Aktion
// keinen passenden Prozess und bricht mit obigem Fehler ab.
//
// Das passiert nicht nur beim Entwickeln: Wer die App aus dem Programme-Ordner nutzt
// und die heruntergeladene Kopie in „Downloads" liegen lässt oder sie einmal direkt
// vom gemounteten DMG gestartet hat, bekommt denselben Fehler.
//
// Diese Prüfung ersetzt die kryptische Systemmeldung durch einen Hinweis, der sagt,
// welche Kopie gemeint ist. Sie entscheidet nichts und ändert nichts — sie vergleicht
// zwei Pfade.

enum Doppelinstallation {

    /// Ergebnis des Vergleichs zwischen laufender und registrierter Kopie.
    enum Befund: Equatable {
        /// Die laufende Kopie ist die, die macOS anspricht. Alles gut.
        case stimmigÜberein
        /// macOS spricht eine andere Kopie an — Aktionen aus Spotlight gehen dorthin.
        case andereKopieRegistriert(bevorzugt: URL)
        /// Keine Registrierung auffindbar (frisch kopiert, noch nicht indiziert,
        /// App-Translocation). Kein Hinweis — wir wissen es schlicht nicht.
        case unbekannt
    }

    /// Kern der Prüfung, ohne Zugriff auf das System — damit sie prüfbar bleibt.
    ///
    /// Beide Pfade werden vor dem Vergleich aufgelöst: Symlinks aufgelöst, `/private`
    /// vorangestellt oder nicht, abschließender Schrägstrich. Ohne das meldet dieselbe
    /// App sich selbst als fremde Kopie.
    static func vergleichen(laufend: URL, registriert: URL?) -> Befund {
        guard let registriert else { return .unbekannt }
        return normiert(laufend) == normiert(registriert)
            ? .stimmigÜberein
            : .andereKopieRegistriert(bevorzugt: registriert)
    }

    /// Vergleichbare Schreibweise eines Bundle-Pfads.
    static func normiert(_ url: URL) -> String {
        url.resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .replacingOccurrences(of: "/private/var/", with: "/var/")
            .trimmedTrailingSlash
    }

    /// Prüft die laufende App gegen die Registrierung von LaunchServices.
    @MainActor
    static func pruefen(bundle: Bundle = .main) -> Befund {
        guard let id = bundle.bundleIdentifier else { return .unbekannt }
        let registriert = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        return vergleichen(laufend: bundle.bundleURL, registriert: registriert)
    }

    // MARK: - Hinweis

    /// Merkt sich, für welche fremde Kopie schon gewarnt wurde. Kommt später eine
    /// *andere* dazu, erscheint der Hinweis erneut — dieselbe nervt nicht zweimal.
    private static let gezeigtKey = "simplebanking.doppelinstallationGezeigtFuer"

    /// Zeigt den Hinweis, falls nötig. Ruhig im Normalfall: Wer nur eine Kopie hat,
    /// merkt von dieser Funktion nichts.
    @MainActor
    static func hinweisZeigenFallsNoetig(bundle: Bundle = .main,
                                         defaults: UserDefaults = .standard) {
        guard case let .andereKopieRegistriert(bevorzugt) = pruefen(bundle: bundle) else { return }

        let laufend = bundle.bundleURL
        AppLogger.log("Doppelinstallation: läuft aus \(normiert(laufend)), macOS bevorzugt \(normiert(bevorzugt))",
                      category: "App", level: "WARN")

        guard defaults.string(forKey: gezeigtKey) != normiert(bevorzugt) else { return }
        defaults.set(normiert(bevorzugt), forKey: gezeigtKey)

        // **Nicht** sofort: `runModal` hält den Aufrufer an, und der Aufrufer ist
        // `applicationDidFinishLaunching`. Beim ersten Einbau stand damit der ganze
        // Start hinter dem Dialog — im Protokoll vier Sekunden Lücke, in denen es
        // weder Menüleisten-Symbol noch Kontostand gab. Der Hinweis ist wichtig,
        // aber nicht so wichtig.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { zeigeHinweis(laufend: laufend, bevorzugt: bevorzugt) }
        }
    }

    @MainActor
    private static func zeigeHinweis(laufend: URL, bevorzugt: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("simplebanking liegt doppelt auf diesem Mac",
                                   "simplebanking exists twice on this Mac")
        alert.informativeText = L10n.t(
            """
            Spotlight, Kurzbefehle und Raycast sprechen immer die Kopie an, die macOS kennt:
            \(bevorzugt.path)

            Gerade läuft aber:
            \(laufend.path)

            Deshalb schlagen Aktionen aus Spotlight mit „LinkDaemon.ProcessRegistry"-Fehlern fehl. Lösche die Kopie, die du nicht brauchst, und starte simplebanking aus dem Programme-Ordner.
            """,
            """
            Spotlight, Shortcuts and Raycast always talk to the copy macOS knows about:
            \(bevorzugt.path)

            But the one running right now is:
            \(laufend.path)

            That is why actions from Spotlight fail with “LinkDaemon.ProcessRegistry” errors. Delete the copy you don't need and start simplebanking from the Applications folder.
            """
        )
        alert.addButton(withTitle: L10n.t("Im Finder zeigen", "Reveal in Finder"))
        alert.addButton(withTitle: L10n.t("Später", "Later"))
        if let iconPath = Bundle.main.path(forResource: "app_icon", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            alert.icon = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([bevorzugt, laufend])
        }
    }

    #if DEBUG
    @MainActor
    static func hinweisVergessen(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: gezeigtKey)
    }
    #endif
}

private extension String {
    /// Ein Bundle-Pfad ist mit und ohne abschließenden Schrägstrich derselbe.
    var trimmedTrailingSlash: String {
        hasSuffix("/") && count > 1 ? String(dropLast()) : self
    }
}
