import Foundation

// MARK: - Centralized slot-context switching
//
// Vorher waren `YaxiService.activeSlotId`, `CredentialsStore.activeSlotId` und
// `TransactionsDatabase.activeSlotId` drei separate `nonisolated(unsafe) static var`,
// die an jedem Switch-Punkt manuell sequenziell gesetzt werden mussten — mit
// teils inkonsistenter Reihenfolge zwischen 6 Triple-Set-Callsites in BalanceBar.
// Wer einen Layer vergaß (oder ein neuer Layer kam dazu), produzierte silent
// stale state.
//
// `SlotContext.activate(slotId:)` ist die zentrale Stelle für den Switch. Wenn
// ein neuer Layer mit `activeSlotId` dazukommt, wird er hier ergänzt und alle
// Triple-Set-Callsites bekommen das Update automatisch.
//
// Race-Window: die Setzungen sind sequenziell. Cross-Thread-Reader (CLI-Process
// liest Persistierten state, GRDB-Background-Threads lesen DB-Lokation am Anfang
// jeder Operation) sehen das mid-update-Window theoretisch — praktisch passieren
// alle Setzungen sync auf MainActor und DB-Reads picken den slotId am Anfang.
// Komplette Auflösung würde Computed-Property auf MultibankingStore erfordern
// und ist als separater Refactor geplant.

enum SlotContext {

    /// Schaltet alle Layer auf den neuen Slot. Single Point of Truth.
    static func activate(slotId: String) {
        YaxiService.activeSlotId = slotId
        CredentialsStore.activeSlotId = slotId
        TransactionsDatabase.activeSlotId = slotId
    }

    /// Snapshot des aktuellen Slot-Status für temporäre Switches.
    /// Pattern: `let snap = SlotContext.snapshot(); defer { SlotContext.restore(snap) }`
    /// Genutzt von Importers, die kurz in einen anderen Slot wechseln und am
    /// Ende wiederherstellen.
    struct Snapshot: Equatable {
        let yaxi: String
        let credentials: String
        let database: String
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            yaxi: YaxiService.activeSlotId,
            credentials: CredentialsStore.activeSlotId,
            database: TransactionsDatabase.activeSlotId
        )
    }

    static func restore(_ snapshot: Snapshot) {
        YaxiService.activeSlotId = snapshot.yaxi
        CredentialsStore.activeSlotId = snapshot.credentials
        TransactionsDatabase.activeSlotId = snapshot.database
    }
}
