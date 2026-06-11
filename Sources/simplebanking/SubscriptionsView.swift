import AppKit
import SwiftUI

// MARK: - View Mode (Kalender · Liste · Stats)

enum SubViewMode: String, CaseIterable {
    case kalender
    case liste
    case stats

    var icon: String {
        switch self {
        case .kalender: return "calendar"
        case .liste:    return "list.bullet"
        case .stats:    return "chart.pie"
        }
    }

    var label: String {
        switch self {
        case .kalender: return "Kalender"
        case .liste:    return "Liste"
        case .stats:    return "Statistik"
        }
    }
}

// MARK: - View

struct SubscriptionsView: View {
    let transactions: [TransactionsResponse.Transaction]
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var logoStore = SubscriptionLogoStore.shared

    @State private var viewMode: SubViewMode = .liste
    @State private var activeTab: SubscriptionTab = .abos
    @State private var detectedCandidates: [SubscriptionCandidate] = []
    @State private var isLoading = true
    @State private var detailCandidate: SubscriptionCandidate? = nil

    // Unified correction store (shared with FixedCostsAnalyzer) — keyed by canonical merchant base.
    @AppStorage(RecurringAssignments.storageKey) private var assignmentsRaw: String = ""

    // MARK: Formatters

    private static let amountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    private static let isoOutFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func fmt(_ v: Double) -> String {
        amountFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f €", v)
    }
    static func fmtDate(_ d: Date) -> String { dateFormatter.string(from: d) }

    // MARK: Forecast/Stats source

    /// Mappt einen Candidate → `RecurringPayment`. Confidence 1.0, weil die Auswahl bereits durch
    /// die Liste (`allCandidates`, exkl. ausgeschlossene) gefiltert ist.
    private func recurringPayment(from c: SubscriptionCandidate) -> RecurringPayment {
        RecurringPayment(
            merchant: c.displayName,
            groupKey: c.id,
            averageAmount: abs(c.averageAmount),
            occurrences: c.occurrences,
            months: c.occurrences,
            frequency: c.cadence,
            lastDate: Self.isoOutFormatter.string(from: c.lastDate),
            category: c.category,
            confidence: 1.0
        )
    }

    /// Genau die Abos, die auch die Liste zeigt (confirmed + möglich, exkl. ausgeschlossene).
    /// Eine einzige Quelle für Liste, Kalender und Stats → alle drei sind deckungsgleich.
    private var subscriptionPayments: [RecurringPayment] {
        allCandidates.map(recurringPayment(from:))
    }

    private var subscriptionAvgMonthly: Double {
        SubscriptionStatsCalc.compute(payments: subscriptionPayments).avgMonthly
    }

    /// Abo-Buchungen für den Kalender: echte vergangene (aus `matchedTransactions`, deckungsgleich
    /// mit den Listen-Einträgen) + projizierte Zukunft (bis +12 Monate).
    private var subscriptionCalendarCharges: [UpcomingCharge] {
        var charges: [UpcomingCharge] = []
        for c in allCandidates {
            for tx in c.matchedTransactions where tx.parsedAmount < 0 {
                let raw = tx.bookingDate ?? tx.valueDate ?? ""
                guard let d = AbosForecast.parseDate(String(raw.prefix(10))) else { continue }
                charges.append(UpcomingCharge(
                    date: d, merchant: c.displayName, amount: -abs(tx.parsedAmount),
                    frequency: c.cadence, groupKey: c.id, isForecast: false
                ))
            }
        }
        let cal = Calendar(identifier: .gregorian)
        let until = cal.date(byAdding: .month, value: 12, to: Date()) ?? Date()
        charges += AbosForecast.project(payments: subscriptionPayments, from: Date(), until: until)
        return charges
    }

    // MARK: Correction-store helpers (unified RecurringAssignments)

    private var assignments: RecurringAssignments { RecurringAssignments.decode(assignmentsRaw) }

