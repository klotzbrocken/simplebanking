import Foundation

/// Gemeinsame Render-Logik, die sowohl von den Hauptbefehlen (tx, summary) als
/// auch von den Shortcut-Befehlen (today, week, month) aufgerufen wird.
/// ArgumentParser-Struct-Instanzen können nicht direkt aufgerufen werden —
/// deshalb liegt die tatsächliche Arbeit hier, und die Commands sind dünne Wrapper.
enum Shortcuts {

    // MARK: - Transactions

    static func renderTransactions(
        days: Int, slot: String?, category: String?, limit: Int?, json: Bool
    ) throws {
        let rows = try DataReader.loadTransactions(
            slotId: slot, sinceDaysAgo: days, category: category, limit: limit
        )

        if json {
            struct Out: Encodable {
                let date: String
                let amount: Double
                let currency: String
                let merchant: String
                let category: String?
                let slotId: String
                let status: String
            }
            let items = rows.map { r in
                Out(date: r.bookingDate, amount: r.amount, currency: r.currency,
                    merchant: r.effectiveMerchant.isEmpty
                        ? (r.amount < 0 ? (r.empfaenger ?? "") : (r.absender ?? ""))
                        : r.effectiveMerchant,
                    category: r.category, slotId: r.slotId, status: r.status)
            }
            print(Format.json(items))
            return
        }

        if rows.isEmpty {
            print("Keine Transaktionen im gewählten Zeitraum.")
            return
        }
        print(ANSIColor.dim("DATUM       BETRAG           HÄNDLER                          KATEGORIE       SLOT"))
        print(ANSIColor.dim(String(repeating: "─", count: 100)))
        for r in rows {
            let merchant = r.effectiveMerchant.isEmpty
                ? (r.amount < 0 ? (r.empfaenger ?? "—") : (r.absender ?? "—"))
                : r.effectiveMerchant
            let cat = r.category ?? "—"
            let amtColored = Format.colorMoney(r.amount, currency: r.currency)
            let amt = Format.padRightANSI(amtColored, to: 14)
            let m = Format.pad(merchant.prefix(32).description, to: 33)
            let c = Format.pad(cat.prefix(15).description, to: 16)
            let slotShort = ANSIColor.dim(String(r.slotId.prefix(8)))
            print("\(ANSIColor.dim(r.bookingDate))  \(amt)  \(m)\(c)\(slotShort)")
        }
    }

    // MARK: - Summary

    static func renderSummary(month: String?, slot: String?, json: Bool) throws {
        let targetMonth = month ?? currentMonthKey()
        // Date-Range aus YYYY-MM ableiten — vorher fester 90-Tage-Cap, was für
        // ältere Monate (>3 Monate zurück) zu leerem Output führte obwohl Daten
        // im Cache waren. Wir laden vom 1. des Zielmonats bis heute mit etwas
        // Buffer (Tage bis Heute + Monatsbreite + 7 Tage Reserve für mid-month
        // bookingDate-Drift).
        let daysAgo = daysFromTodayToStartOfMonth(targetMonth) + 7
        let rows = try DataReader.loadTransactions(
            slotId: slot, sinceDaysAgo: daysAgo, category: nil, limit: nil
        )
        let inMonth = rows.filter { $0.bookingDate.hasPrefix(targetMonth) }
        let expenses = inMonth.filter { $0.amount < 0 }
        let incomes  = inMonth.filter { $0.amount > 0 }

        var byCategory: [String: Double] = [:]
        for r in expenses {
            let key = r.category ?? "Sonstiges"
            byCategory[key, default: 0] += abs(r.amount)
        }
        let sortedExp = byCategory.sorted { $0.value > $1.value }
        let totalExp = sortedExp.reduce(0.0) { $0 + $1.value }
        let totalInc = incomes.reduce(0.0) { $0 + $1.amount }

        if json {
            struct CatOut: Encodable { let category: String; let amount: Double }
            struct Full: Encodable {
                let month: String
                let totalIncome: Double
                let totalExpenses: Double
                let net: Double
                let byCategory: [CatOut]
            }
            let full = Full(
                month: targetMonth,
                totalIncome: totalInc,
                totalExpenses: totalExp,
                net: totalInc - totalExp,
                byCategory: sortedExp.map { CatOut(category: $0.key, amount: $0.value) }
            )
            print(Format.json(full))
            return
        }

        print(ANSIColor.bold("Summary \(targetMonth)\(slot.map { " · Slot: \($0)" } ?? "")"))
        print(ANSIColor.dim(String(repeating: "─", count: 40)))
        let net = totalInc - totalExp
        print("Einnahmen:  \(Format.padRightANSI(Format.colorMoney(totalInc), to: 14))")
        print("Ausgaben:   \(Format.padRightANSI(Format.colorMoney(-totalExp), to: 14))")
        print("Netto:      \(Format.padRightANSI(Format.colorMoney(net), to: 14))")
        if !sortedExp.isEmpty {
            print("")
            print(ANSIColor.dim("Ausgaben nach Kategorie:"))
            for (cat, amt) in sortedExp {
                print("  \(Format.pad(cat, to: 24))\(Format.padRightANSI(Format.colorMoney(-amt), to: 14))")
            }
        }
    }

    private static func currentMonthKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: Date())
    }

    /// Anzahl Tage von heute zurück zum 1. des angegebenen Monats (YYYY-MM).
    /// Für `--month 2026-01` an einem 26.4.2026 ergibt das z.B. 116 Tage.
    /// Bei ungültigem Format → 90 (alter Default-Fallback).
    static func daysFromTodayToStartOfMonth(_ yyyymm: String) -> Int {
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
        let today = cal.startOfDay(for: Date())
        let diff = cal.dateComponents([.day], from: startOfMonth, to: today).day ?? 90
        // Bei zukünftigen Monaten (--month 2027-12 wenn heute 2026-04) → klein-Bound 1
        return max(1, diff)
    }
}
