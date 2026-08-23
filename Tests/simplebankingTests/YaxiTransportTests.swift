import XCTest
import Foundation
import RoutexClient
@testable import simplebanking

// MARK: - Der austauschbare Transport
//
// Bis SDK 0.4.1 war der HTTP-Stack im SDK fest verdrahtet. Deshalb ließ sich am Bankweg
// nichts prüfen — jede Aussage über Wiederholungen, Zustimmungen oder den Schnellabruf
// war eine Behauptung, belegbar nur an einer echten Bank, und jeder Versuch konnte eine
// Freigabe kosten. Genau das hat die Fehlersuche bei HVB und bunq so zäh gemacht.
//
// Diese Tests belegen, dass der Weg jetzt wirklich durch `YaxiTransport.fabrik` läuft
// und dass ein Ausfall dort den Abruf nicht mitreißt.

/// Nimmt jede Anfrage entgegen, merkt sie sich und antwortet vorgegeben.
///
/// Ein Aktor statt eines Schlosses: `NSLock` darf in asynchronem Zusammenhang nicht
/// genommen werden, und `execute` ist asynchron.
private actor Mitschrift {
    private(set) var anfragen: [HTTPRequest] = []
    func vermerken(_ r: HTTPRequest) { anfragen.append(r) }
}

private struct MitschreibenderTransport: HTTPTransport {
    let mitschrift = Mitschrift()
    let antwort: Result<HTTPResponse, any Error>

    init(antwort: Result<HTTPResponse, any Error> = .failure(HTTPError.noResponse)) {
        self.antwort = antwort
    }

    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        await mitschrift.vermerken(request)
        return try antwort.get()
    }
}

final class YaxiTransportTests: XCTestCase {

    override func tearDown() {
        YaxiTransport.zuruecksetzen()
        UserDefaults.standard.removeObject(forKey: "yaxiNonInteractiveRefreshEnabled")
        super.tearDown()
    }

    /// Der Standardweg bleibt der echte — ein Test darf den nicht dauerhaft entführen.
    func test_standardIstDerEchteTransport() {
        YaxiTransport.zuruecksetzen()
        XCTAssertTrue(YaxiTransport.fabrik() is URLSessionTransport)
    }

    /// Die Naht: Was hier gesetzt wird, benutzen die Clients auch.
    func test_gesetzterTransportWirdBenutzt() async throws {
        let transport = MitschreibenderTransport()
        YaxiTransport.fabrik = { transport }

        let client = YaxiTransport.client()
        let ticket = try YaxiTicketMaker.balancesTicket()
        _ = try? await client.balances(
            ticket: ticket,
            credentials: Credentials(connectionID: try ConnectionID(UUID().uuidString)),
            accounts: [])

        let gesehen = await transport.mitschrift.anfragen
        XCTAssertFalse(gesehen.isEmpty,
                       "Der Client hat den gesetzten Transport nicht benutzt — die Naht greift nicht")
        let ziel = try XCTUnwrap(gesehen.first)
        XCTAssertEqual(ziel.method, .post)
        XCTAssertTrue(ziel.url.absoluteString.hasPrefix("https://"), ziel.url.absoluteString)
    }

    /// Auch der Refresh-Client geht durch dieselbe Naht.
    func test_refreshClientBenutztDenselbenTransport() async throws {
        let transport = MitschreibenderTransport()
        YaxiTransport.fabrik = { transport }

        _ = try? await YaxiTransport.refreshClient().balances(
            ticket: try YaxiTicketMaker.balancesTicket(),
            connectionData: ConnectionData(Data([1, 2, 3])),
            accounts: [])

        let gesehen = await transport.mitschrift.anfragen
        XCTAssertFalse(gesehen.isEmpty)
    }

    /// Fällt der Transport aus, muss der Abruf das als Fehler sehen — und nicht
    /// abstürzen oder stumm etwas Falsches liefern.
    func test_transportausfallWirdZumFehler() async throws {
        struct Netzweg: Error {}
        YaxiTransport.fabrik = { MitschreibenderTransport(antwort: .failure(Netzweg())) }

        do {
            _ = try await YaxiTransport.client().balances(
                ticket: try YaxiTicketMaker.balancesTicket(),
                credentials: Credentials(connectionID: try ConnectionID(UUID().uuidString)),
                accounts: [])
            XCTFail("ein toter Transport darf nicht als Erfolg durchgehen")
        } catch {
            // Der Typ ist je nach Schicht HTTPError oder KeySettlementError — beides ist
            // ein Fehler, und genau darauf kommt es an.
            XCTAssertFalse(error is RoutexError,
                           "ein Netzwerkausfall ist kein Bankfehler")
        }
    }

    // MARK: Der Schalter des Schnellabrufs

    /// **Standardmäßig aus.** War einen Tag lang an; am 23.08.2026 kam die Meldung, dass
    /// bunq in einer Freigabe-Dauerschleife hängt. `unauthorized` als Rohfehler gab es in
    /// der gesamten Protokollhistorie nur an diesem Tag. Solange der Zusammenhang nicht
    /// geklärt ist, bleibt der Weg aus.
    func test_schnellabruf_istStandardmaessigAus() {
        UserDefaults.standard.removeObject(forKey: "yaxiNonInteractiveRefreshEnabled")
        XCTAssertFalse(YaxiService.schnellabrufAktiv,
                       "ohne Eintrag gilt der bewährte Weg")
    }

    /// Zum Erproben lässt er sich einschalten, ohne eine neue Fassung auszuliefern.
    func test_schnellabruf_laesstSichEinschalten() {
        UserDefaults.standard.set(true, forKey: "yaxiNonInteractiveRefreshEnabled")
        XCTAssertTrue(YaxiService.schnellabrufAktiv)
    }
}
