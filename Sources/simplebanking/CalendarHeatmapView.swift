import SwiftUI

struct CalendarHeatmapView: View {

    @AppStorage("demoMode") private var demoMode: Bool = false
    @AppStorage("demoSeed") private var demoSeed: Int = 123456

    @StateObject private var logoStore = SubscriptionLogoStore.shared

    @State private var records: [TransactionRecord] = []
    @State private var isLoading = true
    @State private var displayedMonth: Date = {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return Calendar.current.date(from: comps) ?? Date()
    }()
    @State private var selectedDay: Int? = nil   // nil = Monatsansicht
    @State private var hasAutoNavigated = false

    // Sheet state
    @State private var showDaySheet = false
    @State private var sheetDay: Int = 0
    @State private var sheetDayData: DayData = DayData()

    @Environment(\.dismiss) private var dismiss

    // MARK: - Calendar helpers

    private var gregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }

    private var currentMonthStart: Date {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return Calendar.current.date(from: comps) ?? Date()
    }

    private var isCurrentMonth: Bool {
        gregorian.isDate(displayedMonth, equalTo: currentMonthStart, toGranularity: .month)
    }

    private var monthTitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        fmt.locale = Locale(identifier: "de_DE")
        return fmt.string(from: displayedMonth)
    }

    private var daysInMonth: Int {
        gregorian.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
    }

    private var firstWeekdayOffset: Int {
        var comps = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: displayedMonth)
        comps.day = 1
        guard let firstOfMonth = Calendar(identifier: .gregorian).date(from: comps) else { return 0 }
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: firstOfMonth)
        return (weekday + 5) % 7
    }

    private var displayedMonthKey: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        return fmt.string(from: displayedMonth)
    }

    // MARK: - Data

    struct DayData {
        var expenseTotal: Double = 0
        var incomeTotal: Double = 0
        var records: [TransactionRecord] = []
    }

    private var dataByDay: [Int: DayData] {
        var result: [Int: DayData] = [:]
        let monthKey = displayedMonthKey
        for rec in records {
            let dateStr = rec.datum
            guard dateStr.count >= 10,
                  String(dateStr.prefix(7)) == monthKey,
                  let day = Int(String(dateStr.dropFirst(8).prefix(2))) else { continue }
            var entry = result[day] ?? DayData()
            if rec.betrag < 0 { entry.expenseTotal += abs(rec.betrag) }
            else if rec.betrag > 0 { entry.incomeTotal += rec.betrag }
            entry.records.append(rec)
            result[day] = entry
        }
        return result
    }

    private var maxDayExpense: Double {
        dataByDay.values.map { $0.expenseTotal }.max() ?? 1
    }

    private var maxDayIncome: Double {
        dataByDay.values.map { $0.incomeTotal }.max() ?? 1
    }

    /// Gelb → Orange → Rot → Dunkelrot (Ausgaben)
    private func expenseColor(intensity: Double) -> Color {
        guard intensity > 0 else { return Color.clear }
        let t = min(1.0, intensity)
        let hue        = 0.13 * (1 - t)          // 0.13 (gelb) → 0.0 (rot)
        let saturation = 0.75 + 0.25 * t
        let brightness = 0.88 - 0.42 * t          // hell → dunkelrot
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Hellgrün → Dunkelgrün (Einnahmen)
    private func incomeColor(intensity: Double) -> Color {
        guard intensity > 0 else { return Color.clear }
        let t = min(1.0, intensity)
        let saturation = 0.35 + 0.55 * t
        let brightness = 0.72 - 0.32 * t
        return Color(hue: 0.33, saturation: saturation, brightness: brightness)
    }

    /// Abos erkannt pro Tag: Tag → [displayName]
    private var abosByDay: [Int: [String]] {
        var result: [Int: [String]] = [:]
        let monthKey = displayedMonthKey
        for rec in records {
            guard rec.betrag < 0 else { continue }
            let dateStr = rec.datum
            guard dateStr.count >= 10,
                  String(dateStr.prefix(7)) == monthKey,
                  let day = Int(String(dateStr.dropFirst(8).prefix(2))) else { continue }
            let remittance = rec.verwendungszweck ?? ""
            guard let entry = CancellationLinks.find(merchant: rec.effectiveMerchant, remittance: remittance)
                           ?? CancellationLinks.find(merchant: rec.normalizedMerchant, remittance: remittance)
            else { continue }
            var list = result[day] ?? []
            if !list.contains(entry.displayName) { list.append(entry.displayName) }
            result[day] = list
        }
        return result
    }

    // MARK: - Summary helpers

    /// Label für die Summary-Card: Tagesname wenn Tag gewählt, sonst Monatsname
    private var summaryLabel: String {
        guard let day = selectedDay else { return monthTitle }
        var comps = Calendar.current.dateComponents([.year, .month], from: displayedMonth)
        comps.day = day
        let date = Calendar.current.date(from: comps) ?? displayedMonth
        let fmt = DateFormatter()
        fmt.dateFormat = "d. MMMM"
        fmt.locale = Locale(identifier: "de_DE")
        return fmt.string(from: date)
    }

    private var summaryExpense: Double {
        if let day = selectedDay { return dataByDay[day]?.expenseTotal ?? 0 }
        return dataByDay.values.reduce(0) { $0 + $1.expenseTotal }
    }

    private var summaryIncome: Double {
        if let day = selectedDay { return dataByDay[day]?.incomeTotal ?? 0 }
        return dataByDay.values.reduce(0) { $0 + $1.incomeTotal }
    }

    private func formatAmount(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "de_DE")
        fmt.minimumFractionDigits = 0
        fmt.maximumFractionDigits = 0
        return (fmt.string(from: NSNumber(value: value)) ?? "\(Int(value))") + " €"
    }

    private let weekdayLabels = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Navigation (kein Monatstitel — steht in der Kachel) ─────
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    Button { navigateMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button { navigateMonth(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isCurrentMonth)
                    .opacity(isCurrentMonth ? 0.3 : 1)

                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // ── Summary Card (Balance-Card-Stil) ─────────────────────────
            summaryPanel
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            // ── Kalender-Block (Wochentage + Grid) mit Rahmen ───────────
            VStack(spacing: 0) {
            // Wochentagsbezeichnungen
            HStack(spacing: 0) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Kalender-Grid
            // Immer 6 Reihen (42 Zellen) → gleiche Zellhöhe in jedem Monat.
            // GeometryReader bestimmt die verfügbare Höhe; kein Spacer nötig.
            if isLoading {
                Spacer()
                ProgressView().controlSize(.regular).padding()
                Spacer()
            } else {
                let data     = dataByDay
                let maxExp   = maxDayExpense
                let maxInc   = maxDayIncome
                let abos     = abosByDay
                let offset   = firstWeekdayOffset
                let days     = daysInMonth

                GeometryReader { geo in
                    let spacing: CGFloat = 4
                    // cellH = exakt 1/6 der verfügbaren Höhe minus Abstände
                    // Kein zusätzliches vertikales Padding auf den Zellen!
                    let cellH = (geo.size.height - 5 * spacing) / 6

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 7),
                        spacing: spacing
                    ) {
                        // 42 Zellen = 6 × 7; Zellen außerhalb des Monats sind leer
                        ForEach(0..<42, id: \.self) { index in
                            let day = index - offset + 1
                            if day < 1 || day > days {
                                Color.clear.frame(height: cellH)
                            } else {
                                let dayData        = data[day]
                                let hasTx          = dayData != nil
                                let expense        = dayData?.expenseTotal ?? 0
                                let income         = dayData?.incomeTotal  ?? 0
                                let expIntensity   = expense > 0 ? min(1.0, expense / max(1, maxExp)) : 0
                                let incIntensity   = income  > 0 ? min(1.0, income  / max(1, maxInc)) : 0
                                let expenseDom     = expense >= income
                                let isSelected     = selectedDay == day

                                let heatColor: Color = {
                                    if !hasTx { return Color.clear }
                                    return expenseDom ? expenseColor(intensity: expIntensity)
                                                      : incomeColor(intensity: incIntensity)
                                }()
                                let bgColor: Color = {
                                    if isSelected { return Color.accentColor.opacity(0.15) }
                                    if !hasTx     { return Color(NSColor.quaternaryLabelColor).opacity(0.06) }
                                    return heatColor.opacity(0.18)
                                }()

                                let dayAbos = abos[day] ?? []

                                VStack(spacing: 3) {
                                    Text("\(day)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(hasTx ? .primary : Color(NSColor.secondaryLabelColor))
                                        .padding(.top, 4)

                                    if !dayAbos.isEmpty {
                                        HStack(spacing: 3) {
                                            ForEach(dayAbos.prefix(3), id: \.self) { name in
                                                aboIcon(name: name)
                                            }
                                        }
                                    } else {
                                        Color.clear.frame(height: 22)
                                    }

                                    Spacer(minLength: 0)

                                    Rectangle()
                                        .fill(hasTx ? heatColor : Color.clear)
                                        .frame(height: 3)
                                        .cornerRadius(1.5)
                                        .padding(.bottom, 3)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: cellH)
                                .padding(.horizontal, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(bgColor)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(
                                                    isSelected ? Color.accentColor.opacity(0.4) : Color.clear,
                                                    lineWidth: 1
                                                )
                                        )
                                )
                                .onTapGesture(count: 2) {
                                    if let d = dayData {
                                        sheetDay     = day
                                        sheetDayData = d
                                        showDaySheet = true
                                    }
                                }
                                .onTapGesture(count: 1) {
                                    if dayData != nil {
                                        selectedDay = (selectedDay == day) ? nil : day
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            } // end calendar VStack
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 420, height: 620)
        .background(Color.panelBackground)
        .onAppear { loadFromDatabase() }
        .sheet(isPresented: $showDaySheet) {
            CalendarDaySheet(
                day: sheetDay,
                month: displayedMonth,
                records: sheetDayData.records
            )
        }
    }

    // MARK: - Summary Panel (Balance-Card-Stil)

    private var summaryPanel: some View {
        let expBigger = summaryExpense >= summaryIncome

        let topText:    String = expBigger ? "-\(formatAmount(summaryExpense))" : "+\(formatAmount(summaryIncome))"
        let topColor:   Color  = expBigger
            ? (summaryExpense > 0 ? Color.expenseRed   : Color(NSColor.tertiaryLabelColor))
            : (summaryIncome  > 0 ? Color.incomeGreen  : Color(NSColor.tertiaryLabelColor))

        let bottomText:  String = expBigger ? "+\(formatAmount(summaryIncome))" : "-\(formatAmount(summaryExpense))"
        let bottomColor: Color  = expBigger
            ? (summaryIncome  > 0 ? Color.incomeGreen  : Color(NSColor.tertiaryLabelColor))
            : (summaryExpense > 0 ? Color.expenseRed   : Color(NSColor.tertiaryLabelColor))

        return VStack(alignment: .leading, spacing: 8) {
            // Label: Monatsname (kein Tag gewählt) oder Tagesname
            HStack(spacing: 6) {
                if selectedDay != nil {
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.system(size: 13))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Text(summaryLabel)
                    .font(.system(size: 14))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }

            // Größter Wert oben (32 pt bold)
            Text(topText)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(topColor)
                .monospacedDigit()

            // Kleinerer Wert darunter (13 pt)
            Text(bottomText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(bottomColor)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.15), value: selectedDay)
    }

    // MARK: - Abo Icon

    @ViewBuilder
    private func aboIcon(name: String) -> some View {
        let logoService = MerchantLogoService.shared
        let key = logoService.effectiveLogoKey(
            normalizedMerchant: name.lowercased(),
            empfaenger: name,
            verwendungszweck: ""
        )
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 22, height: 22)
            if let img = logoService.image(for: key) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { logoService.preload(normalizedMerchant: key) }
    }

    // MARK: - Navigation & Loading

    private func navigateMonth(_ delta: Int) {
        if let newDate = gregorian.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = newDate
            selectedDay = nil
        }
    }

    private func loadFromDatabase() {
        Task {
            if demoMode {
                var seed = UInt64(truncatingIfNeeded: demoSeed)
                let fetchDays = UserDefaults.standard.integer(forKey: "fetchDays")
                let days = fetchDays > 0 ? fetchDays : 60
                let fake = FakeData.generateDemoTransactions(seed: &seed, days: days)
                let now = ISO8601DateFormatter().string(from: Date())
                let converted = fake.compactMap { try? TransactionRecord(transaction: $0, updatedAt: now) }
                await MainActor.run {
                    records = converted
                    isLoading = false
                    jumpToLatestWithDataIfNeeded()
                    preloadAboLogos()
                }
                return
            }
            do {
                let loaded = try TransactionsDatabase.loadAllTransactions()
                await MainActor.run {
                    records = loaded
                    isLoading = false
                    jumpToLatestWithDataIfNeeded()
                    preloadAboLogos()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    records = []
                }
            }
        }
    }

    private func preloadAboLogos() {
        let allNames = Set(abosByDay.values.flatMap { $0 })
        logoStore.preloadInitial(displayNames: Array(allNames))
    }

    private func jumpToLatestWithDataIfNeeded() {
        guard !hasAutoNavigated else { return }
        let origin = currentMonthStart
        for i in 0...12 {
            guard let m = gregorian.date(byAdding: .month, value: -i, to: origin) else { break }
            if hasData(for: m) {
                hasAutoNavigated = true
                displayedMonth = m
                return
            }
        }
    }

    private func hasData(for month: Date) -> Bool {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        let key = fmt.string(from: month)
        return records.contains { rec in
            rec.datum.count >= 7 && String(rec.datum.prefix(7)) == key
        }
    }
}

// MARK: - Day Detail Sheet

private struct CalendarDaySheet: View {
    let day: Int
    let month: Date
    let records: [TransactionRecord]

    @Environment(\.dismiss) private var dismiss

    private var dayTitle: String {
        var comps = Calendar.current.dateComponents([.year, .month], from: month)
        comps.day = day
        let date = Calendar.current.date(from: comps) ?? month
        let fmt = DateFormatter()
        fmt.dateFormat = "d. MMMM yyyy"
        fmt.locale = Locale(identifier: "de_DE")
        return fmt.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(dayTitle)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(records, id: \.txID) { rec in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.empfaenger ?? rec.absender ?? "(unbekannt)")
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                if let vwz = rec.verwendungszweck, !vwz.isEmpty {
                                    Text(vwz)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(formatAmount(rec.betrag))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(rec.betrag < 0 ? .expenseRed : .incomeGreen)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.quaternaryLabelColor).opacity(0.08))
                        )
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 360, height: 400)
        .background(Color.panelBackground)
    }

    private func formatAmount(_ value: Double) -> String {
        let absVal = Swift.abs(value)
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "de_DE")
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        let formatted = fmt.string(from: NSNumber(value: absVal)) ?? String(format: "%.2f", absVal)
        return (value >= 0 ? "+" : "-") + formatted + " €"
    }
}
