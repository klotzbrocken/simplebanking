import XCTest
import Routex
@testable import simplebanking

// MARK: - Eine frische Zustimmung ist nicht abgelaufen
//
// `isConnectionResetError` deutet `UnexpectedError(userMessage: nil)` als veraltete
// connectionData. Diese Faustregel wurde für Sparkassen eingeführt und stimmt dort oft.
//
// Bei der HypoVereinsbank ist sie falsch: Der Saldenabruf scheitert mit genau diesem
// Fehler, obwohl die Zustimmung Sekunden zuvor aus der ersten TAN entstanden ist. Die
// App warf sie daraufhin weg, forderte eine zweite TAN an — und scheiterte erneut mit
// demselben Fehler. Gemessen am 29.07. bei zwei verschiedenen Kunden, je zweimal, mit
// einem und mit fünf Konten.
//
// Die zweite TAN war also reine Verschwendung: Sie kostete den Nutzer eine Freigabe,
// zerstörte die gültige Zustimmung und änderte am Ergebnis nichts.

final class FrischeZustimmungTests: XCTestCase {

    private let mehrdeutig = RoutexClientError.UnexpectedError(userMessage: nil)

    // MARK: Der Fall, um den es geht

    func test_frischeZustimmung_wirdNichtWeggeworfen() {
        XCTAssertFalse(
            YaxiService.darfOhneConnectionDataWiederholen(error: mehrdeutig, connectionDataAge: 1.2),
            "Eine 1,2 Sekunden alte Zustimmung kann nicht abgelaufen sein")
    }

    /// Zwischen Kontenabruf und Saldenabruf wählt der Nutzer sein Konto aus — das darf
    /// dauern. Deshalb ist die Frist großzügig.
    func test_zustimmungBleibtWaehrendDerKontoauswahlFrisch() {
        for alter: TimeInterval in [5, 30, 120, 299] {
            XCTAssertFalse(
                YaxiService.darfOhneConnectionDataWiederholen(error: mehrdeutig, connectionDataAge: alter),
                "nach \(Int(alter))s bereits als abgelaufen behandelt")
        }
    }

    // MARK: Was unverändert bleiben muss

    /// Nach Ablauf der Frist gilt wieder die alte Faustregel — sonst hätte diese
    /// Änderung den Sparkassen-Fall gebrochen, für den sie eingeführt wurde.
    func test_alteZustimmung_wirdWieBisherVerworfen() {
        XCTAssertTrue(
            YaxiService.darfOhneConnectionDataWiederholen(error: mehrdeutig, connectionDataAge: 301))
    }

    /// Stammt die Zustimmung aus einer früheren Sitzung, ist ihr Alter unbekannt. Dann
    /// gilt die vorsichtigere Annahme: verhalten wie bisher.
    func test_unbekanntesAlter_verhaeltSichWieBisher() {
        XCTAssertTrue(
            YaxiService.darfOhneConnectionDataWiederholen(error: mehrdeutig, connectionDataAge: nil))
    }

    /// Sagt die Bank ausdrücklich, dass die Zustimmung weg ist, wird ihr geglaubt —
    /// unabhängig vom Alter. Nur die Faustregel wird ausgesetzt, nicht die Aussage.
    func test_ausdrucklicheAussageDerBank_giltImmer() {
        for fehler: RoutexClientError in [.Unauthorized(userMessage: nil), .ConsentExpired(userMessage: nil)] {
            XCTAssertTrue(
                YaxiService.darfOhneConnectionDataWiederholen(error: fehler, connectionDataAge: 0.5),
                "\(fehler) muss auch bei frischer Zustimmung greifen")
        }
    }

    /// Fehler, die gar nichts mit der Zustimmung zu tun haben, dürfen den Zweig nie
    /// auslösen — weder vorher noch nachher.
    func test_fremdeFehlerLoesenDenZweigNichtAus() {
        let fremd = RoutexClientError.InvalidCredentials(userMessage: nil)
        for alter: TimeInterval? in [nil, 0.5, 1000] {
            XCTAssertFalse(
                YaxiService.darfOhneConnectionDataWiederholen(error: fremd, connectionDataAge: alter))
        }
    }

