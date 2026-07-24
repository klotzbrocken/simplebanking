import XCTest
@testable import simplebanking

// MARK: - TransferClipboardParser Tests
//
// Reine Parser-Tests: erkennt Name/IBAN/Betrag/Verwendungszweck aus einem
// zusammenhängend kopierten Block (bzw. später OCR-Text). Kein Pasteboard nötig.

final class TransferClipboardParserTests: XCTestCase {

    // Gültige DE-IBAN (mod-97): DE89 3704 0044 0532 0130 00
    private let iban = "DE89370400440532013000"

    func test_labelledBlock_allFields() {
        let text = """
        Empfänger: Max Mustermann
        IBAN: DE89 3704 0044 0532 0130 00
        Betrag: 1.234,56 EUR
        Verwendungszweck: Rechnung 2026-001
        """
        let p = TransferClipboardParser.parse(text)
        XCTAssertEqual(p.name, "Max Mustermann")
        XCTAssertEqual(p.iban, iban)
        XCTAssertEqual(p.amount, "1234,56")
        XCTAssertEqual(p.purpose, "Rechnung 2026-001")
        XCTAssertTrue(p.isUseful)
    }

    func test_unlabelledBlock_nameAmountIban() {
        let text = """
        Fliegenfranz GmbH
        DE89 3704 0044 0532 0130 00
        42,50 €
        """
        let p = TransferClipboardParser.parse(text)
        XCTAssertEqual(p.name, "Fliegenfranz GmbH")
        XCTAssertEqual(p.iban, iban)
        XCTAssertEqual(p.amount, "42,50")
    }

    /// Regression: Stoppwörter dürfen nur an Wortgrenzen greifen. „M-ust-ermann"
    /// enthält „ust" (USt-ID) und „Musterbank" enthält „bank" — beides sind Namen.
    func test_unlabelledName_withStopwordSubstring() {
        let text = """
        Max Mustermann
        DE89 3704 0044 0532 0130 00
        42,50 €
        Verwendungszweck: Rechnung 2026-001
        """
        let p = TransferClipboardParser.parse(text)
        XCTAssertEqual(p.name, "Max Mustermann")
        XCTAssertEqual(p.iban, iban)
        XCTAssertEqual(p.amount, "42,50")
        XCTAssertEqual(p.purpose, "Rechnung 2026-001")
    }

    func test_stopwordsStillRejectBankAndGreetingLines() {
        XCTAssertNil(TransferClipboardParser.parse("Sparkasse Siegen IBAN DE89370400440532013000 BIC TESTDEFFXXX").name)
    }

    func test_englishLabels_andDotDecimal() {
        let text = """
        Payee: ACME Ltd
        IBAN DE89370400440532013000
        Amount: 1,234.50 EUR
        Reference: INV-77
        """
        let p = TransferClipboardParser.parse(text)
        XCTAssertEqual(p.name, "ACME Ltd")
        XCTAssertEqual(p.amount, "1234,50")
        XCTAssertEqual(p.purpose, "INV-77")
    }

    func test_ibanOnly_isUseful() {
        let p = TransferClipboardParser.parse("Bitte überweisen an DE89 3704 0044 0532 0130 00")
        XCTAssertEqual(p.iban, iban)
        XCTAssertTrue(p.isUseful)
    }

    func test_invalidIban_isIgnored() {
        // Falsche Prüfsumme → keine IBAN.
        let p = TransferClipboardParser.parse("IBAN: DE00 3704 0044 0532 0130 00")
        XCTAssertNil(p.iban)
    }

    func test_emptyText() {
        let p = TransferClipboardParser.parse("   \n  \n")
        XCTAssertTrue(p.isEmpty)
        XCTAssertFalse(p.isUseful)
    }

    // MARK: Betrag-Normalisierung

    func test_normalizeAmount_variants() {
        XCTAssertEqual(TransferClipboardParser.normalizeAmount("1.234,56"), "1234,56")
        XCTAssertEqual(TransferClipboardParser.normalizeAmount("1,234.56"), "1234,56")
        XCTAssertEqual(TransferClipboardParser.normalizeAmount("42"), "42")
        XCTAssertEqual(TransferClipboardParser.normalizeAmount("42,5"), "42,50")
        XCTAssertNil(TransferClipboardParser.normalizeAmount("0"))
        XCTAssertNil(TransferClipboardParser.normalizeAmount("abc"))
    }