    private func isExcluded(_ id: String) -> Bool { assignments.isExcluded(id) }
    private func isConfirmed(_ id: String) -> Bool { assignments.isConfirmed(id) }
    private func tabOverride(_ id: String) -> SubscriptionTab? {
        assignments.assignment(for: id).tab.flatMap(SubscriptionTab.init)
    }

    private func confirm(_ key: String) {
        assignmentsRaw = assignments.setting(key) { a in
            if a.state != .excluded { a.state = .confirmed }
        }.jsonString
    }
    private func exclude(_ key: String) {
        assignmentsRaw = assignments.setting(key) { a in
            a.state = .excluded
            a.tab = nil
        }.jsonString
    }
    private func setTab(_ key: String, _ tab: SubscriptionTab) {
        assignmentsRaw = assignments.setting(key) { a in
            a.tab = tab.rawValue
            if a.state == .neutral { a.state = .confirmed }
        }.jsonString
    }

    // MARK: Derived data

    private var allCandidates: [SubscriptionCandidate] {
        detectedCandidates.filter { !isExcluded($0.id) }
    }

    private func effectiveTab(_ c: SubscriptionCandidate) -> SubscriptionTab {
        tabOverride(c.id) ?? c.defaultTab
    }

    private func candidates(for tab: SubscriptionTab) -> [SubscriptionCandidate] {
        allCandidates.filter { effectiveTab($0) == tab }
    }

    private func confirmed(for tab: SubscriptionTab) -> [SubscriptionCandidate] {
        candidates(for: tab)
            .filter { $0.confidence >= 10 || isConfirmed($0.id) }
            .sorted { a, b in
                if tab == .abos && a.isClassicAbo != b.isClassicAbo { return a.isClassicAbo }
                return a.averageAmount > b.averageAmount  // highest amount first for all tabs
            }
    }