    /// `UnexpectedError` MIT Nachricht war noch nie Teil der Faustregel (das sind die
    /// HBCI-Gateway-Fehler) — daran ändert sich nichts.
    func test_unexpectedErrorMitNachricht_bleibtAussenVor() {
        let mitText = RoutexClientError.UnexpectedError(userMessage: "FGW Gatewaywechsel")
        XCTAssertFalse(
            YaxiService.darfOhneConnectionDataWiederholen(error: mitText, connectionDataAge: nil))
    }

    /// Die Frist ist eine bewusst gewählte Zahl, kein Zufall — wird sie verändert,
    /// soll das auffallen.
    func test_fristIstFuenfMinuten() {
        XCTAssertEqual(YaxiService.frischeZustimmungSekunden, 300)
    }

    // MARK: - Erst wiederholen, dann wegwerfen
    //
    // YAXI am 31.07. zur HypoVereinsbank: „Wir liefern einen UnexpectedError.
    // Daraufhin versucht simplebanking den Vorgang offenbar nochmal ohne
    // ConnectionData. Das ist der Grund, dass die SCA nochmal startet. Prinzipiell
    // spricht nichts dagegen bei UnexpectedError Dinge nochmal zu versuchen und zu
    // hoffen, aber das Weglassen der ConnectionData ist da eher random."
    //
    // Die Altersschranke oben verhindert nur den Fall, dass die Zustimmung eben erst
    // entstanden ist. Ist sie älter als fünf Minuten — der Normalfall bei jedem
    // Refresh — greift die Faustregel weiter und kostet für einen Serverfehler eine
    // Freigabe. Deshalb geht jetzt ein unveränderter Versuch voran.

    func test_vermuteterFehler_erstUnveraendertWiederholen() {
        XCTAssertTrue(
            YaxiService.erstMitConnectionDataWiederholen(mehrdeutig),
            "Der UnexpectedError ist unsere Deutung, keine Aussage der Bank — vor dem "
            + "Wegwerfen der Zustimmung gehört ein Versuch mit ihr")
    }

    /// Die Zwischenstufe ist nur für Vermutungen da. Sagt die Bank selbst, dass die
    /// Zustimmung weg ist, wäre ein Versuch mit ihr verlorene Zeit.
    func test_ausdrucklicheAussage_brauchtKeineZwischenstufe() {
        for fehler: RoutexClientError in [.Unauthorized(userMessage: nil), .ConsentExpired(userMessage: nil)] {
            XCTAssertFalse(
                YaxiService.erstMitConnectionDataWiederholen(fehler),
                "\(fehler) ist eindeutig — da gibt es nichts zu prüfen")
        }
    }

    /// Der Gegentest zur Altersschranke: Beim älteren Bestandskonto — dem Normalfall
    /// im Betrieb — bleibt der Weg zum Wegwerfen offen, aber eben erst danach.
    func test_alteZustimmung_wirdWeiterhinWeggeworfen_aberErstNachDemVersuch() {
        XCTAssertTrue(
            YaxiService.darfOhneConnectionDataWiederholen(error: mehrdeutig, connectionDataAge: 3600),
            "Der Sparkassen-Fall, für den die Faustregel eingeführt wurde, muss erreichbar bleiben")
        XCTAssertTrue(
            YaxiService.erstMitConnectionDataWiederholen(mehrdeutig),
            "… aber nicht im ersten Anlauf")
    }

    /// `UnexpectedError` mit Nachricht (HBCI-Gateway) löst den Zweig gar nicht erst
    /// aus — die Zwischenstufe ist dort ohne Bedeutung, aber sie darf auch nicht
    /// stören, falls die Reihenfolge der Zweige je umgestellt wird.
    func test_gatewayFehler_bleibtUnberuehrt() {
        let mitText = RoutexClientError.UnexpectedError(userMessage: "Fehlender Dialogkontext")
        XCTAssertFalse(
            YaxiService.darfOhneConnectionDataWiederholen(error: mitText, connectionDataAge: 3600))
    }

    func test_fremderFehler_hatKeineZwischenstufe() {
        XCTAssertFalse(
            YaxiService.erstMitConnectionDataWiederholen(RoutexClientError.InvalidCredentials(userMessage: nil)))
        XCTAssertFalse(
            YaxiService.erstMitConnectionDataWiederholen(URLError(.timedOut)))
    }
}
