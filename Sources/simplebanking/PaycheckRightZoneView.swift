import SwiftUI
import AppKit

// MARK: - GreenZoneRing
// Answers "Bin ich im grünen Bereich?" — fraction = balance / referenceIncome (0…1).
// When balance ≥ salary the ring is full green. Dispo mode activates when balance < 0.

struct GreenZoneRing: View {
    let fraction: Double      // 0.0 ... 1.0  (balance / referenceIncome, capped)
    var date: Date = Date()
    var balance: Double? = nil    // current account balance for dispo detection
    var dispoLimit: Int = 0       // overdraft limit in € for dispo-mode display
    var showDispo: Bool = true    // false = hide dispo-mode rendering

    @State private var displayedFraction: Double = 0
    @ObservedObject private var freezeState = FreezeState.shared

    private var isDispoMode: Bool { showDispo && (balance ?? 0) < 0 }

    private var effectiveFraction: Double {
        guard isDispoMode else { return fraction }
        guard dispoLimit > 0, let balance else { return 0 }
        return max(0, min(1, abs(balance) / Double(dispoLimit)))
    }

    private func ringColor(for f: Double) -> Color {
        // Color Harmony Palette — diskrete semantische Bands statt Continuous Hue.
        // Freeze nutzt Blue (info/analyse), Dispo nutzt Red (urgent), sonst Red→Orange→Green nach Threshold.
        if freezeState.isActive {
            return .sbBlueStrong
        }
        guard !isDispoMode else { return .sbRedStrong }
        if f < 0.34 { return .sbRedStrong }
        if f < 0.67 { return .sbOrangeStrong }
        return .sbGreenStrong
    }

    private var day: Int { Calendar.current.component(.day, from: date) }
    private var monthAbbrev: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "de_DE")
        df.dateFormat = "MMM"
        return df.string(from: date)
    }

    var body: some View {
        let color = ringColor(for: displayedFraction)
        ZStack {
            Circle()
                .stroke(color.opacity(0.12), lineWidth: 7)
            Circle()
                .trim(from: 0, to: displayedFraction)
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 1.0), value: displayedFraction)
            VStack(spacing: 1) {
                Text(String(format: "%02d", day))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(color)
                Text(monthAbbrev.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(color.opacity(0.70))
            }
        }
        .frame(width: 72, height: 72)
        .onAppear {
            displayedFraction = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                displayedFraction = effectiveFraction
            }
        }
        .onChange(of: effectiveFraction) { newValue in
            displayedFraction = newValue
        }
    }
}

// MARK: - SalaryProgressCalculator

struct SalaryProgressCalculator {
    struct Progress {
        let daysLeft: Int
        let totalDays: Int
        let elapsed: Int
        let lastSalaryDate: Date
    }

