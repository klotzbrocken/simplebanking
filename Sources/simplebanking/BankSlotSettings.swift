import Foundation

// MARK: - Per-Account Settings

struct BankSlotSettings: Codable {
    var salaryDay: Int = 1
    var dispoLimit: Int = 0
    var targetBuffer: Int = 500
    var targetSavingsRate: Int = 20
    var fetchDays: Int = 60
    var balanceSignalLowUpperBound: Int = 500
    var balanceSignalMediumUpperBound: Int = 2000
    /// Fixed salary amount — also sets MoneyMood green threshold (Option C). 0 = auto-detect.
    var salaryAmount: Int = 0
    /// 0 = Anfang des Monats (day 1, ±4 d), 1 = Mitte (day 15, ±4 d), 2 = Individuell (exact salaryDay).
    var salaryDayPreset: Int = 2
    /// `true` = die Bank liefert den Kontostand inklusive Dispokredit (z.B. C24) → Dispo wird
    /// vom angezeigten Saldo abgezogen. Per-Slot einstellbar in Settings → Konten.
    var creditLimitIncluded: Bool = false

    /// Effective center day for the salary period, derived from preset.
    var effectiveSalaryDay: Int {
        switch salaryDayPreset {
        case 0: return 1
        case 1: return 15
        default: return salaryDay
        }
    }

    /// Legacy: symmetrisches Toleranz-Fenster. Nutze für neue Logik besser die
    /// asymmetrischen Varianten `salaryDayToleranceBefore` / `-After`.
    var salaryDayTolerance: Int { salaryDayToleranceBefore }

    /// Wie viele Tage VOR dem nominalen Gehaltstag das Gehalt typischerweise schon
    /// kommen kann (z.B. wenn der 1. auf einen Sonntag fällt, buchen viele AG am Freitag).
    /// Für `Anfang`/`Mitte`-Presets: 4 Tage Toleranz nach hinten, für `Individuell`: 0.
    var salaryDayToleranceBefore: Int { salaryDayPreset == 2 ? 0 : 4 }

    /// Wie viele Tage NACH dem nominalen Gehaltstag das Gehalt spätestens noch
    /// akzeptiert wird. In der Praxis viel enger als das Before-Fenster: Gehalt
    /// kommt selten 4 Tage zu spät, aber manchmal 1 Tag durch Clearing-Delay.
    /// Für `Anfang`/`Mitte`-Presets: 1 Tag, für `Individuell`: 0.
    var salaryDayToleranceAfter: Int { salaryDayPreset == 2 ? 0 : 1 }

    init(
        salaryDay: Int = 1,
        dispoLimit: Int = 0,
        targetBuffer: Int = 500,
        targetSavingsRate: Int = 20,
        fetchDays: Int = 60,
        balanceSignalLowUpperBound: Int = 500,
        balanceSignalMediumUpperBound: Int = 2000,
        salaryAmount: Int = 0,
        salaryDayPreset: Int = 2
    ) {
        self.salaryDay = salaryDay
        self.dispoLimit = dispoLimit
        self.targetBuffer = targetBuffer
        self.targetSavingsRate = targetSavingsRate
        self.fetchDays = fetchDays
        self.balanceSignalLowUpperBound = balanceSignalLowUpperBound
        self.balanceSignalMediumUpperBound = balanceSignalMediumUpperBound
        self.salaryAmount = salaryAmount
        self.salaryDayPreset = salaryDayPreset
    }

    // Custom decoder: use decodeIfPresent for every field so that JSON saved
    // by older app versions (missing newer fields) doesn't cause a decode failure.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        salaryDay                    = (try? c.decodeIfPresent(Int.self, forKey: .salaryDay)) ?? 1
        dispoLimit                   = (try? c.decodeIfPresent(Int.self, forKey: .dispoLimit)) ?? 0
        targetBuffer                 = (try? c.decodeIfPresent(Int.self, forKey: .targetBuffer)) ?? 500
        targetSavingsRate            = (try? c.decodeIfPresent(Int.self, forKey: .targetSavingsRate)) ?? 20
        fetchDays                    = (try? c.decodeIfPresent(Int.self, forKey: .fetchDays)) ?? 60
        balanceSignalLowUpperBound   = (try? c.decodeIfPresent(Int.self, forKey: .balanceSignalLowUpperBound)) ?? 500
        balanceSignalMediumUpperBound = (try? c.decodeIfPresent(Int.self, forKey: .balanceSignalMediumUpperBound)) ?? 2000
        salaryAmount                 = (try? c.decodeIfPresent(Int.self, forKey: .salaryAmount)) ?? 0
        salaryDayPreset              = (try? c.decodeIfPresent(Int.self, forKey: .salaryDayPreset)) ?? 2
        creditLimitIncluded          = (try? c.decodeIfPresent(Bool.self, forKey: .creditLimitIncluded)) ?? false
    }
}

// MARK: - Store

enum BankSlotSettingsStore {
    private static func key(for slotId: String) -> String {
        "simplebanking.slotSettings.\(slotId)"
    }

    /// Auto-Sync-Zeitraum ist auf 90 Tage begrenzt (ältere Historie via Import).
    /// Bestandsdaten mit fetchDays > 90 werden beim Laden auf 90 gedeckelt.
    private static let maxAutoSyncDays = 90

    /// Loads settings for a slot. On first access, migrates from global AppStorage defaults.
    /// Caps `fetchDays` at `maxAutoSyncDays` (silent migration from pre-1.4.0 values 180/365).
    static func load(slotId: String) -> BankSlotSettings {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: key(for: slotId)),
           var settings = try? JSONDecoder().decode(BankSlotSettings.self, from: data) {
            if settings.fetchDays > maxAutoSyncDays {
                settings.fetchDays = maxAutoSyncDays
                save(settings, slotId: slotId)
            }
            return settings
        }
        // Migration: use existing global defaults as starting values for new per-slot storage
        let migratedFetch   = ud.integer(forKey: "fetchDays")
        let migratedLow     = ud.integer(forKey: "balanceSignalLowUpperBound")
        let migratedMedium  = ud.integer(forKey: "balanceSignalMediumUpperBound")
        let migratedSalary  = ud.integer(forKey: "salaryDay")
        let migratedBuffer  = ud.integer(forKey: "targetBuffer")
        let migratedSavings = ud.integer(forKey: "targetSavingsRate")
        let defaultedFetch  = migratedFetch == 0 ? 60 : migratedFetch
        return BankSlotSettings(
            salaryDay:                  max(1, migratedSalary  == 0 ? 1   : migratedSalary),
            dispoLimit:                 ud.integer(forKey: "dispoLimit"),
            targetBuffer:               max(100, migratedBuffer  == 0 ? 500  : migratedBuffer),
            targetSavingsRate:          max(1, migratedSavings == 0 ? 20  : migratedSavings),
            fetchDays:                  min(maxAutoSyncDays, max(30, defaultedFetch)),
            balanceSignalLowUpperBound: migratedLow    == 0 ? 500  : migratedLow,
            balanceSignalMediumUpperBound: migratedMedium == 0 ? 2000 : migratedMedium
        )
    }

    static func save(_ settings: BankSlotSettings, slotId: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key(for: slotId))
    }

    static func delete(slotId: String) {
        UserDefaults.standard.removeObject(forKey: key(for: slotId))
    }
}
