import AppKit
import Foundation

// MARK: - BankSlot

struct BankSlot: Codable, Identifiable, Equatable {
    let id: String          // UUID string, stable identifier
    var iban: String
    var displayName: String
    var logoId: String?

    static func makeNew(iban: String, displayName: String, logoId: String?) -> BankSlot {
        BankSlot(id: UUID().uuidString, iban: iban, displayName: displayName, logoId: logoId)
    }
}

// MARK: - MultibankingStore

/// Single source of truth for all bank slots and the active slot index.
/// Thread-safe via @MainActor; persist to UserDefaults as JSON.
@MainActor
final class MultibankingStore: ObservableObject {

    static let shared = MultibankingStore()

    private let slotsKey        = "simplebanking.multibanking.slots"
    private let activeIndexKey  = "simplebanking.multibanking.activeIndex"

    @Published private(set) var slots: [BankSlot] = []
    @Published private(set) var activeIndex: Int = 0

    var activeSlot: BankSlot? { slots.indices.contains(activeIndex) ? slots[activeIndex] : slots.first }

    private init() {
        load()
        migrateFromLegacyIfNeeded()
        fixDuplicateDisplayNames()
    }

    // MARK: - Public API

    func addSlot(_ slot: BankSlot) {
        slots.append(slot)
        activeIndex = slots.count - 1
        save()
    }

    func removeSlot(id: String) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        slots.remove(at: idx)
        if activeIndex >= slots.count { activeIndex = max(0, slots.count - 1) }
        save()
    }

    func setActive(index: Int) {
        guard slots.indices.contains(index) else { return }
        activeIndex = index
        UserDefaults.standard.set(activeIndex, forKey: activeIndexKey)
    }

    func updateSlot(_ slot: BankSlot) {
        guard let idx = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slots[idx] = slot
        save()
    }

    /// Called after setup wizard completes for the first slot (replaces slot[0])
    func replaceFirstSlot(with slot: BankSlot) {
        if slots.isEmpty {
            slots.append(slot)
        } else {
            slots[0] = slot
        }
        activeIndex = 0
        save()
    }

    // MARK: - Persistence

    private func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: slotsKey),
           let decoded = try? JSONDecoder().decode([BankSlot].self, from: data) {
            slots = decoded
        }
        activeIndex = d.integer(forKey: activeIndexKey)
        if !slots.indices.contains(activeIndex) { activeIndex = 0 }
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(slots) {
            d.set(data, forKey: slotsKey)
        }
        d.set(activeIndex, forKey: activeIndexKey)
    }

    // MARK: - Legacy migration

    /// If slots are empty but a legacy IBAN exists, import it as slot[0].
    private func migrateFromLegacyIfNeeded() {
        guard slots.isEmpty else { return }
        guard let iban = UserDefaults.standard.string(forKey: "simplebanking.iban"),
              !iban.isEmpty else { return }
        // Use the legacy ID so existing per-slot keys derived from this ID map correctly.
        let legacySlot = BankSlot(id: "legacy", iban: iban, displayName: "", logoId: nil)
        slots = [legacySlot]
        activeIndex = 0
        save()
    }

    /// One-time corruption fix: if the legacy slot shares a displayName with a newer slot,
    /// the legacy slot was corrupted by a race condition during second-account setup.
    /// Clear only the legacy slot's name so IBAN lookup re-derives the correct bank name.
    /// Non-legacy slots keep their user-chosen names unchanged.
    private func fixDuplicateDisplayNames() {
        guard slots.count > 1 else { return }
        guard let legacyIdx = slots.firstIndex(where: { $0.id == "legacy" }) else { return }
        let legacyName = slots[legacyIdx].displayName
        guard !legacyName.isEmpty else { return }
        let otherHasSameName = slots.indices.contains(where: { $0 != legacyIdx && slots[$0].displayName == legacyName })
        guard otherHasSameName else { return }
        // Legacy slot's name is duplicated — it got the second bank's name by mistake. Clear it.
        slots[legacyIdx] = BankSlot(id: "legacy", iban: slots[legacyIdx].iban, displayName: "", logoId: nil)
        save()
    }
}
