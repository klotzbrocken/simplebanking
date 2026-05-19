import Foundation

// MARK: - SlotConnectionHealer
//
// Self-Heal-Migration für ein Problem aus Pre-1.5.0-Builds:
// Wenn ein Multi-Account-Setup (z.B. DKB-Familie, Sparkasse mit Gemeinschafts-
// + Sub-Konten) mit einem Build vor Commit `f038fd5` durchlaufen wurde,
// bekam nur EIN Slot (= der beim discoverBank() aktive) seine connectionId
// in UserDefaults persistiert. Die übrigen Slots haben Credentials + IBAN,
// aber leeren `connectionIdKey` → bei jedem Refresh früh-rausfallen mit
// „no connectionId yet".
//
// Der eigentliche Fix in 1.5.0 (`copyConnectionStateKeys`) repariert nur
// NEUE Setups. Bestehende, bereits korrumpierte Slots brauchen eine
// Migration. Diese läuft beim App-Start einmal pro App-Lifecycle.
//
// Heuristik: zwei Slots desselben Bank-Brands (Priorität: logoId, sonst
// canonical displayName) teilen sich denselben Online-Banking-Login. Wenn
// einer eine connectionId hat und ein anderer nicht, wird sie kopiert. Im
// theoretisch möglichen Fall „2 separate Logins bei derselben Bank" sieht
// der User weiterhin Errors auf dem zweiten Login — also kein Regress.

enum SlotConnectionHealer {

    /// Pure-Function-Eingabe pro Slot. Test-freundlich, frei von Module-State.
    struct SlotInfo: Equatable {
        let id: String
        let bankKey: String
        let connectionId: String?
    }

    /// Heal-Vorschlag: kopiere connectionId + credModel-Keys von `fromSlotId`
    /// nach `toSlotId`. Beide gehören laut Heuristik zum gleichen Bank-Login.
    struct HealAction: Equatable {
        let fromSlotId: String
        let toSlotId: String
        let bankKey: String
    }

    /// Pure: berechnet aus dem aktuellen Slot-State, welche Slots gesund-
    /// kopiert werden können. Deterministisch, sortet Aktionen nach toSlotId
    /// für stabile Test-Erwartungen.
    static func computeHealPlan(slots: [SlotInfo]) -> [HealAction] {
        // Slots gruppieren nach bankKey
        let grouped = Dictionary(grouping: slots, by: { $0.bankKey })
        var actions: [HealAction] = []

        for (_, groupSlots) in grouped {
            guard groupSlots.count > 1 else { continue }
            // Sources: Slots mit nicht-leerer connectionId
            // Targets: Slots ohne / leere connectionId
            let withConn = groupSlots.filter {
                if let cid = $0.connectionId, !cid.isEmpty { return true }
                return false
            }.sorted(by: { $0.id < $1.id })
            let withoutConn = groupSlots.filter {
                if let cid = $0.connectionId, !cid.isEmpty { return false }
                return true
            }.sorted(by: { $0.id < $1.id })

            guard let source = withConn.first, !withoutConn.isEmpty else { continue }

            for target in withoutConn {
                actions.append(HealAction(
                    fromSlotId: source.id,
                    toSlotId:   target.id,
                    bankKey:    source.bankKey
                ))
            }
        }

        return actions.sorted { $0.toSlotId < $1.toSlotId }
    }

    /// Berechnet den Bank-Key für einen Slot. Bevorzugt `logoId` (resolved
    /// Brand, stabil), fällt zurück auf normalisiertes `displayName`. Slots
    /// ohne beides fallen auf ihre eigene `id` zurück — damit gruppieren sie
    /// alleine und triggern nie eine Heal-Action.
    static func bankKey(for slot: BankSlot) -> String {
        if let logo = slot.logoId, !logo.isEmpty { return logo.lowercased() }
        let normalized = slot.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? slot.id : normalized
    }

    /// Side-effecting: liest Slots aus `MultibankingStore`, baut den Plan,
    /// wendet ihn via `YaxiService.copyConnectionStateKeys` an. Idempotent —
    /// nach einmaligem Lauf sind alle Targets gehealt; ein zweiter Lauf
    /// produziert leeren Plan (kein doppeltes Kopieren).
    @MainActor
    static func runOnStartup() {
        let d = UserDefaults.standard
        let slotInfos: [SlotInfo] = MultibankingStore.shared.slots.map { slot in
            SlotInfo(
                id: slot.id,
                bankKey: bankKey(for: slot),
                connectionId: d.string(forKey: YaxiService.connectionIdKey(for: slot.id))
            )
        }

        let plan = computeHealPlan(slots: slotInfos)
        guard !plan.isEmpty else { return }

        AppLogger.log("SlotConnectionHealer: \(plan.count) slots zu healen", category: "SlotHealer")
        for action in plan {
            YaxiService.copyConnectionStateKeys(
                fromSlotId: action.fromSlotId,
                toSlotId:   action.toSlotId
            )
            AppLogger.log(
                "SlotConnectionHealer: healed \(action.toSlotId.prefix(8)) ← \(action.fromSlotId.prefix(8)) (bank=\(action.bankKey))",
                category: "SlotHealer"
            )
        }
    }
}
