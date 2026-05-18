import XCTest
@testable import simplebanking

// MARK: - copyConnectionStateKeys Tests
//
// Regression-Gate für den DKB-Multi-Account-Bug 2026-05-15:
// `YaxiService.copyConnectionState` kopierte nur SessionStore-Daten, NICHT die
// UserDefaults-Keys (connectionId + credModel*). Neue Slots aus einer
// Multi-Account-Login-Discovery hatten dadurch `connectionId = nil` →
// jeder fetchBalances rannte sofort in „no connectionId yet".
//
// Diese Tests sichern: copyConnectionStateKeys kopiert deterministisch alle
// kritischen Keys vom source-slot in den target-slot.

@MainActor
final class CopyConnectionStateKeysTests: XCTestCase {

    private let srcSlot = "test-src-slot-7E8F9A"
    private let dstSlot = "test-dst-slot-1B2C3D"

    override func tearDown() {
        // Alle Keys räumen, die der Test geschrieben hat — sonst leakt UserDefaults
        // zwischen Tests.
        let d = UserDefaults.standard
        for slot in [srcSlot, dstSlot] {
            d.removeObject(forKey: YaxiService.connectionIdKey(for: slot))
            d.removeObject(forKey: YaxiService.credModelFullKey(for: slot))
            d.removeObject(forKey: YaxiService.credModelUserIdKey(for: slot))
            d.removeObject(forKey: YaxiService.credModelNoneKey(for: slot))
        }
        super.tearDown()
    }

    func test_connectionId_copied_to_target() {
        let d = UserDefaults.standard
        d.set("conn-abc-12345", forKey: YaxiService.connectionIdKey(for: srcSlot))
        XCTAssertNil(d.string(forKey: YaxiService.connectionIdKey(for: dstSlot)))

        YaxiService.copyConnectionStateKeys(fromSlotId: srcSlot, toSlotId: dstSlot)

        XCTAssertEqual(d.string(forKey: YaxiService.connectionIdKey(for: dstSlot)), "conn-abc-12345")
    }

    func test_credModel_flags_copied_to_target() {
        let d = UserDefaults.standard
        d.set(true,  forKey: YaxiService.credModelFullKey(for: srcSlot))
        d.set(false, forKey: YaxiService.credModelUserIdKey(for: srcSlot))
        d.set(true,  forKey: YaxiService.credModelNoneKey(for: srcSlot))
        d.set("conn-xyz", forKey: YaxiService.connectionIdKey(for: srcSlot))

        YaxiService.copyConnectionStateKeys(fromSlotId: srcSlot, toSlotId: dstSlot)

        XCTAssertEqual(d.bool(forKey: YaxiService.credModelFullKey(for: dstSlot)),   true)
        XCTAssertEqual(d.bool(forKey: YaxiService.credModelUserIdKey(for: dstSlot)), false)
        XCTAssertEqual(d.bool(forKey: YaxiService.credModelNoneKey(for: dstSlot)),   true)
    }

    func test_empty_source_connectionId_does_not_overwrite_target() {
        // Wenn source keine connectionId hat, darf target's eigener Wert nicht
        // mit leerem String überschrieben werden.
        let d = UserDefaults.standard
        d.set("dst-existing", forKey: YaxiService.connectionIdKey(for: dstSlot))
        // src bleibt leer

        YaxiService.copyConnectionStateKeys(fromSlotId: srcSlot, toSlotId: dstSlot)

        XCTAssertEqual(d.string(forKey: YaxiService.connectionIdKey(for: dstSlot)), "dst-existing")
    }

    func test_missing_source_credModel_keys_do_not_create_target_keys() {
        // Wenn source kein credModel-Flag gesetzt hat, soll target auch
        // keinen Eintrag bekommen (nicht versehentlich `false` schreiben).
        let d = UserDefaults.standard

        YaxiService.copyConnectionStateKeys(fromSlotId: srcSlot, toSlotId: dstSlot)

        XCTAssertNil(d.object(forKey: YaxiService.credModelFullKey(for: dstSlot)))
        XCTAssertNil(d.object(forKey: YaxiService.credModelUserIdKey(for: dstSlot)))
        XCTAssertNil(d.object(forKey: YaxiService.credModelNoneKey(for: dstSlot)))
    }

    func test_idempotent_called_twice_same_result() {
        let d = UserDefaults.standard
        d.set("conn-idem", forKey: YaxiService.connectionIdKey(for: srcSlot))
        d.set(true, forKey: YaxiService.credModelNoneKey(for: srcSlot))

        YaxiService.copyConnectionStateKeys(fromSlotId: srcSlot, toSlotId: dstSlot)
        YaxiService.copyConnectionStateKeys(fromSlotId: srcSlot, toSlotId: dstSlot)

        XCTAssertEqual(d.string(forKey: YaxiService.connectionIdKey(for: dstSlot)), "conn-idem")
        XCTAssertEqual(d.bool(forKey: YaxiService.credModelNoneKey(for: dstSlot)), true)
    }
}
