import XCTest
@testable import simplebanking

final class ReceiptCategoryRingTests: XCTestCase {

    private func item(_ name: String, _ cents: Int) -> ReweLineItem {
        ReweLineItem(name: name, quantity: nil, totalCents: cents, taxCategory: nil)
    }

    func test_emptyItems_noSegments() {
        XCTAssertTrue(ReceiptCategoryRing.segments(forItems: [], source: .dm).isEmpty)
    }

    func test_topFourCappedAndNormalized_dm() {
        let items = [
            item("Denkmit Spülmittel", 300),   // Haushalt
            item("Balea Duschgel", 200),       // Körper
            item("Dontodent Zahnpasta", 150),  // Zahn
            item("Mivolis Magnesium", 100),    // Gesundheit
            item("dmBio Tee", 50),             // Ernährung (5. → fällt raus)
        ]
        let segs = ReceiptCategoryRing.segments(forItems: items, source: .dm)
        XCTAssertEqual(segs.count, 4)                       // max 4
        XCTAssertEqual(segs.first?.label, "Haushalt & Reinigung")
        // Normiert auf die Summe der Top-4 (300+200+150+100 = 750)
        XCTAssertEqual(segs.first!.fraction, 300.0 / 750.0, accuracy: 0.0001)
        let total = segs.reduce(0) { $0 + $1.fraction }
        XCTAssertEqual(total, 1.0, accuracy: 0.0001)
        // Erste vier Palettenfarben in Reihenfolge
        XCTAssertEqual(segs.map(\.colorHex), Array(ReceiptCategoryRing.palette.prefix(4)))
    }

    func test_zeroPrices_fallsBackToCounts() {
        // dm ohne aufgelöste Preise: Gewichtung nach Stückzahl.
        let items = [
            item("Balea A", 0), item("Balea B", 0),   // Körper ×2
            item("Denkmit C", 0),                       // Haushalt ×1
        ]
        let segs = ReceiptCategoryRing.segments(forItems: items, source: .dm)
        XCTAssertEqual(segs.first?.label, "Körper & Kosmetik")
        XCTAssertEqual(segs.first!.fraction, 2.0 / 3.0, accuracy: 0.0001)
    }

    func test_reweCategorizerUsedWhenNotDM() {
        let segs = ReceiptCategoryRing.segments(forItems: [item("NEKTARINE", 200)], source: .rewe)
        XCTAssertEqual(segs.first?.label, "Obst & Gemüse")
    }
}
