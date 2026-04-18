import EventKit
import Foundation

/// Manages creation and deletion of EKReminders in macOS Reminders.app.
/// Linked mode: removing a reminder in simplebanking also deletes it from Reminders.app.
final class ReminderService {

    nonisolated(unsafe) static let shared = ReminderService()
    private let store = EKEventStore()

    private init() {}

    // MARK: - Access

    /// Requests Reminders access. Returns true if granted.
    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            do {
                return try await store.requestFullAccessToReminders()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .authorized ||
        {
            if #available(macOS 14.0, *) {
                return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            }
            return false
        }()
    }

    // MARK: - Create

    /// Creates a reminder in the default Reminders list. Returns the `calendarItemIdentifier`.
    func createReminder(title: String, notes: String? = nil, dueDate: Date) async throws -> String {
        if !hasAccess {
            let granted = await requestAccess()
            guard granted else { throw ReminderError.accessDenied }
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let notes { reminder.notes = notes }
        reminder.calendar = store.defaultCalendarForNewReminders()
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: dueDate
        )
        reminder.dueDateComponents = components
        reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    // MARK: - Delete

    /// Deletes the reminder with the given calendarItemIdentifier. Silently ignores not-found.
    func deleteReminder(id: String) async {
        guard hasAccess else { return }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? store.remove(item, commit: true)
    }

    // MARK: - Exists check (for startup sync)

    /// Returns false if the reminder was deleted from Reminders.app externally.
    func reminderExists(id: String) -> Bool {
        guard hasAccess else { return true } // assume exists if no access
        return store.calendarItem(withIdentifier: id) != nil
    }

    // MARK: - Startup sync

    /// Removes stale reminder_ek_ids for reminders that no longer exist in Reminders.app.
    func pruneStaleReminders(bankIds: [String]) async {
        guard hasAccess else { return }
        let all = TransactionsDatabase.allReminders(bankIds: bankIds)
        for entry in all {
            if !reminderExists(id: entry.reminderId) {
                try? TransactionsDatabase.setReminderId(txID: entry.txID, bankId: entry.bankId, reminderId: nil)
            }
        }
    }
}

enum ReminderError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Zugriff auf Erinnerungen verweigert. Bitte in den Systemeinstellungen erlauben."
        }
    }
}
