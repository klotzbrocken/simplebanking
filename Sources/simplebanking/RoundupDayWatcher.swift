import Foundation
import AppKit

extension Notification.Name {
    /// Gefeuert wenn ein offener Tages-Spartopf eine User-Entscheidung braucht.
    /// userInfo: ["slotId": String, "potDate": String].
    static let roundupPromptRequired = Notification.Name("simplebanking.roundupPromptRequired")
}

/// End-of-Day-Trigger fürs Aufrunden. Wird beim ersten App-Open nach lokaler
/// Mitternacht / vor jedem Flyout-Open / nach jedem erfolgreichen Refresh
/// gerufen. Markiert `open` Pots vor heute als `pending` und feuert genau eine
/// `.roundupPromptRequired`-Notification für den ältesten nicht-snoozed Pot.
@MainActor
final class RoundupDayWatcher {

    static let shared = RoundupDayWatcher()
    private init() {}

    nonisolated(unsafe) private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Cutoff = startOfDay(now) in lokaler Zeitzone als `YYYY-MM-DD`. Alles
    /// davor zählt als „Vortag oder älter".
    func checkAndPromptIfNeeded(bankId: String = "primary") {
        let cutoffDate = Self.isoDateFormatter.string(from: Calendar.current.startOfDay(for: Date()))

        for slot in MultibankingStore.shared.slots {
            let settings = BankSlotSettingsStore.load(slotId: slot.id)
            guard settings.roundupEnabled else { continue }

            _ = try? RoundupStore.markStalePending(
                slotId: slot.id, before: cutoffDate, bankId: bankId
            )

            let pending = (try? RoundupStore.pendingPots(
                slotId: slot.id, before: cutoffDate, bankId: bankId
            )) ?? []

            for pot in pending where !isSnoozed(slotId: slot.id, potDate: pot.potDate) {
                postPrompt(slotId: slot.id, potDate: pot.potDate)
                return  // Nur EINEN Pot pro Aufruf prompten.
            }
        }
    }

    /// Manueller Trigger — z.B. aus Settings ein „Topf jetzt anzeigen"-Button.
    func presentManually(slotId: String, potDate: String) {
        postPrompt(slotId: slotId, potDate: potDate)
    }

    // MARK: - Private

    private func isSnoozed(slotId: String, potDate: String) -> Bool {
        let key = "simplebanking.roundupSnoozeUntil.\(slotId).\(potDate)"
        guard let until = UserDefaults.standard.object(forKey: key) as? Date else { return false }
        if until > Date() { return true }
        // Snooze expired — cleanup, damit der Key nicht ewig hängenbleibt.
        UserDefaults.standard.removeObject(forKey: key)
        return false
    }

    private func postPrompt(slotId: String, potDate: String) {
        NotificationCenter.default.post(
            name: .roundupPromptRequired,
            object: nil,
            userInfo: ["slotId": slotId, "potDate": potDate]
        )
    }
}
