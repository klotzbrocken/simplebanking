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

    /// Auch bei ausdrücklichem `unauthorized` wird bei einer Redirect-Bank nicht
    /// verworfen — seit dem gemeldeten bunq-Dauerlauf am 23.08.2026. Siehe
    /// `darfZustimmungVerwerfen` für die Begründung.
    func test_redirectBank_verwirftAuchBeiUnauthorizedNicht() {
        XCTAssertFalse(
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

    /// **Der gemeldete Dauerlauf, als Regel festgehalten.** Am 23.08.2026 hing bunq in
    /// einer Freigabe-Schleife: zwei bestätigte QR-Scans, danach beim nächsten
    /// Umsatzabruf wieder von vorn. Die Kette im Protokoll war
    ///
    ///     Rohfehler: unauthorized
    ///     consent expired, retrying without connectionData
    ///     clearing ALL state after auth reset
    ///
    /// Beide Schritte hängen an dieser einen Entscheidung. Solange sie für Redirect-
    /// Banken `false` liefert, kann die Kette nicht anlaufen — unabhängig davon, welchen
    /// Fehler die Bank meldet.
    func test_keinFehlerDarfDieZustimmungEinerRedirectBankKosten() {
        let alleFehler: [RoutexError] = [
            .unauthorized(userMessage: nil),
            .unauthorized(userMessage: "consent invalid"),
            .unexpectedError(userMessage: nil),
            .unexpectedError(userMessage: "irgendwas"),
            .interruptError,
            .invalidCredentials(userMessage: nil),
            .accessExceeded(userMessage: nil),
            .notFound,
        ]
        for fehler in alleFehler {
            XCTAssertFalse(
                YaxiService.darfZustimmungVerwerfen(error: fehler, istRedirectBank: true),
                "\(fehler) darf bei bunq/N26/Revolut keinen QR-Scan auslösen")
        }
    }

    /// Die Gegenprobe: Bei Zugangsdaten-Banken bleibt der Weg offen. Dort liefert die
    /// nächste Antwort eine frische Zustimmung nach — der Sparkassen-Fall, für den die
    /// Regel ursprünglich gebaut wurde, darf nicht mitgesperrt werden.
    func test_zugangsdatenBankBleibtUnberuehrt() {
        for fehler: RoutexError in [.unauthorized(userMessage: nil),
                                    .unexpectedError(userMessage: nil)] {
            XCTAssertTrue(
                YaxiService.darfZustimmungVerwerfen(error: fehler, istRedirectBank: false),
                "\(fehler)")
        }
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

    // MARK: Werttypen dürfen nicht in die Einstellungen

    /// **Der Absturz vom 23.08.2026.** Beim Einrichten einer neuen Bank beendete sich die
    /// App. Im Bericht: `storeConnectionInfo` → `NSUserDefaults setObject:forKey:` →
    /// Objective-C-Ausnahme → SIGABRT.
    ///
    /// Ursache: `ConnectionInfo.id` war bis SDK 0.4.1 ein `String` und ist seit 0.5 ein
    /// `ConnectionID`-Werttyp. `UserDefaults.set` nimmt `Any?` entgegen — der Compiler
    /// merkt also nichts — und wirft zur Laufzeit, sobald der Wert kein
    /// Property-List-Typ ist. Eine geworfene ObjC-Ausnahme beendet einen Swift-Prozess.
    ///
    /// Dieser Test hält beide Hälften fest: Der Werttyp ist nicht ablagefähig, seine
    /// Drahtform schon.
    func test_connectionIDGehoertNichtRohInDieEinstellungen() throws {
        let kennung = try ConnectionID(UUID().uuidString)

        XCTAssertFalse(PropertyListSerialization.propertyList(kennung, isValidFor: .binary),
                       "Direkt abgelegt beendet dieser Wert den Prozess — siehe storeConnectionInfo")
        XCTAssertTrue(PropertyListSerialization.propertyList(kennung.description, isValidFor: .binary))
    }

    /// Die Drahtform muss zurückgelesen werden können, sonst hätten wir den Absturz gegen
    /// eine kaputte Verbindung getauscht.
    func test_drahtformIstWiederEinlesbar() throws {
        let original = try ConnectionID(UUID().uuidString)
        let zurueck = try ConnectionID(original.description)
        XCTAssertEqual(zurueck, original)
    }

    /// Dieselbe Falle für die übrigen Werttypen aus 0.5: Sitzung, Zustimmung und
    /// Trace-Kennung werden als `Data` abgelegt, nie als Umschlag.
    func test_opakeWerttypenNurAlsBytes() {
        let sitzung = Session(Data([1, 2, 3]))
        XCTAssertFalse(PropertyListSerialization.propertyList(sitzung, isValidFor: .binary))
        XCTAssertTrue(PropertyListSerialization.propertyList(sitzung.bytes, isValidFor: .binary))
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
