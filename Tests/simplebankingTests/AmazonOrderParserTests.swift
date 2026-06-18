import XCTest
@testable import simplebanking

final class AmazonOrderParserTests: XCTestCase {

    func test_parseAmountCents_variants() {
        XCTAssertEqual(AmazonOrderParser.parseAmountCents("47,99 €"), 4799)
        XCTAssertEqual(AmazonOrderParser.parseAmountCents("EUR 1.234,56"), 123456)
        XCTAssertEqual(AmazonOrderParser.parseAmountCents("Summe 9,90 €"), 990)
        XCTAssertNil(AmazonOrderParser.parseAmountCents("kostenlos"))
    }

    func test_parseDate_germanAndNumeric() {
        XCTAssertEqual(AmazonOrderParser.parseDate("12. Mai 2026"), "2026-05-12")
        XCTAssertEqual(AmazonOrderParser.parseDate("3. Februar 2025"), "2025-02-03")
        XCTAssertEqual(AmazonOrderParser.parseDate("12.05.2026"), "2026-05-12")
        XCTAssertNil(AmazonOrderParser.parseDate("gestern"))
    }

    func test_parse_buildsReceiptsWithItemsAndDedupes() {
        let orders = [
            AmazonScrapedOrder(id: "302-1234567-7654321", dateText: "12. Mai 2026", totalText: "47,99 €",
                               items: ["Anker USB-C Kabel 2m", "Logitech Maus M185"]),
            // Dublette derselben Bestell-ID → wird zusammengeführt.
            AmazonScrapedOrder(id: "302-1234567-7654321", dateText: "12. Mai 2026", totalText: "47,99 €", items: []),
            AmazonScrapedOrder(id: "", dateText: "01. Juni 2026", totalText: "9,90 €", items: ["Buch: Clean Code"]),
        ]
        let receipts = AmazonOrderParser.parse(orders, slotId: "s", fetchedAt: "x")
        XCTAssertEqual(receipts.count, 2)
        let first = receipts.first { $0.receiptId == "302-1234567-7654321" }
        XCTAssertEqual(first?.totalCents, 4799)
        XCTAssertEqual(first?.timestamp.prefix(10), "2026-05-12")
        XCTAssertEqual(first?.items.count, 2)
        XCTAssertEqual(first?.marketName, "Amazon")
        // Ohne ID: synthetischer Schlüssel aus Datum+Summe.
        XCTAssertNotNil(receipts.first { $0.receiptId.contains("2026-06-01") })
    }

    func test_decode_roundTrip() {
        let json = #"[{"id":"x","dateText":"12. Mai 2026","totalText":"5,00 €","items":["A"]}]"#
        let orders = AmazonOrderParser.decode(json)
        XCTAssertEqual(orders.count, 1)
        XCTAssertEqual(orders.first?.items, ["A"])
    }

    func test_categorizer_mapsCommonTitles() {
        XCTAssertEqual(AmazonItemCategorizer.category(forName: "Anker USB-C Ladegerät 65W"), .elektronik)
        XCTAssertEqual(AmazonItemCategorizer.category(forName: "Clean Code (Taschenbuch)"), .buecherMedien)
        XCTAssertEqual(AmazonItemCategorizer.category(forName: "LEGO Technic Bagger"), .spielzeugHobby)
        XCTAssertEqual(AmazonItemCategorizer.category(forName: "Nivea Duschgel 250ml"), .drogerieBeauty)
        XCTAssertEqual(AmazonItemCategorizer.category(forName: "Völlig Unbekanntes Dings"), .sonstiges)
    }
}
