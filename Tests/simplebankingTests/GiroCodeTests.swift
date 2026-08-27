import XCTest
@testable import simplebanking

// MARK: - Der QR-Code auf der Rechnung
//
// Gemeldet am 27.08.2026 an einer Handwerkerrechnung: Als Empfänger übernahm die App
// „Pos Menge Bezeichnung MwSt. Einheitspreis Gesamt" — die Tabellenüberschrift. Sie steht
// zwei Zeilen unter der IBAN, und genau dort sucht die Namenserkennung.
//
// Auf derselben Rechnung stand ein GiroCode mit Name und IBAN im Klartext. Was dort steht,
// hat der Rechnungssteller eingetragen; alles andere auf dem Blatt muss geraten werden.
// Deshalb hat der Code jetzt Vorrang — und die Heuristik daneben wurde trotzdem
// nachgezogen, weil längst nicht jede Rechnung einen QR-Code trägt.
//
// Die Daten hier sind nachgebaut: gleicher Aufbau, erfundene Namen und IBANs.

final class GiroCodeTests: XCTestCase {

    /// Genau der Aufbau aus der gemeldeten Rechnung: Fassung 001, BIC gesetzt,
    /// Betragszeile `EUR0.0` — also ausdrücklich **kein** Betrag.
    private let nutzlast = """
    BCD
    001
    1
    SCT
    GENODEM1NRD
    SaniTop
    DE02120300000000202051
    EUR0.0
    """

    func test_nameUndIbanKommenAusDemCode() throws {
        let d = try XCTUnwrap(GiroCode.parse(nutzlast))
        XCTAssertEqual(d.name, "SaniTop")
        XCTAssertEqual(d.iban, "DE02120300000000202051")
    }

    /// `EUR0.0` heißt „Betrag offen". Null ins Feld zu schreiben wäre schlimmer, als es
    /// leer zu lassen — im Zweifel überweist jemand null Euro.
    func test_nullBetragIstKeinBetrag() throws {
        let d = try XCTUnwrap(GiroCode.parse(nutzlast))
        XCTAssertNil(d.betrag)
        XCTAssertNil(GiroCode.betrag(aus: "EUR0.00"))
        XCTAssertNil(GiroCode.betrag(aus: "EUR0"))
    }

    func test_betragKommtImDeutschenFormat() {
        XCTAssertEqual(GiroCode.betrag(aus: "EUR123.45"), "123,45")
        XCTAssertEqual(GiroCode.betrag(aus: "EUR7"), "7,00")
        XCTAssertNil(GiroCode.betrag(aus: "USD10.00"), "nur Euro ist im GiroCode zulässig")
        XCTAssertNil(GiroCode.betrag(aus: "keine Zahl"))
    }

    func test_verwendungszweckWirdGelesen() throws {
        let mitZweck = nutzlast + "\n\n\nRechnung RE-1563"
        let d = try XCTUnwrap(GiroCode.parse(mitZweck))
        XCTAssertEqual(d.verwendungszweck, "Rechnung RE-1563")
    }

    /// Ein QR-Code auf einer Rechnung muss keiner sein.
    func test_fremderQrCodeWirdNichtAlsZahlungGelesen() {
        XCTAssertNil(GiroCode.parse("https://example.com/rechnung/1563"))
        XCTAssertNil(GiroCode.parse("BCD\n001\n1\nXXX\n\nName\nDE02120300000000202051"))
        XCTAssertNil(GiroCode.parse("BCD\n001\n1\nSCT\n\nName\nkeine-iban"))
        XCTAssertNil(GiroCode.parse(""))
    }

    // MARK: Zusammenführen mit dem Fließtext

    func test_betragKommtAusDemTextWennDerCodeKeinenHat() throws {
        let ausCode = GiroCode.alsParsed(try XCTUnwrap(GiroCode.parse(nutzlast)))
        let ausText = TransferClipboardParser.Parsed(
            name: "Tabellenkopf", iban: nil, amount: "2.443,74", purpose: "RE-1563")

        let zusammen = GiroCode.ergaenzt(ausCode, mit: ausText)
        XCTAssertEqual(zusammen.name, "SaniTop", "der Name aus dem Code hat Vorrang")
        XCTAssertEqual(zusammen.amount, "2.443,74")
        XCTAssertEqual(zusammen.purpose, "RE-1563")
    }

    /// Nennt der Text eine **andere** IBAN, gehört sein Betrag womöglich zu einer anderen
    /// Zahlung auf demselben Blatt. Dann lieber nichts ergänzen.
    func test_fremdeIbanImTextErgaenztNichts() throws {
        let ausCode = GiroCode.alsParsed(try XCTUnwrap(GiroCode.parse(nutzlast)))
        let ausText = TransferClipboardParser.Parsed(
            name: nil, iban: "DE02100500000054540402", amount: "99,00", purpose: "andere Sache")

        XCTAssertNil(GiroCode.ergaenzt(ausCode, mit: ausText).amount)
    }
}

// MARK: - Die Heuristik ohne QR-Code

final class RechnungsNamenTests: XCTestCase {

    /// Nachgebaut nach der gemeldeten Rechnung: IBAN in der Fußzeile, Tabellenüberschrift
    /// zwei Zeilen darunter, der Firmenname davor in einer Zeile mit „|".
    private let rechnung = """
    Bauer & Sohn Gbr, Hagenerstr. 19, 57489 Musterstadt
    Herr
    Max Mustermann
    Blauwunderstraße 10
    57072 Musterstadt
    Rechnungsnummer RE-1563
    Belegdatum 27.08.2026
    Abschlussrechnung
    RE-1563
    Bauer & Sohn Gbr | Hagenerstr. 19 | 57489 Musterstadt | Geschäftsführer: Nikolaos Bauer
    HRB | USt-IdNr.: DE338420587
    Volksbank | IBAN: DE02120300000000202051 | BIC: GENODEM1NRD
    Seite 1/3
    Pos Menge Bezeichnung MwSt. Einheitspreis Gesamt
    001 1,5 pauschal Silikon-Arbeiten Dusche
    Gesamtbetrag 2.443,74 €
    """

    func test_tabellenkopfWirdNichtAlsEmpfaengerUebernommen() {
        let p = TransferClipboardParser.parse(rechnung)
        XCTAssertNotEqual(p.name, "Pos Menge Bezeichnung MwSt. Einheitspreis Gesamt")
        XCTAssertEqual(p.name, "Bauer & Sohn Gbr",
                       "der Kontoinhaber steht in der Fußzeile vor dem ersten „|“")
    }

    func test_ibanUndBetragBleibenRichtig() {
        let p = TransferClipboardParser.parse(rechnung)
        XCTAssertEqual(p.iban, "DE02120300000000202051")
        XCTAssertEqual(p.amount, "2443,74")
    }

    func test_tabellenkopfErkennung() {
        XCTAssertTrue(TransferClipboardParser.istTabellenkopf("Pos Menge Bezeichnung MwSt. Einheitspreis Gesamt"))
        XCTAssertTrue(TransferClipboardParser.istTabellenkopf("Menge Einheit Preis Gesamt"))
        // Firmennamen dürfen ein Spaltenwort enthalten, ohne zur Überschrift zu werden.
        XCTAssertFalse(TransferClipboardParser.istTabellenkopf("Preis GmbH"))
        XCTAssertFalse(TransferClipboardParser.istTabellenkopf("Menge & Söhne Handels KG"))
        XCTAssertFalse(TransferClipboardParser.istTabellenkopf("Bauer & Sohn Gbr"))
    }
}
