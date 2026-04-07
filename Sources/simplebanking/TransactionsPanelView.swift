import AppKit
import Combine
import SwiftUI

private struct TransactionsPanelView: View {
    @ObservedObject var vm: TransactionsViewModel
    let onRefresh: () async -> Void
    @ObservedObject var accountNav: AccountNavModel
    @ObservedObject private var logoStore = BankLogoStore.shared
    @ObservedObject private var multibankingStore = MultibankingStore.shared
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("llmAPIKeyPresent") private var llmAPIKeyPresent: Bool = false
    @AppStorage("infiniteScrollEnabled") private var infiniteScrollEnabled: Bool = false
    @AppStorage("confettiEffect") private var confettiEffect: Int = ConfettiEffect.money.rawValue
    @AppStorage("celebrationStyle") private var celebrationStyle: Int = 1
    @AppStorage("scoreStabilityMultiplier") private var scoreStabilityMultiplier: Double = 3.0
    @AppStorage("scoreCoverageWeight") private var scoreCoverageWeight: Double = 0.6
    @AppStorage("scoreFixedCostWarningRatio") private var scoreFixedCostWarningRatio: Double = 0.70
    @AppStorage(MerchantResolver.pipelineEnabledKey) private var effectiveMerchantPipelineEnabled: Bool = true
    @AppStorage(ThemeManager.storageKey) private var themeId: String = ThemeManager.defaultThemeID
    @AppStorage("showTransactionCategories") private var showCategories: Bool = false
    @AppStorage("monthRingEnabled") private var monthRingEnabled: Bool = true
    @Environment(\.colorScheme) private var environmentColorScheme
    
    @State private var showAccountNav = false
    @State private var autoShowNavTask: Task<Void, Never>? = nil
    @State private var showScoreSheet = false
    @State private var showFixedCosts = false
    @State private var fixedCostPayments: [RecurringPayment] = []
    @State private var showSubscriptions = false
    @State private var showCalendar = false
    @State private var panelIsWide: Bool = false
    @State private var greenZoneFractionCached: Double = 0
    @State private var chatDraft = ""
    @State private var chatMessages: [ChatMessage] = []
    @State private var chatState: ChatState = .idle
    @State private var showChatSheet = false
    @State private var lastLLMSQL = ""
    @State private var isPullRefreshing = false
    @State private var isInfiniteLoadingMore = false
    @State private var infiniteVisibleCount: Int = 10
    @State private var pullDragOffset: CGFloat = 0
    @State private var topSentinelOffset: CGFloat = 0
    @State private var lastLLMRowsPreview = ""

    private let infinitePageSize: Int = 10
    private let pullTriggerDistance: CGFloat = 86
    private let pullMaxVisualOffset: CGFloat = 58
    private let pullRefreshHoldOffset: CGFloat = 24

