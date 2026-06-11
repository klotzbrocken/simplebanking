import SwiftUI

/// Anzeige-Modus des Kalenders.
/// • `.spending` — klassische Ausgaben-/Einnahmen-Heatmap (Standalone-Sheet im Umsatzpanel).
/// • `.subscriptions` — Abo-Fokus: Monats-Abo-Summe + Klassifizierung im Header, erwartete
///   Abbuchungen als schraffierte Forecast-Tage in der Zukunft. Eingebettet in SubscriptionsView.
enum CalendarMode {
    case spending
    case subscriptions
}

struct CalendarHeatmapView: View {

    @AppStorage("demoMode") private var demoMode: Bool = false
    @AppStorage("demoSeed") private var demoSeed: Int = 123456

    /// Modus — steuert Header, Forecast und Zukunfts-Navigation.
    var mode: CalendarMode = .spending
    /// Abo-Buchungen für den `.subscriptions`-Modus — vergangene (`isForecast == false`) UND
    /// projizierte (`isForecast == true`). Wird von außen aus DENSELBEN Candidates gebaut, die auch
    /// die Liste zeigt → Kalender und Liste sind deckungsgleich. Im `.spending`-Modus ungenutzt.
    var subscriptionCharges: [UpcomingCharge] = []
    /// Ø Monatskosten aller Abos — nur für die Monats-Klassifizierung im Header.
    var subscriptionAvgMonthly: Double = 0
    /// `true`, wenn die View in einen Container eingebettet ist (kein eigener Schließen-Button,
    /// keine feste Fenstergröße).
    var embedded: Bool = false

    @StateObject private var logoStore = SubscriptionLogoStore.shared

    @State private var records: [TransactionRecord] = []
    @State private var isLoading = true
    @State private var displayedMonth: Date = {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return Calendar.current.date(from: comps) ?? Date()
    }()
    @State private var selectedDay: Int? = nil   // nil = Monatsansicht
    @State private var hasAutoNavigated = false

    // (b) Fixkosten/Alle-Filter (nur Geldfluss-Modus).
    @State private var fixkostenOnly = false
    /// txIDs der als wiederkehrend (Fixkosten) erkannten Buchungen — exakt per
    /// `SubscriptionDetector`-matchedTransactions ermittelt (Fingerprint → txID).
    @State private var recurringTxIDs: Set<String> = []

    /// Records gemäß Fixkosten-Filter. `hasData`/Monatsauswahl nutzen bewusst die
    /// VOLLEN records, damit ein Monat mit Umsätzen wählbar bleibt.
    private var filteredRecords: [TransactionRecord] {
        guard fixkostenOnly else { return records }
        return records.filter { recurringTxIDs.contains($0.txID) }
    }

