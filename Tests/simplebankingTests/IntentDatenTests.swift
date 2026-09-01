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
        XCTAssertEqual(IntentDaten.satz(fuer: [], konten: 0),
                       L10n.t("Noch kein Kontostand abgerufen.", "No balance fetched yet."))
    }

    /// Bei einem Konto steht der Betrag allein, bei mehreren die Zahl dazu — sonst weiß
    /// niemand, worüber summiert wurde.
    func test_satzNenntDieAnzahlNurBeiMehrerenKonten() {
        let einzeln = IntentDaten.satz(fuer: [.init(summe: 1234.56, waehrung: "EUR")], konten: 1)
        XCTAssertFalse(einzeln.contains("1 "), einzeln)

        let mehrere = IntentDaten.satz(fuer: [.init(summe: 1234.56, waehrung: "EUR")], konten: 3)
        XCTAssertTrue(mehrere.contains("3"), mehrere)
    }

    /// Der Betrag wird als Währung ausgegeben, nicht als nackte Zahl.
    func test_betragWirdAlsWaehrungFormatiert() {
        let text = IntentDaten.satz(fuer: [.init(summe: 1234.5, waehrung: "EUR")], konten: 1)
        XCTAssertTrue(text.contains("€"), text)
        XCTAssertFalse(text.contains("1234.5"), "roher Double-Wert im Text: \(text)")
    }

    /// Ausgaben sind ein positiver Betrag, obwohl Buchungen negativ sind. „−340 €
    /// ausgegeben" liest sich falsch herum.
    func test_ausgabenSindPositiv() {
        for posten in IntentDaten.ausgaben(tage: 30, slots: []) {
            XCTAssertGreaterThanOrEqual(posten.summe, 0)
        }
    }

    /// Leere Kontoauswahl heißt leere Antwort, nicht „alle Konten". Sonst lieferte ein
    /// Intent mit versehentlich leerem Filter plötzlich alles.
    func test_leereAuswahlLiefertNichts() {
        XCTAssertTrue(IntentDaten.ausgaben(tage: 30, slots: []).isEmpty)
        XCTAssertTrue(IntentDaten.letzteBuchungen(anzahl: 5, tage: 30, slots: []).isEmpty)
    }

    /// Die Anzahl wird eingehalten, auch bei unsinniger Eingabe aus einem Kurzbefehl.
    ///
    /// **Mit vorhandenen Buchungen geprüft.** Die frühere Fassung dieses Tests rief
    /// `slots: []` auf — eine leere Auswahl liefert aber immer nichts, wie der Test
    /// darüber selbst festhält. Er konnte deshalb gar nicht fehlschlagen und blieb auch
    /// dann grün, als die Umsetzung mit `max(1, anzahl)` bei 0 eine Buchung zurückgab.
    func test_anzahlWirdBegrenztUndNieNegativ() throws {
        let slots = try mitDemoBuchungen()

        XCTAssertTrue(IntentDaten.letzteBuchungen(anzahl: 0, tage: jahre, slots: slots).isEmpty)
        XCTAssertTrue(IntentDaten.letzteBuchungen(anzahl: -3, tage: jahre, slots: slots).isEmpty)
    }

    /// Gegenprobe: Ohne sie wäre der Test darüber auch mit einer Umsetzung grün, die
    /// grundsätzlich nichts zurückgibt.
    func test_anzahlSchneidetAufDieGewuenschteMengeZu() throws {
        let slots = try mitDemoBuchungen()

        XCTAssertGreaterThan(IntentDaten.letzteBuchungen(anzahl: 99, tage: jahre, slots: slots).count, 2,
                             "Vorbedingung: die Demo-Datenbank muss mehr als zwei Buchungen haben")
        XCTAssertEqual(IntentDaten.letzteBuchungen(anzahl: 2, tage: jahre, slots: slots).count, 2)
        XCTAssertEqual(IntentDaten.letzteBuchungen(anzahl: 1, tage: jahre, slots: slots).count, 1)
    }

    // MARK: - Aufbau

    /// Weit genug gefasst, dass der Tagesfilter das Ergebnis nicht mitbestimmt.
    private let jahre = 3650

    /// Legt die Demo-Datenbank an und schaltet `IntentDaten` darauf um. Ohne den
    /// Demo-Schalter läse die Auswertung die echte Datenbank des Rechners.
    private func mitDemoBuchungen() throws -> [String] {
        let slots = ["demo-slot-0", "demo-slot-1", "demo-slot-2"]
        try? FileManager.default.removeItem(at: TransactionsDatabase.databaseURL(bankId: "demo"))
        TransactionsDatabase.writeDemoDB(seed: 4711, slotIds: slots)
        UserDefaults.standard.set(true, forKey: "demoMode")
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "demoMode")
            try? FileManager.default.removeItem(
                at: TransactionsDatabase.databaseURL(bankId: "demo"))
        }
        return slots
    }
}
