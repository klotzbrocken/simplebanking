import XCTest
@testable import simplebanking

// MARK: - Kontoauswahl von Verfahrensauswahl unterscheiden
//
// Audit-Befund vom 05.09.2026: Der `.selection`-Zweig beantwortet jede Auswahl selbst,
// mit einer Heuristik für TAN-Verfahren. Fragt die Bank nach dem Konto, wählt sie blind.
// Seit die App `debtorAccount` benennt, sollte das nicht mehr auftreten — die Erkennung
// hier sorgt dafür, dass es im Protokoll steht, falls doch.

final class AuswahlartTests: XCTestCase {

    func test_ibanWirdErkannt() {
        XCTAssertTrue(Auswahlart.enthaeltIban("DE89370400440532013000"))
        XCTAssertTrue(Auswahlart.enthaeltIban("NL20BUNQ2029400129"))
    }

    /// Banken schreiben IBANs oft in Vierergruppen.
    func test_ibanMitLeerzeichenWirdErkannt() {
        XCTAssertTrue(Auswahlart.enthaeltIban("DE89 3704 0044 0532 0130 00"))
    }

    /// Der eigentliche Zweck: eingebettet in einen Beschriftungstext.
    func test_ibanImFliesstextWirdErkannt() {
        XCTAssertTrue(Auswahlart.enthaeltIban("Girokonto DE89 3704 0044 0532 0130 00 (Hauptkonto)"))
    }

    /// Die Gegenprobe, auf die es ankommt: TAN-Verfahren dürfen NICHT als Konten
    /// gelten, sonst stünde die Warnung bei jeder gewöhnlichen Freigabe im Protokoll
    /// und wäre wertlos.
    func test_tanVerfahrenSindKeineKonten() {
        let verfahren = [
            "pushtan pushTAN-App Bestätigung in der S-App",
            "chiptan chipTAN QR Mit Ihrem TAN-Generator",
            "smstan SMS-TAN An Ihre hinterlegte Mobilnummer",
            "decoupled App-Freigabe Bestätigen Sie in Ihrer Banking-App",
        ]
        XCTAssertFalse(Auswahlart.sindKonten(verfahren))
    }

    func test_kontoauswahlWirdErkannt() {
        let konten = [
            "acc1 Girokonto DE89 3704 0044 0532 0130 00",
            "acc2 Tagesgeld DE02 1203 0000 0000 2020 51",
        ]
        XCTAssertTrue(Auswahlart.sindKonten(konten))
    }

    /// Kurze Zeichenketten mit Buchstaben und Ziffern sind keine IBAN — ohne die
    /// Mindestlänge träfe die Erkennung auf fast jeden Verfahrensschlüssel zu.
    func test_kurzeKennungenSindKeineIban() {
        XCTAssertFalse(Auswahlart.enthaeltIban("TAN12"))
        XCTAssertFalse(Auswahlart.enthaeltIban("DE01"))
        XCTAssertFalse(Auswahlart.sindKonten([]))
    }
}

// MARK: - Quellkonto der Überweisung
//
// Audit-Befund: Alle drei transfer-Aufrufe gaben `debtorAccount: nil` mit. Die SDK-Doku
// sagt dazu „the bank prompts the user when omitted" — und diese Rückfrage beantwortete
// die App selbst. Geprüft wird hier die Abbildung; dass der Auftrag die IBAN dann auch
// über die Leitung trägt, übernimmt das SDK.

final class QuellkontoTests: XCTestCase {

    func test_hinterlegteIbanWirdUebernommen() {
        XCTAssertEqual(Quellkonto.iban(ausGespeicherter: "DE89370400440532013000"),
                       "DE89370400440532013000")
    }

    /// Gespeicherte IBANs stehen oft in Vierergruppen; die Bank erwartet sie kompakt.
    func test_leerzeichenWerdenEntfernt() {
        XCTAssertEqual(Quellkonto.iban(ausGespeicherter: "DE89 3704 0044 0532 0130 00"),
                       "DE89370400440532013000")
    }

    func test_kleinschreibungWirdVereinheitlicht() {
        XCTAssertEqual(Quellkonto.iban(ausGespeicherter: "nl20bunq2029400129"),
                       "NL20BUNQ2029400129")
    }

    /// Ohne hinterlegte IBAN bleibt es beim bisherigen Verhalten. Eine geratene IBAN
    /// wäre schlimmer als die Rückfrage der Bank.
    func test_ohneIbanKeinQuellkonto() {
        XCTAssertNil(Quellkonto.iban(ausGespeicherter: nil))
        XCTAssertNil(Quellkonto.iban(ausGespeicherter: ""))
        XCTAssertNil(Quellkonto.iban(ausGespeicherter: "   "))
    }

    func test_waehrungIstEuroWieDerBetrag() {
        XCTAssertEqual(Quellkonto.waehrung, "EUR")
    }
}
