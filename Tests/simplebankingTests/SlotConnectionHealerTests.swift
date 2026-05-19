import XCTest
@testable import simplebanking

// MARK: - SlotConnectionHealer Tests
//
// Pure-function tests für die Self-Heal-Logik. Sicherstellt:
// - Heal-Plan nur für Slots ohne connectionId
// - Source ist deterministisch (sortierter erster mit connectionId)
// - Pro Bank-Gruppe wird gehealt; getrennte Banken bleiben isoliert
// - Idempotent: ein zweiter Aufruf produziert leeren Plan
// - bankKey-Heuristik: logoId bevorzugt, sonst normalized displayName
// - Edge-Case: Slot alleine in seiner Bank → kein Heal
// - Edge-Case: alle in einer Bank haben/haben keine connectionId → kein Heal

final class SlotConnectionHealerTests: XCTestCase {

    typealias SlotInfo = SlotConnectionHealer.SlotInfo
    typealias HealAction = SlotConnectionHealer.HealAction

    func test_emptyInput_returnsEmptyPlan() {
        let plan = SlotConnectionHealer.computeHealPlan(slots: [])
        XCTAssertEqual(plan, [])
    }

    func test_singleSlot_noHealPossible() {
        let plan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb", connectionId: nil)
        ])
        XCTAssertEqual(plan, [])
    }

    func test_singleBank_allWithConnectionId_noHeal() {
        let plan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb", connectionId: "conn-1"),
            SlotInfo(id: "B", bankKey: "dkb", connectionId: "conn-1"),
        ])
        XCTAssertEqual(plan, [])
    }

    func test_singleBank_allMissingConnectionId_noHeal() {
        // Kein Source vorhanden → nichts zu kopieren
        let plan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb", connectionId: nil),
            SlotInfo(id: "B", bankKey: "dkb", connectionId: nil),
        ])
        XCTAssertEqual(plan, [])
    }

    func test_oneSource_oneTarget_singleHeal() {
        let plan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb", connectionId: "conn-1"),
            SlotInfo(id: "B", bankKey: "dkb", connectionId: nil),
        ])
        XCTAssertEqual(plan, [
            HealAction(fromSlotId: "A", toSlotId: "B", bankKey: "dkb")
        ])
    }

    func test_oneSource_multipleTargets_healAllFromSameSource() {
        let plan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb", connectionId: "conn-1"),
            SlotInfo(id: "B", bankKey: "dkb", connectionId: nil),
            SlotInfo(id: "C", bankKey: "dkb", connectionId: ""),  // empty == missing
            SlotInfo(id: "D", bankKey: "dkb", connectionId: nil),
        ])
        XCTAssertEqual(plan, [
            HealAction(fromSlotId: "A", toSlotId: "B", bankKey: "dkb"),
            HealAction(fromSlotId: "A", toSlotId: "C", bankKey: "dkb"),
            HealAction(fromSlotId: "A", toSlotId: "D", bankKey: "dkb"),
        ])
    }

    func test_multipleSources_picksFirstSortedAsSource() {
        // Sources sortiert nach id; nimmt den ersten alphabetisch
        let plan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "Z", bankKey: "dkb", connectionId: "conn-z"),
            SlotInfo(id: "A", bankKey: "dkb", connectionId: "conn-a"),
            SlotInfo(id: "M", bankKey: "dkb", connectionId: nil),
        ])
        XCTAssertEqual(plan, [
            HealAction(fromSlotId: "A", toSlotId: "M", bankKey: "dkb")
        ])
    }

    func test_separateBanks_isolated() {
        // DKB-Gruppe healt nicht in Sparkasse-Gruppe rein und umgekehrt
        let plan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb",       connectionId: "dkb-conn"),
            SlotInfo(id: "B", bankKey: "dkb",       connectionId: nil),
            SlotInfo(id: "C", bankKey: "sparkasse", connectionId: nil),
            SlotInfo(id: "D", bankKey: "sparkasse", connectionId: "spk-conn"),
            SlotInfo(id: "E", bankKey: "sparkasse", connectionId: nil),
        ])
        // Aktionen sortiert nach toSlotId
        XCTAssertEqual(plan, [
            HealAction(fromSlotId: "A", toSlotId: "B", bankKey: "dkb"),
            HealAction(fromSlotId: "D", toSlotId: "C", bankKey: "sparkasse"),
            HealAction(fromSlotId: "D", toSlotId: "E", bankKey: "sparkasse"),
        ])
    }

    func test_slotAloneInItsBank_noHeal() {
        let plan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb",       connectionId: "conn-1"),
            SlotInfo(id: "B", bankKey: "dkb",       connectionId: nil),
            SlotInfo(id: "Z", bankKey: "comdirect", connectionId: nil),  // alone, can't be healed
        ])
        XCTAssertEqual(plan, [
            HealAction(fromSlotId: "A", toSlotId: "B", bankKey: "dkb")
        ])
    }

    func test_idempotent_secondRunEmptyPlan() {
        // Nach Anwendung des ersten Plans hätte target nun connectionId — der
        // zweite Lauf liefert leeren Plan. (Wir simulieren das durch das
        // Setzen der connectionId.)
        let initialPlan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb", connectionId: "conn-1"),
            SlotInfo(id: "B", bankKey: "dkb", connectionId: nil),
        ])
        XCTAssertEqual(initialPlan.count, 1)

        // State nach Heilung
        let secondPlan = SlotConnectionHealer.computeHealPlan(slots: [
            SlotInfo(id: "A", bankKey: "dkb", connectionId: "conn-1"),
            SlotInfo(id: "B", bankKey: "dkb", connectionId: "conn-1"),
        ])
        XCTAssertEqual(secondPlan, [])
    }

    func test_bankKey_prefersLogoId() {
        let slot = BankSlot(id: "x", iban: "DE...", displayName: "DKB Hauptkonto",
                            logoId: "dkb", nickname: nil)
        XCTAssertEqual(SlotConnectionHealer.bankKey(for: slot), "dkb")
    }

    func test_bankKey_fallsBackToDisplayName_whenLogoIdNil() {
        let slot = BankSlot(id: "x", iban: "DE...", displayName: "DKB Hauptkonto",
                            logoId: nil, nickname: nil)
        XCTAssertEqual(SlotConnectionHealer.bankKey(for: slot), "dkb hauptkonto")
    }

    func test_bankKey_fallsBackToDisplayName_whenLogoIdEmpty() {
        let slot = BankSlot(id: "x", iban: "DE...", displayName: "Sparkasse Köln",
                            logoId: "", nickname: nil)
        XCTAssertEqual(SlotConnectionHealer.bankKey(for: slot), "sparkasse köln")
    }

    func test_bankKey_fallsBackToOwnId_whenBothEmpty() {
        // Verhindert dass leere bankKeys verschiedene Slots fälschlich gruppieren
        let slot = BankSlot(id: "uniq-id", iban: "", displayName: "",
                            logoId: nil, nickname: nil)
        XCTAssertEqual(SlotConnectionHealer.bankKey(for: slot), "uniq-id")
    }
}
