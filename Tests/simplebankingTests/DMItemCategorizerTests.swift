import XCTest
@testable import simplebanking

final class DMItemCategorizerTests: XCTestCase {

    private func cat(_ name: String) -> DMCategory { DMItemCategorizer.category(forName: name) }

    func test_categorizesByBrandAndKeyword() {
        XCTAssertEqual(cat("Denkmit Badreiniger Konzentrat, 100 ml"), .haushaltReinigung)
        XCTAssertEqual(cat("Profissimo Müllbeutel"), .haushaltReinigung)
        XCTAssertEqual(cat("Balea Bodylotion"), .koerperKosmetik)
        XCTAssertEqual(cat("alverde Handcreme"), .koerperKosmetik)
        XCTAssertEqual(cat("Dontodent Zahnpasta"), .zahnMund)
        XCTAssertEqual(cat("Babylove Windel Gr. 4"), .babyKind)
        XCTAssertEqual(cat("Mivolis Magnesium 400"), .gesundheit)
        XCTAssertEqual(cat("dmBio Haferflocken"), .ernaehrung)
        XCTAssertEqual(cat("Balea Men Shampoo"), .haareStyling)
    }

    func test_unknownFallsBackToSonstiges() {
        XCTAssertEqual(cat("XYZ Kryptisch"), .sonstiges)
    }

    func test_breakdownAggregatesAndSorts() {
        let r = ReweReceipt(
            slotId: "s", receiptId: "1", timestamp: "2026-06-13T09:00:00Z", totalCents: 0,
            marketName: "dm", marketCity: "Siegen", cancelled: false,
            items: [
                ReweLineItem(name: "Denkmit Spülmittel", quantity: nil, totalCents: 200, taxCategory: nil),
                ReweLineItem(name: "Profissimo Reiniger", quantity: nil, totalCents: 150, taxCategory: nil),
                ReweLineItem(name: "Balea Duschgel", quantity: nil, totalCents: 95, taxCategory: nil),
            ], parsed: true, fetchedAt: "x")
        let b = DMItemCategorizer.breakdown([r])
        XCTAssertEqual(b.first?.category, .haushaltReinigung)   // 200+150 = 350 (größter)
        XCTAssertEqual(b.first?.totalCents, 350)
        XCTAssertEqual(b.first?.count, 2)
        XCTAssertEqual(b.first(where: { $0.category == .koerperKosmetik })?.totalCents, 95)
    }

    func test_breakdownSkipsCancelled() {
        let r = ReweReceipt(slotId: "s", receiptId: "1", timestamp: "2026-06-13T09:00:00Z", totalCents: 0,
                            marketName: "dm", marketCity: "Siegen", cancelled: true,
                            items: [ReweLineItem(name: "Balea Creme", quantity: nil, totalCents: 99, taxCategory: nil)],
                            parsed: true, fetchedAt: "x")
        XCTAssertTrue(DMItemCategorizer.breakdown([r]).isEmpty)
    }
}
