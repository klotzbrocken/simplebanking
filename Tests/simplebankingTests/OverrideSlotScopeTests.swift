import XCTest
@testable import simplebanking

// MARK: - Override Slot-Scope Regression Tests
//
// Schützt gegen P2-Regression aus dem externen Reviewer-Pass:
// TransactionCategorizer.saveOverride und MerchantResolver.saveOverride
// keyten vorher nur auf txID — bei identischem Fingerprint in mehreren
// Slots leakte ein manueller Override in andere Slots. Composite-Key
// `slotId|txID` löst das.
//
// Plus: legacy-Einträge (alter Storage-Form) müssen im Read-Path noch
// gefunden werden, damit Bestandsdaten nach Update nicht "verschwinden".

final class CategorizerOverrideSlotScopeTests: XCTestCase {

    private let txID = "test-fingerprint-cat-\(UUID().uuidString.prefix(8))"
    private let slotA = "slot-A-\(UUID().uuidString.prefix(6))"
    private let slotB = "slot-B-\(UUID().uuidString.prefix(6))"

    override func tearDownWithError() throws {
        // Cleanup nach jedem Test (UserDefaults bleibt sonst persistent)
        _ = TransactionCategorizer.removeOverride(txID: txID, slotId: slotA)
        _ = TransactionCategorizer.removeOverride(txID: txID, slotId: slotB)
    }

    func test_overrideInSlotA_doesNotLeakToSlotB() {
        TransactionCategorizer.saveOverride(txID: txID, slotId: slotA, category: .freizeit)

        XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: txID, slotId: slotA), .freizeit)
        XCTAssertNil(TransactionCategorizer.overrideCategory(txID: txID, slotId: slotB),
            "Override in Slot A darf nicht in Slot B sichtbar sein — sonst Composite-Key gebrochen")
    }

    func test_differentOverridesPerSlot_keptIndependent() {
        TransactionCategorizer.saveOverride(txID: txID, slotId: slotA, category: .freizeit)
        TransactionCategorizer.saveOverride(txID: txID, slotId: slotB, category: .essenAlltag)

        XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: txID, slotId: slotA), .freizeit)
        XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: txID, slotId: slotB), .essenAlltag)
    }

    func test_removeOverride_onlyAffectsTargetSlot() {
        TransactionCategorizer.saveOverride(txID: txID, slotId: slotA, category: .freizeit)
        TransactionCategorizer.saveOverride(txID: txID, slotId: slotB, category: .essenAlltag)

        _ = TransactionCategorizer.removeOverride(txID: txID, slotId: slotA)

        XCTAssertNil(TransactionCategorizer.overrideCategory(txID: txID, slotId: slotA))
        XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: txID, slotId: slotB), .essenAlltag,
            "removeOverride für Slot A darf Slot B nicht löschen")
    }

    func test_legacyOverride_isStillReadable() {
        // Simuliere einen Legacy-Eintrag (alter Storage-Form, nur txID).
        // Storage ist JSON-encoded Data unter "transactionCategoryOverrides".
        let legacyKey = txID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let storageKey = TransactionCategorizer.overridesStorageKey
        var existing = readOverrides(storageKey: storageKey)
        existing[legacyKey] = TransactionCategory.freizeit.rawValue
        writeOverrides(existing, storageKey: storageKey)

        // Legacy-Lookup mit beliebigem slotId muss den alten Wert finden.
        XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: txID, slotId: slotA), .freizeit,
            "Legacy-Override (nur txID) muss im Read-Path noch gefunden werden")

        // Cleanup
        existing.removeValue(forKey: legacyKey)
        writeOverrides(existing, storageKey: storageKey)
    }

    func test_saveOverride_migratesLegacyEntry() {
        let legacyKey = txID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let storageKey = TransactionCategorizer.overridesStorageKey
        var existing = readOverrides(storageKey: storageKey)
        existing[legacyKey] = TransactionCategory.freizeit.rawValue
        writeOverrides(existing, storageKey: storageKey)

        // Save mit slotId → muss Legacy aufräumen
        TransactionCategorizer.saveOverride(txID: txID, slotId: slotA, category: .essenAlltag)

        let after = readOverrides(storageKey: storageKey)
        XCTAssertNil(after[legacyKey], "Legacy-Key muss nach saveOverride weg sein (Migration)")
        XCTAssertEqual(after["\(slotA.lowercased())|\(legacyKey)"], TransactionCategory.essenAlltag.rawValue)
    }

    // MARK: - storage helpers (JSON-encoded Data unter overridesStorageKey)

    private func readOverrides(storageKey: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func writeOverrides(_ dict: [String: String], storageKey: String) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

final class MerchantResolverOverrideSlotScopeTests: XCTestCase {

    private let txID = "test-fingerprint-merch-\(UUID().uuidString.prefix(8))"
    private let slotA = "slot-A-\(UUID().uuidString.prefix(6))"
    private let slotB = "slot-B-\(UUID().uuidString.prefix(6))"

    override func tearDownWithError() throws {
        _ = MerchantResolver.removeOverride(txID: txID, slotId: slotA)
        _ = MerchantResolver.removeOverride(txID: txID, slotId: slotB)
    }

    func test_merchantOverrideInSlotA_doesNotLeakToSlotB() {
        MerchantResolver.saveOverride(txID: txID, slotId: slotA, merchant: "Slot A Merchant")

        XCTAssertEqual(MerchantResolver.overrideForTransaction(txID: txID, slotId: slotA), "Slot A Merchant")
        XCTAssertNil(MerchantResolver.overrideForTransaction(txID: txID, slotId: slotB),
            "Merchant-Override in Slot A darf nicht in Slot B sichtbar sein")
    }

    func test_hasOverride_isSlotScoped() {
        MerchantResolver.saveOverride(txID: txID, slotId: slotA, merchant: "X")

        XCTAssertTrue(MerchantResolver.hasOverride(txID: txID, slotId: slotA))
        XCTAssertFalse(MerchantResolver.hasOverride(txID: txID, slotId: slotB))
    }
}
