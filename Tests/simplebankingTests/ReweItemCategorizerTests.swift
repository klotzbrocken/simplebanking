import XCTest
@testable import simplebanking

final class ReweItemCategorizerTests: XCTestCase {

    private func cat(_ name: String, _ tax: String? = "B") -> ReweCategory {
        ReweItemCategorizer.category(forName: name, taxCategory: tax)
    }

    func test_categorizesCommonItems() {
        XCTAssertEqual(cat("NEKTARINE GELB"), .obstGemuese)
        XCTAssertEqual(cat("KART.VF.BIO"), .obstGemuese)
        XCTAssertEqual(cat("KALBS-LEBERWURST"), .fleischWurst)
        XCTAssertEqual(cat("BEEF JERKY ORIG"), .fleischWurst)
        XCTAssertEqual(cat("PAULANER OM HELL", "A"), .alkohol)
        XCTAssertEqual(cat("SCAVI&RAY PROSEC", "A"), .alkohol)
        XCTAssertEqual(cat("RB R.BETE SAFT", "A"), .getraenke)
        XCTAssertEqual(cat("PFAND 0,25 EURO", "A"), .pfand)
        XCTAssertEqual(cat("TRAGETASCHE PAPI", "A"), .haushaltDrogerie)
        XCTAssertEqual(cat("PIZZA TAKEOVER"), .tiefkuehl)
        XCTAssertEqual(cat("HUMMUS MAN.CURR."), .milchKaese)
    }

    func test_unknownFallsBackToSonstiges() {
        XCTAssertEqual(cat("XYZ KRYPTISCH"), .sonstiges)
    }

    func test_breakdownAggregatesAndSorts() {
        let r = ReweReceipt(
            slotId: "s", receiptId: "1", timestamp: "2026-06-13T09:00:00Z", totalCents: 0,
            marketName: "REWE", marketCity: "Siegen", cancelled: false,
            items: [
                ReweLineItem(name: "NEKTARINE", quantity: nil, totalCents: 211, taxCategory: "B"),
                ReweLineItem(name: "KIWI GOLD", quantity: nil, totalCents: 99, taxCategory: "B"),
                ReweLineItem(name: "PAULANER", quantity: nil, totalCents: 238, taxCategory: "A"),
            ], parsed: true, fetchedAt: "x")
        let b = ReweItemCategorizer.breakdown([r])
        XCTAssertEqual(b.first?.category, .obstGemuese)         // 211+99 = 310 (größter)
        XCTAssertEqual(b.first?.totalCents, 310)
        XCTAssertEqual(b.first?.count, 2)
        XCTAssertEqual(b.first(where: { $0.category == .alkohol })?.totalCents, 238)
    }

    func test_breakdownSkipsCancelled() {
        let r = ReweReceipt(slotId: "s", receiptId: "1", timestamp: "2026-06-13T09:00:00Z", totalCents: 0,
                            marketName: "REWE", marketCity: "Siegen", cancelled: true,
                            items: [ReweLineItem(name: "KIWI", quantity: nil, totalCents: 99, taxCategory: "B")],
                            parsed: true, fetchedAt: "x")
        XCTAssertTrue(ReweItemCategorizer.breakdown([r]).isEmpty)
    }
}
