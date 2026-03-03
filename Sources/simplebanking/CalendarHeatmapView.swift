import SwiftUI

struct CalendarHeatmapView: View {

    @AppStorage("demoMode") private var demoMode: Bool = false
    @AppStorage("demoSeed") private var demoSeed: Int = 123456

    @State private var records: [TransactionRecord] = []
    @State private var isLoading = true

    @State private var displayedMonth: Date = {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return Calendar.current.date(from: comps) ?? Date()
    }()

    private var gregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
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
        // Explizit Tag=1 setzen, damit Zeitzoneneffekte etc. keinen falschen Tag liefern
        var comps = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: displayedMonth)
        comps.day = 1
        guard let firstOfMonth = Calendar(identifier: .gregorian).date(from: comps) else { return 0 }
        // weekday: 1=So, 2=Mo, 3=Di, 4=Mi, 5=Do, 6=Fr, 7=Sa (Gregorian, unveränderlich)
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: firstOfMonth)
        // Mo-first Offset: Mo=0, Di=1, Mi=2, Do=3, Fr=4, Sa=5, So=6
        return (weekday + 5) % 7
    }

    private var displayedMonthKey: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        return fmt.string(from: displayedMonth)
    }

    struct DayData {
        var expenseTotal: Double = 0
        var incomeTotal: Double = 0
        var records: [TransactionRecord] = []
    }

    private var dataByDay: [Int: DayData] {
        var result: [Int: DayData] = [:]
        let monthKey = displayedMonthKey
        for rec in records {
            let dateStr = rec.buchungsdatum
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

    private var maxDayActivity: Double {
        let maxExp = dataByDay.values.map { $0.expenseTotal }.max() ?? 0
        let maxInc = dataByDay.values.map { $0.incomeTotal }.max() ?? 0
        let maxCnt = Double(dataByDay.values.map { $0.records.count }.max() ?? 1)
        if maxExp > 0 { return maxExp }
        if maxInc > 0 { return maxInc }
        return maxCnt
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

    @Environment(\.dismiss) private var dismiss
    @State private var showDaySheet = false
    @State private var selectedDay: Int = 0
    @State private var selectedDayData: DayData = DayData()
    @State private var hasAutoNavigated = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(monthTitle)
                    .font(.system(size: 16, weight: .semibold))
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
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Weekday header
            HStack(spacing: 0) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                    .padding()
                Spacer()
            } else {
                let data = dataByDay
                let maxActivity = maxDayActivity

                let offset = firstWeekdayOffset
                let totalCells = offset + daysInMonth
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                    spacing: 4
                ) {
                    ForEach(0..<totalCells, id: \.self) { index in
                        let day = index - offset + 1
                        if day < 1 {
                            Color.clear.frame(height: 62)
                        } else {
                            let dayData = data[day]
                            let hasTx = dayData != nil
                            let expense = dayData?.expenseTotal ?? 0
                            let income = dayData?.incomeTotal ?? 0
                            let txCount = Double(dayData?.records.count ?? 0)

                            let activity: Double = expense > 0 ? expense : (income > 0 ? income : txCount)
                            let intensity: Double = hasTx ? min(1.0, activity / max(1, maxActivity)) : 0

                            let bgColor: Color = {
                                if !hasTx { return Color(NSColor.quaternaryLabelColor).opacity(0.06) }
                                if expense > 0 { return Color.red.opacity(0.04 + intensity * 0.12) }
                                if income > 0  { return Color.green.opacity(0.04 + intensity * 0.08) }
                                return Color.blue.opacity(0.04 + intensity * 0.08)
                            }()
                            let barColor: Color = {
                                if !hasTx { return Color.clear }
                                if expense > 0 { return Color.red.opacity(0.20 + intensity * 0.70) }
                                if income > 0  { return Color.green.opacity(0.20 + intensity * 0.60) }
                                return Color.blue.opacity(0.20 + intensity * 0.50)
                            }()

                            VStack(spacing: 3) {
                                Text("\(day)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(hasTx ? .primary : Color(NSColor.secondaryLabelColor))
                                if expense > 0 {
                                    Text(formatAmount(expense))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else if income > 0 {
                                    Text("+\(formatAmount(income))")
                                        .font(.system(size: 9))
                                        .foregroundColor(Color.green.opacity(0.8))
                                        .lineLimit(1)
                                } else if hasTx {
                                    Text("\(dayData!.records.count)×")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(" ").font(.system(size: 9))
                                }
                                Rectangle()
                                    .fill(barColor)
                                    .frame(height: 4)
                                    .cornerRadius(2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 62)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(bgColor))
                            .onTapGesture(count: 2) {
                                if let d = dayData {
                                    selectedDay = day
                                    selectedDayData = d
                                    showDaySheet = true
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)

                Spacer(minLength: 0)

                if dataByDay.isEmpty {
                    Text("Keine Buchungen in diesem Monat")
                        .font(.system(size: 12))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        .padding(.bottom, 4)
                }

                // Legend
                HStack(spacing: 20) {
                    Spacer(minLength: 0)
                    legendItem(color: Color.red.opacity(0.20), label: "Niedrig")
                    legendItem(color: Color.red.opacity(0.55), label: "Mittel")
                    legendItem(color: Color.red.opacity(0.90), label: "Hoch")
                    legendItem(color: Color.green.opacity(0.40), label: "Eingang")
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 20)
            }
        }
        .frame(width: 420, height: 620)
        .background(Color.panelBackground)
        .onAppear { loadFromDatabase() }
        .sheet(isPresented: $showDaySheet) {
            CalendarDaySheet(
                day: selectedDay,
                month: displayedMonth,
                records: selectedDayData.records
            )
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private func navigateMonth(_ delta: Int) {
        if let newDate = gregorian.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = newDate
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
                }
                return
            }
            do {
                let loaded = try TransactionsDatabase.loadAllTransactions()
                await MainActor.run {
                    records = loaded
                    isLoading = false
                    jumpToLatestWithDataIfNeeded()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    records = []
                }
            }
        }
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
            rec.buchungsdatum.count >= 7 && String(rec.buchungsdatum.prefix(7)) == key
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
