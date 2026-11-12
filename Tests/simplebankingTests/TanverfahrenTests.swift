import XCTest
@testable import simplebanking

/// Welches TAN-Verfahren die App beantwortet — und dass die Wahl des Nutzers vorgeht.
final class TanverfahrenTests: XCTestCase {

    private let angebote = [
        Tanverfahren.Angebot(schluessel: "M1", beschriftung: "chipTAN QR"),
        Tanverfahren.Angebot(schluessel: "M2", beschriftung: "S-pushTAN"),
    ]

    // MARK: - Ohne Einstellung bleibt es bei der bisherigen Heuristik

    func testOhneEinstellungGewinntDiePushFreigabe() {
        XCTAssertEqual(
            Tanverfahren.wahl(aus: angebote, gespeicherterSchluessel: nil, gespeicherterName: nil)?.schluessel,
            "M2")
    }

    func testOhneStichwortDerErsteEintrag() {
        let ohnePush = [
            Tanverfahren.Angebot(schluessel: "M1", beschriftung: "chipTAN QR"),
            Tanverfahren.Angebot(schluessel: "M9", beschriftung: "smsTAN"),
        ]
        XCTAssertEqual(
            Tanverfahren.wahl(aus: ohnePush, gespeicherterSchluessel: nil, gespeicherterName: nil)?.schluessel,
            "M1")
    }

    /// Das Stichwort darf auch in der Erläuterung stehen — manche Banken führen die
    /// Bezeichnung nur dort.
    func testStichwortAuchInDerErlaeuterung() {
        let mitErklaerung = [
            Tanverfahren.Angebot(schluessel: "M1", beschriftung: "chipTAN QR"),
            Tanverfahren.Angebot(schluessel: "M7", beschriftung: "Verfahren 7",
                                 erklaerung: "Freigabe in der Banking-App"),
        ]
        XCTAssertEqual(
            Tanverfahren.wahl(aus: mitErklaerung, gespeicherterSchluessel: nil, gespeicherterName: nil)?.schluessel,
            "M7")
    }

    func testKeineAngeboteKeineWahl() {
        XCTAssertNil(Tanverfahren.wahl(aus: [], gespeicherterSchluessel: "M1", gespeicherterName: "chipTAN QR"))
    }

    // MARK: - Mit Einstellung

    /// Der Kern der Meldung: Wer chipTAN einstellt, bekommt chipTAN — nicht pushTAN,
    /// weil die Heuristik es für bequemer hält.
    func testGespeicherterSchluesselSchlaegtDieHeuristik() {
        XCTAssertEqual(
            Tanverfahren.wahl(aus: angebote, gespeicherterSchluessel: "M1", gespeicherterName: "chipTAN QR")?.schluessel,
            "M1")
    }

    /// Ändert die Bank ihre Schlüssel, trägt die Beschriftung die Wahl weiter.
    func testBeiFremdemSchluesselEntscheidetDieBeschriftung() {
        XCTAssertEqual(
            Tanverfahren.wahl(aus: angebote, gespeicherterSchluessel: "ALT", gespeicherterName: "chiptan qr")?.schluessel,
            "M1")
    }

    /// Passt weder Schlüssel noch Beschriftung, rät die App wie früher weiter. Eine
    /// Einrichtung, die nach einem Bank-Update klemmt, wäre schlimmer.
    func testUnbekannteEinstellungFaelltStillZurueck() {
        XCTAssertEqual(
            Tanverfahren.wahl(aus: angebote, gespeicherterSchluessel: "ALT", gespeicherterName: "photoTAN")?.schluessel,
            "M2")
    }

    // MARK: - Reihenfolge in den Einstellungen

    func testSortiertNachBeschriftungUnabhaengigVomWoerterbuch() {
        let sortiert = Tanverfahren.sortiert(["M2": "S-pushTAN", "M1": "chipTAN QR"])
        XCTAssertEqual(sortiert.map(\.beschriftung), ["chipTAN QR", "S-pushTAN"])
        XCTAssertEqual(sortiert.map(\.schluessel), ["M1", "M2"])
    }
}

/// Das gewählte Verfahren muss ein Programmneustart überleben. `BankSlotSettings` hat
/// einen handgeschriebenen Decoder — ein dort vergessenes Feld wird gespeichert und nie
/// gelesen, ohne Fehler und ohne Warnung (die Datei sagt es selbst: „stille Amnesie").
final class TanverfahrenSpeicherTests: XCTestCase {

    func testVerfahrenUndAngeboteUeberlebenEinenNeustart() throws {
        var einstellungen = BankSlotSettings()
        einstellungen.tanVerfahrenSchluessel = "M1"
        einstellungen.tanVerfahrenName = "chipTAN QR"
        einstellungen.tanVerfahrenAngebote = ["M1": "chipTAN QR", "M2": "S-pushTAN"]

        let daten = try JSONEncoder().encode(einstellungen)
        let gelesen = try JSONDecoder().decode(BankSlotSettings.self, from: daten)

        XCTAssertEqual(gelesen.tanVerfahrenSchluessel, "M1")
        XCTAssertEqual(gelesen.tanVerfahrenName, "chipTAN QR")
        XCTAssertEqual(gelesen.tanVerfahrenAngebote, ["M1": "chipTAN QR", "M2": "S-pushTAN"])
    }

    /// Einstellungen aus einer älteren Fassung kennen die Felder nicht — das darf das
    /// Dekodieren nicht kosten, sonst wären alle Konto-Einstellungen weg.
    func testAlteEinstellungenOhneDieFelderBleibenLesbar() throws {
        let alt = Data(#"{"salaryDay":5,"fetchDays":60}"#.utf8)
        let gelesen = try JSONDecoder().decode(BankSlotSettings.self, from: alt)

        XCTAssertEqual(gelesen.salaryDay, 5)
        XCTAssertNil(gelesen.tanVerfahrenSchluessel)
        XCTAssertEqual(gelesen.tanVerfahrenAngebote, [:])
    }
}
