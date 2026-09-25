import AppKit
import AuthenticationServices

// MARK: - Freigabefenster
//
// Öffnet die Freigabe-Seite der Bank in einer `ASWebAuthenticationSession` statt in
// Safari. Anlass (09/2026, ING): Kunden bekamen auf myaccount.ing.com „400 Request
// Header Or Cookie Too Large" — der Cookie-Bestand ihres Safari für ing.com war über
// die Jahre so groß geworden, dass INGs Server die Anfrage ablehnte. Die App trägt
// dazu nichts bei, kann es aber umgehen: Die Sitzung hier ist „ephemeral", sie hat
// weder Cookies noch Verlauf des Nutzers und startet jedes Mal leer.
//
// Warum nicht `WKWebView`: Passkeys, Systemdialoge und der Wechsel in die App der
// Bank funktionieren in der Authentifizierungssitzung wie in Safari; ein roher
// WebView kann das nicht. Die Sitzung endet, sobald die Bank auf die registrierte
// Rückleitung `simplebanking://auth-callback` weiterleitet — das Schema steht in der
// Info.plist (build-app.sh) — oder wenn die App sie nach abgeschlossenem Polling
// schließt.
@MainActor
final class Freigabefenster: NSObject, ASWebAuthenticationPresentationContextProviding {

    /// Rückleitung, die bei YAXI registriert wird. Die Sitzung erkennt das Schema und
    /// endet damit; die eigentliche Bestätigung läuft weiter über das Polling.
    nonisolated static let callbackScheme = "simplebanking"
    nonisolated static let callbackURI = "simplebanking://auth-callback"

    /// Einstellung: Freigabe im eigenen Fenster (Standard) oder in Safari wie bis 2.0.3.
    nonisolated static let einstellungKey = "scaEphemeralWindow"
    static var aktiv: Bool {
        UserDefaults.standard.object(forKey: einstellungKey) as? Bool ?? true
    }

    private var session: ASWebAuthenticationSession?
    private var anker: NSWindow?
    private var fertigContinuation: AsyncStream<Void>.Continuation?

    /// Feuert einmal, wenn die Bank auf die Rückleitung weitergeleitet hat. Gibt es
    /// keine passende Rückleitung (Fall `.redirect` mit fremder URI), feuert er nie —
    /// dann trägt allein das Polling.
    let fertig: AsyncStream<Void>

    override init() {
        var cont: AsyncStream<Void>.Continuation?
        fertig = AsyncStream { cont = $0 }
        super.init()
        fertigContinuation = cont
    }

    /// Öffnet die Seite. `false`, wenn die Sitzung nicht startet — dann greift der
    /// Aufrufer auf Safari zurück.
    func oeffnen(_ url: URL, erwartetRueckleitung: Bool) -> Bool {
        let s = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: erwartetRueckleitung ? Self.callbackScheme : nil
        // `@Sendable` ist hier kein Beiwerk, sondern der ganze Punkt.
        //
        // Ohne die Auszeichnung erbt dieser Abschluss die Isolation der Funktion, in
        // der er steht — und die ist `@MainActor`. Aufgerufen wird er aber von
        // AuthenticationServices auf der XPC-Antwortschlange des Safari-Agenten. Swift 6
        // prüft das beim Eintritt (`swift_task_checkIsolated`), die Prüfung schlägt fehl,
        // und der Prozess endet mit SIGTRAP. Für den Nutzer sah das so aus: Freigabe in
        // der Bank erteilt, App weg. Zweimal reproduziert (24.09.2026, Builds
        // 20260923691 und 20260924692), Absturzbericht jeweils
        // `_dispatch_assert_queue_fail` unter dieser Closure.
        //
        // Das `Task { @MainActor in … }` darunter gab es vorher schon — es kam nur nie
        // dazu, weil die Prüfung davor zuschlug. Deshalb ausdrücklich isolationsfrei
        // und der Sprung auf den Hauptthread von Hand.
        ) { @Sendable [weak self] callbackURL, error in
            // Vor dem Sprung auf das Nötige eindampfen: `any Error` ist nicht `Sendable`
            // und dürfte die Schlangengrenze nicht überqueren.
            let rueckleitungKam = callbackURL != nil
            let vomNutzerGeschlossen = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            let fehlertext = error?.localizedDescription

            Task { @MainActor in
                guard let self else { return }
                if rueckleitungKam {
                    AppLogger.log("Freigabefenster: Rückleitung angekommen", category: "YaxiService")
                    self.fertigContinuation?.yield()
                } else if vomNutzerGeschlossen {
                    // Fenster vom Nutzer geschlossen. Kein Abbruch: Die Freigabe kann in der
                    // Banking-App längst erteilt sein, das Polling läuft weiter und der
                    // Nutzer kann es über „Warten beenden" selbst stoppen.
                    AppLogger.log("Freigabefenster: vom Nutzer geschlossen — Polling läuft weiter", category: "YaxiService")
                } else if let fehlertext {
                    AppLogger.log("Freigabefenster: Sitzung endete mit Fehler: \(fehlertext)",
                                  category: "YaxiService", level: "WARN")
                }
                self.fertigContinuation?.finish()
                self.session = nil
            }
        }
        s.prefersEphemeralWebBrowserSession = true
        s.presentationContextProvider = self
        session = s
        guard s.start() else {
            AppLogger.log("Freigabefenster: Sitzung ließ sich nicht starten — Rückfall auf Safari",
                          category: "YaxiService", level: "WARN")
            session = nil
            fertigContinuation?.finish()
            return false
        }
        return true
    }

    /// Schließt das Fenster, wenn das Polling fertig ist oder der Nutzer das Warten beendet.
    ///
    /// `nonisolated` mit eigenem Sprung über die Runloop — und das ist der Punkt.
    ///
    /// Aufgerufen wird das aus dem Bankweg, also aus einem Zusammenhang ohne Isolation.
    /// Wäre die Methode schlicht `@MainActor`, müsste Swift dafür auf die
    /// Main-Dispatch-Queue springen, und die kommt während des modalen
    /// Einrichtungsassistenten nicht rechtzeitig dran. Gemeldet am 25.09.2026: Die
    /// Freigabe der ING war erteilt, das Fenster zu, das Polling fertig —
    /// `SCA result: connectionData=1637b` steht im Protokoll — und danach stand der
    /// Assistent still, weil er genau hier auf den Hauptthread wartete. Siehe die
    /// Begründung an `YaxiService.onMainRunLoop`.
    ///
    /// Der Sprung steckt deshalb in der Methode selbst und nicht in ihren Aufrufern:
    /// So kann keine spätere Aufrufstelle ihn vergessen.
    nonisolated func schliessen() async {
        await withCheckedContinuation { (fortsetzung: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated {
                    self.schliessenAufDemHauptthread()
                    fortsetzung.resume()
                }
            }
        }
    }

    private func schliessenAufDemHauptthread() {
        session?.cancel()
        session = nil
        fertigContinuation?.finish()
        anker?.orderOut(nil)
        anker = nil
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            // Eine Menüleisten-App hat oft kein Fenster. Die Sitzung braucht aber einen
            // Anker; ein sichtbares App-Fenster ist der beste, sonst ein winziges
            // Hilfsfenster außerhalb des Blickfelds.
            if let sichtbar = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal && !$0.isMiniaturized }) {
                return sichtbar
            }
            if let anker { return anker }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.alphaValue = 0
            w.orderFront(nil)
            anker = w
            return w
        }
    }
}
