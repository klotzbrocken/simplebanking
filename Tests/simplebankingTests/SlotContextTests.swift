import XCTest
@testable import simplebanking

// MARK: - SlotContext tests
//
// Sichert ab, dass `SlotContext.activate(_:)` ALLE Layer (Yaxi, Credentials,
// Database) gleichzeitig auf den neuen Slot setzt — und dass die Snapshot/
// Restore-Mechanik symmetrisch ist. Wenn ein Maintainer in `SlotContext`
// einen Layer vergisst zu adden (z.B. neuer Cache-Layer), brechen diese
// Tests sofort.

final class SlotContextTests: XCTestCase {

    private var savedSnapshot: SlotContext.Snapshot!

    override func setUpWithError() throws {
        // Vor jedem Test snapshotten — am Ende restoren, damit wir den globalen
        // Static-State nicht verfälschen für andere Tests.
        savedSnapshot = SlotContext.snapshot()
    }

    override func tearDownWithError() throws {
        SlotContext.restore(savedSnapshot)
    }

    // MARK: - activate touches all layers

    func test_activate_setsAllThreeLayersToSameSlotId() {
        SlotContext.activate(slotId: "test-slot-A")

        XCTAssertEqual(YaxiService.activeSlotId, "test-slot-A",
            "YaxiService nicht aktualisiert — vergessen in SlotContext.activate?")
        XCTAssertEqual(CredentialsStore.activeSlotId, "test-slot-A",
            "CredentialsStore nicht aktualisiert — vergessen in SlotContext.activate?")
        XCTAssertEqual(TransactionsDatabase.activeSlotId, "test-slot-A",
            "TransactionsDatabase nicht aktualisiert — vergessen in SlotContext.activate?")
    }

    func test_activate_overwritesPreviousSlot() {
        SlotContext.activate(slotId: "first")
        SlotContext.activate(slotId: "second")

        XCTAssertEqual(YaxiService.activeSlotId, "second")
        XCTAssertEqual(CredentialsStore.activeSlotId, "second")
        XCTAssertEqual(TransactionsDatabase.activeSlotId, "second")
    }

    // MARK: - snapshot/restore round-trip

    func test_snapshot_capturesCurrentSlot() {
        SlotContext.activate(slotId: "snapshotted")
        let snap = SlotContext.snapshot()

        XCTAssertEqual(snap.yaxi, "snapshotted")
        XCTAssertEqual(snap.credentials, "snapshotted")
        XCTAssertEqual(snap.database, "snapshotted")
    }

    func test_restore_resetsAllLayers() {
        SlotContext.activate(slotId: "original")
        let snap = SlotContext.snapshot()

        // Zwischendurch wechseln
        SlotContext.activate(slotId: "transient")
        XCTAssertEqual(YaxiService.activeSlotId, "transient")

        // Restore
        SlotContext.restore(snap)
        XCTAssertEqual(YaxiService.activeSlotId, "original")
        XCTAssertEqual(CredentialsStore.activeSlotId, "original")
        XCTAssertEqual(TransactionsDatabase.activeSlotId, "original")
    }

    func test_snapshot_isEquatable() {
        SlotContext.activate(slotId: "x")
        let snapA = SlotContext.snapshot()
        let snapB = SlotContext.snapshot()
        XCTAssertEqual(snapA, snapB)

        SlotContext.activate(slotId: "y")
        let snapC = SlotContext.snapshot()
        XCTAssertNotEqual(snapA, snapC)
    }

    // MARK: - Importer-Pattern (snapshot → activate → defer restore)

    func test_importerPattern_restoresOriginalSlotAfterTemporarySwitch() {
        SlotContext.activate(slotId: "user-active-slot")

        // Simuliere Importer-Code:
        do {
            let snap = SlotContext.snapshot()
            defer { SlotContext.restore(snap) }
            SlotContext.activate(slotId: "import-target-slot")

            // Während Import: alle Layer zeigen auf import-Ziel
            XCTAssertEqual(YaxiService.activeSlotId, "import-target-slot")
            XCTAssertEqual(CredentialsStore.activeSlotId, "import-target-slot")
            XCTAssertEqual(TransactionsDatabase.activeSlotId, "import-target-slot")
        }

        // Nach Import: original wiederhergestellt
        XCTAssertEqual(YaxiService.activeSlotId, "user-active-slot")
        XCTAssertEqual(CredentialsStore.activeSlotId, "user-active-slot")
        XCTAssertEqual(TransactionsDatabase.activeSlotId, "user-active-slot")
    }
}
