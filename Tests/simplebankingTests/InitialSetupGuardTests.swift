import XCTest
@testable import simplebanking

// MARK: - InitialSetupGuard Tests
//
// Verifies the BankSlotSettings round-trip used by the InitialSetupExtension
// wizard (Step 1: Gehaltstag, Step 2: Dispo). Other steps write to
// UserDefaults directly and are covered by manual smoke-tests.
//
// Note: The "fires only once" guard lives in BalanceBar via a UserDefaults
// flag. It's tested manually since BalanceBar is not unit-test friendly.

@MainActor
final class InitialSetupGuardTests: XCTestCase {

    private let testSlotId = "test-initial-setup-extension"

    override func tearDown() {
        // Clean up: remove test-slot settings + flag
        UserDefaults.standard.removeObject(forKey: "simplebanking.slotSettings.\(testSlotId)")
        super.tearDown()
    }

    func test_salaryDayPresetAnfang_persists() {
        var s = BankSlotSettingsStore.load(slotId: testSlotId)
        s.salaryDayPreset = 0
        BankSlotSettingsStore.save(s, slotId: testSlotId)

        let loaded = BankSlotSettingsStore.load(slotId: testSlotId)
        XCTAssertEqual(loaded.salaryDayPreset, 0)
        XCTAssertEqual(loaded.effectiveSalaryDay, 1)
    }

    func test_salaryDayPresetMitte_persists() {
        var s = BankSlotSettingsStore.load(slotId: testSlotId)
        s.salaryDayPreset = 1
        BankSlotSettingsStore.save(s, slotId: testSlotId)

        let loaded = BankSlotSettingsStore.load(slotId: testSlotId)
        XCTAssertEqual(loaded.salaryDayPreset, 1)
        XCTAssertEqual(loaded.effectiveSalaryDay, 15)
    }

    func test_salaryDayCustom_persistsWithDay() {
        var s = BankSlotSettingsStore.load(slotId: testSlotId)
        s.salaryDayPreset = 2
        s.salaryDay = 27
        BankSlotSettingsStore.save(s, slotId: testSlotId)

        let loaded = BankSlotSettingsStore.load(slotId: testSlotId)
        XCTAssertEqual(loaded.salaryDayPreset, 2)
        XCTAssertEqual(loaded.salaryDay, 27)
        XCTAssertEqual(loaded.effectiveSalaryDay, 27)
    }

    func test_dispoLimit_zeroAndPositive_roundTrip() {
        var s = BankSlotSettingsStore.load(slotId: testSlotId)
        s.dispoLimit = 0
        BankSlotSettingsStore.save(s, slotId: testSlotId)
        XCTAssertEqual(BankSlotSettingsStore.load(slotId: testSlotId).dispoLimit, 0)

        s.dispoLimit = 1500
        BankSlotSettingsStore.save(s, slotId: testSlotId)
        XCTAssertEqual(BankSlotSettingsStore.load(slotId: testSlotId).dispoLimit, 1500)
    }
}
