import Foundation
import AppKit

/// Runtime-State der Aufrunden-Ansicht. Singleton, MainActor-bound.
/// Wird durch den Centsign-Toggle in TransactionsPanelView aktiviert.
///
/// Tageswerte (Heute/Gestern/Vorgestern/Monat) werden **live** aus der
/// gerade angezeigten TRX-Liste + aktuellem `stepCents` berechnet — sodass
/// ein Step-Wechsel im Banner sofort die Anzeige aktualisiert (hypothetische
/// "was wäre wenn"-Sicht). Keine Persistierung der Pot-Status (`roundup_pots`
/// existiert weiterhin, wird vom Pipeline-Hook gefüllt, aber UI liest live).
@MainActor
final class RoundupViewState: ObservableObject {

    static let shared = RoundupViewState()
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSlotSettingsChanged),
            name: .slotSettingsChanged,
            object: nil
        )
    }

    @Published var isActive: Bool = false
    @Published var stepCents: Int = 100
    @Published var todayPotCents: Int = 0
    @Published var yesterdayPotCents: Int = 0
    @Published var dayBeforeYesterdayPotCents: Int = 0
    @Published var monthToDateCents: Int = 0

    private var cachedTransactions: [TransactionsResponse.Transaction] = []

    /// Aktiviert den View-Mode für den Slot, lädt Step + führt Live-Berechnung
    /// der Tageswerte aus der TRX-Liste durch.
    func activate(slotId: String, bankId: String, transactions: [TransactionsResponse.Transaction]) {
        let settings = BankSlotSettingsStore.load(slotId: slotId)
        guard settings.roundupEnabled else { return }
        cachedTransactions = transactions
        stepCents = settings.roundupStepCents
        recomputeLiveValues()
        isActive = true
    }

    func deactivate() {
        isActive = false
        todayPotCents = 0
        yesterdayPotCents = 0
        dayBeforeYesterdayPotCents = 0
        monthToDateCents = 0
        cachedTransactions = []
    }

    /// Push neue TRX-Liste vom Caller (z.B. nach Refresh/Filter-Change).
    func setTransactions(_ transactions: [TransactionsResponse.Transaction]) {
        cachedTransactions = transactions
        guard isActive else { return }
        recomputeLiveValues()
    }

    /// Step-Wechsel über den Banner-Picker: persistiert in Settings, ruft
    /// Recompute. Caller-Notification (.slotSettingsChanged) feuert die View-
    /// Subscriber, hier intern direkt aktualisieren.
    func applyStepChange(slotId: String, bankId: String, stepCents: Int) {
        var settings = BankSlotSettingsStore.load(slotId: slotId)
        settings.roundupStepCents = stepCents
        BankSlotSettingsStore.save(settings, slotId: slotId)
        self.stepCents = stepCents
        recomputeLiveValues()
        NotificationCenter.default.post(name: .slotSettingsChanged, object: nil)
    }

    // MARK: - Private compute

    private func recomputeLiveValues() {
        guard stepCents > 0 else {
            todayPotCents = 0; yesterdayPotCents = 0
            dayBeforeYesterdayPotCents = 0; monthToDateCents = 0
            return
        }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let today = Self.isoDateFormatter.string(from: startOfToday)
        let yesterday = Self.isoDateFormatter.string(from: cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday)
        let dayBefore = Self.isoDateFormatter.string(from: cal.date(byAdding: .day, value: -2, to: startOfToday) ?? startOfToday)
        let monthStart = Self.isoDateFormatter.string(from: cal.date(from: cal.dateComponents([.year, .month], from: startOfToday)) ?? startOfToday)

        todayPotCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: today, bookingDateTo: today, stepCents: stepCents
        )
        yesterdayPotCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: yesterday, bookingDateTo: yesterday, stepCents: stepCents
        )
        dayBeforeYesterdayPotCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: dayBefore, bookingDateTo: dayBefore, stepCents: stepCents
        )
        monthToDateCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: monthStart, bookingDateTo: today, stepCents: stepCents
        )
    }

    // MARK: - Notifications

    @objc private func handleSlotSettingsChanged() {
        guard isActive,
              let slotId = MultibankingStore.shared.activeSlot?.id else { return }
        let settings = BankSlotSettingsStore.load(slotId: slotId)
        if !settings.roundupEnabled {
            deactivate()
        } else if settings.roundupStepCents != stepCents {
            stepCents = settings.roundupStepCents
            recomputeLiveValues()
        }
    }

    // MARK: - Private

    nonisolated(unsafe) private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
