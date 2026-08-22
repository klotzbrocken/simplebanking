import XCTest
import Foundation
import RoutexClient
@testable import simplebanking

// MARK: - Die Fehlerfamilien des SDK
//
// SDK 0.5 hat den einen `RoutexClientError` in vier Typen aufgeteilt: `RoutexError` für
// das, was der Dienst meldet, `RoutexClientError` für Fehler im Client, `HTTPError` für
// den Transport und `KeySettlementError` für die Attestierung.
//
// Die Migrationsanleitung führt das ausdrücklich als Änderung, „die der Compiler nicht
// anmerkt": Eine Abfrage auf den alten Typ übersetzt weiterhin, trifft aber nie wieder
// zu. Betroffen wären ausgerechnet unsere Entscheidungsstellen — der bunq-Schutz, die
// Zwei-Stufen-Wiederholung und der Fehlerbericht. Sie würden stillschweigend nichts mehr
// tun: keine Ausnahme, keine Logzeile, nur wieder ein QR-Scan bei jedem Abruf.
//
// Diese Tests sind der Ersatz für den Compiler.

final class SDKFehlerfamilienTests: XCTestCase {

    /// Ein Dienstfehler ist **kein** `RoutexClientError`. Fällt dieser Test, ist die
    /// Trennung wieder aufgehoben und die Abfragen unten sagen nichts mehr aus.
    func test_dienstfehler_istNichtDerClientTyp() {
        let dienst: any Error = RoutexError.unexpectedError(userMessage: nil)
        XCTAssertNil(dienst as? RoutexClientError,
                     "Wäre das nicht nil, hätte die alte Abfrage zufällig weiter funktioniert")
        XCTAssertNotNil(dienst as? RoutexError)
    }

    // MARK: Der bunq-Schutz

    /// Redirect-Bank, unklarer Serverfehler → Zustimmung bleibt. Das ist der Kundenfall.
    func test_redirectBank_behaeltZustimmungBeiUnklaremFehler() {
        XCTAssertFalse(
            YaxiService.darfZustimmungVerwerfen(
                error: RoutexError.unexpectedError(userMessage: nil),
                istRedirectBank: true),
            "Bei bunq wächst eine verworfene Zustimmung nicht nach — jeder Abruf verlangte wieder einen QR-Scan")
    }

    /// Sagt die Bank es selbst, wird verworfen. `ConsentExpired` ist seit 0.5 in
    /// `unauthorized` aufgegangen; die Entscheidung bleibt dieselbe.
    func test_redirectBank_verwirftBeiAusdruecklicherAussage() {
        XCTAssertTrue(
            YaxiService.darfZustimmungVerwerfen(
                error: RoutexError.unauthorized(userMessage: nil),
                istRedirectBank: true))
    }

    /// Zugangsdaten-Banken liefern mit der nächsten Antwort eine frische Zustimmung —
    /// der Sparkassen-Fall, für den die Faustregel eingeführt wurde, darf nicht brechen.
    func test_zugangsdatenBank_darfImmerVerwerfen() {
        XCTAssertTrue(
            YaxiService.darfZustimmungVerwerfen(
                error: RoutexError.unexpectedError(userMessage: nil),
                istRedirectBank: false))
    }

    // MARK: Die Zwei-Stufen-Regel

    func test_unklarerFehler_wirdErstUnveraendertWiederholt() {
        XCTAssertTrue(YaxiService.erstMitConnectionDataWiederholen(
            RoutexError.unexpectedError(userMessage: nil)))
    }

    /// Ein Transportfehler ist keine Aussage über die Zustimmung. Er kam bis 0.4.1 als
    /// `RoutexClientError.RequestError`; seit 0.5 ist es ein eigener Typ, und ein
    /// vergessener Zweig hätte ihn als Bankfehler behandelt.
    func test_transportfehler_loestKeineZustimmungslogikAus() {
        let netz = HTTPError.transportFailure(underlying: URLError(.timedOut))
        XCTAssertFalse(YaxiService.erstMitConnectionDataWiederholen(netz))
        XCTAssertFalse(YaxiService.isConnectionResetError(netz))
        XCTAssertFalse(YaxiService.darfZustimmungVerwerfen(error: netz, istRedirectBank: true))
    }

    // MARK: Der Nutzertext

    /// Jede der vier Familien muss einen eigenen, nicht-generischen Titel bekommen —
    /// sonst hieße jeder Fehler „Unbekannter Fehler", und niemand merkte es.
    func test_jedeFamilieBekommtEinenEigenenTitel() {
        let generisch = RoutexErrorMapper.userMessage(
            for: NSError(domain: "x", code: 1)).title

        for fehler: any Error in [
            RoutexError.unauthorized(userMessage: nil),
            HTTPError.noResponse,
            RoutexClientError.malformedResponse(message: "x", underlying: nil),
        ] {
            let titel = RoutexErrorMapper.userMessage(for: fehler).title
            XCTAssertFalse(titel.isEmpty, "\(fehler)")
            XCTAssertNotEqual(titel, generisch,
                              "\(fehler) fällt auf den generischen Text zurück — die Familie wird nicht erkannt")
        }
    }

    // MARK: Typisierte Tickets

    /// Der Ticket-Typ prüft die Dienstangabe im Token. Ein für „Balances" ausgestelltes
    /// Ticket lässt sich damit nicht mehr an den Konten-Dienst geben — vorher fiel so
    /// etwas erst der Bank auf.
    func test_ticketPrueftDenDienst() throws {
        let konten = try YaxiTicketMaker.accountsTicket()
        XCTAssertFalse(konten.raw.isEmpty)
        XCTAssertThrowsError(try AccountsTicket(YaxiTicketMaker.issueTicket(service: "Balances")),
                             "ein Salden-Ticket darf nicht als Konten-Ticket durchgehen")
    }

    /// Die Ticket-Kennung kommt jetzt vom SDK statt aus eigenem JWT-Zerlegen.
    func test_ticketKennungIstLesbar() throws {
        let t = try YaxiTicketMaker.balancesTicket()
        XCTAssertNotEqual(t.id, UUID(uuid: UUID_NULL))
    }
}
