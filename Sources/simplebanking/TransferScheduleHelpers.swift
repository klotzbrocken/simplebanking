import Foundation

// MARK: - TransferScheduleHelpers
//
// Pure functions für die Termin-Auswahl im TransferSheet (Quick-Picks +
// Datums-Formatierung). Bewusst ohne UI-Bezug — testbar ohne SwiftUI.

enum TransferScheduleHelpers {

    /// Heute, normalisiert auf 00:00:00 lokaler Zeitzone.
    static func today(_ now: Date = Date(),
                      calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    /// Morgen (heute + 1 Tag).
    static func tomorrow(_ now: Date = Date(),
                         calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: today(now, calendar: calendar))!
    }

    /// In 7 Tagen.
    static func in7Days(_ now: Date = Date(),
                        calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 7, to: today(now, calendar: calendar))!
    }

    /// Erster Tag des nächsten Monats. Wenn heute der 1. ist, kommt der
    /// 1. des Folgemonats raus (also nicht heute).
    static func firstOfNextMonth(_ now: Date = Date(),
                                 calendar: Calendar = .current) -> Date {
        let start = today(now, calendar: calendar)
        // 1 Monat addieren, dann auf den 1. des Monats clampen.
        let plusMonth = calendar.date(byAdding: .month, value: 1, to: start)!
        var comps = calendar.dateComponents([.year, .month], from: plusMonth)
        comps.day = 1
        return calendar.date(from: comps)!
    }

    /// Anzeige-Format `DD.MM.YYYY` (de_DE-locale). Verwendet für UI-Ausgabe.
    static func formatDateDisplay(_ date: Date) -> String {
        Self.displayFormatter.string(from: date)
    }

    /// API-Format `YYYY-MM-DD` (ISO 8601 date-only). Verwendet als
    /// `requestedExecutionDate` für YAXI/Routex.
    static func formatDateISO(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    nonisolated(unsafe) private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current   // ISO-Date-only ohne TZ-Konversion
        return f
    }()
}
