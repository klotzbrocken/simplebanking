import Foundation
import Sparkle

/// Wraps SPUStandardUpdaterController for use in the menu-bar app.
/// Auto-checks for updates on launch; exposes checkForUpdates() for the menu item.
@MainActor
final class UpdateChecker: NSObject {
    private var updaterController: SPUStandardUpdaterController!

    /// Höchstens ein Aufräumen pro Start. Hilft es nicht, drehte sich der Versuch
    /// sonst im Kreis: Fehler → aufräumen → prüfen → derselbe Fehler.
    private var hatAufgeraeumt = false

    /// Die bereitliegende Fassung („2.1.0"), sobald Sparkles eigene Prüfung eine
    /// gefunden hat — sonst `nil`. Wird nicht gepollt: Sparkle meldet sie.
    private(set) var verfuegbareVersion: String?

    /// Meldet dem Host jede Änderung, damit er Menüleiste und Flyout nachzieht.
    var onVerfuegbareVersion: ((String?) -> Void)?

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Leer zählt als „nichts da": `displayVersionString` kommt aus dem Appcast und
    /// ist damit fremder Text. Ein Band ohne Fassungsnummer wäre schlimmer als keins.
    private func setzeVerfuegbareVersion(_ version: String?) {
        let gesaeubert = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let neue = (gesaeubert?.isEmpty ?? true) ? nil : gesaeubert
        guard verfuegbareVersion != neue else { return }
        verfuegbareVersion = neue
        onVerfuegbareVersion?(neue)
    }
}

// MARK: - Stiller Hinweis statt Fenster („gentle reminders")

// Die Prüfung macht Sparkle längst von selbst, nach seinem eigenen Zeitplan. Was
// fehlte, war ein Weg, das Ergebnis zu erfahren, ohne dass dem Nutzer ein Fenster
// vor die Nase springt. Genau dafür ist diese Schnittstelle da, und Sparkle
// schreibt uns sogar ins Protokoll, dass sie uns fehlt: „Background app
// automatically schedules for update checks but does not implement gentle
// reminders."
//
// `…ShouldHandleShowingScheduledUpdate → false` heißt: Sparkle findet, prüft und
// hält die Sitzung offen, zeigt aber nichts. Wir setzen stattdessen das Zeichen in
// der Leiste und das Band ins Flyout. Der Knopf dort postet
// `.checkForUpdatesRequested` → `checkForUpdates()` → Sparkle holt genau dieses
// schon gefundene Update nach vorn. **Kein zweiter Update-Pfad, kein eigener
// Zeitgeber, kein eigener Appcast-Abruf.**
// `@preconcurrency`: Sparkle ruft diese Methoden auf dem Hauptthread, aber
// `SPUStandardUserDriverDelegate` ist — anders als `SPUUpdaterDelegate` — nicht als
// `NS_SWIFT_UI_ACTOR` deklariert. Ohne die Annotation lehnt der Compiler die
// Konformanz einer `@MainActor`-Klasse ab.
extension UpdateChecker: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // Zeigt Sparkle es selbst (der Nutzer hat gerade „Nach Updates suchen…"
        // geklickt), braucht es daneben keinen stillen Hinweis.
        guard !handleShowingUpdate else { return }
        setzeVerfuegbareVersion(update.displayVersionString)
    }

    /// Der Nutzer hat das Update zu Gesicht bekommen — der Hinweis hat seinen
    /// Zweck erfüllt und verschwindet, auch wenn er die Installation vertagt.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        setzeVerfuegbareVersion(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        setzeVerfuegbareVersion(nil)
    }
}

// MARK: - Selbstheilung bei hängengebliebener Installation