    /// Echte Rechnungsstruktur (Daten erfunden): Adressblock des ZAHLERS oben,
    /// Positionszeilen mit Einzelpreisen, Gesamtbetrag ohne Doppelpunkt, Bankzeile
    /// und Signatur unten. Erwartet: Empfänger = Kontoinhaber bei der IBAN (Signatur),
    /// Betrag = Gesamtbetrag (nicht der Kilometersatz aus der Positionszeile).
    func test_invoiceLayout_picksPayeeAndTotal() {
        let text = """
        Erika Beispiel - Musterweg 10 - 12345 Musterstadt - Steuernummer 123/4567/8901
        Beispiel Service GmbH & Co. KG
        Philip Muster
        Am Testgraben 115
        70565 Teststadt
        E-Mail: erika@example.com
        Sonntag, 21.06.2026
        Rechnung Nr.: 011-Juni-26
        Pos. Menge Artikelname Datum Entgelt (Euro)
        1 1 Vortrag inkl. Vorbereitung 17.06.26 1500
        2 1 Fahrkosten, 280 km x 0,40 EUR 17.06.26 112
        Rechnungsbetrag 1.612
        Musterbank IBAN DE89370400440532013000 BIC TESTDEFFXXX
        Mit besten Grüßen,
        Erika Beispiel
        """
        let p = TransferClipboardParser.parse(text)
        XCTAssertEqual(p.iban, iban)
        XCTAssertEqual(p.amount, "1612", "Gesamtbetrag muss den Positionspreis 0,40 schlagen")
        XCTAssertEqual(p.name, "Erika Beispiel", "Empfänger ist der Kontoinhaber, nicht der Adressat")
    }

    func test_ibanSurroundedByBankAndBic() {
        // Greedy-Regex darf die IBAN zwischen Bankname und BIC nicht verlieren.
        let p = TransferClipboardParser.parse("Musterbank IBAN DE89370400440532013000 BIC TESTDEFFXXX")
        XCTAssertEqual(p.iban, iban)
    }

    // MARK: - Muster aus echten Rechnungen (Struktur übernommen, Daten erfunden)

    /// „Kontoinhaber:" enthält oft die komplette Bankzeile — nur der Inhaber ist der Name.
    func test_accountHolderLabel_trimsBankBlob() {
        let text = """
        Zahlungsempfänger
        Kontoinhaber:. Muster Finance GmbH - Commerzbank AG Hagen . BIC: COBADEFFXXX - IBAN: DE89 3704 0044 0532 0130 00
        Rechnungsbetrag 90,44
        """
        let p = TransferClipboardParser.parse(text)
        XCTAssertEqual(p.name, "Muster Finance GmbH")
        XCTAssertEqual(p.amount, "90,44")
    }

    /// PDF-Tabellen trennen Label und Wert auf eigene Zeilen.
    func test_totalLabelOnSeparateLine() {
        let text = """
        Musterpraxis Dr. Beispiel
        Rechnungsbetrag:
        120,93 EUR
        IBAN DE89 3704 0044 0532 0130 00
        """
        let p = TransferClipboardParser.parse(text)
        XCTAssertEqual(p.amount, "120,93")
        XCTAssertEqual(p.iban, iban)
    }

    /// Nummern dürfen nie als Betrag durchgehen: PLZ, Kunden-/Rechnungsnummern.
    func test_numbersAreNotAmounts() {
        let text = """
        Musterfirma GmbH
        Musterweg 3
        57072 Musterstadt
        Kundennummer 803226979
        IBAN DE89 3704 0044 0532 0130 00
        """
        let p = TransferClipboardParser.parse(text)
        XCTAssertNil(p.amount, "PLZ/Kundennummer dürfen kein Betrag sein")
    }

    /// Mehrere „…betrag"-Zeilen (Zwischensummen): der Gesamtbetrag ist der größte.
    func test_multipleTotalMarkers_takesLargest() {
        let text = """
        Musterkanzlei mbB
        Zwischenbetrag 20,00
        Restbetrag 354,00
        IBAN DE89 3704 0044 0532 0130 00
        """
        XCTAssertEqual(TransferClipboardParser.parse(text).amount, "354,00")
    }

    /// Der Adressblock (Zahler) darf den Empfänger nie verdrängen — maßgeblich ist,
    /// wem die IBAN gehört (Signatur/Kontoinhaber).
    func test_addresseeDoesNotWinOverPayee() {
        let text = """
        Erika Beispiel - Musterweg 10 - 12345 Musterstadt - Steuernummer 123/4567/8901
        Beispiel Service GmbH & Co. KG
        Philip Muster
        Am Testgraben 115
        Rechnungsbetrag 1.612
        Musterbank IBAN DE89370400440532013000 BIC TESTDEFFXXX
        Mit besten Grüßen,
        Erika Beispiel
        """
        XCTAssertEqual(TransferClipboardParser.parse(text).name, "Erika Beispiel")
    }

    func test_amountPrefersDecimalToken() {
        // Rechnungsnummer (ganzzahlig) darf den echten Betrag nicht verdrängen.
        XCTAssertEqual(TransferClipboardParser.amount(in: "Rechnung 2026 über 89,90 EUR"), "89,90")
    }
}
