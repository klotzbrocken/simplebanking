import XCTest
@testable import simplebanking

/// Parser-Tests gegen echte REWE-eBon-Texte (PDFKit/pdftotext), Phase-0-verifiziert.
final class ReweReceiptParserTests: XCTestCase {

    func test_realReceipt_12items_sumMatchesTotal() {
        let text = """
        Friedhelm Dornseifer GmbH & Co.KG
        Leimbachstrasse 17
        57074 Siegen
        EUR
        VEG.SPICKER                       1,59 B
        VEG SALAMI                        1,59 B
        SANLUCAR HEIDELB                  3,99 B
        NEKTARINE GELB                    2,11 B
        0,530 kg x  3,99 EUR/kg
        KIWI GOLD                         0,99 B
        AVOCADO SAN LUCA                  3,49 B
        ZUCCHINI BIO                      2,79 B
        CLASSIC PAPRIKA                   1,79 B
        HOT & SPICY                       1,79 B
        SNYDERS PIECES                    2,29 B
        WUNDERLICH POPCO                  3,99 B
        FRUCHTG.ASSORTIE                  1,49 B
        SUMME                   EUR      27,90
        """
        let r = ReweReceiptParser.parse(text)
        XCTAssertEqual(r.totalCents, 2790)
        XCTAssertEqual(r.items.count, 12)
        XCTAssertEqual(r.items.reduce(0) { $0 + $1.totalCents }, 2790)
        // Gewichtszeile gehört zum vorherigen Artikel (NEKTARINE GELB).
        XCTAssertEqual(r.items.first { $0.name == "NEKTARINE GELB" }?.quantity?.contains("kg"), true)
    }

    func test_realReceipt_withPfandAndStk_19items() {
        let text = """
        Friedhelm Dornseifer GmbH & Co.KG
        EUR
        SCHINKENW. OFFEN 2,12 B
        KALBS-LEBERWURST 2,09 B
        BEEF JERKY ORIG 4,99 B
        BAERLAUCHCREME 2,89 B
        HUMMUS MAN.CURR. 1,69 B
        KARTOFFELSUPPE 3,99 B
        VEG POMMERSCHE 2,49 B
        WASSERMEL.VIERTE 2,80 B
        SAN LUCAR ORANGE 3,72 B
        0,828 kg x 4,49 EUR/kg
        AVOCADO FEINE W. 3,09 B
        KART.VF.BIO 2,59 B
        PIZZA TAKEOVER 4,99 B
        HOT & SPICY 1,89 B
        PRETZELS HO.SENF 1,29 B
        PAULANER OM HELL 2,38 A
        2 Stk x 1,19
        PFAND 0,25 EURO 0,50 A *
        2 Stk x 0,25
        RB R.BETE SAFT 0,95 A
        SCAVI&RAY PROSEC 7,99 A
        TRAGETASCHE PAPI 0,30 A
        SUMME EUR 52,75
        """
        let r = ReweReceiptParser.parse(text)
        XCTAssertEqual(r.totalCents, 5275)
        XCTAssertEqual(r.items.count, 19)
        XCTAssertEqual(r.items.reduce(0) { $0 + $1.totalCents }, 5275,
                       "Σ Artikel muss die Bon-Summe treffen (inkl. Pfand)")
        // Pfand-Zeile trotz angehängtem '*' korrekt erfasst.
        XCTAssertTrue(r.items.contains { $0.name.contains("PFAND") && $0.totalCents == 50 })
    }

    func test_footerLinesAreNotMistakenForItems() {
        let text = """
        EUR
        APFEL 1,00 B
        SUMME EUR 1,00
        Geg. Maestro EUR 1,00
        B= 7,0% 0,93 0,07 1,00
        Gesamtbetrag 0,93 0,07 1,00
        """
        let r = ReweReceiptParser.parse(text)
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(r.items.first?.name, "APFEL")
        XCTAssertEqual(r.totalCents, 100)
    }
}
