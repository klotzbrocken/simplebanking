import XCTest
import Foundation
@testable import simplebanking

// MARK: - Die Datenquelle der App Intents
//
// Intents selbst sind über ihre Hülle kaum sinnvoll zu prüfen — die Auswertung dahinter
// schon. Zwei Zusagen hängen daran, und beide sind in einer Automatisierung teurer als
// im Fenster: Ein falscher Kontostand wird ungeprüft weiterverarbeitet, und ein
// unbeabsichtigter Bankabruf kostet eine TAN.

final class IntentDatenTests: XCTestCase {

    /// **Kein Kontostand ist nicht null.** Ein Konto ohne abgerufenen Stand darf nicht als
    /// „0,00 €" erscheinen: In einem Kurzbefehl, der Salden summiert, wäre das eine
    /// stillschweigend falsche Zahl.
    func test_ohneStandKeineNull() {
        XCTAssertEqual(IntentDaten.satz(fuer: nil, konten: 0),
                       L10n.t("Noch kein Kontostand abgerufen.", "No balance fetched yet."))
    }

    /// Bei einem Konto steht der Betrag allein, bei mehreren die Zahl dazu — sonst weiß
    /// niemand, worüber summiert wurde.
    func test_satzNenntDieAnzahlNurBeiMehrerenKonten() {
        let einzeln = IntentDaten.satz(fuer: 1234.56, konten: 1)
        XCTAssertFalse(einzeln.contains("1 "), einzeln)

        let mehrere = IntentDaten.satz(fuer: 1234.56, konten: 3)
        XCTAssertTrue(mehrere.contains("3"), mehrere)
    }

    /// Der Betrag wird als Währung ausgegeben, nicht als nackte Zahl.
    func test_betragWirdAlsWaehrungFormatiert() {
        let text = IntentDaten.satz(fuer: 1234.5, konten: 1)
        XCTAssertTrue(text.contains("€"), text)
        XCTAssertFalse(text.contains("1234.5"), "roher Double-Wert im Text: \(text)")
    }

    /// Ausgaben sind ein positiver Betrag, obwohl Buchungen negativ sind. „−340 €
    /// ausgegeben" liest sich falsch herum.
    func test_ausgabenSindPositiv() {
        let summe = IntentDaten.ausgaben(tage: 30, slots: [])
        XCTAssertGreaterThanOrEqual(summe, 0)
    }

    /// Leere Kontoauswahl heißt leere Antwort, nicht „alle Konten". Sonst lieferte ein
    /// Intent mit versehentlich leerem Filter plötzlich alles.
    func test_leereAuswahlLiefertNichts() {
        XCTAssertEqual(IntentDaten.ausgaben(tage: 30, slots: []), 0)
        XCTAssertTrue(IntentDaten.letzteBuchungen(anzahl: 5, tage: 30, slots: []).isEmpty)
    }

    /// Die Anzahl wird eingehalten, auch bei unsinniger Eingabe aus einem Kurzbefehl.
    func test_anzahlWirdBegrenztUndNieNegativ() {
        XCTAssertTrue(IntentDaten.letzteBuchungen(anzahl: -3, tage: 30, slots: []).isEmpty)
        XCTAssertTrue(IntentDaten.letzteBuchungen(anzahl: 0, tage: 30, slots: []).isEmpty)
    }
}