    static func progress(salaryDay: Int, tolerance: Int = 0, from today: Date = Date()) -> Progress {
        let cal = Calendar.current
        let year  = cal.component(.year,  from: today)
        let month = cal.component(.month, from: today)
        let day   = cal.component(.day,   from: today)

        func clamp(_ d: Int, in date: Date) -> Int {
            min(d, cal.range(of: .day, in: .month, for: date)?.count ?? 28)
        }

        let thisMonthSalary = cal.date(from: DateComponents(
            year: year, month: month, day: clamp(salaryDay, in: today)))!

        let lastSalary: Date
        let nextSalary: Date
        // With tolerance: consider salary "arrived" if today is within tolerance days before or after the salary day
        if day >= cal.component(.day, from: thisMonthSalary) - tolerance {
            lastSalary = thisMonthSalary
            let nm = cal.date(byAdding: .month, value: 1, to:
                cal.date(from: DateComponents(year: year, month: month, day: 1))!)!
            nextSalary = cal.date(from: DateComponents(
                year:  cal.component(.year,  from: nm),
                month: cal.component(.month, from: nm),
                day:   clamp(salaryDay, in: nm)))!
        } else {
            nextSalary = thisMonthSalary
            let pm = cal.date(byAdding: .month, value: -1, to:
                cal.date(from: DateComponents(year: year, month: month, day: 1))!)!
            lastSalary = cal.date(from: DateComponents(
                year:  cal.component(.year,  from: pm),
                month: cal.component(.month, from: pm),
                day:   clamp(salaryDay, in: pm)))!
        }

        let totalDays = cal.dateComponents([.day], from: lastSalary, to: nextSalary).day ?? 30
        let elapsed   = max(0, cal.dateComponents([.day], from: lastSalary,
                                                   to: cal.startOfDay(for: today)).day ?? 0)
        let daysLeft  = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: today),
                                                   to: nextSalary).day ?? 0)
        return Progress(daysLeft: daysLeft, totalDays: totalDays, elapsed: elapsed, lastSalaryDate: lastSalary)
    }

    /// Detects the most recent income amount from transactions (same multi-signal logic as ringFraction).
    /// Returns the current period income, or the previous period's if salary hasn't arrived yet.
    static func detectedIncome(salaryDay: Int, tolerance: Int = 0, transactions: [TransactionsResponse.Transaction]) -> Double {
        let cal = Calendar.current
        let p = Self.progress(salaryDay: salaryDay, tolerance: tolerance)
        // Expand window back by tolerance days so pre-arrival income is included
        let currentStart = cal.startOfDay(for:
            cal.date(byAdding: .day, value: -tolerance, to: p.lastSalaryDate) ?? p.lastSalaryDate)
        let periodMonthFirst = cal.date(from: cal.dateComponents([.year, .month], from: p.lastSalaryDate))!
        let prevMonthFirst   = cal.date(byAdding: .month, value: -1, to: periodMonthFirst)!
        let clampedDay       = min(salaryDay, cal.range(of: .day, in: .month, for: prevMonthFirst)?.count ?? 28)
        var prevComps        = cal.dateComponents([.year, .month], from: prevMonthFirst)
        prevComps.day        = clampedDay
        let prevStart        = cal.startOfDay(for:
            cal.date(byAdding: .day, value: -tolerance, to: cal.date(from: prevComps)!) ?? cal.date(from: prevComps)!)

        func txDate(_ tx: TransactionsResponse.Transaction) -> Date? {
            let d = tx.bookingDate ?? tx.valueDate ?? ""
            guard d.count >= 10 else { return nil }
            let parts = d.prefix(10).split(separator: "-")
            guard parts.count == 3,
                  let y = Int(parts[0]), let m = Int(parts[1]), let day = Int(parts[2]) else { return nil }
            return cal.date(from: DateComponents(year: y, month: m, day: day)).map { cal.startOfDay(for: $0) }
        }

        // Two-pass approach:
        // Pass 1 — explicit salary signals (SALA purpose code, GEHALT/LOHN keywords).
        //          These are unambiguous; sum them and use if found.
        // Pass 2 — if no explicit signal, fall back to the single largest credit >= 1000
        //          in the period (never a sum, to avoid aggregating invoice payments etc.)
        var currentExplicit = 0.0, prevExplicit = 0.0
        var currentLargest  = 0.0, prevLargest  = 0.0
        // Use max (not sum) for explicit salary too — avoids double-counting when
        // two salary periods overlap (e.g. March salary on Mar 10, April on Apr 10).
        for tx in transactions {
            guard let d = txDate(tx) else { continue }
            let raw = tx.parsedAmount
            guard raw > 0 else { continue }
            let cat     = tx.category?.lowercased() ?? ""
            let purpose = tx.purposeCode?.uppercased() ?? ""
            let rem     = (tx.remittanceInformation ?? []).joined(separator: " ").uppercased()
            let add     = tx.additionalInformation?.uppercased() ?? ""
            // Only trust bank-authoritative signals for salary detection.
            // AI category ("einkommen", "gehalt") intentionally excluded — it matches
            // freelance invoices, Kleinanzeigen, refunds, and anything the model guesses
            // as income, causing all of them to be summed as if they were salary.
            let isExplicitSalary = purpose == "SALA"
                || rem.contains("GEHALT") || rem.contains("LOHN")
                || add.contains("GEHALT") || add.contains("LOHN")
            let isRefund = rem.contains("ERSTATTUNG") || rem.contains("RETOURE")
                || rem.contains("REFUND") || rem.contains("RÜCKZAHLUNG")
                || add.contains("ERSTATTUNG") || add.contains("RETOURE")
            if d >= currentStart {
                if isExplicitSalary { currentExplicit = max(currentExplicit, raw) }
                else if raw >= 1000 && !isRefund { currentLargest = max(currentLargest, raw) }
            } else if d >= prevStart {
                if isExplicitSalary { prevExplicit = max(prevExplicit, raw) }
                else if raw >= 1000 && !isRefund { prevLargest = max(prevLargest, raw) }
            }
        }
        let current = currentExplicit > 0 ? currentExplicit : currentLargest
        let prev    = prevExplicit    > 0 ? prevExplicit    : prevLargest
        return current > 0 ? current : prev
    }

    /// Detects non-salary positive income in the current period (freelance, rentals, etc.).
    static func detectedOtherIncome(salaryDay: Int, transactions: [TransactionsResponse.Transaction]) -> Double {
        let cal = Calendar.current
        let p = Self.progress(salaryDay: salaryDay)
        let currentStart = cal.startOfDay(for: p.lastSalaryDate)

        func txDate(_ tx: TransactionsResponse.Transaction) -> Date? {
            let d = tx.bookingDate ?? tx.valueDate ?? ""
            guard d.count >= 10 else { return nil }
            let parts = d.prefix(10).split(separator: "-")
            guard parts.count == 3,
                  let y = Int(parts[0]), let m = Int(parts[1]), let day = Int(parts[2]) else { return nil }
            return cal.date(from: DateComponents(year: y, month: m, day: day)).map { cal.startOfDay(for: $0) }
        }

        var otherSum = 0.0
        for tx in transactions {
            guard let d = txDate(tx), d >= currentStart else { continue }
            let raw = tx.parsedAmount
            guard raw > 0 else { continue }
            let cat     = tx.category?.lowercased() ?? ""
            let purpose = tx.purposeCode?.uppercased() ?? ""
            let rem     = (tx.remittanceInformation ?? []).joined(separator: " ").uppercased()
            let add     = tx.additionalInformation?.uppercased() ?? ""
            let isRefund = rem.contains("ERSTATTUNG") || rem.contains("RETOURE")
                || rem.contains("REFUND") || rem.contains("RÜCKZAHLUNG")
                || add.contains("ERSTATTUNG") || add.contains("RETOURE")
            let isSalary = (raw >= 1000 && !isRefund)
                || cat.contains("gehalt") || cat.contains("einkommen")
                || purpose == "SALA"
                || rem.contains("GEHALT") || rem.contains("LOHN")
                || add.contains("GEHALT") || add.contains("LOHN")
            if !isSalary { otherSum += raw }
        }
        return otherSum
    }

    /// MoneyMood-Ring fraction: balance / mediumThreshold, clamped 0…1.
    /// mediumThreshold = balanceSignalMediumUpperBound, which is kept in sync with
    /// the user's salary setting (Option C). Ring full = you have ≥ one salary on hand.
    static func greenZoneFraction(balance: Double?, mediumThreshold: Int) -> Double {
        guard let balance, balance >= 0, mediumThreshold > 0 else { return 0 }
        return max(0, min(1, balance / Double(mediumThreshold)))
    }

    /// Legacy budget-burn fraction — kept for reference, no longer used by the ring.
    static func ringFraction(salaryDay: Int, transactions: [TransactionsResponse.Transaction], salaryAmount: Int = 0) -> Double {
        let cal = Calendar.current
        let p = Self.progress(salaryDay: salaryDay)
        let currentStart = cal.startOfDay(for: p.lastSalaryDate)

        // Derive previous period start
        let periodMonthFirst = cal.date(from: cal.dateComponents([.year, .month], from: p.lastSalaryDate))!
        let prevMonthFirst   = cal.date(byAdding: .month, value: -1, to: periodMonthFirst)!
        let clampedDay       = min(salaryDay, cal.range(of: .day, in: .month, for: prevMonthFirst)?.count ?? 28)
        var prevComps        = cal.dateComponents([.year, .month], from: prevMonthFirst)
        prevComps.day        = clampedDay
        let prevStart        = cal.startOfDay(for: cal.date(from: prevComps)!)

        func txStartOfDay(_ tx: TransactionsResponse.Transaction) -> Date? {
            let d = tx.bookingDate ?? tx.valueDate ?? ""
            guard d.count >= 10 else { return nil }
            let parts = d.prefix(10).split(separator: "-")
            guard parts.count == 3,
                  let y = Int(parts[0]), let m = Int(parts[1]), let day = Int(parts[2]) else { return nil }
            return cal.date(from: DateComponents(year: y, month: m, day: day)).map { cal.startOfDay(for: $0) }
        }

        var currentIncome = 0.0, currentExpenses = 0.0, prevIncome = 0.0
        for tx in transactions {
            guard let d = txStartOfDay(tx) else { continue }

            // Use AmountParser (via parsedAmount) — handles German format "3.450,00" correctly
            let raw = tx.parsedAmount

            // Multi-signal income detection: amount sign OR category OR SEPA code OR keywords
            let cat = tx.category?.lowercased() ?? ""
            let purpose = tx.purposeCode?.uppercased() ?? ""
            let rem = (tx.remittanceInformation ?? []).joined(separator: " ").uppercased()
            let add = tx.additionalInformation?.uppercased() ?? ""
            // Exclude common refund patterns before the amount-threshold check so
            // Erstattungen / Retouren / tax returns don't inflate the salary reference.
            let isRefund = rem.contains("ERSTATTUNG") || rem.contains("RETOURE")
                || rem.contains("REFUND") || rem.contains("RÜCKZAHLUNG")
                || add.contains("ERSTATTUNG") || add.contains("RETOURE")
            let isIncomeTx = (raw >= 1000 && !isRefund)
                || cat.contains("gehalt") || cat.contains("einkommen")
                || purpose == "SALA"
                || rem.contains("GEHALT") || rem.contains("LOHN")
                || add.contains("GEHALT") || add.contains("LOHN")

            if d >= currentStart {
                if isIncomeTx { currentIncome += abs(raw) }
                else if raw < 0 { currentExpenses += abs(raw) }
            } else if d >= prevStart {
                if isIncomeTx { prevIncome += abs(raw) }
            }
        }

        let autoIncome = currentIncome > 0 ? currentIncome : prevIncome
        let refIncome = salaryAmount > 0 ? Double(salaryAmount) : autoIncome
        guard refIncome > 0 else { return 0 }
        return max(0, min(1, (refIncome - currentExpenses) / refIncome))
    }
}

