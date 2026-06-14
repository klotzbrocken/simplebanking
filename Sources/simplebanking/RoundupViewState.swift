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
    /// Payout-Varianten der Tageswerte: identisch zu den `*PotCents`, aber bereits
    /// als `transferred` finalisierte Tage werden ausgeblendet. Der Auswahl-Dialog
    /// (RoundupChoiceSheet) liest diese — so kann ein bereits ausgezahlter Tag nicht
    /// erneut überwiesen werden. Die `*PotCents` oben bleiben die volle hypothetische
    /// Sicht für die motivational Savings-Card.
    @Published var todayPayoutCents: Int = 0
    @Published var yesterdayPayoutCents: Int = 0
    @Published var dayBeforePayoutCents: Int = 0
    @Published var monthToDatePayoutCents: Int = 0
    /// Aufeinanderfolgende Tage mit Aufrunden-Beitrag, rückwärts vom letzten
    /// Beitrags-Tag. Bei step-Wechsel + neuer TRX-Push neu berechnet.
    @Published var streakDays: Int = 0

    private var cachedTransactions: [TransactionsResponse.Transaction] = []
    private var lastSlotId: String?
    private var lastBankId: String = "primary"

    /// ISO-Datums-Strings des letzten Recompute — vom Dialog genutzt, um den
    /// gewählten Zeitraum auf einen Finalisierungs-Range `[from, to]` zu mappen.
    private(set) var todayDate: String = ""
    private(set) var yesterdayDate: String = ""
    private(set) var dayBeforeDate: String = ""
    private(set) var monthStartDate: String = ""

    /// Aktiviert den View-Mode für den Slot, lädt Step + führt Live-Berechnung
    /// der Tageswerte aus der TRX-Liste durch.
    func activate(slotId: String, bankId: String, transactions: [TransactionsResponse.Transaction]) {
        let settings = BankSlotSettingsStore.load(slotId: slotId)
        guard settings.roundupEnabled else { return }
        cachedTransactions = transactions
        lastSlotId = slotId
        lastBankId = bankId
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
        todayPayoutCents = 0
        yesterdayPayoutCents = 0
        dayBeforePayoutCents = 0
        monthToDatePayoutCents = 0
        streakDays = 0
        cachedTransactions = []
        lastSlotId = nil
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
        lastSlotId = slotId
        recomputeLiveValues()
        NotificationCenter.default.post(name: .slotSettingsChanged, object: nil)
    }

    /// Mappt einen Dialog-Zeitraum auf den Finalisierungs-Range `[from, to]`
    /// (inklusive). Nutzt die beim letzten Recompute gespeicherten Datums-Strings.
    func dateRange(for range: RoundupChoiceSheet.TimeRange) -> (from: String, to: String) {
        switch range {
        case .today: return (todayDate, todayDate)
        case .yesterday: return (yesterdayDate, yesterdayDate)
        case .dayBeforeYesterday: return (dayBeforeDate, dayBeforeDate)
        case .monthToDate: return (monthStartDate, todayDate)
        }
    }

    /// Nach einer erfolgreichen Auszahlung gerufen — lädt die `transferred`-Tage
    /// neu und blendet sie aus den Payout-Werten aus, sodass derselbe Betrag nicht
    /// erneut überwiesen werden kann.
    func refreshAfterPayout() {
        guard isActive else { return }
        recomputeLiveValues()
    }

    // MARK: - Private compute

    private func recomputeLiveValues() {
        guard stepCents > 0 else {
            todayPotCents = 0; yesterdayPotCents = 0
            dayBeforeYesterdayPotCents = 0; monthToDateCents = 0
            todayPayoutCents = 0; yesterdayPayoutCents = 0
            dayBeforePayoutCents = 0; monthToDatePayoutCents = 0
            streakDays = 0
            return
        }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let today = Self.isoDateFormatter.string(from: startOfToday)
        let yesterday = Self.isoDateFormatter.string(from: cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday)
        let dayBefore = Self.isoDateFormatter.string(from: cal.date(byAdding: .day, value: -2, to: startOfToday) ?? startOfToday)
        let monthStart = Self.isoDateFormatter.string(from: cal.date(from: cal.dateComponents([.year, .month], from: startOfToday)) ?? startOfToday)
        todayDate = today; yesterdayDate = yesterday
        dayBeforeDate = dayBefore; monthStartDate = monthStart

        // Spar-IBAN dieses Slots — Überweisungen dorthin werden NICHT aufgerundet.
        let savingsIban: String = {
            guard let slotId = lastSlotId else { return "" }
            return BankSlotSettingsStore.load(slotId: slotId).savingsAccountIban ?? ""
        }()

        // Bereits ausgezahlte Tage — aus den Payout-Werten ausgeblendet. Umfasst sowohl
        // einzelne `transferred`-Pot-Tage als auch ALLE Tage in persistierten Auszahlungs-
        // Ranges (deckt Buchungen ohne Pot-Zeile ab → verhindert Doppelauszahlung).
        let transferredDates: Set<String> = {
            guard let slotId = lastSlotId else { return [] }
            var dates = (try? RoundupStore.transferredPotDates(slotId: slotId, bankId: lastBankId)) ?? []
            let ranges = (try? RoundupStore.paidDateRanges(slotId: slotId, bankId: lastBankId)) ?? []
            for r in ranges { dates.formUnion(Self.datesInRange(from: r.from, to: r.to)) }
            return dates
        }()

        todayPotCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: today, bookingDateTo: today, stepCents: stepCents, savingsIban: savingsIban
        )
        yesterdayPotCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: yesterday, bookingDateTo: yesterday, stepCents: stepCents, savingsIban: savingsIban
        )
        dayBeforeYesterdayPotCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: dayBefore, bookingDateTo: dayBefore, stepCents: stepCents, savingsIban: savingsIban
        )
        monthToDateCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: monthStart, bookingDateTo: today, stepCents: stepCents, savingsIban: savingsIban
        )

        todayPayoutCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: today, bookingDateTo: today, stepCents: stepCents, excludingDates: transferredDates, savingsIban: savingsIban
        )
        yesterdayPayoutCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: yesterday, bookingDateTo: yesterday, stepCents: stepCents, excludingDates: transferredDates, savingsIban: savingsIban
        )
        dayBeforePayoutCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: dayBefore, bookingDateTo: dayBefore, stepCents: stepCents, excludingDates: transferredDates, savingsIban: savingsIban
        )
        monthToDatePayoutCents = RoundupCalculator.liveRoundupCents(
            transactions: cachedTransactions, bookingDateFrom: monthStart, bookingDateTo: today, stepCents: stepCents, excludingDates: transferredDates, savingsIban: savingsIban
        )

        streakDays = RoundupCalculator.liveStreakDays(
            transactions: cachedTransactions,
            savingsIban: savingsIban,
            today: Date(),
            stepCents: stepCents
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

    /// Alle ISO-Tage (YYYY-MM-DD) im inklusiven Range [from, to]. Leer bei ungültigem
    /// Range. Für den Ausschluss ausgezahlter Zeiträume aus der Live-Anzeige.
    private static func datesInRange(from: String, to: String) -> [String] {
        let cal = Calendar(identifier: .gregorian)
        guard let start = isoDateFormatter.date(from: from),
              let end = isoDateFormatter.date(from: to),
              start <= end else { return [] }
        var out: [String] = []
        var cur = cal.startOfDay(for: start)
        let last = cal.startOfDay(for: end)
        while cur <= last {
            out.append(isoDateFormatter.string(from: cur))
            guard let next = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return out
    }

    nonisolated(unsafe) private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