    private static let inputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private static let amountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let monthFormatterDE: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private static let monthFormatterEN: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()
    
    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case 1: return .light
        case 2: return .dark
        default: return nil  // System
        }
    }

    private var isDefaultTheme: Bool {
        themeId == ThemeManager.defaultThemeID
    }

    private var activeColorScheme: ColorScheme {
        colorScheme ?? environmentColorScheme
    }

    private var activeSlotSettings: BankSlotSettings {
        BankSlotSettingsStore.load(slotId: multibankingStore.activeSlot?.id ?? "legacy")
    }

    private var normalizedBalanceThresholds: BalanceSignalThresholds {
        let s = activeSlotSettings
        return BalanceSignal.normalizedThresholds(
            low: s.balanceSignalLowUpperBound,
            medium: s.balanceSignalMediumUpperBound
        )
    }

    /// Green-zone fraction: cached, recomputed when balance or transaction count changes.
    private var greenZoneFraction: Double { greenZoneFractionCached }

    private func recomputeGreenZone() {
        let s = activeSlotSettings
        let balance = AmountParser.parseCurrencyDisplayOrNil(vm.currentBalance)
        // Ring reference: salary takes priority over the MoneyMood medium threshold.
        // If salaryAmount is set manually, use it. Otherwise auto-detect from transactions.
        // Fallback to balanceSignalMediumUpperBound only when no salary is known.
        let reference: Int
        if s.salaryAmount > 0 {
            reference = s.salaryAmount
        } else {
            let detected = SalaryProgressCalculator.detectedIncome(
                salaryDay: s.effectiveSalaryDay,
                tolerance: s.salaryDayTolerance,
                transactions: vm.transactions)
            reference = detected > 0 ? Int(detected.rounded()) : s.balanceSignalMediumUpperBound
        }
        greenZoneFractionCached = SalaryProgressCalculator.greenZoneFraction(
            balance: balance,
            mediumThreshold: reference)
    }

    /// Load 90 days of transaction history for FixedCosts analysis.
    /// Uses a wider window than the normal view (fetchDays) so that subscriptions
    /// charging early in the month always have 2+ occurrences (e.g., day-1 charge in
    /// February + March, even when today is April 4 and the normal 60-day cutoff is Feb 4).
    private func recomputeFixedCosts() {
        let slots: [String]? = vm.isUnifiedMode
            ? MultibankingStore.shared.slots.map { $0.id }
            : [TransactionsDatabase.activeSlotId]
        let extended = (try? TransactionsDatabase.loadUnifiedTransactions(slots: slots, days: 90))
            ?? vm.transactions
        fixedCostPayments = FixedCostsAnalyzer.analyze(transactions: extended)
    }

    /// Returns the slot's display color: custom > generated > fallback gray.
    private func slotDisplayColor(for slot: BankSlot) -> Color {
        if let hex = slot.customColor, let c = Color(hex: hex) { return c }
        if let logoId = slot.logoId, let hex = GeneratedBankColors.primaryColor(forLogoId: logoId), let c = Color(hex: hex) { return c }
        return Color.secondary.opacity(0.4)
    }

    /// Formats a balance value as German-locale string with currency symbol at the end, e.g. "1.234,56 €".
    private func formatBalance(_ amount: Double, currency: String) -> String {
        let symbol: String
        switch currency {
        case "USD": symbol = "$"
        case "GBP": symbol = "£"
        default:    symbol = "€"
        }
        let formatted = Self.amountFormatter.string(from: NSNumber(value: abs(amount))) ?? String(format: "%.2f", abs(amount))
        let sign = amount < 0 ? "-" : ""
        return "\(sign)\(formatted) \(symbol)"
    }

    /// Balance card for unified mode: same visual size as defaultThemeBalanceCard.
    /// Shows total/per-slot sum prominently, then a compact slot icon strip below.
    private var unifiedBalanceCard: some View {
        let slots = multibankingStore.slots
        let glassColor = activeColorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.60)
        let borderColor = activeColorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.35)

        // Compute per-slot balances for display
        let slotBalances: [(slot: BankSlot, balance: Double?)] = slots.map { slot in
            let b = UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slot.id)") as? Double
            return (slot, b)
        }
        // Sum all available balances (same currency only if all match, else show per-slot)
        let currencies = Set(slots.compactMap { $0.currency ?? "EUR" })
        let allSameCurrency = currencies.count <= 1
        let totalBalance: Double? = allSameCurrency
            ? slotBalances.reduce(nil) { acc, item in item.balance.map { (acc ?? 0) + $0 } }
            : nil
        let displayCurrency = currencies.first ?? "EUR"

        // Apply BalanceSignal to unified total — scale thresholds by slot count so
        // the sentiment colors stay consistent with individual account cards.
        let slotCount = max(1, slots.count)
        let aggregatedThresholds = BalanceSignalThresholds(
            lowUpperBound: normalizedBalanceThresholds.lowUpperBound * Double(slotCount),
            mediumUpperBound: normalizedBalanceThresholds.mediumUpperBound * Double(slotCount)
        )
        let totalSignalColor: Color = {
            let level = BalanceSignal.classify(balance: totalBalance, thresholds: aggregatedThresholds)
            return BalanceSignal.style(for: level).amountColor
        }()

        let leftContent = VStack(alignment: .leading, spacing: 8) {
            // Row 1: slot icons strip — mirrors single-account card's logo+timestamp row
            HStack(spacing: 10) {
                ForEach(slotBalances, id: \.slot.id) { item in
                    let slot = item.slot
                    let brand = BankLogoAssets.resolve(displayName: slot.displayName, logoID: slot.logoId, iban: slot.iban)
                    let barColor = slotDisplayColor(for: slot)
                    HStack(spacing: 6) {
                        if let img = logoStore.image(for: brand) {
                            let invertActive = activeColorScheme == .dark && BankLogoAssets.isDark(brandId: brand?.id ?? "")
                            if invertActive {
                                Image(nsImage: img).resizable().scaledToFit()
                                    .frame(width: 16, height: 16)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .colorInvert()
                            } else {
                                Image(nsImage: img).resizable().scaledToFit()
                                    .frame(width: 16, height: 16)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor.opacity(0.30))
                                .frame(width: 16, height: 16)
                        }
                        if let nick = slot.nickname {
                            Text(nick)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                                .lineLimit(1)
                        }
                        if let b = item.balance {
                            Text(formatBalance(b, currency: slot.currency ?? "EUR"))
                                .font(.system(size: 11))
                                .foregroundColor(b < 0 ? Color.expenseRed : Color(NSColor.secondaryLabelColor))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(barColor.opacity(0.10)))
                    .overlay(Capsule().stroke(barColor.opacity(0.30), lineWidth: 0.5))
                }
                Spacer()
            }

            // Row 2: aggregated balance — same 32pt bold as single-account card
            if let total = totalBalance {
                Text(formatBalance(total, currency: displayCurrency))
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .foregroundColor(totalSignalColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.trailing, 0)
            } else if slotBalances.isEmpty || slotBalances.allSatisfy({ $0.balance == nil }) {
                Text("--,-- €")
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 0)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(slotBalances.prefix(2), id: \.slot.id) { item in
                        if let b = item.balance {
                            Text(formatBalance(b, currency: item.slot.currency ?? "EUR"))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(b < 0 ? Color.expenseRed : (b > 0 ? Color.incomeGreen : .primary))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.trailing, 0)
            }

            // Row 3: context label — mirrors "Gutes Polster" position in single-account card
            Text(L10n.t("Aggregierter Kontostand", "Aggregated Balance"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        let ringVisible = monthRingEnabled && !vm.isUnifiedMode
        return Group {
            if panelIsWide {
                HStack(alignment: .center, spacing: 0) {
                    leftContent
                    PaycheckRightZoneView(
                        salaryDay: activeSlotSettings.effectiveSalaryDay,
                        salaryDayTolerance: activeSlotSettings.salaryDayTolerance,
                        iban: nil,
                        ringFraction: greenZoneFraction,
                        showRing: ringVisible
                    )
                }
            } else {
                HStack(alignment: .center, spacing: 0) {
                    leftContent
                    if ringVisible {
                        GreenZoneRing(fraction: greenZoneFraction)
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(glassColor)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.06), .clear],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(borderColor, lineWidth: 1))
    }

    private var defaultThemeBalanceCard: some View {
        let parsedBalance = AmountParser.parseCurrencyDisplayOrNil(vm.currentBalance)
        let level = BalanceSignal.classify(balance: parsedBalance, thresholds: normalizedBalanceThresholds)
        let style = BalanceSignal.style(for: level)
        let displayBalance = parsedBalance == nil ? "--,-- €" : (vm.currentBalance ?? "--,-- €")
        let glassColor = activeColorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.60)
        let borderColor = activeColorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.35)

        let balanceBrand = BankLogoAssets.resolve(displayName: vm.connectedBankDisplayName,
                                                   logoID: vm.connectedBankLogoID,
                                                   iban: vm.connectedBankIBAN)
        let leftContent = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let img = vm.connectedBankLogoImage ?? logoStore.image(for: balanceBrand) {
                    let invertActive = activeColorScheme == .dark && BankLogoAssets.isDark(brandId: balanceBrand?.id ?? "")
                    if invertActive {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .colorInvert()
                    } else {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                } else {
                    Image(systemName: "wallet.pass")
                        .font(.system(size: 16))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Text(formatBalanceTimestamp(vm.currentBalanceFetchedAt))
                    .font(.system(size: 14))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                if let nick = vm.connectedBankNickname {
                    Text(nick)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color(NSColor.quaternaryLabelColor)))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Spacer()
            }

            Text(displayBalance)
                .font(.system(size: 32, weight: .bold, design: .default))
                .foregroundColor(style.amountColor)

            Text(style.localizedStatusText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(style.statusColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        let ringVisible = monthRingEnabled && !vm.isUnifiedMode
        return HStack(alignment: .center, spacing: 0) {
            leftContent
                .frame(minHeight: 108)
            if panelIsWide {
                PaycheckRightZoneView(
                    salaryDay: activeSlotSettings.effectiveSalaryDay,
                    salaryDayTolerance: activeSlotSettings.salaryDayTolerance,
                    iban: vm.connectedBankIBAN,
                    ringFraction: greenZoneFraction,
                    balance: parsedBalance,
                    dispoLimit: activeSlotSettings.dispoLimit,
                    showRing: ringVisible
                )
                .transition(.opacity)
            } else if ringVisible {
                GreenZoneRing(fraction: greenZoneFraction, balance: parsedBalance, dispoLimit: activeSlotSettings.dispoLimit)
                    .padding(.leading, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: panelIsWide)
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(glassColor)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [style.gradientBaseColor.opacity(0.10), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var legacyBalanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "creditcard")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                Text(formatBalanceTimestamp(vm.currentBalanceFetchedAt))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            if let balance = vm.currentBalance {
                let balanceValue = AmountParser.parseCurrencyDisplay(balance)
                Text(balance)
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .foregroundColor(balanceValue < 0 ? .expenseRed : (balanceValue > 0 ? .incomeGreen : .primary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground)
        )
    }
    
    @ViewBuilder
    private func bankNavLogoView(_ logo: NSImage?, brandId: String?, chevron: String) -> some View {
        HStack(alignment: .center, spacing: 3) {
            // Left chevron — always reserved so logo stays in fixed position
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 12, height: 18)
                .opacity(chevron == "chevron.left" ? 1 : 0)
            // Logo — always at same position
            let invert = activeColorScheme == .dark && BankLogoAssets.isDark(brandId: brandId ?? "")
            if let logo {
                if invert {
                    Image(nsImage: logo).resizable().scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .colorInvert()
                } else {
                    Image(nsImage: logo).resizable().scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            } else {
                Color.clear.frame(width: 18, height: 18)
            }
            // Right chevron — always reserved
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 12, height: 18)
                .opacity(chevron == "chevron.right" ? 1 : 0)
        }
    }

    private func formatBalanceTimestamp(_ date: Date?) -> String {
        guard let date else { return "Kontostand" }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let dayLabel: String
        if cal.isDateInToday(date) {
            dayLabel = "Heute"
        } else if cal.isDateInYesterday(date) {
            dayLabel = "Gestern"
        } else if let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: Date()),
                  cal.isDate(date, inSameDayAs: twoDaysAgo) {
            dayLabel = "Vorgestern"
        } else {
            dayLabel = Self.dayFormatter.string(from: date)
        }
        return "Kontostand \(dayLabel), \(hour) Uhr"
    }

    private func formatDateDE(_ dateStr: String) -> String {
        guard let date = Self.inputDateFormatter.date(from: dateStr) else { return dateStr }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Heute" }
        if calendar.isDateInYesterday(date) { return "Gestern" }

        return Self.dayFormatter.string(from: date)
    }
    
    private func dateKey(_ t: TransactionsResponse.Transaction) -> String {
        t.bookingDate ?? t.valueDate ?? ""
    }

    private func amountDouble(_ t: TransactionsResponse.Transaction) -> Double {
        t.parsedAmount
    }

    private func amountText(_ t: TransactionsResponse.Transaction) -> String {
        guard let a = t.amount else { return "" }
        let value = amountDouble(t)
        let formatted = Self.amountFormatter.string(from: NSNumber(value: abs(value))) ?? a.amount
        let sign = value >= 0 ? "+" : "-"
        return "\(sign)\(formatted) €"
    }

    private func amountColor(_ t: TransactionsResponse.Transaction) -> Color {
        let v = amountDouble(t)
        if v < 0 { return .expenseRed }
        if v > 0 { return .incomeGreen }
        return Color(NSColor.tertiaryLabelColor)
    }
    
    private func recipientName(_ t: TransactionsResponse.Transaction) -> String {
        let rawName: String
        if effectiveMerchantPipelineEnabled {
            let merchant = MerchantResolver.resolve(transaction: t).effectiveMerchant
            let cleaned = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                rawName = cleaned
            } else {
                rawName = fallbackRecipientRaw(t)
            }
        } else {
            rawName = fallbackRecipientRaw(t)
        }
        return truncateRecipient(rawName, maxWords: panelIsWide ? 3 : 2)
    }

    private func fallbackRecipientRaw(_ t: TransactionsResponse.Transaction) -> String {
        let isIncoming = amountDouble(t) >= 0
        if isIncoming {
            return t.debtor?.name ?? t.creditor?.name ?? ""
        } else {
            return t.creditor?.name ?? t.debtor?.name ?? ""
        }
    }

    private func truncateRecipient(_ raw: String, maxWords: Int = 2) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return "(ohne Name)" }
        let words = clean.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return clean }
        // Wenn das zweite Token mit "(" beginnt: Klammer nur behalten wenn sie in genau diesem Token schließt
        if words[1].hasPrefix("(") {
            return words[1].hasSuffix(")") ? words.prefix(2).joined(separator: " ") : words[0]
        }
        return words.prefix(maxWords).joined(separator: " ")
    }

    private func category(for transaction: TransactionsResponse.Transaction) -> TransactionCategory {
        TransactionCategorizer.category(for: transaction)
    }

    /// Returns the bank brand color for a transaction's slot in unified mode.
    private func slotColor(for transaction: TransactionsResponse.Transaction) -> Color? {
        guard let slotId = transaction.slotId, let slot = vm.slotMap[slotId] else { return nil }
        return slotDisplayColor(for: slot)
    }

    private var displayedTransactions: [TransactionsResponse.Transaction] {
        if infiniteScrollEnabled {
            let count = min(max(infiniteVisibleCount, 0), vm.filteredTransactions.count)
            return Array(vm.filteredTransactions.prefix(count))
        }
        return vm.currentPageItems
    }

    private var hasMoreInfiniteTransactions: Bool {
        infiniteScrollEnabled && displayedTransactions.count < vm.filteredTransactions.count
    }

    private var hasLoadedAllInfiniteTransactions: Bool {
        infiniteScrollEnabled &&
        !vm.filteredTransactions.isEmpty &&
        !isInfiniteLoadingMore &&
        displayedTransactions.count >= vm.filteredTransactions.count
    }

    private func monthKey(for dateStr: String) -> String {
        guard dateStr.count >= 7 else { return dateStr }
        return String(dateStr.prefix(7))
    }

    private func monthLabel(for dateStr: String) -> String {
        guard let date = Self.inputDateFormatter.date(from: dateStr) else { return dateStr }
        let language = AppLanguage.resolved()
        if language == .en {
            return Self.monthFormatterEN.string(from: date)
        }
        return Self.monthFormatterDE.string(from: date)
    }

    private func resetInfiniteWindowIfNeeded() {
        guard infiniteScrollEnabled else {
            isInfiniteLoadingMore = false
            return
        }
        isInfiniteLoadingMore = false
        let initial = min(infinitePageSize, vm.filteredTransactions.count)
        infiniteVisibleCount = max(0, initial)
    }

    private func loadMoreTransactionsIfNeeded(current: TransactionsResponse.Transaction) {
        guard infiniteScrollEnabled else { return }
        guard !isInfiniteLoadingMore else { return }
        guard hasMoreInfiniteTransactions else { return }
        guard let lastVisible = displayedTransactions.last else { return }
        guard current.stableIdentifier == lastVisible.stableIdentifier else { return }

        isInfiniteLoadingMore = true
        Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.20)) {
                    infiniteVisibleCount = min(vm.filteredTransactions.count, infiniteVisibleCount + infinitePageSize)
                }
                isInfiniteLoadingMore = false
            }
        }
    }

    // Group transactions by date
    private var groupedTransactions: [(date: String, transactions: [TransactionsResponse.Transaction])] {
        let items = displayedTransactions
        var groups: [String: [TransactionsResponse.Transaction]] = [:]
        for t in items {
            let key = dateKey(t)
            groups[key, default: []].append(t)
        }
        // Wichtig: Nur die Daten zurückgeben, die in den aktuellen Items enthalten sind
        return groups.keys.sorted(by: >).map { (date: $0, transactions: groups[$0]!) }
    }

    private var isAtTopOfList: Bool {
        topSentinelOffset >= -2
    }

    private var pullListOffset: CGFloat {
        if isPullRefreshing { return pullRefreshHoldOffset }
        return pullDragOffset
    }

    private var pullIndicatorOpacity: Double {
        if isPullRefreshing { return 1.0 }
        return Double(min(max((pullDragOffset - 4) / 26, 0), 1))
    }

    private var pullToRefreshGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !isPullRefreshing else { return }
                guard abs(value.translation.width) < 80 else { return }
                guard value.translation.height > 0 else {
                    if pullDragOffset > 0 {
                        withAnimation(.easeOut(duration: 0.14)) {
                            pullDragOffset = 0
                        }
                    }
                    return
                }
                guard isAtTopOfList else { return }

                let damped = min(pullMaxVisualOffset, value.translation.height * 0.42)
                pullDragOffset = damped
            }
            .onEnded { value in
                guard !isPullRefreshing else { return }
                let canRefresh = isAtTopOfList && abs(value.translation.width) < 90
                let shouldRefresh = canRefresh && value.translation.height >= pullTriggerDistance

                if shouldRefresh {
                    Task { await triggerPullRefresh() }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        pullDragOffset = 0
                    }
                }
            }
    }

    private var pullRefreshIndicator: some View {
        let showIndicator = isPullRefreshing || pullDragOffset > 1
        let spinnerVisible = isPullRefreshing || pullIndicatorOpacity > 0.35
        let circleFill = activeColorScheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.62)
        let borderColor = activeColorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.48)

        return HStack {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 30, height: 30)
                Circle()
                    .stroke(borderColor, lineWidth: 1)
                    .frame(width: 30, height: 30)

                ProgressView()
                    .controlSize(.small)
                    .tint(Color(NSColor.secondaryLabelColor))
                    .scaleEffect(0.82)
                    .opacity(spinnerVisible ? 1 : 0)

                if !spinnerVisible {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .rotationEffect(.degrees(Double(pullDragOffset * 2.5)))
                        .opacity(1 - pullIndicatorOpacity)
                }
            }
            .shadow(color: Color.black.opacity(activeColorScheme == .dark ? 0.30 : 0.10), radius: 6, x: 0, y: 2)
            Spacer(minLength: 0)
        }
        .frame(height: 34)
        .opacity(showIndicator ? 1 : 0)
        .offset(y: showIndicator ? max(2, min(20, pullListOffset * 0.6)) : -20)
        .animation(.easeOut(duration: 0.14), value: pullDragOffset)
        .animation(.easeOut(duration: 0.14), value: isPullRefreshing)
        .allowsHitTesting(false)
    }


    var body: some View {
        VStack(spacing: 0) {
            // Balance Card
            Group {
                if vm.isUnifiedMode {
                    unifiedBalanceCard
                } else if isDefaultTheme {
                    defaultThemeBalanceCard
                } else {
                    legacyBalanceCard
                }
            }
            .onDisappear { autoShowNavTask?.cancel() }
            .onHover { hovering in
                showAccountNav = hovering
            }
            .rippleEffect(trigger: celebrationStyle == 1 ? vm.rippleTrigger : 0,
                          defaultOrigin: CGPoint(x: 190, y: 65))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, multibankingStore.slots.count > 1 ? 8 : 12)

            // Account dot indicators — slot dots + "Alle Konten" dot
            if multibankingStore.slots.count > 1 {
                HStack(spacing: 8) {
                    // One dot per slot
                    ForEach(Array(multibankingStore.slots.enumerated()), id: \.offset) { idx, slot in
                        let isActive = !vm.unifiedModeEnabled && idx == multibankingStore.activeIndex
                        let color = slotDisplayColor(for: slot)
                        Capsule()
                            .fill(isActive ? color : Color(NSColor.tertiaryLabelColor))
                            .frame(width: isActive ? 24 : 8, height: 8)
                            .animation(.easeInOut(duration: 0.3), value: isActive)
                            .onTapGesture {
                                guard !isActive else { return }
                                if vm.unifiedModeEnabled { vm.unifiedModeEnabled = false }
                                accountNav.onSwitchToIndex?(idx)
                            }
                    }
                    // "Alle Konten" dot
                    let unifiedActive = vm.unifiedModeEnabled
                    Capsule()
                        .fill(unifiedActive ? Color.accentColor : Color(NSColor.tertiaryLabelColor))
                        .frame(width: unifiedActive ? 24 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.3), value: unifiedActive)
                        .onTapGesture {
                            guard !unifiedActive else { return }
                            vm.unifiedModeEnabled = true
                        }
                }
                .padding(.bottom, 10)
            }

            // Search + Icons — same row
            HStack(spacing: 8) {
                // Search field — flexible
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(Color(NSColor.placeholderTextColor))
                    TextField("Suchen...", text: $vm.query)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 13))
                    if !vm.query.isEmpty {
                        Button(action: { vm.query = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Color(NSColor.placeholderTextColor))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))

                // Icons
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                }
                Menu {
                    Button(L10n.t("Als CSV exportieren", "Export as CSV")) {
                        exportTransactionsCSV(vm.transactions)
                    }
                    Divider()
                    let months: [ReportMonth] = [.current, .current.previous, .current.previous.previous]
                    let monthLabels = [
                        L10n.t("Aktueller Monat", "Current month"),
                        L10n.t("Vorheriger Monat", "Previous month"),
                        L10n.t("Vorletzter Monat", "Month before last")
                    ]
                    ForEach(Array(zip(months, monthLabels).enumerated()), id: \.offset) { _, pair in
                        let (month, label) = pair
                        Button("\(label) (\(month.shortLabel))") {
                            exportSimpleReport(month: month)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(.secondary)
                .help(L10n.t("Exportieren", "Export"))
                Button(action: { showCategories.toggle() }) {
                    Image(systemName: showCategories ? "tag.fill" : "tag")
                        .font(.system(size: 15))
                        .foregroundColor(showCategories ? Color(NSColor.labelColor) : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L10n.t("Kategorien ein-/ausblenden", "Show/hide categories"))
                FilterMenuButton(activeFilter: vm.activeFilter) { vm.activeFilter = $0 }
                    .frame(width: 20, height: 20)
                    .help(L10n.t("Filter", "Filter"))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            
            // Error
            if let err = vm.error {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.expenseRed)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            // TAN/2FA pending
            if vm.isTanPending {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("Bitte bestätige in deiner Banking-App")
                        .font(.caption)
                        .foregroundColor(.orange)
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if vm.isSearchActive || vm.activeFilter != .all {
                HStack(spacing: 6) {
                    Text("\(vm.filteredTransactions.count) Ergebnisse")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    if vm.activeFilter != .all {
                        Text("· \(vm.activeFilter.label)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button(action: { vm.activeFilter = .all }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            
            // Transactions List (grouped by date) with pull-to-refresh indicator
            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Color.clear
                            .frame(height: 0)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: TransactionsTopOffsetPreferenceKey.self,
                                        value: proxy.frame(in: .named("transactionsScroll")).minY
                                    )
                                }
                            )

                        ForEach(Array(groupedTransactions.enumerated()), id: \.element.date) { index, group in
                            if infiniteScrollEnabled {
                                let currentMonthKey = monthKey(for: group.date)
                                let previousMonthKey = index > 0 ? monthKey(for: groupedTransactions[index - 1].date) : nil
                                if index > 0 && previousMonthKey != currentMonthKey {
                                    HStack(spacing: 8) {
                                        Rectangle()
                                            .frame(height: 0.5)
                                            .foregroundColor(.secondary.opacity(0.3))
                                        Text(monthLabel(for: group.date))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .fixedSize()
                                        Rectangle()
                                            .frame(height: 0.5)
                                            .foregroundColor(.secondary.opacity(0.3))
                                    }
                                    .padding(.top, 12)
                                    .padding(.bottom, 3)
                                }
                            }

                            // Date Section Header
                            Text(formatDateDE(group.date))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                                .padding(.bottom, 4)

                            // Transactions for this date
                            ForEach(group.transactions, id: \.stableIdentifier) { t in
                                let txID = TransactionRecord.fingerprint(for: t)
                                let enrichment = vm.enrichmentData[txID]
                                let resolution = MerchantResolver.resolve(transaction: t)
                                let rowSlotColor: Color? = vm.isUnifiedMode ? slotColor(for: t) : nil
                                let isTransfer = vm.isUnifiedMode && vm.internalTransferIDs.contains(txID)
                                TransactionRowNew(
                                    transaction: t,
                                    category: category(for: t),
                                    name: recipientName(t),
                                    normalizedMerchant: resolution.normalizedMerchant,
                                    amount: amountText(t),
                                    amountColor: amountColor(t),
                                    matchBadges: vm.searchMatchBadges(for: t),
                                    userNote: enrichment?.note,
                                    attachmentCount: enrichment?.attachmentCount ?? 0,
                                    bankId: "primary",
                                    onEnrichmentChanged: { vm.loadEnrichmentData(bankId: "primary") },
                                    isWide: panelIsWide,
                                    slotColor: rowSlotColor,
                                    isInternalTransfer: isTransfer,
                                    showCategories: showCategories
                                )
                                .opacity(t.status == "pending" ? 0.65 : 1.0)
                                .onAppear {
                                    loadMoreTransactionsIfNeeded(current: t)
                                }
                            }
                        }

                        if infiniteScrollEnabled && isInfiniteLoadingMore {
                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.84)
                                    .tint(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 12)
                        } else if hasLoadedAllInfiniteTransactions {
                            HStack {
                                Spacer(minLength: 0)
                                Text("Alle Umsätze geladen")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        }
                    }
                    .id(vm.page) // Erzwingt komplette Neuzeichnung der Liste pro Seite
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .coordinateSpace(name: "transactionsScroll")
                .offset(y: pullListOffset)
                .onPreferenceChange(TransactionsTopOffsetPreferenceKey.self) { topSentinelOffset = $0 }
                .simultaneousGesture(pullToRefreshGesture)

                pullRefreshIndicator
            }
            
            Spacer(minLength: 0)
            
            // Pagination Footer
            HStack {
                // Ko-fi
                Button(action: {
                    if let url = URL(string: "https://ko-fi.com/N4N11K1NC") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Image(systemName: "cup.and.saucer")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L10n.t("Support simplebanking", "Support simplebanking"))

                if !infiniteScrollEnabled && vm.page > 0 {
                    Button(action: { vm.prevPage() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                            Text("Neuere")
                                .font(.system(size: 14))
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.primary)
                }

                Spacer()

                HStack(spacing: 16) {
                    // Fixkosten Button
                    Button(action: { showFixedCosts = true }) {
                        Image(systemName: "repeat.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L10n.t("Fixkosten analysieren", "Analyze fixed costs"))
                    
                    // Financial Health Button
                    Button(action: { showScoreSheet = true }) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L10n.t("Financial Health Score", "Financial Health Score"))

                    // Abos Button
                    Button(action: { showSubscriptions = true }) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 15))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L10n.t("Abos der letzten 60 Tage", "Subscriptions of the last 60 days"))

                    // Kalender-Heatmap Button
                    Button(action: { showCalendar.toggle() }) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L10n.t("Ausgaben-Kalender", "Spending calendar"))
                }
                
                Spacer()
                
                if !infiniteScrollEnabled && vm.page < vm.totalPages - 1 {
                    Button(action: { vm.nextPage() }) {
                        HStack(spacing: 4) {
                            Text("Ältere")
                                .font(.system(size: 14))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.panelBackground) // Light grey background for footer too
        }
        .overlay {
            if celebrationStyle == 0 {
                ConfettiOverlayView(trigger: vm.confettiTrigger, effectRawValue: confettiEffect)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 840, minHeight: 620, idealHeight: 620, maxHeight: 620)
        .background(Color.panelBackground) // Light grey background
        .tint(Color.themeAccent)
        .preferredColorScheme(colorScheme)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
            withAnimation(.easeInOut(duration: 0.2)) {
                panelIsWide = newWidth >= 700
            }
        }
        .onChange(of: llmAPIKeyPresent) { enabled in
            if !enabled {
                chatDraft = ""
                chatState = .idle
                lastLLMSQL = ""
                lastLLMRowsPreview = ""
                showChatSheet = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MerchantRulesChanged"))) { _ in
            vm.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TransactionCategoriesChanged"))) { _ in
            vm.objectWillChange.send()
        }
        .onAppear {
            resetInfiniteWindowIfNeeded()
            vm.loadEnrichmentData(bankId: "primary")
            if celebrationStyle == 1 && UserDefaults.standard.bool(forKey: "rippleAlwaysOn") {
                vm.rippleTrigger += 1
            }
            recomputeGreenZone()
        }
        .onChange(of: vm.transactions.count) { _ in
            recomputeGreenZone()
        }
        .onChange(of: infiniteScrollEnabled) { _ in
            resetInfiniteWindowIfNeeded()
        }
        .onChange(of: vm.unifiedModeEnabled) { _ in
            // Reload transactions when user toggles unified mode.
            Task { await onRefresh() }
        }
        .onChange(of: vm.filteredTransactions.count) { _ in
            if infiniteScrollEnabled {
                let minimumVisible = min(infinitePageSize, vm.filteredTransactions.count)
                if infiniteVisibleCount < minimumVisible {
                    infiniteVisibleCount = minimumVisible
                }
                if infiniteVisibleCount > vm.filteredTransactions.count {
                    infiniteVisibleCount = vm.filteredTransactions.count
                }
                isInfiniteLoadingMore = false
            }
        }
        .sheet(isPresented: $showScoreSheet) {
            FinancialHealthScoreView(
                transactions: vm.transactions,
                salaryDay: activeSlotSettings.salaryDay,
                dispoLimit: activeSlotSettings.dispoLimit,
                targetBuffer: activeSlotSettings.targetBuffer,
                targetSavingsRate: activeSlotSettings.targetSavingsRate,
                stabilityOutlierMultiplier: scoreStabilityMultiplier,
                coverageRatioWeight: scoreCoverageWeight,
                fixedCostWarningRatio: scoreFixedCostWarningRatio
            )
        }
        .sheet(isPresented: $showFixedCosts) {
            FixedCostsView(payments: fixedCostPayments)
        }
        .onChange(of: showFixedCosts) { isShown in
            if isShown { recomputeFixedCosts() }
        }
        .sheet(isPresented: $showSubscriptions) {
            SubscriptionsView(transactions: vm.transactions)
        }
        .sheet(isPresented: $showCalendar) {
            CalendarHeatmapView()
        }
        .sheet(isPresented: $showChatSheet) {
            ChatOverlaySheet(
                isPresented: $showChatSheet,
                draft: $chatDraft,
                messages: $chatMessages,
                chatState: $chatState,
                lastSQL: $lastLLMSQL,
                lastRowsPreview: $lastLLMRowsPreview,
                llmEnabled: llmAPIKeyPresent,
                submitAction: { submitQuestion() },
                clearAction: {
                    chatMessages = []
                    chatState = .idle
                    lastLLMSQL = ""
                    lastLLMRowsPreview = ""
                },
                copyAction: { text in
                    copyToClipboard(text)
                }
            )
        }
    }
    
    private func triggerPullRefresh() async {
        guard !isPullRefreshing else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            isPullRefreshing = true
            pullDragOffset = pullRefreshHoldOffset
        }
        let refreshStartedAt = Date()
        await onRefresh()
        let minSpinnerTime: TimeInterval = 0.55
        let elapsed = Date().timeIntervalSince(refreshStartedAt)
        if elapsed < minSpinnerTime {
            let remaining = minSpinnerTime - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            isPullRefreshing = false
            pullDragOffset = 0
        }
    }

    // Computed property - wird bei jeder Änderung neu berechnet
    private var currentScore: FinancialHealthScore {
        let s = activeSlotSettings
        return FinancialHealthScorer.score(
            transactions: vm.transactions,
            salaryDay: s.salaryDay,
            dispoLimit: s.dispoLimit,
            targetBuffer: s.targetBuffer,
            targetSavingsRate: s.targetSavingsRate,
            stabilityOutlierMultiplier: scoreStabilityMultiplier,
            coverageRatioWeight: scoreCoverageWeight,
            fixedCostWarningRatio: scoreFixedCostWarningRatio
        )
    }
    
    // MARK: - CSV Export
    private func exportTransactionsCSV(_ transactions: [TransactionsResponse.Transaction]) {
        var csv = "Datum;Buchungsdatum;Betrag;Währung;Empfänger/Absender;IBAN;Verwendungszweck;Kategorie;EndToEndId\n"
        
        for tx in transactions {
            let valueDate = tx.valueDate ?? ""
            let bookingDate = tx.bookingDate ?? ""
            let amount = tx.amount?.amount ?? ""
            let currency = tx.amount?.currency ?? ""
            let creditor = tx.creditor?.name ?? ""
            let debtor = tx.debtor?.name ?? ""
            let party = creditor.isEmpty ? debtor : creditor
            let iban = tx.creditor?.iban ?? tx.debtor?.iban ?? ""
            let remittance = (tx.remittanceInformation ?? []).joined(separator: " ").replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "\n", with: " ")
            let purposeCode = tx.purposeCode ?? ""
            let endToEndId = tx.endToEndId ?? ""
            
            csv += "\(valueDate);\(bookingDate);\(amount);\(currency);\(party);\(iban);\(remittance);\(purposeCode);\(endToEndId)\n"
        }
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "transaktionen.csv"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = "CSV-Export fehlgeschlagen"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - simple.report Export

    private func exportSimpleReport(month: ReportMonth) {
        guard let slot = multibankingStore.activeSlot else { return }
        // Load 90 days for recurring/fixed-cost detection — same window as FixedCostsView.
        // vm.transactions only covers fetchDays (default 60) which misses early-month
        // subscriptions and cuts off quarterly patterns entirely.
        let slots: [String]? = vm.isUnifiedMode
            ? MultibankingStore.shared.slots.map { $0.id }
            : [TransactionsDatabase.activeSlotId]
        let allTxs = (try? TransactionsDatabase.loadUnifiedTransactions(slots: slots, days: 90))
            ?? vm.transactions
        let monthTxs = month.filter(allTxs)
        let prevTxs  = month.previous.filter(allTxs)

        let report  = MonthlyReportBuilder().build(
            slot: slot, month: month,
            transactions: monthTxs,
            previousMonth: prevTxs,
            allTransactions: allTxs
        )
        let pdfData = MonthlyReportPDFRenderer().render(report: report)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let safeName = (slot.nickname ?? slot.displayName)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "simple-report_\(safeName)_\(month.fileLabel).pdf"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try pdfData.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = "simple.report Export fehlgeschlagen"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func rowsPreviewText(_ rows: [[String: String]], maxRows: Int = 25) -> String {
        guard !rows.isEmpty else { return "Keine Ergebniszeilen." }
        let previewRows = rows.prefix(maxRows)
        let rendered = previewRows.map { row in
            row.keys.sorted().map { key in
                "\(key)=\(row[key] ?? "")"
            }.joined(separator: " | ")
        }.joined(separator: "\n")
        if rows.count > maxRows {
            return "\(rendered)\n… (\(rows.count - maxRows) weitere Zeilen)"
        }
        return rendered
    }

    private func submitQuestion() {
        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        chatDraft = ""
        chatMessages.append(ChatMessage(role: .user, text: question))
        chatState = .loading

        let key = vm.anthropicApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = key, !apiKey.isEmpty else {
            chatState = .failed("API-Key ist noch nicht verfügbar. Öffne die Umsatzliste nach dem Entsperren erneut oder setze den Key in den Einstellungen.")
            return
        }

        Task {
            do {
                let answer = try await LLMService.ask(question: question, apiKey: apiKey)
                await MainActor.run {
                    chatMessages.append(ChatMessage(role: .assistant, text: answer.answerText))
                    lastLLMSQL = answer.sql
                    lastLLMRowsPreview = rowsPreviewText(answer.resultRows)
                    chatState = .idle
                }
            } catch {
                await MainActor.run {
                    chatMessages.append(ChatMessage(role: .system, text: "Fehler: \(error.localizedDescription)"))
                    chatState = .failed("Anfrage fehlgeschlagen.")
                }
            }
        }
    }
}

private struct TransactionsTopOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TransactionRowNew: View {
    let transaction: TransactionsResponse.Transaction
    let category: TransactionCategory
    let name: String
    let normalizedMerchant: String
    let amount: String
    let amountColor: Color
    let matchBadges: [String]
    let userNote: String?
    let attachmentCount: Int
    let bankId: String
    let onEnrichmentChanged: () -> Void
    var isWide: Bool = false
    var slotColor: Color? = nil
    var isInternalTransfer: Bool = false
    var showCategories: Bool = false

    private var isPending: Bool { transaction.status == "pending" }

    @ObservedObject private var logoService = MerchantLogoService.shared
    @State private var showDetail: Bool = false

    private var empfaengerText: String {
        [transaction.creditor?.name, transaction.debtor?.name]
            .compactMap { $0 }.joined(separator: " ")
    }

    private var verwendungszweckText: String {
        ((transaction.remittanceInformation ?? []) + [transaction.additionalInformation])
            .compactMap { $0 }.joined(separator: " ")
    }

    private var logoKey: String {
        logoService.effectiveLogoKey(
            normalizedMerchant: normalizedMerchant,
            empfaenger: empfaengerText,
            verwendungszweck: verwendungszweckText
        )
    }

    private var merchantLogo: NSImage? {
        logoService.image(for: logoKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 10) {
                    if let logo = merchantLogo {
                        Image(nsImage: logo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                    } else {
                        Image(systemName: category.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        if showCategories {
                            Text(category.rawValue)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                .lineLimit(1)
                        }
                    }
                }
                if isWide {
                    let remittance = transaction.remittanceInformation?.first ?? ""
                    Text(remittance)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .padding(.leading, 8)
                } else {
                    Spacer()
                }
                // Enrichment indicators (monochrome)
                HStack(spacing: 4) {
                    if attachmentCount > 0 {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    if let note = userNote, !note.isEmpty {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 10))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(amount)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(amountColor)
                    if isPending {
                        Text(L10n.t("Vorgemerkt", "Pending"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
                }
            }

            if isInternalTransfer || !matchBadges.isEmpty {
                HStack(spacing: 6) {
                    if isInternalTransfer {
                        Label(L10n.t("Eigenüberweisung", "Own Transfer"), systemImage: "arrow.left.arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color(NSColor.quaternaryLabelColor).opacity(0.18))
                            )
                    }
                    ForEach(matchBadges, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color(NSColor.quaternaryLabelColor).opacity(0.18))
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.cardBackground)
        )
        // 3px leading color bar for bank attribution in unified mode
        .overlay(alignment: .leading) {
            if let color = slotColor {
                color
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            showDetail = true
        }
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            guard attachmentCount < 3 else { return false }
            let txID = TransactionRecord.fingerprint(for: transaction)
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        guard let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in
                            _ = try? TransactionsDatabase.addAttachment(txID: txID, bankId: bankId, sourceURL: url)
                            onEnrichmentChanged()
                        }
                    }
                }
            }
            return true
        }
        .sheet(isPresented: $showDetail) {
            TransactionDetailView(
                transaction: transaction,
                bankId: bankId,
                initialUserNote: userNote,
                onEnrichmentChanged: onEnrichmentChanged
            )
        }
        .onAppear {
            MerchantLogoService.shared.preload(normalizedMerchant: logoKey)
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return Color.accentColor
        case .assistant:
            return Color(NSColor.windowBackgroundColor)
        case .system:
            return Color(NSColor.systemOrange).opacity(0.22)
        }
    }

    private var textColor: Color {
        message.role == .user ? .white : .primary
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isUser {
                Spacer(minLength: 44)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundColor(textColor)
                    .textSelection(.enabled)
                Text(Self.timeFormatter.string(from: message.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(message.role == .user ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                ZStack(alignment: isUser ? .bottomTrailing : .bottomLeading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(bubbleColor)
                    BubbleTail(isUser: isUser)
                        .fill(bubbleColor)
                        .frame(width: 10, height: 10)
                        .offset(x: isUser ? 4 : -4, y: 2)
                }
            )
            .frame(maxWidth: 290, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 44)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BubbleTail: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isUser {
            path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

private struct ChatOverlaySheet: View {
    @Binding var isPresented: Bool
    @Binding var draft: String
    @Binding var messages: [ChatMessage]
    @Binding var chatState: ChatState
    @Binding var lastSQL: String
    @Binding var lastRowsPreview: String

    let llmEnabled: Bool
    let submitAction: () -> Void
    let clearAction: () -> Void
    let copyAction: (String) -> Void

    @State private var showDebug = false

    private var isLoading: Bool {
        if case .loading = chatState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Text("simply Chat")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !lastSQL.isEmpty {
                    Button(showDebug ? "Debug aus" : "Debug") {
                        showDebug.toggle()
                    }
                    .buttonStyle(PlainButtonStyle())
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
                Button("Leeren") {
                    clearAction()
                }
                .buttonStyle(PlainButtonStyle())
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.panelBackground)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Hey, ich bin simply.")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Frag mich zum Beispiel: „Wie viel habe ich letzten Monat für Versicherungen ausgegeben?“")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.cardBackground)
                            )
                        } else {
                            ForEach(messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color.panelBackground)
                .onChange(of: messages.count) { _ in
                    guard let last = messages.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if case .loading = chatState {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Ich schaue kurz in deine Umsätze…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(Color.panelBackground)
            } else if case .failed(let text) = chatState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(Color.panelBackground)
            }

            if showDebug {
                VStack(alignment: .leading, spacing: 8) {
                    if !lastSQL.isEmpty {
                        HStack {
                            Text("Letzte SQL-Abfrage")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Kopieren") {
                                copyAction(lastSQL)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }

                        Text(lastSQL)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.cardBackground)
                            )
                    }

                    if !lastRowsPreview.isEmpty {
                        HStack {
                            Text("Ergebnis-Preview")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Kopieren") {
                                copyAction(lastRowsPreview)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }

                        Text(lastRowsPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.cardBackground)
                            )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .background(Color.panelBackground)
            }

            Divider()

            HStack(spacing: 10) {
                TextField(llmEnabled ? "Stell eine Frage zu deinen Umsätzen…" : "API-Key fehlt", text: $draft)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(!llmEnabled || isLoading)
                    .onSubmit {
                        guard llmEnabled, !isLoading else { return }
                        submitAction()
                    }
                Button(action: { submitAction() }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(llmEnabled ? Color.accentColor : Color.gray.opacity(0.45))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!llmEnabled || isLoading || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.panelBackground)
        }
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 840, minHeight: 620, idealHeight: 620, maxHeight: 620)
        .background(Color.panelBackground)
    }
}

// MARK: - Transactions Panel Host

/// Hält die Multibanking-Navigations-Callbacks reaktiv für SwiftUI.
final class AccountNavModel: ObservableObject {
    @Published var onPrevAccount: (() -> Void)? = nil
    @Published var onNextAccount: (() -> Void)? = nil
    @Published var onAddAccount:  (() -> Void)? = nil
    @Published var onSwitchToIndex: ((Int) -> Void)? = nil
    @Published var prevAccountLogo: NSImage? = nil
    @Published var nextAccountLogo: NSImage? = nil
    @Published var prevAccountBrandId: String? = nil
    @Published var nextAccountBrandId: String? = nil
    @Published var prevAccountCurrency: String? = nil
    @Published var nextAccountCurrency: String? = nil
    @Published var prevAccountNickname: String? = nil
    @Published var nextAccountNickname: String? = nil
}

@MainActor final class TransactionsPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    var isVisible: Bool { panel.isVisible }
    private let vm: TransactionsViewModel
    let accountNav: AccountNavModel

    nonisolated static let narrowWidth: CGFloat = 420
    nonisolated static let wideWidth:   CGFloat = 840
    nonisolated static let panelHeight: CGFloat = 620
    private let titleIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "simplebanking")
    private let titleTrailingSpacer = NSView()
    private let titleStack = NSStackView()
    private var toolbarDelegate: TransactionsPanelToolbarDelegate?
    private var cancellables: Set<AnyCancellable> = []
    private var isUpdatingTitlebar = false
    private let clippy = MediumClippy()
    private var headerClickTimestamps: [TimeInterval] = []
    private let clippyHeaderClickWindowSeconds: TimeInterval = 1.8
    private let clippyRequiredClicks: Int = 5
    private var autonomousClickTimestamps: [TimeInterval] = []
    private let clippyAutonomousClickWindowSeconds: TimeInterval = 3.0
    private let clippyAutonomousRequiredClicks: Int = 8
    private let onSettings: (() -> Void)?

    init(vm: TransactionsViewModel, onRefresh: @escaping () async -> Void = {}, onSettings: (() -> Void)? = nil) {
        self.vm = vm
        self.onSettings = onSettings
        self.accountNav = AccountNavModel()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "simplebanking"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        if #available(macOS 11.0, *) {
            panel.toolbarStyle = .unifiedCompact
        }

        // Fullscreen deaktivieren — grüner Button wird zum Breiten-Toggle
        panel.collectionBehavior = [.fullScreenNone, .managed]

        let h = Self.panelHeight
        let w = Self.narrowWidth
        panel.setContentSize(NSSize(width: w, height: h))
        panel.minSize = NSSize(width: w, height: h)
        panel.maxSize = NSSize(width: w, height: h)

        super.init()

        panel.delegate = self
        configureTitlebar()
        bindTitlebar()
        updateTitlebarContent()
        _ = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clippy.hide()
            }
        }

        let host = NSHostingView(rootView: TransactionsPanelView(
            vm: vm, onRefresh: onRefresh, accountNav: accountNav
        ))
        host.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(host)
        panel.contentView = content

        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        clippy.resumeAutonomousModeIfEnabled(on: panel.contentView)
    }

    func close() {
        panel.orderOut(nil)
    }

    // MARK: - NSWindowDelegate: Zoom-Toggle (grüner Button)

    nonisolated func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let narrow = TransactionsPanel.narrowWidth
        let wide   = TransactionsPanel.wideWidth
        let height = window.frame.height  // preserve actual frame height (includes title bar)
        let isNarrow = window.frame.width < (narrow + wide) / 2
        let targetWidth: CGFloat = isNarrow ? wide : narrow
        let x = window.frame.midX - targetWidth / 2
        let y = window.frame.minY
        let screen = window.screen?.visibleFrame ?? defaultFrame
        let clampedX = max(screen.minX, min(x, screen.maxX - targetWidth))
        return NSRect(x: clampedX, y: y, width: targetWidth, height: height)
    }

    nonisolated func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let narrow = TransactionsPanel.narrowWidth
        let wide   = TransactionsPanel.wideWidth
        let snap: CGFloat = window.frame.width > (narrow + wide) / 2 ? wide : narrow
        let frameHeight = window.frame.height  // preserve actual frame height (includes title bar)
        // Lock to snapped size to prevent free drag-resizing
        DispatchQueue.main.async {
            window.minSize = NSSize(width: snap, height: frameHeight)
            window.maxSize = NSSize(width: snap, height: frameHeight)
        }
    }

    private func configureTitlebar() {
        titleIconView.imageScaling = .scaleProportionallyUpOrDown
        titleIconView.translatesAutoresizingMaskIntoConstraints = false
        titleIconView.setContentHuggingPriority(.required, for: .horizontal)
        titleIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 8
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.setContentHuggingPriority(.required, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleStack.addArrangedSubview(titleIconView)
        titleStack.addArrangedSubview(titleLabel)
        titleTrailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        titleTrailingSpacer.setContentHuggingPriority(.required, for: .horizontal)
        titleTrailingSpacer.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleStack.addArrangedSubview(titleTrailingSpacer)

        NSLayoutConstraint.activate([
            titleIconView.widthAnchor.constraint(equalToConstant: 16),
            titleIconView.heightAnchor.constraint(equalToConstant: 16),
            titleStack.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 230),
            titleTrailingSpacer.widthAnchor.constraint(equalToConstant: 5),
        ])


        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(onBankHeaderClicked(_:)))
        clickGesture.numberOfClicksRequired = 1
        clickGesture.buttonMask = 0x1
        titleStack.addGestureRecognizer(clickGesture)

        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("simplebanking.transactions.toolbar"))
        toolbar.showsBaselineSeparator = true
        let delegate = TransactionsPanelToolbarDelegate(principalView: titleStack, onSettings: onSettings)
        toolbar.delegate = delegate
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        panel.toolbar = toolbar
        toolbarDelegate = delegate
    }

    private func bindTitlebar() {
        vm.$connectedBankDisplayName
            .sink { [weak self] _ in self?.updateTitlebarContent() }
            .store(in: &cancellables)
        vm.$connectedBankLogoID
            .sink { [weak self] _ in self?.updateTitlebarContent() }
            .store(in: &cancellables)
        vm.$connectedBankIBAN
            .sink { [weak self] _ in self?.updateTitlebarContent() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTitlebarContent() }
            .store(in: &cancellables)
        BankLogoStore.shared.$images
            .sink { [weak self] _ in self?.updateTitlebarContent() }
            .store(in: &cancellables)
    }

    private func updateTitlebarContent() {
        guard !isUpdatingTitlebar else { return }
        isUpdatingTitlebar = true
        defer { isUpdatingTitlebar = false }

        // Unified mode: neutral "Alle Konten" label + columns icon
        if vm.isUnifiedMode {
            let label = L10n.t("Alle Konten", "All Accounts")
            titleLabel.stringValue = label
            panel.title = label
            titleIconView.image = NSImage(systemSymbolName: "building.columns.fill", accessibilityDescription: nil)
            titleIconView.contentTintColor = .secondaryLabelColor
            return
        }

        // Single-account mode
        let brand = BankLogoAssets.resolve(
            displayName: vm.connectedBankDisplayName,
            logoID: vm.connectedBankLogoID,
            iban: vm.connectedBankIBAN
        )
        let rawName = vm.connectedBankDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = brand?.displayName ?? "simplebanking"
        let displayName = rawName.isEmpty ? fallbackName : rawName
        titleLabel.stringValue = displayName
        panel.title = displayName

        if BankLogoStore.shared.image(for: brand) == nil {
            BankLogoStore.shared.preload(brand: brand)
        }

        if let image = BankLogoStore.shared.image(for: brand) {
            titleIconView.image = image
            titleIconView.contentTintColor = nil
        } else {
            titleIconView.image = NSImage(systemSymbolName: "building.columns.circle.fill", accessibilityDescription: "Bank")
            titleIconView.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func onBankHeaderClicked(_ sender: NSClickGestureRecognizer) {
        guard sender.state == .ended else { return }
        let now = Date().timeIntervalSinceReferenceDate

        // 5 Klicks in 1.8s → Clippy ein/ausblenden
        headerClickTimestamps.append(now)
        headerClickTimestamps = headerClickTimestamps.filter { now - $0 <= clippyHeaderClickWindowSeconds }
        if headerClickTimestamps.count >= clippyRequiredClicks {
            headerClickTimestamps.removeAll(keepingCapacity: true)
            guard let host = panel.contentView else { return }
            clippy.toggle(on: host)
        }

        // 8 Klicks in 3s → autonomen Modus umschalten
        autonomousClickTimestamps.append(now)
        autonomousClickTimestamps = autonomousClickTimestamps.filter { now - $0 <= clippyAutonomousClickWindowSeconds }
        if autonomousClickTimestamps.count >= clippyAutonomousRequiredClicks {
            autonomousClickTimestamps.removeAll(keepingCapacity: true)
            let newMode = !clippy.isAutonomousMode
            clippy.setAutonomousMode(newMode, on: panel.contentView)
            clippy.showFeedback(autonomousEnabled: newMode, on: panel.contentView)
        }
    }
}

private final class TransactionsPanelToolbarDelegate: NSObject, NSToolbarDelegate {
    private let principalIdentifier = NSToolbarItem.Identifier("simplebanking.transactions.principal")
    private let settingsIdentifier = NSToolbarItem.Identifier("simplebanking.transactions.settings")
    private let principalView: NSView
    private let onSettings: (() -> Void)?

    init(principalView: NSView, onSettings: (() -> Void)?) {
        self.principalView = principalView
        self.onSettings = onSettings
        super.init()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, principalIdentifier, settingsIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, principalIdentifier, settingsIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == principalIdentifier {
            let item = NSToolbarItem(itemIdentifier: principalIdentifier)
            item.view = principalView
            item.label = "Bank"
            return item
        }
        if itemIdentifier == settingsIdentifier {
            let item = NSToolbarItem(itemIdentifier: settingsIdentifier)
            let button = NSButton()
            button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Einstellungen")
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.target = self
            button.action = #selector(settingsTapped)
            button.toolTip = "Einstellungen"
            item.view = button
            item.label = "Einstellungen"
            return item
        }
        return nil
    }

    @objc private func settingsTapped() {
        onSettings?()
    }
}

// MARK: - Filter Menu Button (NSViewRepresentable)

private struct FilterMenuButton: NSViewRepresentable {
    let activeFilter: TxFilter
    let onSelect: (TxFilter) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked(_:))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.activeFilter = activeFilter
        context.coordinator.onSelect = onSelect
        let name = activeFilter == .all
            ? "line.3.horizontal.decrease"
            : "line.3.horizontal.decrease.circle.fill"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            img.isTemplate = true
            button.image = img
        }
        button.contentTintColor = .labelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var activeFilter: TxFilter = .all
        var onSelect: (TxFilter) -> Void = { _ in }

        @objc func clicked(_ sender: NSButton) {
            let menu = NSMenu()
            for filter in TxFilter.allCases {
                let item = NSMenuItem(title: filter.label, action: #selector(itemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = filter.rawValue
                if let img = NSImage(systemSymbolName: filter.icon, accessibilityDescription: nil) {
                    img.isTemplate = true
                    item.image = img
                }
                if activeFilter == filter { item.state = .on }
                menu.addItem(item)
            }
            let bounds = sender.bounds
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: sender)
        }

        @objc func itemSelected(_ sender: NSMenuItem) {
            guard let filter = TxFilter(rawValue: sender.tag) else { return }
            onSelect(filter)
        }
    }
}

// MARK: - Color from hex

extension Color {
    /// Initialize from a 6-digit hex string (without #), e.g. "ee0000".
    init?(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