// MARK: - DotsGridWidthKey
// Misst die intrinsische Breite des PaycheckDotsGrid und propagiert sie nach oben,
// damit die IBAN-Zeile exakt auf die Kalenderbreite constrained werden kann.
private struct DotsGridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - PaycheckDotsGrid

private enum DotState { case past, today, future }

private struct PaycheckDotsGrid: View {
    let totalDays: Int
    let elapsed: Int

    private var rows: [[DotState]] {
        guard totalDays > 0 else { return [] }
        let r1 = Int(ceil(Double(totalDays) / 3.0))
        let rem = totalDays - r1
        let r2 = Int(ceil(Double(rem) / 2.0))
        let r3 = rem - r2
        let counts = [r1, r2, r3].filter { $0 > 0 }
        var result: [[DotState]] = []
        var idx = 0
        for count in counts {
            var row: [DotState] = []
            for _ in 0..<count {
                row.append(idx < elapsed ? .past : (idx == elapsed ? .today : .future))
                idx += 1
            }
            result.append(row)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, state in
                        dotView(state)
                    }
                }
                // Erste Zeile = breiteste → publiziert ihre Breite nach oben
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: DotsGridWidthKey.self, value: geo.size.width)
                    }
                )
            }
        }
    }

    @ViewBuilder private func dotView(_ state: DotState) -> some View {
        switch state {
        case .past:
            Circle().fill(Color.primary.opacity(0.55)).frame(width: 12, height: 12)
        case .today:
            ZStack {
                Circle().stroke(Color.primary.opacity(0.70), lineWidth: 2)
                Circle().fill(Color.primary.opacity(0.70)).frame(width: 5, height: 5)
            }.frame(width: 12, height: 12)
        case .future:
            Circle().fill(Color.primary.opacity(0.12)).frame(width: 12, height: 12)
        }
    }
}