    // Sheet state
    @State private var showDaySheet = false
    @State private var sheetDay: Int = 0
    @State private var sheetDayData: DayData = DayData()
    @State private var sheetForecast: [UpcomingCharge] = []

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
        for rec in filteredRecords {
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
        for rec in filteredRecords {
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

    // MARK: - Subscriptions (subscriptions mode)

    /// Abo-Buchungen, die in den angezeigten Monat fallen (vergangen + projiziert).
    private var monthCharges: [UpcomingCharge] {
        guard mode == .subscriptions else { return [] }
        let monthKey = displayedMonthKey
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM"
        return subscriptionCharges.filter { fmt.string(from: $0.date) == monthKey }
    }

    /// Tag → Abo-Buchungen dieses Tages.
    private var chargesByDay: [Int: [UpcomingCharge]] {
        var result: [Int: [UpcomingCharge]] = [:]
        let cal = Calendar(identifier: .gregorian)
        for c in monthCharges {
            let day = cal.component(.day, from: c.date)
            result[day, default: []].append(c)
        }
        return result
    }

    /// Summe der Abo-Kosten in diesem Monat (absolut).
    private var monthSubscriptionTotal: Double {
        monthCharges.reduce(0) { $0 + abs($1.amount) }
    }

    /// Klassifizierung des Monats vs. dem Ø-Monatsbudget aller Abos: „Günstiger / Regulärer / Teurer Monat".
    private var monthClassification: (text: String, color: Color)? {
        guard mode == .subscriptions, monthSubscriptionTotal > 0 else { return nil }
        guard subscriptionAvgMonthly > 0 else { return (L10n.t("Regulärer Monat", "Regular month"), .sbNeutralStrong) }
        let ratio = monthSubscriptionTotal / subscriptionAvgMonthly
        if ratio > 1.15 { return (L10n.t("Teurer Monat", "Heavy month"), .expenseRed) }
        if ratio < 0.85 { return (L10n.t("Günstiger Monat", "Light month"), .incomeGreen) }
        return (L10n.t("Regulärer Monat", "Regular month"), .sbNeutralStrong)
    }

    /// Eindeutige Händler eines Tages (für Icon-Reihe), Reihenfolge stabil.
    private func uniqueMerchants(_ charges: [UpcomingCharge]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in charges where !seen.contains(c.merchant) {
            seen.insert(c.merchant); out.append(c.merchant)
        }
        return out
    }

    /// Forecast-Horizont: aktueller Monat + 12 Monate (für Zukunfts-Navigation im Abo-Modus).
    private var forecastHorizonMonth: Date {
        gregorian.date(byAdding: .month, value: 12, to: currentMonthStart) ?? currentMonthStart
    }

    private var isAtForecastHorizon: Bool {
        gregorian.isDate(displayedMonth, equalTo: forecastHorizonMonth, toGranularity: .month)
            || displayedMonth >= forecastHorizonMonth
    }

    /// Vorwärts-Navigation gesperrt? Im Abo-Modus bis zum Forecast-Horizont erlaubt, sonst am aktuellen Monat.
    private var forwardDisabled: Bool {
        mode == .subscriptions ? isAtForecastHorizon : isCurrentMonth
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

    // MARK: - Month picker

    /// Auswählbare Monate für das Sprung-Menü: 13 Monate zurück bis aktueller Monat
    /// (bzw. bis Forecast-Horizont im Abo-Modus), neueste zuerst.
    private var selectableMonths: [Date] {
        let cal = gregorian
        let start = cal.date(byAdding: .month, value: -13, to: currentMonthStart) ?? currentMonthStart
        let end = (mode == .subscriptions) ? forecastHorizonMonth : currentMonthStart
        var months: [Date] = []
        var d = start
        var safety = 0
        while d <= end {
            months.append(d)
            guard let n = cal.date(byAdding: .month, value: 1, to: d) else { break }
            d = n; safety += 1; if safety > 60 { break }
        }
        // (a) Im Geldfluss-Modus nur Monate MIT Daten zeigen — alte leere Monate raus.
        // Der laufende Monat bleibt immer wählbar (auch wenn noch keine Buchung da ist).
        if mode == .spending {
            months = months.filter {
                hasData(for: $0) || gregorian.isDate($0, equalTo: currentMonthStart, toGranularity: .month)
            }
        }
        return months.reversed()   // neueste zuerst
    }

    /// Index von `displayedMonth` in `selectableMonths` (neueste zuerst), falls vorhanden.
    private var displayedMonthIndex: Int? {
        selectableMonths.firstIndex { gregorian.isDate($0, equalTo: displayedMonth, toGranularity: .month) }
    }

    /// Zurück-Pfeil sperren, wenn kein älterer Monat MIT Daten existiert (Geldfluss-Modus).
    private var backwardDisabled: Bool {
        guard mode == .spending else { return false }
        guard let idx = displayedMonthIndex else { return false }
        return idx >= selectableMonths.count - 1   // bereits ältester Daten-Monat
    }

    private func monthLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        fmt.locale = Locale(identifier: "de_DE")
        return fmt.string(from: date)
    }

    // MARK: - Body

    /// Monats-Menu + Vor/Zurück-Pfeile (Trailing für den Geldfluss-Kopf bzw. Inline im Abo-Modus).
    @ViewBuilder private var monthNav: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(selectableMonths, id: \.self) { m in
                    Button(monthLabel(m)) { displayedMonth = m; selectedDay = nil }
                }
            } label: { MenuTriggerLabel(text: monthTitle) }
            .menuStyle(.borderlessButton).fixedSize()

            Button { navigateMonth(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium)) }
                .buttonStyle(.plain)
                .disabled(backwardDisabled).opacity(backwardDisabled ? 0.3 : 1)
            Button { navigateMonth(1) } label: { Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)) }
                .buttonStyle(.plain)
                .disabled(forwardDisabled).opacity(forwardDisabled ? 0.3 : 1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Kopf ───────────────────────────────────────────
            if mode == .spending {
                TabHeader("Geldfluss", subtitle: "Ausgaben & Eingänge pro Tag") { monthNav }
                Divider()
            } else {
                HStack { Spacer(); monthNav }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            }

            // (b) Fixkosten/Alle-Umschalter — nur Geldfluss.
            if mode == .spending {
                Picker("", selection: $fixkostenOnly) {
                    Text("Alle").tag(false)
                    Text("Fixkosten").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // ── Summary Card (Balance-Card-Stil) ─────────────────────────
            Group {
                if mode == .subscriptions {
                    subscriptionsSummaryPanel
                } else {
                    summaryPanel
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, mode == .spending ? 12 : 0)
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
                let subMode  = (mode == .subscriptions)
                let data     = subMode ? [:] : dataByDay
                let maxExp   = maxDayExpense
                let maxInc   = maxDayIncome
                let abos     = subMode ? [:] : abosByDay
                let charges  = subMode ? chargesByDay : [:]
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
                                let dayAbos = abos[day] ?? []
                                let dayCharges = charges[day] ?? []
                                let hasSub = subMode && !dayCharges.isEmpty
                                let isForecastDay = hasSub && dayCharges.allSatisfy { $0.isForecast }
                                let subMerchants = subMode ? uniqueMerchants(dayCharges) : []
                                let active = subMode ? hasSub : hasTx

                                let bgColor: Color = {
                                    if isSelected { return Color.accentColor.opacity(0.15) }
                                    if isForecastDay { return Color.sbNeutralSoft.opacity(0.6) }
                                    if subMode {
                                        return hasSub ? Color.sbNeutralSoft.opacity(0.35)
                                                      : Color(NSColor.quaternaryLabelColor).opacity(0.06)
                                    }
                                    if !hasTx     { return Color(NSColor.quaternaryLabelColor).opacity(0.06) }
                                    return heatColor.opacity(0.18)
                                }()

                                VStack(spacing: 3) {
                                    Text("\(day)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(active ? .primary : Color(NSColor.secondaryLabelColor))
                                        .padding(.top, 4)

                                    if subMode {
                                        if hasSub {
                                            HStack(spacing: 3) {
                                                ForEach(subMerchants.prefix(3), id: \.self) { name in
                                                    aboIcon(name: name)
                                                }
                                            }
                                            .opacity(isForecastDay ? 0.85 : 1)
                                        } else {
                                            Color.clear.frame(height: 22)
                                        }
                                    } else if !dayAbos.isEmpty {
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
                                        .fill(subMode ? Color.clear : (hasTx ? heatColor : Color.clear))
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
                                            Group {
                                                if isForecastDay {
                                                    DiagonalHatch(spacing: 5)
                                                        .stroke(Color.sbOrangeStrong.opacity(0.22), lineWidth: 1)
                                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                                }
                                            }
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(
                                                    isSelected ? Color.accentColor.opacity(0.4)
                                                        : (isForecastDay ? Color.sbOrangeStrong.opacity(0.35) : Color.clear),
                                                    style: StrokeStyle(lineWidth: 1, dash: isForecastDay ? [3, 2] : [])
                                                )
                                        )
                                )
                                .overlay(alignment: .topTrailing) {
                                    if isForecastDay {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundColor(Color.sbOrangeStrong)
                                            .padding(3)
                                    }
                                }
                                .onTapGesture(count: 2) {
                                    if subMode {
                                        if hasSub {
                                            sheetDay      = day
                                            sheetDayData  = DayData()
                                            sheetForecast = dayCharges
                                            showDaySheet  = true
                                        }
                                    } else if let d = dayData {
                                        sheetDay     = day
                                        sheetDayData = d
                                        sheetForecast = []
                                        showDaySheet = true
                                    }
                                }
                                .onTapGesture(count: 1) {
                                    if active {
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
        .frame(width: embedded ? nil : 420, height: embedded ? nil : 620)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Color.panelBackground)
        .onAppear { loadFromDatabase() }
        .sheet(isPresented: $showDaySheet) {
            CalendarDaySheet(
                day: sheetDay,
                month: displayedMonth,
                records: sheetDayData.records,
                forecast: sheetForecast
            )
        }
    }

    // MARK: - Summary Panel (Balance-Card-Stil)

    private var summaryPanel: some View {
        let gap = summaryIncome - summaryExpense
        let tertiary = Color(NSColor.tertiaryLabelColor)

        return VStack(alignment: .leading, spacing: 10) {
            // Label: Monatsname (kein Tag gewählt) oder Tagesname
            HStack(spacing: 6) {
                if selectedDay != nil {
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.system(size: 12))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Text(summaryLabel)
                    .font(.system(size: 13))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                Spacer(minLength: 0)
            }

            // Ausgaben · Einnahmen · Gap — gleichwertig in einer Zeile.
            HStack(spacing: 0) {
                summaryCell(icon: "arrow.up.right", title: "Ausgaben",
                            value: "-\(formatAmount(summaryExpense))",
                            color: summaryExpense > 0 ? Color.expenseRed : tertiary)
                summaryDivider
                summaryCell(icon: "arrow.down.left", title: "Einnahmen",
                            value: "+\(formatAmount(summaryIncome))",
                            color: summaryIncome > 0 ? Color.incomeGreen : tertiary)
                summaryDivider
                summaryCell(icon: gap >= 0 ? "plus.forwardslash.minus" : "plus.forwardslash.minus",
                            title: "Gap",
                            value: "\(gap >= 0 ? "+" : "-")\(formatAmount(abs(gap)))",
                            color: gap > 0 ? Color.incomeGreen : (gap < 0 ? Color.expenseRed : tertiary))
            }
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

    private var summaryDivider: some View {
        Rectangle().fill(Color(NSColor.separatorColor).opacity(0.5)).frame(width: 1, height: 34)
    }

    private func summaryCell(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(color)
                Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold)).foregroundColor(color)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Subscriptions Summary Panel (Monats-Abo-Summe + Klassifizierung)

    private var subscriptionsSummaryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monthTitle)
                .font(.system(size: 14))
                .foregroundColor(Color(NSColor.secondaryLabelColor))

            // New-York-Serif für die Premium-Anmutung (wie der Saldo im Flyout)
            Text(monthSubscriptionTotal > 0 ? "-\(formatAmount(monthSubscriptionTotal))" : formatAmount(0))
                .font(.system(size: 32, weight: .bold, design: .serif))
                .foregroundColor(monthSubscriptionTotal > 0 ? Color.expenseRed : Color(NSColor.tertiaryLabelColor))
                .monospacedDigit()

            if let cls = monthClassification {
                Text(cls.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(cls.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(cls.color.opacity(0.14)))
            } else {
                Text(L10n.t("Keine wiederkehrenden Abbuchungen erkannt",
                            "No recurring charges detected"))
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
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
        // Geldfluss: zwischen den verfügbaren Daten-Monaten springen (leere überspringen).
        if mode == .spending, let idx = displayedMonthIndex {
            let months = selectableMonths                 // neueste zuerst
            let newIdx = idx - delta                       // +1 = neuer (kleinerer Index)
            if months.indices.contains(newIdx) {
                displayedMonth = months[newIdx]
                selectedDay = nil
            }
            return
        }
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
                let recurring = Self.computeRecurringTxIDs(from: converted)
                await MainActor.run {
                    records = converted
                    recurringTxIDs = recurring
                    isLoading = false
                    jumpToLatestWithDataIfNeeded()
                    preloadAboLogos()
                }
                return
            }
            do {
                let loaded = try TransactionsDatabase.loadAllTransactions()
                let recurring = Self.computeRecurringTxIDs(from: loaded)
                await MainActor.run {
                    records = loaded
                    recurringTxIDs = recurring
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

    /// txIDs aller Buchungen, die zu einem wiederkehrenden Posten gehören — exakt
    /// über `SubscriptionDetector.matchedTransactions` (Fingerprint → txID).
    nonisolated private static func computeRecurringTxIDs(
        from records: [TransactionRecord]
    ) -> Set<String> {
        let pairs: [(rec: TransactionRecord, tx: TransactionsResponse.Transaction)] =
            records.compactMap { rec in rec.toTransaction().map { (rec, $0) } }
        guard !pairs.isEmpty else { return [] }
        let candidates = SubscriptionDetector.detect(in: pairs.map { $0.tx })
        let recurringFPs = Set(candidates.flatMap { $0.matchedTransactions }
            .map { TransactionRecord.fingerprint(for: $0) })
        return Set(pairs
            .filter { recurringFPs.contains(TransactionRecord.fingerprint(for: $0.tx)) }
            .map { $0.rec.txID })
    }

    private func preloadAboLogos() {
        let names: Set<String> = (mode == .subscriptions)
            ? Set(subscriptionCharges.map { $0.merchant })
            : Set(abosByDay.values.flatMap { $0 })
        logoStore.preloadInitial(displayNames: Array(names))
    }

    private func jumpToLatestWithDataIfNeeded() {
        // Im Abo-Modus auf dem aktuellen Monat bleiben (zeigt laufende + erwartete Abbuchungen).
        guard mode != .subscriptions else { return }
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
    var forecast: [UpcomingCharge] = []

    @Environment(\.dismiss) private var dismiss

    private var isForecast: Bool { records.isEmpty && !forecast.isEmpty }

    private var anyForecast: Bool { forecast.contains { $0.isForecast } }

    private var forecastTotal: Double { forecast.reduce(0) { $0 + abs($1.amount) } }

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

            if isForecast {
                HStack(spacing: 6) {
                    Image(systemName: anyForecast ? "clock.arrow.circlepath" : "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(anyForecast ? Color.sbOrangeStrong : .secondary)
                    Text(anyForecast
                         ? L10n.t("Vorgemerkt — basiert auf erkannten Abos · erwartet \(formatAmount(-forecastTotal))",
                                  "Forecast — based on detected subscriptions · expected \(formatAmount(-forecastTotal))")
                         : L10n.t("Abo-Abbuchungen · \(formatAmount(-forecastTotal))",
                                  "Subscription charges · \(formatAmount(-forecastTotal))"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            ScrollView {
                VStack(spacing: 8) {
                    if isForecast {
                        ForEach(forecast) { charge in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(charge.merchant)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Text(charge.isForecast
                                         ? L10n.t("\(charge.frequency.rawValue) · vorgemerkt", "\(charge.frequency.rawValue) · forecast")
                                         : charge.frequency.rawValue)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(formatAmount(charge.amount))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(charge.isForecast ? Color.sbOrangeStrong : Color.expenseRed)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(charge.isForecast ? Color.sbNeutralSoft.opacity(0.5)
                                                            : Color(NSColor.quaternaryLabelColor).opacity(0.08))
                            )
                        }
                    } else {
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

// MARK: - Diagonal Hatch (Forecast-Tage)

/// Diagonale Schraffur für „vorgemerkte" Forecast-Tage im Kalender.
private struct DiagonalHatch: Shape {
    var spacing: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return p
    }
}