// Sparkle setzt eine angefangene Installation fort, sobald der Fortschritts-Agent
// für unsere Bundle-ID auf seinem Mach-Dienst antwortet (`probeInstallerInProgress`).
// Liefert derselbe Agent dann keine Installationsdaten, bricht Sparkle mit
// `SUResumeAppcastError` ab und zeigt „Failed to resume installing update."
// Der Anwender kommt da nicht mehr heraus: Jeder weitere Versuch nimmt denselben
// Weg und endet an derselben Stelle. Gemeldet am 04.11.2026 von einem Nutzer mit
// 2.0.7 — Appcast, Signatur und Schlüssel waren nachweislich in Ordnung, es lag
// allein am Rest auf seinem Rechner.
//
// Aufgeräumt wird, was den Rest ausmacht: die beiden launchd-Aufträge, die Sparkle
// für eine Installation einträgt, und der Sparkle-Zwischenspeicher. Beides ist zu
// diesem Zeitpunkt gefahrlos — ohne Installationsdaten hat der Agent noch nichts
// angefasst, was eine Unterbrechung kaputtmachen könnte.
extension UpdateChecker: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard !hatAufgeraeumt, Self.istFortsetzFehler(error) else { return }
        hatAufgeraeumt = true

        let bundleId = Bundle.main.bundleIdentifier ?? ""
        AppLogger.log("Fortsetzen der Installation gescheitert — räume Sparkle-Reste auf (\(bundleId))",
                      category: "UpdateChecker", level: "WARN")
        Self.resteAufraeumen(bundleId: bundleId)

        // Nicht aus dem Abbruch heraus neu starten: Sparkle schließt die laufende
        // Sitzung erst danach ab und lehnt eine zweite Prüfung sonst ab.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.checkForUpdates()
        }
    }
}

extension UpdateChecker {
    /// `SUResumeAppcastError` (1004) ist der Abbruch, aus dem der Anwender nicht
    /// mehr herausfindet. Andere Fehler bleiben unangetastet — ein fehlender
    /// Netzzugang oder eine abgelehnte Signatur heilt kein Aufräumen.
    static func istFortsetzFehler(_ error: Error) -> Bool {
        let fehler = error as NSError
        return fehler.domain == SUSparkleErrorDomain
            && fehler.code == SUError.resumeAppcastError.rawValue
    }

    /// Die launchd-Aufträge, die Sparkles `SUInstallerLauncher` für eine
    /// Installation in die Benutzer-Domäne einträgt (`-sparkle-progress` für den
    /// Fortschritts-Agenten, `-sparkle-updater` für den Installierer).
    static func launchdAuftraege(bundleId: String) -> [String] {
        ["\(bundleId)-sparkle-progress", "\(bundleId)-sparkle-updater"]
    }

    /// `~/Library/Caches/<bundleId>/org.sparkle-project.Sparkle` — darunter legt
    /// Sparkle `PersistentDownloads` und `Installation` ab.
    static func sparkleCacheOrdner(bundleId: String, cachesWurzel: URL) -> URL {
        cachesWurzel
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
    }

    private static func resteAufraeumen(bundleId: String) {
        guard !bundleId.isEmpty else { return }

        for label in launchdAuftraege(bundleId: bundleId) {
            entladen(label: label)
        }

        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let ordner = sparkleCacheOrdner(bundleId: bundleId, cachesWurzel: caches)
            try? FileManager.default.removeItem(at: ordner)
        }
    }

    /// `launchctl bootout` statt `SMJobRemove` — letzteres ist seit macOS 10.10
    /// abgekündigt und entfernt in der Benutzer-Domäne nichts mehr. Ein Auftrag,
    /// den es nicht gibt, liefert einen Fehlercode; der interessiert hier nicht.
    private static func entladen(label: String) {
        let prozess = Process()
        prozess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        prozess.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        prozess.standardOutput = FileHandle.nullDevice
        prozess.standardError = FileHandle.nullDevice
        do {
            try prozess.run()
            prozess.waitUntilExit()
        } catch {
            AppLogger.log("launchctl bootout \(label) nicht ausführbar: \(error.localizedDescription)",
                          category: "UpdateChecker", level: "WARN")
        }
    }
}
