import XCTest
import RoutexClient
@testable import simplebanking

/// Die Flagge in der Bankenliste kommt aus `ConnectionInfo.countries`, nicht
/// aus dem Namen. Bis 2.2.2 wurde sie geraten, und das hat am 14.11.2026 einen
/// Nutzer eine Einrichtung gekostet: Die süddeutsche Zweigniederlassung der
/// Raiffeisenlandesbank Oberösterreich traf dasselbe Namensmuster wie das
/// österreichische Haus, also trugen beide Einträge dieselbe falsche Flagge.
final class BankCountryResolverTests: XCTestCase {

    private func flagge(_ codes: String...) -> String {
        BankCountryResolver.flagge(fuer: codes.map { CountryCode($0) })
    }

    func test_einLandGibtSeineFlagge() {
        XCTAssertEqual(flagge("DE"), "🇩🇪")
        XCTAssertEqual(flagge("AT"), "🇦🇹")
        XCTAssertEqual(flagge("ES"), "🇪🇸")
    }

    /// Portugal trug unter der Heuristik eine deutsche Flagge, weil der Name
    /// kein Muster traf und alles Unbekannte als deutsch galt. YAXI führt dort
    /// 22 Verbindungen.
    func test_portugalWarDerStilleFehlerDerHeuristik() {
        XCTAssertEqual(flagge("PT"), "🇵🇹")
    }

    /// Der Fall, um den es ging: zwei Häuser derselben Bank, zwei Länder, und
    /// der Name hilft bei keinem von beiden.
    func test_zweiNiederlassungenDerselbenBankSindUnterscheidbar() {
        XCTAssertNotEqual(flagge("DE"), flagge("AT"))
    }

    /// Kleinschreibung vom Server darf nicht zum Globus führen.
    func test_kleingeschriebenerCodeZaehltAuch() {
        XCTAssertEqual(flagge("de"), "🇩🇪")
    }

    /// Mehrere Länder sind keine Aussage über eines. Revolut führt eine lange
    /// Liste; eine davon zu zeigen wäre geraten, und genau das sollte weg.
    func test_mehrereLaenderGebenDenGlobus() {
        XCTAssertEqual(flagge("DE", "AT", "ES"), BankCountryResolver.globus)
    }

    func test_keinLandGibtDenGlobus() {
        XCTAssertEqual(BankCountryResolver.flagge(fuer: []), BankCountryResolver.globus)
    }

    /// Das SDK prüft den Code nicht gegen die ISO-Liste, damit alte Server
    /// durchlaufen. Hier kann also alles ankommen.
    func test_unsinnigerCodeGibtDenGlobus() {
        XCTAssertEqual(flagge("D"), BankCountryResolver.globus)
        XCTAssertEqual(flagge("DEU"), BankCountryResolver.globus)
        XCTAssertEqual(flagge("12"), BankCountryResolver.globus)
        XCTAssertEqual(flagge(""), BankCountryResolver.globus)
    }
}