    private func possible(for tab: SubscriptionTab) -> [SubscriptionCandidate] {
        candidates(for: tab)
            .filter { $0.confidence < 10 && !isConfirmed($0.id) }
            .sorted { $0.averageAmount > $1.averageAmount }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            TabHeader("Abos & Verträge", subtitle: subtitleText) {
                // Ansicht-Umschalter (icon-only) rechts oben.
                Picker("", selection: $viewMode) {
                    ForEach(SubViewMode.allCases, id: \.self) { m in
                        Image(systemName: m.icon).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .labelsHidden()
                .frame(width: 156)
                .help("Ansicht: Kalender · Liste · Statistik")
            }
            Divider()

            if viewMode == .liste {
            // Linksbündige Tab-Piles mit Icon (statt gestrecktem Segmented-Picker).
            HStack(spacing: 8) {
                ForEach(SubscriptionTab.allCases, id: \.self) { tab in
                    let active = activeTab == tab
                    Button { activeTab = tab } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tabIcon(tab)).font(.system(size: 11, weight: .medium))
                            Text(tabLabel(tab)).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        }
                        .foregroundColor(active ? .primary : .secondary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Color.cardBackground : Color.sbInputTint)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(active ? Color.sbBorder : Color.clear, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            // ── Summary strip ──────────────────────────────────────
            if !isLoading && !allCandidates.isEmpty {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activeTab.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(Self.fmt(tabTotal(for: activeTab)))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 1, height: 28)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Monatl. Fixkosten")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(Self.fmt(grandTotal))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.06))

                Divider()
            }

            let conf = confirmed(for: activeTab)
            let poss = possible(for: activeTab)

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Analysiere Transaktionen…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if conf.isEmpty && poss.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                    Text("Keine \(emptyStateLabel(for: activeTab)) erkannt.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(conf) { sub in
                            SubscriptionRow(
                                subscription: sub,
                                currentTab:   activeTab,
                                moveOptions:  moveOptions(for: sub.id, currentTab: activeTab),
                                onExclude:   { exclude(sub.id) }
                            )
                            .onTapGesture(count: 2) { detailCandidate = sub }
                        }

                        if !poss.isEmpty {
                            Text("Mögliche \(possibleSectionLabel(for: activeTab))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.top, 6)

                            ForEach(poss) { sub in
                                SubscriptionRow(
                                    subscription: sub,
                                    dimmed:      true,
                                    currentTab:   activeTab,
                                    moveOptions:  moveOptions(for: sub.id, currentTab: activeTab),
                                    onConfirm:   { confirm(sub.id) },
                                    onExclude:   { exclude(sub.id) }
                                )
                                .onTapGesture(count: 2) { detailCandidate = sub }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            } else if viewMode == .kalender {
                CalendarHeatmapView(mode: .subscriptions,
                                    subscriptionCharges: subscriptionCalendarCharges,
                                    subscriptionAvgMonthly: subscriptionAvgMonthly,
                                    embedded: true)
            } else {
                statsContent
            }
        }
        .frame(width: embedded ? nil : 420, height: embedded ? nil : 640)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Color.panelBackground)
        .sheet(item: $detailCandidate) { candidate in
            SubscriptionDetailView(candidate: candidate)
        }
        .onAppear {
            RecurringAssignments.migrateLegacyIfNeeded()
            let txSnapshot = transactions
            Task.detached(priority: .userInitiated) {
                let result = SubscriptionDetector.detect(in: txSnapshot)
                await MainActor.run {
                    detectedCandidates = result
                    isLoading = false
                    logoStore.preloadInitial(displayNames: result.map(\.displayName))
                }
            }
        }
    }

    // MARK: Labels

    private func tabLabel(_ tab: SubscriptionTab) -> String {
        let total = confirmed(for: tab).count + possible(for: tab).count
        return total > 0 ? "\(tab.rawValue) (\(total))" : tab.rawValue
    }

    private func tabIcon(_ tab: SubscriptionTab) -> String {
        switch tab {
        case .abos:              return "play.rectangle"
        case .vertraege:         return "doc.text"
        case .sparen:            return "banknote"
        case .verbindlichkeiten: return "lock.doc"
        }
    }

    private var subtitleText: String {
        let total = allCandidates.count
        guard total > 0 else { return isLoading ? "Lädt…" : "Keine erkannt" }
        let conf = allCandidates.filter { $0.confidence >= 10 || isConfirmed($0.id) }.count
        let poss = total - conf
        var parts: [String] = []
        if conf > 0 { parts.append("\(conf) erkannt") }
        if poss > 0 { parts.append("\(poss) möglich") }
        return parts.joined(separator: " · ")
    }

    private func moveOptions(for key: String, currentTab: SubscriptionTab) -> [(label: String, systemImage: String, action: () -> Void)] {
        SubscriptionTab.allCases
            .filter { $0 != currentTab }
            .map { tab in
                let label: String
                let icon: String
                switch tab {
                case .abos:              label = "Zu Abos verschieben";              icon = "play.rectangle"
                case .vertraege:         label = "Zu Verträgen verschieben";         icon = "doc.text"
                case .sparen:            label = "Zu Sparen verschieben";            icon = "banknote"
                case .verbindlichkeiten: label = "Zu Verbindlichkeiten verschieben"; icon = "lock.doc"
                }
                return (label: label, systemImage: icon, action: { setTab(key, tab) })
            }
    }

    private func emptyStateLabel(for tab: SubscriptionTab) -> String {
        switch tab {
        case .abos:              return "Abos"
        case .vertraege:         return "Verträge"
        case .sparen:            return "Sparpläne"
        case .verbindlichkeiten: return "Verbindlichkeiten"
        }
    }

    private func possibleSectionLabel(for tab: SubscriptionTab) -> String {
        switch tab {
        case .abos:              return "Abos"
        case .vertraege:         return "Verträge"
        case .sparen:            return "Sparpläne"
        case .verbindlichkeiten: return "Verbindlichkeiten"
        }
    }

    private func tabTotal(for tab: SubscriptionTab) -> Double {
        (confirmed(for: tab) + possible(for: tab)).reduce(0) { $0 + $1.averageAmount }
    }

    private var grandTotal: Double {
        SubscriptionTab.allCases.reduce(0.0) { $0 + tabTotal(for: $1) }
    }

    // MARK: - Stats (Jahres-Forecast · Ø · Kategorie-Ring)

    private var statsContent: some View {
        let stats = SubscriptionStatsCalc.compute(payments: subscriptionPayments)
        return ScrollView {
            if stats.yearlyForecast <= 0 {
                VStack(spacing: 10) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                    Text("Noch keine bestätigten Abos für eine Auswertung.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 400)
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        statCard(title: "Jahres-Hochrechnung", value: Self.fmt(stats.yearlyForecast))
                        statCard(title: "Ø pro Monat", value: Self.fmt(stats.avgMonthly))
                    }

                    SubscriptionCategoryRing(slices: stats.byCategory)
                        .frame(height: 200)
                        .padding(.vertical, 4)

                    VStack(spacing: 8) {
                        ForEach(stats.byCategory, id: \.category) { slice in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(slice.category.color)
                                    .frame(width: 10, height: 10)
                                Text(slice.category.rawValue)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(Int((slice.share * 100).rounded())) %")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Text(Self.fmt(slice.yearlyAmount))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .frame(width: 80, alignment: .trailing)
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
                .padding(20)
            }
        }
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                )
        )
    }

    // MARK: - Row

    private struct SubscriptionRow: View {
        let subscription: SubscriptionCandidate
        var dimmed: Bool = false
        var currentTab: SubscriptionTab = .abos
        var moveOptions: [(label: String, systemImage: String, action: () -> Void)] = []
        var onConfirm: (() -> Void)? = nil
        var onExclude: (() -> Void)? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                // ── Main info row ────────────────────────────────────
                HStack(alignment: .top, spacing: 10) {
                    SubscriptionLogo(displayName: subscription.displayName)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(subscription.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(dimmed ? .secondary : .primary)
                        HStack(spacing: 6) {
                            Text("Zuletzt: \(SubscriptionsView.fmtDate(subscription.lastDate))")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            if subscription.cadence == .monthly {
                                Text("· Monatlich")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(SubscriptionsView.fmt(subscription.lastAmount))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(dimmed ? .secondary : .primary)
                        if subscription.occurrences > 1 {
                            Text("\(subscription.occurrences)×")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // ── Action row: Ändern links, Kündigen rechts ────────
                HStack {
                    Menu {
                        if let onConfirm {
                            Button(action: onConfirm) {
                                Label("Als echt markieren", systemImage: "checkmark.circle")
                            }
                        }
                        if !moveOptions.isEmpty {
                            ForEach(Array(moveOptions.enumerated()), id: \.offset) { _, opt in
                                Button(action: opt.action) {
                                    Label(opt.label, systemImage: opt.systemImage)
                                }
                            }
                        }
                        if let onExclude {
                            Divider()
                            Button(role: .destructive, action: onExclude) {
                                Label("Kein Abo / Vertrag", systemImage: "hand.raised.slash")
                            }
                        }
                    } label: {
                        Text("Ändern")
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()

                    Spacer()

                    if onConfirm == nil,
                       currentTab != .verbindlichkeiten,
                       subscription.hasCancellationLink,
                       let entry = subscription.cancellationEntry {
                        Button("Kündigen") { NSWorkspace.shared.open(entry.url) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
                    .opacity(dimmed ? 0.65 : 1.0)
            )
        }
    }

    // MARK: - Logo

    private struct SubscriptionLogo: View {
        let displayName: String
        @ObservedObject private var logoService = MerchantLogoService.shared

        var body: some View {
            let key = logoService.effectiveLogoKey(
                normalizedMerchant: displayName.lowercased(),
                empfaenger: displayName,
                verwendungszweck: ""
            )
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
                if let img = logoService.image(for: key) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
            .onAppear { logoService.preload(normalizedMerchant: key) }
        }
    }
}

// MARK: - Category Ring (Stats)

private struct SubscriptionCategoryRing: View {
    let slices: [SubscriptionStats.CategorySlice]

    private func segments() -> [(start: CGFloat, end: CGFloat, color: Color)] {
        var acc: CGFloat = 0
        var out: [(start: CGFloat, end: CGFloat, color: Color)] = []
        for s in slices {
            let start = acc
            acc += CGFloat(s.share)
            out.append((start: start, end: min(1, acc), color: s.category.color))
        }
        return out
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(NSColor.quaternaryLabelColor).opacity(0.15), lineWidth: 26)

            ForEach(Array(segments().enumerated()), id: \.offset) { _, seg in
                Circle()
                    .trim(from: seg.start, to: seg.end)
                    .stroke(seg.color, style: StrokeStyle(lineWidth: 26, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            if let top = slices.first {
                VStack(spacing: 2) {
                    Text(top.category.rawValue)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(Int((top.share * 100).rounded())) %")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 30)
            }
        }
        .padding(13)
    }
}

// MARK: - Detail Sheet

private struct SubscriptionDetailView: View {
    let candidate: SubscriptionCandidate
    @Environment(\.dismiss) private var dismiss

    private static let amountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    private func fmt(_ v: Double) -> String {
        Self.amountFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f €", v)
    }
    private func fmtDate(_ s: String) -> String {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = TimeZone.current
        guard let d = iso.date(from: s) else { return s }
        return Self.dateFormatter.string(from: d)
    }

    private static let isoOut: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// „17.10.2026 (in 138 Tagen)" — nächste erwartete Abbuchung aus Frequenz + letztem Datum.
    private var nextPaymentText: String? {
        let lastStr = Self.isoOut.string(from: candidate.lastDate)
        guard let next = AbosForecast.nextPaymentDate(after: Date(), lastDate: lastStr, frequency: candidate.cadence)
        else { return nil }
        let days = AbosForecast.daysUntil(from: Date(), to: next)
        let dateStr = Self.dateFormatter.string(from: next)
        return "\(dateStr) (\(L10n.t("in \(days) Tagen", "in \(days) days")))"
    }

    /// Summe der sichtbaren Buchungen — „(sichtbar)", weil das Datenfenster begrenzt ist.
    private var totalSpentVisible: Double {
        candidate.matchedTransactions.reduce(0) { $0 + abs($1.parsedAmount) }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.displayName)
                        .font(.system(size: 20, weight: .bold))
                    Text("\(candidate.occurrences) Buchungen · Ø \(fmt(candidate.averageAmount))")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // ── Übersicht: nächste Zahlung + bisher gezahlt ─────────
            VStack(spacing: 0) {
                infoRow(L10n.t("Häufigkeit", "Frequency"), candidate.cadence.rawValue)
                Divider().padding(.leading, 20)
                if let next = nextPaymentText {
                    infoRow(L10n.t("Nächste Zahlung", "Next payment"), next)
                    Divider().padding(.leading, 20)
                }
                infoRow(L10n.t("Bisher gezahlt (sichtbar)", "Paid so far (visible)"), fmt(totalSpentVisible))
            }
            .background(Color.secondary.opacity(0.04))

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(candidate.matchedTransactions.enumerated()), id: \.offset) { _, tx in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fmtDate(tx.bookingDate ?? tx.valueDate ?? ""))
                                    .font(.system(size: 13, weight: .medium))
                                if let rem = tx.remittanceInformation?.first, !rem.isEmpty {
                                    Text(rem)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(fmt(abs(tx.parsedAmount)))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        Divider().padding(.leading, 20)
                    }
                }
            }
        }
        .frame(width: 380, height: 500)
        .background(Color.panelBackground)
    }
}
