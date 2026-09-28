import XCTest
@testable import simplebanking

/// Gemeldet am 28.09.2026: Bei zwei Konten stand statt des Bank-Logos ein Buchstabe.
/// Der Buchstabe ist das Monogramm-Ersatzbild und erscheint nur, wenn `resolve` gar
/// nichts findet.
///
/// `resolve` prüft drei Merkmale der Reihe nach — logoID, Anzeigename, IBAN. Wer nur
/// eines übergibt, verschenkt die anderen beiden. Genau das tat `DashboardView`: Es
/// fragte allein mit dem Namen, und für eine Bank, deren Name kein bekanntes Stichwort
/// enthält, blieb das Logo weg, obwohl die Bankleitzahl es verraten hätte.
///
/// Diese Tests halten fest, was jedes einzelne Merkmal leisten kann.
final class BankLogoMerkmaleTests: XCTestCase {

    /// Beispiel-IBAN mit der Bankleitzahl der Hamburger Sparkasse. Die Kontonummer ist
    /// erfunden; für die Erkennung zählen nur die Stellen 5 bis 12.
    private let haspaIBAN = "DE00200505500000000000"

    // MARK: - Was der Name allein leistet

    func test_name_erkenntSparkasseUeberDasStichwort() {
        XCTAssertEqual(BankLogoAssets.find(byName: "Hamburger Sparkasse")?.id, "sparkasse")
        XCTAssertEqual(BankLogoAssets.find(byName: "HASPA")?.id, "sparkasse")
    }

    /// Der Fall, der den Fehler sichtbar machte: ein Name ohne jedes Stichwort.
    func test_nameOhneStichwort_findetNichts() {
        XCTAssertNil(BankLogoAssets.find(byName: "Mein Konto"))
    }

    // MARK: - Was die Bankleitzahl leistet

    func test_bankleitzahl_erkenntSparkasseAnDerViertenStelle() {
        XCTAssertEqual(BankLogoAssets.find(byIBAN: haspaIBAN)?.id, "sparkasse")
    }

    func test_bankleitzahl_erkenntVolksbank() {
        // Vierte Stelle 6 oder 9 → Volks- und Raiffeisenbanken.
        XCTAssertEqual(BankLogoAssets.find(byIBAN: "DE00300600100000000000")?.id, "volksbank")
        XCTAssertEqual(BankLogoAssets.find(byIBAN: "DE00300900000000000000")?.id, "volksbank")
    }

    // MARK: - Der gemeldete Fall

    /// Nur mit dem Namen: nichts. Mit der IBAN dazu: die Marke. Das ist der Unterschied,
    /// den `DashboardView` verschenkt hat.
    func test_nurName_bleibtLeer_mitIbanNicht() {
        XCTAssertNil(BankLogoAssets.resolve(displayName: "Mein Konto", logoID: nil, iban: nil),
                     "Ohne Stichwort im Namen und ohne IBAN kann nichts gefunden werden — "
                     + "in der Ansicht erscheint dann der Buchstabe.")

        XCTAssertEqual(BankLogoAssets.resolve(displayName: "Mein Konto",
                                              logoID: nil,
                                              iban: haspaIBAN)?.id,
                       "sparkasse")
    }

    /// Reihenfolge: Die logoID hat Vorrang vor allem anderen.
    func test_logoIdSchlaegtNameUndIban() {
        let marke = BankLogoAssets.resolve(displayName: "Mein Konto",
                                           logoID: "commerzbank",
                                           iban: haspaIBAN)
        XCTAssertEqual(marke?.id, "commerzbank")
    }

    /// Ein eigenes HASPA-Logo führt der Katalog nicht; das rote Sparkassen-S ist das
    /// richtige Ergebnis, nicht ein Notbehelf.
    func test_keinEigenesHaspaLogoImKatalog() {
        XCTAssertFalse(BankLogoCatalog.availableLogoIds.contains("haspa"))
        XCTAssertTrue(BankLogoCatalog.availableLogoIds.contains("sparkasse"))
    }

    // MARK: - Der eigentliche Befund: die Hamburger Vorwahl

    /// comdirect sitzt in Hamburg und trug die Vorwahl `200`. Die fing jede Hamburger
    /// Bank mit ein — daher das „C" auf den Sparkassenkonten.
    func test_hamburgerVorwahl_ueberschreibtDieGruppeNichtMehr() {
        // HASPA: 200 505 50 → vierte Stelle 5 → Sparkasse, nicht comdirect.
        XCTAssertEqual(BankLogoAssets.find(byIBAN: "DE00200505500000000000")?.id, "sparkasse")
        // Hamburger Volksbank: 201 900 03 → vierte Stelle 9 → Volksbank.
        XCTAssertEqual(BankLogoAssets.find(byIBAN: "DE00201900030000000000")?.id, "volksbank")
    }

    /// Gegenprobe: comdirect selbst muss die Vorwahl weiterhin bekommen. Ihre vierte
    /// Stelle ist 1, die Gruppenregel greift also nicht und die Vorwahl bleibt zuständig.
    func test_comdirectBehaeltSeineVorwahl() {
        XCTAssertEqual(BankLogoAssets.find(byIBAN: "DE00200411440000000000")?.id, "comdirect")
    }
}
