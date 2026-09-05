import XCTest
import RoutexModels
@testable import simplebanking

// MARK: - Wann darf ein Aufruf wiederholt werden?
//
// Audit-Befund vom 05.09.2026: Ein `UnexpectedError` ohne Nutzertext wurde als veraltete
// Zustimmung gelesen und der Aufruf mit frischem Ticket wiederholt. Beim Lesen kostet das
// nichts. Bei einer Überweisung schickt es womöglich eine ZWEITE Zahlung — und YAXI sagt
// ausdrücklich, dass ein UnexpectedError kein Beleg dafür ist, dass die Operation nicht
// ausgeführt wurde.

final class ZahlungWiederholungTests: XCTestCase {

    private let unklar = RoutexError.unexpectedError(userMessage: nil)
    private let bankSagtNein = RoutexError.unauthorized(userMessage: nil)

    /// Der Kern des Befunds.
    func test_zahlungWirdBeiUnklaremFehlerNichtWiederholt() {
        XCTAssertFalse(YaxiService.darfOhneConnectionDataWiederholen(
            error: unklar, connectionDataAge: 99 * 3600, istZahlung: true))
    }

    /// Gegenprobe: Genau derselbe Fehler darf beim Lesen weiterhin wiederholt werden —
    /// sonst wäre der Test oben auch mit einem pauschalen `false` grün.
    func test_datenabrufWirdBeiDemselbenFehlerWeiterhinWiederholt() {
        XCTAssertTrue(YaxiService.darfOhneConnectionDataWiederholen(
            error: unklar, connectionDataAge: 99 * 3600, istZahlung: false))
    }

    /// Unbekanntes Alter war bisher ein Freibrief. Für Zahlungen nicht mehr.
    func test_unbekanntesAlterErlaubtKeineZweiteZahlung() {
        XCTAssertFalse(YaxiService.darfOhneConnectionDataWiederholen(
            error: unklar, connectionDataAge: nil, istZahlung: true))
        XCTAssertTrue(YaxiService.darfOhneConnectionDataWiederholen(
            error: unklar, connectionDataAge: nil, istZahlung: false))
    }

    /// Sagt die Bank ausdrücklich „nicht autorisiert", steht fest, dass nichts
    /// angenommen wurde — dann ist ein zweiter Versuch auch bei einer Zahlung richtig.
    /// Ohne diesen Fall würde die Korrektur oben legitime Wiederholungen mitnehmen.
    func test_ausdrucklicheAblehnungErlaubtDenZweitenVersuch() {
        XCTAssertTrue(YaxiService.darfOhneConnectionDataWiederholen(
            error: bankSagtNein, connectionDataAge: nil, istZahlung: true))
    }

    /// Fehler, die gar nichts mit der Zustimmung zu tun haben, lösen weiterhin keine
    /// Wiederholung aus.
    func test_fremderFehlerLoestKeineWiederholungAus() {
        let anderer = NSError(domain: "test", code: 1)
        XCTAssertFalse(YaxiService.darfOhneConnectionDataWiederholen(
            error: anderer, connectionDataAge: nil, istZahlung: false))
        XCTAssertFalse(YaxiService.darfOhneConnectionDataWiederholen(
            error: anderer, connectionDataAge: nil, istZahlung: true))
    }
}
