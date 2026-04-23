import AppKit
import SwiftUI

// MARK: - View

struct SubscriptionsView: View {
    let transactions: [TransactionsResponse.Transaction]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var logoStore = SubscriptionLogoStore.shared

    @State private var activeTab: SubscriptionTab = .abos
    @State private var detectedCandidates: [SubscriptionCandidate] = []
    @State private var isLoading = true
    @State private var detailCandidate: SubscriptionCandidate? = nil

    @AppStorage("subscriptions.userConfirmed") private var confirmedRaw: String = ""
    @AppStorage("subscriptions.userExcluded")  private var excludedRaw:  String = ""
    @AppStorage("subscriptions.tabOverrides")  private var overridesRaw: String = ""

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

    static func fmt(_ v: Double) -> String {
        amountFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f €", v)
    }
    static func fmtDate(_ d: Date) -> String { dateFormatter.string(from: d) }

    // MARK: UserDefaults helpers

    private var confirmedKeys: Set<String> {
        Set(confirmedRaw.components(separatedBy: "\n").filter { !$0.isEmpty })
    }
    private var excludedKeys: Set<String> {
        Set(excludedRaw.components(separatedBy: "\n").filter { !$0.isEmpty })
    }
    private var tabOverrides: [String: SubscriptionTab] {
        var result: [String: SubscriptionTab] = [:]
        for line in overridesRaw.components(separatedBy: "\n") where !line.isEmpty {
            guard let sep = line.lastIndex(of: "§") else { continue }
            let key = String(line[..<sep])
            let raw = String(line[line.index(after: sep)...])
            if let tab = SubscriptionTab(rawValue: raw) { result[key] = tab }
        }
        return result
    }

    private func confirm(_ key: String) {
        var s = confirmedKeys; s.insert(key); confirmedRaw = s.joined(separator: "\n")
    }
    private func exclude(_ key: String) {
        var ex = excludedKeys; ex.insert(key); excludedRaw = ex.joined(separator: "\n")
        var cf = confirmedKeys; cf.remove(key); confirmedRaw = cf.joined(separator: "\n")
        var ov = tabOverrides; ov.removeValue(forKey: key)
        overridesRaw = ov.map { "\($0.key)§\($0.value.rawValue)" }.joined(separator: "\n")
    }
    private func setTab(_ key: String, _ tab: SubscriptionTab) {
        var ov = tabOverrides; ov[key] = tab
        overridesRaw = ov.map { "\($0.key)§\($0.value.rawValue)" }.joined(separator: "\n")
        confirm(key)
    }

    // MARK: Derived data

    private var allCandidates: [SubscriptionCandidate] {
        detectedCandidates.filter { !excludedKeys.contains($0.id) }
    }

    private func effectiveTab(_ c: SubscriptionCandidate) -> SubscriptionTab {
        tabOverrides[c.id] ?? c.defaultTab
    }

    private func candidates(for tab: SubscriptionTab) -> [SubscriptionCandidate] {
        allCandidates.filter { effectiveTab($0) == tab }
    }

    private func confirmed(for tab: SubscriptionTab) -> [SubscriptionCandidate] {
        candidates(for: tab)
            .filter { $0.confidence >= 10 || confirmedKeys.contains($0.id) }
            .sorted { a, b in
                if tab == .abos && a.isClassicAbo != b.isClassicAbo { return a.isClassicAbo }
                return a.averageAmount > b.averageAmount  // highest amount first for all tabs
            }
    }

    private func possible(for tab: SubscriptionTab) -> [SubscriptionCandidate] {
        candidates(for: tab)
            .filter { $0.confidence < 10 && !confirmedKeys.contains($0.id) }
            .sorted { $0.averageAmount > $1.averageAmount }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Abos & Verträge")
                        .font(.system(size: 22, weight: .bold))
                    Text(subtitleText)
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
            .padding(.bottom, 12)

            Picker("", selection: $activeTab) {
                ForEach(SubscriptionTab.allCases, id: \.self) { tab in
                    Text(tabLabel(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

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
                        Text("Gesamt")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(Self.fmt(grandTotal))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.secondary)
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
        }
        .frame(width: 420, height: 640)
        .background(Color.panelBackground)
        .sheet(item: $detailCandidate) { candidate in
            SubscriptionDetailView(candidate: candidate)
        }
        .onAppear {
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

    private var subtitleText: String {
        let total = allCandidates.count
        guard total > 0 else { return isLoading ? "Lädt…" : "Keine erkannt" }
        let conf = allCandidates.filter { $0.confidence >= 10 || confirmedKeys.contains($0.id) }.count
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
        .frame(width: 380, height: 420)
        .background(Color.panelBackground)
    }
}
