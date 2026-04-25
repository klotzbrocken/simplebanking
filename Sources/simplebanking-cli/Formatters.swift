import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ColorMode: String, CaseIterable {
    case auto, always, never
}

enum ANSIColor {
    nonisolated(unsafe) static var enabled: Bool = isTTY()

    /// stdout ist ein echtes Terminal? Nur dann ANSI-Escape-Codes emittieren,
    /// damit Pipes (`sb balance | grep`) und Redirects (`sb tx > file`) sauberes
    /// Plain-Text bekommen.
    static func isTTY() -> Bool {
        isatty(fileno(stdout)) != 0
    }

    static func configure(_ mode: ColorMode) {
        switch mode {
        case .auto:   enabled = isTTY()
        case .always: enabled = true
        case .never:  enabled = false
        }
    }

    static func wrap(_ s: String, _ code: String) -> String {
        guard enabled else { return s }
        return "\u{001B}[\(code)m\(s)\u{001B}[0m"
    }

    static func red(_ s: String) -> String    { wrap(s, "31") }
    static func green(_ s: String) -> String  { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func dim(_ s: String) -> String    { wrap(s, "2") }
    static func bold(_ s: String) -> String   { wrap(s, "1") }
}

enum Format {

    private static let eurFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "de_DE")
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()

    static func money(_ value: Double, currency: String = "EUR") -> String {
        eurFmt.currencyCode = currency
        return eurFmt.string(from: NSNumber(value: value)) ?? "\(value) \(currency)"
    }

    /// Beträge mit Farbe: rot für Ausgaben, grün für Einnahmen, unverändert für 0.
    static func colorMoney(_ value: Double, currency: String = "EUR") -> String {
        let s = money(value, currency: currency)
        if value < 0 { return ANSIColor.red(s) }
        if value > 0 { return ANSIColor.green(s) }
        return s
    }

    /// Visible width ohne ANSI-Escape-Codes (\u{001B}[..m). Gleiches Padding
    /// wie `pad/padRight`, aber korrekt für eingefärbte Strings.
    static func visibleWidth(_ s: String) -> Int {
        var count = 0
        var inEscape = false
        for ch in s {
            if ch == "\u{001B}" { inEscape = true; continue }
            if inEscape {
                if ch == "m" { inEscape = false }
                continue
            }
            count += 1
        }
        return count
    }

    static func padRightANSI(_ s: String, to w: Int) -> String {
        let diff = w - visibleWidth(s)
        return diff > 0 ? String(repeating: " ", count: diff) + s : s
    }

    static func padANSI(_ s: String, to w: Int) -> String {
        let diff = w - visibleWidth(s)
        return diff > 0 ? s + String(repeating: " ", count: diff) : s
    }

    /// Pads `s` to visual width `w` (right-padded). Nicht unicode-perfekt aber gut genug für CLI-Tabellen.
    static func pad(_ s: String, to w: Int) -> String {
        let count = s.count
        if count >= w { return s }
        return s + String(repeating: " ", count: w - count)
    }

    static func padRight(_ s: String, to w: Int) -> String {
        let count = s.count
        if count >= w { return s }
        return String(repeating: " ", count: w - count) + s
    }

    /// JSON-Serializer, emit stdout-suitable UTF-8 string.
    static func json<T>(_ value: T) -> String where T: Encodable {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
