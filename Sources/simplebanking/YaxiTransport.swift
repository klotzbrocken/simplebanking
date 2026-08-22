import Foundation
import RoutexClient
import RoutexRefresh

// MARK: - Der HTTP-Weg zur Bank
//
// Bis routex-client-swift 0.4.1 war der HTTP-Stack im SDK fest verdrahtet. Deshalb steht
// in CLAUDE.md, dass es keine Mock-Schicht gibt und Neues nur testbar wird, indem man
// reine Funktionen herauszieht: Alles, was wirklich mit der Bank spricht — die
// SCA-Schleife, die Wiederholungen, die Zustimmungsregeln im Zusammenspiel — war
// schlicht nicht prüfbar. Genau daran hing die Fehlersuche bei HVB und bunq.
//
// 0.5 nimmt den Transport als Parameter. Diese Datei ist die Stelle, an der er gesetzt
// wird: in Produktion `URLSessionTransport`, im Test ein eigener.

enum YaxiTransport {

    /// Der Transport, den jeder Client bekommt.
    ///
    /// `nonisolated(unsafe)`, weil er aus Hintergrund-Tasks gelesen wird und nach dem
    /// Start unverändert bleibt. Gesetzt wird er nur beim Programmstart oder im Test —
    /// nicht während laufender Bankaufrufe.
    nonisolated(unsafe) static var fabrik: @Sendable () -> any HTTPTransport = {
        URLSessionTransport()
    }

    /// Ein Client mit dem aktuell gesetzten Transport.
    static func client() -> RoutexClient {
        RoutexClient(transport: fabrik())
    }

    /// Ein Refresh-Client für Verbindungen, die den interaktiven Teil hinter sich haben.
    ///
    /// `userInSession: .onThisConnection` ist hier richtig und nicht bloß eine Option:
    /// Die Voreinstellung von YAXI geht davon aus, dass niemand vor dem Bildschirm
    /// sitzt, und Banken begrenzen solche Abrufe eng — überschritten kommt
    /// `accessExceeded`. simplebanking ist eine Menüleisten-App; wenn sie abruft, schaut
    /// jemand hin. Damit reicht YAXI die IP des Nutzers an die Bank durch und die enge
    /// Grenze entfällt.
    static func refreshClient() -> RoutexRefreshClient {
        RoutexRefreshClient(transport: fabrik(), userInSession: .onThisConnection)
    }

    /// Setzt den Transport zurück. Für Tests, damit einer den nächsten nicht erbt.
    static func zuruecksetzen() {
        fabrik = { URLSessionTransport() }
    }
}
