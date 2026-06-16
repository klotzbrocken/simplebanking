import XCTest
@testable import simplebanking

/// Sichert die Decode-Kompatibilität: `BankSlot.source` ist optional, damit
/// bereits persistierte Slots ohne dieses Feld weiterhin dekodieren.
final class ReweSlotSourceTests: XCTestCase {

    func test_legacySlotJSON_withoutSource_decodesAsBankSlot() throws {
        let json = Data(#"{"id":"x","iban":"DE89370400440532013000","displayName":"DKB","logoId":"dkb"}"#.utf8)
        let slot = try JSONDecoder().decode(BankSlot.self, from: json)
        XCTAssertNil(slot.source)
        XCTAssertFalse(slot.isREWE)
    }

    func test_reweSlot_roundTripsAndIsFlagged() throws {
        let made = BankSlot.makeREWE()
        XCTAssertTrue(made.isREWE)
        XCTAssertEqual(made.logoId, "rewe")
        XCTAssertTrue(made.iban.isEmpty)

        let data = try JSONEncoder().encode(made)
        let back = try JSONDecoder().decode(BankSlot.self, from: data)
        XCTAssertEqual(back.source, .rewe)
        XCTAssertTrue(back.isREWE)
    }

    func test_bankSlotMakeNew_isNotREWE() {
        XCTAssertFalse(BankSlot.makeNew(iban: "DE..", displayName: "X", logoId: nil).isREWE)
    }
}