// MARK: - PaycheckRightZoneView

struct PaycheckRightZoneView: View {
    let salaryDay: Int
    var salaryDayTolerance: Int = 0
    let iban: String?
    let ringFraction: Double
    var balance: Double? = nil
    var dispoLimit: Int = 0
    var showRing: Bool = true

    @State private var dotsGridWidth: CGFloat = 0

    private var progress: SalaryProgressCalculator.Progress {
        SalaryProgressCalculator.progress(salaryDay: salaryDay, tolerance: salaryDayTolerance)
    }

    private var salaryLabel: String {
        let d = progress.daysLeft
        if progress.elapsed == 0 { return L10n.t("Heute: Gehaltstag", "Payday today") }
        return L10n.t("Gehalt in \(d) Tag\(d == 1 ? "" : "en")",
                      "Payday in \(d) day\(d == 1 ? "" : "s")")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(salaryLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .padding(.bottom, 8)

                PaycheckDotsGrid(totalDays: progress.totalDays, elapsed: progress.elapsed)

                if let iban {
                    IBANLabel(iban: iban)
                        .frame(width: dotsGridWidth > 0 ? dotsGridWidth : nil, alignment: .leading)
                        .padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onPreferenceChange(DotsGridWidthKey.self) { dotsGridWidth = $0 }

            if showRing {
                GreenZoneRing(fraction: ringFraction, balance: balance, dispoLimit: dispoLimit)
            } else {
                Color.clear.frame(width: 72, height: 72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 12)
        .padding(.trailing, 12)
    }
}

// MARK: - IBANLabel

struct IBANLabel: View {
    let iban: String
    @State private var copied = false

    /// Maskiert die letzten 3 Stellen, Rest bleibt sichtbar.
    /// Beispiel: "DE83460500010001808123" → "IBAN DE83460500010001808XXX"
    private func displayString(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
        guard cleaned.count > 3 else { return "IBAN " + cleaned }
        return "IBAN " + cleaned.prefix(cleaned.count - 3) + "XXX"
    }

    /// Bank-Anzeigename aus dem aktiven Slot (für den Mail-Body).
    private var bankName: String? {
        MultibankingStore.shared.activeSlot?.displayName.nilIfEmpty
    }

    /// Erzeugt eine `mailto:`-URL mit Bankverbindung im Body.
    private func mailtoURL() -> URL? {
        let subject = L10n.t("Meine Bankverbindung", "My bank details")
        var body = L10n.t("Hier ist meine Bankverbindung:\n\n", "Here are my bank details:\n\n")
        body += "IBAN: \(iban)\n"
        if let bankName {
            body += L10n.t("Bank: \(bankName)\n", "Bank: \(bankName)\n")
        }
        let enc: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
        let urlString = "mailto:?subject=\(enc(subject))&body=\(enc(body))"
        return URL(string: urlString)
    }

    var body: some View {
        HStack(spacing: 4) {
            if copied {
                Text(L10n.t("IBAN kopiert", "IBAN copied"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sbGreenStrong)
                Spacer(minLength: 0)
            } else {
                Text(displayString(iban))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(iban, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                .buttonStyle(.plain)
                .help(L10n.t("IBAN kopieren", "Copy IBAN"))

                Button {
                    if let url = mailtoURL() {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "envelope")
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                .buttonStyle(.plain)
                .help(L10n.t("Bankverbindung per E-Mail teilen", "Share bank details via email"))
                .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
