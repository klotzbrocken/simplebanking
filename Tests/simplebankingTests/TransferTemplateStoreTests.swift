import XCTest
@testable import simplebanking

// MARK: - TransferTemplateStore Tests
//
// Tests laufen gegen UserDefaults.standard und löschen ihren Storage-Key
// im setUp/tearDown wieder, damit kein State zwischen Tests bleibt.

final class TransferTemplateStoreTests: XCTestCase {

    private let storageKey = "simplebanking.transfer.templates"

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - Helpers

    private func makeTemplate(
        id: String = UUID().uuidString,
        slotId: String = "slot-a",
        name: String = "Miete Mai",
        amount: Decimal = Decimal(string: "720.50")!,
        purpose: String? = "Miete Mai 2026"
    ) -> TransferTemplate {
        TransferTemplate(
            id: id, slotId: slotId, name: name,
            recipientName: "Heike Vermieter",
            recipientIban: "DE19 5001 0517 0123 4567 89",
            amount: amount, purpose: purpose
        )
    }

    // MARK: - CRUD

    func test_save_and_load_roundtrip() {
        let t = makeTemplate(name: "Miete Mai")
        TransferTemplateStore.save(t)

        let loaded = TransferTemplateStore.load(slotId: "slot-a")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Miete Mai")
        XCTAssertEqual(loaded.first?.recipientName, "Heike Vermieter")
        // IBAN soll normalisiert sein (kein Whitespace)
        XCTAssertEqual(loaded.first?.recipientIban, "DE19500105170123456789")
        XCTAssertEqual(loaded.first?.purpose, "Miete Mai 2026")
    }

    func test_delete_removesOnlyThatId() {
        let a = makeTemplate(id: "id-A", name: "Vorlage A")
        let b = makeTemplate(id: "id-B", name: "Vorlage B")
        TransferTemplateStore.save(a)
        TransferTemplateStore.save(b)

        TransferTemplateStore.delete(id: "id-A")

        let remaining = TransferTemplateStore.load(slotId: "slot-a")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, "id-B")
    }

    func test_save_sameId_replacesEntry() {
        let v1 = makeTemplate(id: "id-1", name: "Erste Version")
        let v2 = makeTemplate(id: "id-1", name: "Geänderte Version")
        TransferTemplateStore.save(v1)
        TransferTemplateStore.save(v2)

        let loaded = TransferTemplateStore.load(slotId: "slot-a")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Geänderte Version")
    }

    // MARK: - Slot-Isolation

    func test_load_filtersBySlotId() {
        let inA = makeTemplate(slotId: "slot-a", name: "Nur A")
        let inB = makeTemplate(slotId: "slot-b", name: "Nur B")
        TransferTemplateStore.save(inA)
        TransferTemplateStore.save(inB)

        let a = TransferTemplateStore.load(slotId: "slot-a")
        let b = TransferTemplateStore.load(slotId: "slot-b")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a.first?.name, "Nur A")
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b.first?.name, "Nur B")
    }

    // MARK: - Decimal-Roundtrip

    func test_decimal_roundtrip_preservesPrecision() {
        // Decimal mit Nachkommastellen, die in Double driften würden
        let weird = Decimal(string: "1234567.89")!
        let t = makeTemplate(amount: weird)
        TransferTemplateStore.save(t)

        let loaded = TransferTemplateStore.load(slotId: "slot-a")
        XCTAssertEqual(loaded.first?.amount, weird)
    }

    func test_load_sorted_alphabetically_caseInsensitive() {
        TransferTemplateStore.save(makeTemplate(name: "zebra"))
        TransferTemplateStore.save(makeTemplate(name: "Apfel"))
        TransferTemplateStore.save(makeTemplate(name: "möhre"))

        let names = TransferTemplateStore.load(slotId: "slot-a").map(\.name)
        XCTAssertEqual(names, ["Apfel", "möhre", "zebra"])
    }
}
