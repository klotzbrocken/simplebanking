import XCTest

// MARK: - sb summary date-range derivation
//
// Schützt P3-Fix: vorher festes sinceDaysAgo=90 → ältere Monate (>3 Monate
// zurück) erschienen leer. Jetzt aus YYYY-MM direkt abgeleitet.
//
// Wir können `Shortcuts.daysFromTodayToStartOfMonth` nicht via @testable
// importieren (CLI-Target ist Executable, das ist nicht @testable-fähig).
// Deshalb spiegeln wir die pure Logik hier — wenn die Production-Logik
// driftet, brauchen wir auch den Test anzupassen (manuelle Sync-Pflicht).

final class ShortcutsDateRangeTests: XCTestCase {

    private func daysFromTodayToStartOfMonth(_ yyyymm: String, today: Date) -> Int {
        let parts = yyyymm.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else {
            return 90
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let startOfMonth = cal.date(from: comps) else { return 90 }
        let todayDay = cal.startOfDay(for: today)
        let diff = cal.dateComponents([.day], from: startOfMonth, to: todayDay).day ?? 90
        return max(1, diff)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return cal.date(from: c)!
    }

    // MARK: - happy paths

    func test_currentMonth_returnsAtMost31Days() {
        // Heute Mitte des Monats → Tage seit 1. des Monats sind klein.
        let today = date(2026, 4, 26)
        XCTAssertEqual(daysFromTodayToStartOfMonth("2026-04", today: today), 25,
            "26.4. → 25 Tage seit 1.4.")
    }

    func test_lastMonth_returnsBetween28And62Days() {
        let today = date(2026, 4, 26)
        let days = daysFromTodayToStartOfMonth("2026-03", today: today)
        XCTAssertEqual(days, 56, "26.4. → 56 Tage seit 1.3.")
    }

    func test_threeMonthsBack_returnsMoreThanOldDefault() {
        // Hauptzweck des Fixes: ältere Monate als 90 Tage zurück.
        let today = date(2026, 4, 26)
        let days = daysFromTodayToStartOfMonth("2026-01", today: today)
        XCTAssertGreaterThan(days, 90,
            "Januar von Ende April aus → muss >90 Tage sein, sonst alter Bug")
    }

    func test_yearAgo_returnsCorrectDayCount() {
        let today = date(2026, 4, 26)
        let days = daysFromTodayToStartOfMonth("2025-04", today: today)
        XCTAssertEqual(days, 365 + 25, "26.4.2026 → 1.4.2025 ist 390 Tage")
    }

    // MARK: - edge cases

    func test_invalidFormat_returnsLegacyDefault() {
        let today = date(2026, 4, 26)
        XCTAssertEqual(daysFromTodayToStartOfMonth("not-a-month", today: today), 90)
        XCTAssertEqual(daysFromTodayToStartOfMonth("2026", today: today), 90)
        XCTAssertEqual(daysFromTodayToStartOfMonth("", today: today), 90)
    }

    func test_futureMonth_returnsAtLeast1() {
        // --month 2027-12 wenn heute 2026-04 → wir wollen nicht negativ
        let today = date(2026, 4, 26)
        let days = daysFromTodayToStartOfMonth("2027-12", today: today)
        XCTAssertGreaterThanOrEqual(days, 1)
    }

    func test_currentMonthFirstDay_returnsZeroClampedToOne() {
        // Edge case: 1. des Monats — heute ist 1. ist startOfMonth → 0 Tage.
        // max(1, ...) clamped → 1.
        let today = date(2026, 4, 1)
        XCTAssertEqual(daysFromTodayToStartOfMonth("2026-04", today: today), 1)
    }
}
