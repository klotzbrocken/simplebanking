import XCTest
@testable import simplebanking

// MARK: - Slot-Removal Cleanup tests
//
// Schützt P3.2 + P3.3: nach removeSlot() müssen alle slot-suffixed
// Persistenz-Spuren weg sein. Sonst leakt der entfernte Slot:
//  - cachedBalance.<id> + lastSeenTxSig.<id> als UserDefaults-Bloat
//  - credentials-<id>.json als dead file auf Platte (encrypted, aber dead)
//  - YAXI session/connectionData (sensitive!)

@MainActor
final class SlotRemovalCleanupTests: XCTestCase {

    // MARK: - UserDefaults cleanup

    func test_purgePerSlotData_removesCachedBalance() {
        let slotId = "test-purge-\(UUID().uuidString.prefix(6))"
        let key = "simplebanking.cachedBalance.\(slotId)"
        UserDefaults.standard.set(1234.56, forKey: key)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key),
            "Sanity: balance war gesetzt")

        MultibankingStore.purgePerSlotData(slotId: slotId)

        XCTAssertNil(UserDefaults.standard.object(forKey: key),
            "cachedBalance.\(slotId) muss nach Purge weg sein — sonst Bloat-Leak")
    }

    func test_purgePerSlotData_removesLastSeenTxSig() {
        let slotId = "test-purge-\(UUID().uuidString.prefix(6))"
        let key = "simplebanking.lastSeenTxSig.\(slotId)"
        UserDefaults.standard.set("some-fingerprint", forKey: key)

        MultibankingStore.purgePerSlotData(slotId: slotId)

        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func test_purgePerSlotData_doesNotTouchOtherSlots() {
        // Räumt slot A auf, slot B bleibt unberührt — kritisch, sonst kann
        // ein Slot-Remove versehentlich nachbar-slots löschen.
        let slotA = "test-purge-A-\(UUID().uuidString.prefix(4))"
        let slotB = "test-purge-B-\(UUID().uuidString.prefix(4))"
        UserDefaults.standard.set(100.0, forKey: "simplebanking.cachedBalance.\(slotA)")
        UserDefaults.standard.set(200.0, forKey: "simplebanking.cachedBalance.\(slotB)")

        MultibankingStore.purgePerSlotData(slotId: slotA)

        XCTAssertNil(UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slotA)"))
        XCTAssertNotNil(UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slotB)"),
            "Slot B darf vom Slot-A-Purge unberührt bleiben")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "simplebanking.cachedBalance.\(slotB)")
    }

    // MARK: - CredentialsStore.deleteSlotFile

    func test_deleteSlotFile_legacySlotIsProtected() {
        // legacy ist die default-Datei (credentials.json), darf NIE gelöscht werden.
        // deleteSlotFile soll dafür ein no-op sein.
        // Wir erzeugen keine echte Datei — Funktion soll früh returnen.
        // Wenn Funktion buggy wäre und legacy-Path probiert zu löschen, wäre das
        // im normal-Run problemlos (Datei existiert evtl. schon nicht), aber hier
        // testen wir nur dass kein Crash erfolgt.
        XCTAssertNoThrow(CredentialsStore.deleteSlotFile(slotId: "legacy"))
    }

    func test_deleteSlotFile_nonLegacySlotDoesNotCrash() {
        // Datei existiert vermutlich nicht — try? FileManager.removeItem schluckt das.
        XCTAssertNoThrow(CredentialsStore.deleteSlotFile(
            slotId: "test-no-such-slot-\(UUID().uuidString.prefix(6))"))
    }
}
