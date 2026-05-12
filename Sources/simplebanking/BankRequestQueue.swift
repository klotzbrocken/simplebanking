import Foundation

/// Per-Slot HBCI-Mutex. Verhindert parallele Bank-Calls (balances / transactions
/// / transfer) für denselben Slot — mehrere Aufrufer (Auto-Refresh-Timer, CLI
/// `sb refresh`, TransferSheet, Diagnose-Session) konkurrieren sonst um denselben
/// HBCI-Dialogkontext und können sich gegenseitig die SCA-Sessions zerschießen.
///
/// Wer das Acquire nicht bekommt, soll möglichst graceful failen (Refresh skip,
/// CLI-Retry später) statt zu blockieren — daher non-blocking via `withSlot`.
actor BankRequestQueue {
    static let shared = BankRequestQueue()

    private var inFlight: Set<String> = []

    /// Atomares Acquire-Run-Release. Liefert `nil` wenn der Slot schon
    /// besetzt ist (graceful busy), sonst das Resultat des Closures.
    ///
    /// Wichtig: Release passiert via `defer` INSIDE des Actor-Methods.
    /// Damit ist garantiert dass `inFlight` vor dem Funktions-Return wieder
    /// leer ist — auch im Throw-Pfad. Vorher wurde `release` per
    /// `Task { await … }` außerhalb des Actors gescheduled; das konnte
    /// dazu führen dass direkt sequenzielle Folge-Calls den Slot
    /// fälschlich noch als busy sahen (P1.1).
    func withSlot<T>(_ slotId: String, _ work: () async throws -> T) async rethrows -> T? {
        guard !inFlight.contains(slotId) else { return nil }
        inFlight.insert(slotId)
        defer { inFlight.remove(slotId) }
        return try await work()
    }

    func isBusy(slotId: String) -> Bool {
        inFlight.contains(slotId)
    }
}
