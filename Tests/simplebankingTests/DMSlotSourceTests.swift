import XCTest
@testable import simplebanking

final class DMSlotSourceTests: XCTestCase {

    func test_dmSlot_roundTripsAndIsFlagged() throws {
        let made = BankSlot.makeDM()
        XCTAssertTrue(made.isDM)
        XCTAssertTrue(made.isReceiptSlot)
        XCTAssertFalse(made.isREWE)
        XCTAssertEqual(made.logoId, "dm")
        XCTAssertTrue(made.iban.isEmpty)

        let data = try JSONEncoder().encode(made)
        let back = try JSONDecoder().decode(BankSlot.self, from: data)
        XCTAssertEqual(back.source, .dm)
        XCTAssertTrue(back.isDM)
        XCTAssertTrue(back.isReceiptSlot)
    }

    func test_reweSlot_isReceiptSlotButNotDM() {
        let rewe = BankSlot.makeREWE()
        XCTAssertTrue(rewe.isReceiptSlot)
        XCTAssertFalse(rewe.isDM)
    }

    func test_bankSlot_isNeitherDMNorReceipt() {
        let bank = BankSlot.makeNew(iban: "DE89370400440532013000", displayName: "DKB", logoId: "dkb")
        XCTAssertFalse(bank.isDM)
        XCTAssertFalse(bank.isReceiptSlot)
    }
}
