import XCTest
@testable import simplebanking

final class ReweReceiptMergerTests: XCTestCase {

    private func listReceipt(_ id: String, total: Int, ts: String) -> ReweReceipt {
        ReweReceipt(slotId: "s", receiptId: id, timestamp: ts, totalCents: total,
                    marketName: "REWE", marketCity: "Siegen", cancelled: false,
                    items: [], parsed: false, fetchedAt: "old")
    }
    private func parsed(date: String?, total: Int?, _ names: [String]) -> ReweParsedReceipt {
        ReweParsedReceipt(marketHeader: "REWE", date: date, totalCents: total,
                          items: names.map { ReweLineItem(name: $0, quantity: nil, totalCents: 0, taxCategory: "B") })
    }

    func test_matchesByDateAndTotal_setsItemsAndParsed() {
        let list = [listReceipt("a", total: 2790, ts: "2026-06-13T09:56:17Z")]
        let p = [parsed(date: "2026-06-13", total: 2790, ["APFEL", "MILCH"])]
        let merged = ReweReceiptMerger.merge(list: list, parsed: p, fetchedAt: "now")
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].parsed)
        XCTAssertEqual(merged[0].items.map(\.name), ["APFEL", "MILCH"])
        XCTAssertEqual(merged[0].fetchedAt, "now")
    }

    func test_noMatch_leavesReceiptUnparsed() {
        let list = [listReceipt("a", total: 2790, ts: "2026-06-13T09:56:17Z")]
        let p = [parsed(date: "2026-06-12", total: 999, ["X"])]   // anderes Datum + Summe
        let merged = ReweReceiptMerger.merge(list: list, parsed: p, fetchedAt: "now")
        XCTAssertFalse(merged[0].parsed)
        XCTAssertTrue(merged[0].items.isEmpty)
    }

    func test_sameDaySameTotal_eachListReceiptGetsOneParsed() {
        let list = [
            listReceipt("a", total: 2000, ts: "2026-06-13T08:00:00Z"),
            listReceipt("b", total: 2000, ts: "2026-06-13T19:00:00Z"),
        ]
        let p = [
            parsed(date: "2026-06-13", total: 2000, ["FIRST"]),
            parsed(date: "2026-06-13", total: 2000, ["SECOND"]),
        ]
        let merged = ReweReceiptMerger.merge(list: list, parsed: p, fetchedAt: "now")
        XCTAssertTrue(merged.allSatisfy(\.parsed))
        // Beide bekommen je genau einen Warenkorb (kein doppeltes Zuordnen).
        XCTAssertEqual(Set(merged.flatMap { $0.items.map(\.name) }), ["FIRST", "SECOND"])
    }

    func test_parserExtractsDate() {
        let text = """
        EUR
        APFEL 1,00 B
        SUMME EUR 1,00
        Datum:                                  13.06.2026
        """
        XCTAssertEqual(ReweReceiptParser.parse(text).date, "2026-06-13")
    }
}
