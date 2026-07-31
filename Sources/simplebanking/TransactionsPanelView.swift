import AppKit
import Combine
import SwiftUI

private struct TransactionsPanelView: View {
    @ObservedObject var vm: TransactionsViewModel
    let onRefresh: () async -> Void
    @ObservedObject var accountNav: AccountNavModel
    /// Öffnet das einheitliche Dashboard am gewünschten Tab (löst die Einzel-Sheets ab).
    var onOpenDashboard: ((DashboardTab) -> Void)? = nil
    // Fenster-Chrome jetzt im SwiftUI-Header (statt NSToolbar) — damit die Money-Heat
    // bis ganz oben hinter Ampel/Icons reicht. Refresh/Pin/Einstellungen als Buttons.
    var onSettings: (() -> Void)? = nil
    var onTogglePin: (() -> Void)? = nil
    var isPinnedProvider: (() -> Bool)? = nil
    @State private var isPinnedLocal: Bool = false
    @ObservedObject private var logoStore = BankLogoStore.shared
    @ObservedObject private var multibankingStore = MultibankingStore.shared
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("llmAPIKeyPresent") private var llmAPIKeyPresent: Bool = false
    /// Infinite Scroll ist seit v1.5.0 immer aktiv (war früher Toggle).
    /// Variable bleibt als Konstante, damit die ehemaligen if-Branches
    /// nicht alle aufgelöst werden müssen — Compiler optimiert das raus.
    private let infiniteScrollEnabled: Bool = true
    // Konfetti komplett raus in v1.5.0 — nur Ripple bleibt als Income-Effekt.
    @AppStorage(MerchantResolver.pipelineEnabledKey) private var effectiveMerchantPipelineEnabled: Bool = true
    @AppStorage(ThemeManager.storageKey) private var themeId: String = ThemeManager.defaultThemeID
    @AppStorage("showTransactionCategories") private var showCategories: Bool = false
    @AppStorage("showFilterPills") private var showFilterPills: Bool = false
    @AppStorage("attentionInboxEnabled") private var attentionInboxEnabled: Bool = true
    @AppStorage("simplesendVisible") private var simplesendVisible: Bool = true
    @AppStorage("monthRingEnabled") private var monthRingEnabled: Bool = true
    @AppStorage(BankTintProvider.globalKey) private var bankTintEnabled: Bool = BankTintProvider.globalDefault
    @AppStorage(BankTintProvider.intensityKey) private var bankTintIntensity: Double = BankTintProvider.defaultIntensity
    @AppStorage(BankTintStyle.storageKey) private var bankTintStyleRaw: String = BankTintStyle.sidebar.rawValue
    @AppStorage("greenZoneIncludeOtherIncome") private var greenZoneIncludeOtherIncome: Bool = false
    @AppStorage("greenZoneShowDispo") private var greenZoneShowDispo: Bool = true
    @AppStorage("demoMode") private var demoMode: Bool = false
    @AppStorage("subscriptions.userExcluded") private var subscriptionExcludedRaw: String = ""
    @AppStorage("subscriptions.tabOverrides")  private var subscriptionOverridesRaw: String = ""
    @Environment(\.colorScheme) private var environmentColorScheme
    
    @ObservedObject private var roundupView = RoundupViewState.shared
    @State private var reweReceipts: [ReweReceipt] = []
    @State private var reweRange: Int = 0   // 0 = Monat, 1 = Jahr, 2 = Vorjahr
    @State private var reweExpanded: Set<String> = []
    @State private var reweTab: Int = 0   // 0 = Einkäufe, 1 = Kategorien
    /// eBon-Slot aktiv (REWE oder dm) — selbe Karten-/Listen-Mechanik, nur Logo,
    /// Name und Kategorie-Wörterbuch unterscheiden sich.
    private var receiptActive: Bool { multibankingStore.activeSlot?.isReceiptSlot == true }
    private var receiptSource: SlotSource { multibankingStore.activeSlot?.source ?? .rewe }
    private var receiptLogo: NSImage? { multibankingStore.activeSlot?.receiptLogoImage }
    private var receiptBrandName: String { multibankingStore.activeSlot?.receiptBrandName ?? "REWE" }
    @State private var showAttentionInbox = false
    @State private var attentionCards: [AttentionCard] = []
    @State private var inboxGeneration: Int = 0
    /// Signature der letzten Attention-Inbox-Berechnung. Hash aus den Inputs, die
    /// das Ergebnis determinieren — wenn identisch, kann die Inbox ohne Neu-Rechnung
    /// direkt wieder angezeigt werden. Invalidiert sich automatisch bei neuen Tx
    /// oder Reminder-Änderungen, weil sich der Hash ändert.
    @State private var attentionCacheSignature: String?
    @State private var selectedTxID: String? = nil
    @State private var activeSwipedTxID: String? = nil
    @State private var reminderPickerTxID: String? = nil
    @State private var reminderPickerBankId: String = "primary"
    @State private var reminderPickerSlotId: String = "legacy"
    @State private var reminderPickerDate: Date = {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.day = (comps.day ?? 1) + 1
        comps.hour = 9; comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }()
    @State private var panelIsWide: Bool = false
    /// Wird bei jedem Themewechsel hochgezählt und hängt als `.id` an der Wurzel.
    ///
    /// `ThemeManager` ist kein `ObservableObject` — die Theme-Stellen lesen
    /// `currentTheme` direkt, SwiftUI kennt also keine Abhängigkeit und invalidiert
    /// nichts. Das Flyout fiel damit nicht auf, weil es bei jedem Öffnen neu entsteht;
    /// die Umsatzliste bleibt offen und zeigte das neue Theme erst nach Schließen und
    /// Öffnen. Die Kennung erzwingt genau diesen Neubau — nur ohne Handarbeit.
    @State private var themeRevision: Int = 0
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

    // Scroll-wheel gesture monitor (trackpad two-finger swipe)
    // Equatable wrapper with a nonce so onChange fires even when the same target
    // is selected twice in a row (e.g. duplicate cards for the same transaction).
    private struct ScrollTarget: Equatable {
        let id: String
        let nonce: UUID
    }
    @State private var scrollTarget: ScrollTarget?
    @State private var highlightedTxStableId: String? // briefly highlight after scroll
    @State private var highlightBounce: CGFloat = 1.0  // transient scale-bounce for highlighted row

    @State private var scrollWheelMonitor: Any?
    @State private var overscrollAccum: CGFloat = 0
    @State private var overscrollActive = false     // true only when gesture STARTED at list top
    @State private var overscrollStartTime: Date?   // when overscroll accumulation began
    @State private var swipeAccumX: CGFloat = 0
    @State private var swipeTriggered = false

    private let infinitePageSize: Int = 10
    private let pullTriggerDistance: CGFloat = 72
    private let pullMaxVisualOffset: CGFloat = 90
    private let pullRefreshHoldOffset: CGFloat = 36
    private let scrollOverscrollThreshold: CGFloat = 65   // capped pts before trigger
    private let overscrollDeadZone: CGFloat = 16          // ignore first N pts (avoid accidental)
    private let overscrollPerEventCap: CGFloat = 4.0      // max contribution per scroll event
    private let overscrollMinDuration: TimeInterval = 0.55 // must sustain pull for this long
    private let horizontalSwipeThreshold: CGFloat = 50

    private static let inputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        // Parse as local midnight so Calendar.current.isDateInToday / isDateInYesterday
        // classify correctly. UTC-midnight would misclassify on negative UTC offsets.
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    /// Active bank ID for enrichment data (unread/flagged) — "demo" in demo mode, "primary" otherwise.
    private var activeBankId: String {
        demoMode ? "demo" : "primary"
    }

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

    private static let leftToPayFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    @AppStorage("balanceSubtitleStyle.panel") private var panelSubtitleStyle: Int = 0

    // MARK: PayPal-Untertitel (Umsatzliste): Toggle letzte Buchung / Monatsausgaben
    @State private var paypalSubtitleRange: Int = 0

    private func eurFormatted(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE"); f.numberStyle = .currency; f.currencyCode = "EUR"
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.2f €", v)
    }

    private var paypalLastBookingText: String {
        guard let last = vm.transactions.first else { return L10n.t("Keine Buchung", "No transaction") }
        let amt = last.amount.flatMap { Double($0.amount) } ?? 0
        let name = (last.creditor?.name ?? last.debtor?.name ?? "").trimmingCharacters(in: .whitespaces)
        let base = name.isEmpty ? eurFormatted(abs(amt)) : "\(eurFormatted(abs(amt))) · \(name)"
        return L10n.t("Letzte Buchung: \(base)", "Last: \(base)")
    }

    private var paypalMonthSpendText: String {
        let cal = Calendar.current, now = Date()
        let ym = String(format: "%04d-%02d", cal.component(.year, from: now), cal.component(.month, from: now))
        let spend = vm.transactions
            .filter { ($0.bookingDate ?? "").hasPrefix(ym) }
            .compactMap { $0.amount.flatMap { Double($0.amount) } }
            .filter { $0 < 0 }
            .reduce(0, +)
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "LLLL"
        return "\(L10n.t("Ausgaben", "Spending")) \(f.string(from: now)): \(eurFormatted(abs(spend)))"
    }

    @ViewBuilder
    private func panelPayPalSubtitle(detail: Color) -> some View {
        Button {
            paypalSubtitleRange = paypalSubtitleRange == 0 ? 1 : 0
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                Text(paypalSubtitleRange == 0 ? paypalLastBookingText : paypalMonthSpendText)
                    .font(.system(size: 12)).lineLimit(1)
            }
            .foregroundColor(detail)
        }
        .buttonStyle(.plain)
        .help(L10n.t("Tippen: letzte Buchung / Ausgaben diesen Monat",
                     "Tap: last transaction / spending this month"))
    }

    private var leftToPaySubtitle: some View {
        // Im Unified-Mode ist leftToPay pro-Slot aggregiert (jeder Slot mit eigenem
        // Gehaltstag). Sub-Metrics würden diese Summe gegen EINEN Gehaltstag
        // rechnen → fachlich falsch. Deshalb im Unified-Mode Classic erzwingen.
        // Im Aufrunden-Modus wird die ganze Balance-Card durch RoundupSavingsCard
        // ersetzt — dieser Subtitle läuft dann gar nicht.
        let parsed = AmountParser.parseCurrencyDisplayOrNil(vm.currentBalance)
        let level = BalanceSignal.classify(balance: parsed, thresholds: normalizedBalanceThresholds)
        let style = BalanceSignal.style(for: level)
        let detail = BalanceWash.colors(level: level, style: style, dark: activeColorScheme == .dark).detail
        return BalanceSubtitleSwitch(
            balance: parsed,
            leftToPayAmount: vm.leftToPayAmount,
            salaryDay: activeSlotSettings.effectiveSalaryDay,
            salaryToleranceBefore: activeSlotSettings.salaryDayToleranceBefore,
            salaryToleranceAfter: activeSlotSettings.salaryDayToleranceAfter,
            cycleEndOverride: vm.leftToPayCycleEnd,
            style: $panelSubtitleStyle,
            forceClassic: vm.isUnifiedMode,
            detailColor: detail
        )
    }

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
    /// Kurzform: ein Theme (nicht Default) ist aktiv → Flyout/Liste getönt.
    private var themed: Bool { !isDefaultTheme }
    /// Lo-Fi-Modus (BTX): größere Raster-Typografie, Block-Felder, bündige Zeilen.
    /// Farb-Themes wie Game Boy/Sunrise behalten die Default-Metriken.
    private var lofi: Bool { themed && ThemeChrome.lofi }

    private var activeColorScheme: ColorScheme {
        colorScheme ?? environmentColorScheme
    }

    private var activeSlotSettings: BankSlotSettings {
        BankSlotSettingsStore.load(slotId: multibankingStore.activeSlot?.id ?? "legacy")
    }

    private var normalizedBalanceThresholds: BalanceSignalThresholds {
        let s = activeSlotSettings
        return BalanceSignal.normalizedThresholds(
            deepOverdraft: s.balanceSignalDeepOverdraftThreshold,
            low: s.balanceSignalLowUpperBound,
            medium: s.balanceSignalMediumUpperBound,
            veryGood: s.balanceSignalVeryGoodLowerBound
        )
    }

    private var activePanelBg: Color {
        // Bei aktivem Theme bleibt die Theme-Fläche auch im Sparmodus erhalten — das
        // Mint-Grün des Aufrunden-Views würde jede Theme-Farbwelt sprengen.
        if roundupView.isActive { return themed ? .themedSurfaceOrClear : .roundupPanelBackground }
        // Ein aktives Theme schlägt auch den Händler-Marken-Ton: Die Fläche gehört dem
        // Theme, nicht der Marke — sonst bekäme ein Händler-Slot eine fremde Farbe.
        if themed { return .themedSurfaceOrClear }
        // Händler-/eBon-Slots: Liste im Marken-Ton (untere Wash-Farbe), damit der
        // Marken-Header nahtlos in die Liste übergeht. WICHTIG: vor dem Money-Heat-
        // Zweig — sonst würde der (als cachedBalance gespeicherte) Letzt-Bon-Betrag
        // fälschlich wie ein Saldo klassifiziert und die Liste saldo-getönt.
        if receiptActive { return MerchantWash.colors(for: receiptSource).bottom }
        // Aggregat: neutral (passend zur neutralen Aggregat-Karte).
        if vm.isUnifiedMode {
            return BalanceWash.colors(level: .unknown, style: BalanceSignal.style(for: .unknown),
                                      dark: activeColorScheme == .dark).bottom
        }
        // Money-Heat-Theme (Default): Liste in der Temperaturfarbe des Kontostands.
        if isDefaultTheme {
            return moneyHeatListTint
        }
        // Aktives Theme (nicht Default): flache Theme-Farbe über die ganze Liste —
        // oder durchsichtig, wenn ein Wallpaper darunterliegt.
        return .themedSurfaceOrClear
    }

    /// Heller Temperatur-Ton (untere Money-Heat-Farbe) für den Listen-Hintergrund,
    /// damit der Verlauf des Headers nahtlos in die Liste übergeht.
    private var moneyHeatListTint: Color {
        let parsed = AmountParser.parseCurrencyDisplayOrNil(vm.currentBalance)
        let level = BalanceSignal.classify(balance: parsed, thresholds: normalizedBalanceThresholds)
        let style = BalanceSignal.style(for: level)
        return BalanceWash.colors(level: level, style: style, dark: activeColorScheme == .dark).bottom
    }

    /// Voll-saturierte Bank-Color für Sidebar-Streifen (A) und Border (D).
    /// Nil im Aufrunden-Modus, im Unified-Mode oder wenn Bank-Tint deaktiviert.
    private var bankAccentForOverlay: Color? {
        guard !roundupView.isActive else { return nil }
        return BankTintProvider.currentBankAccentColor()
    }

    private var currentTintStyle: BankTintStyle {
        BankTintStyle(rawValue: bankTintStyleRaw) ?? .soft
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
        var effectiveRef = reference
        if greenZoneIncludeOtherIncome {
            let other = SalaryProgressCalculator.detectedOtherIncome(
                salaryDay: s.effectiveSalaryDay, transactions: vm.transactions)
            effectiveRef += Int(other.rounded())
        }
        greenZoneFractionCached = SalaryProgressCalculator.greenZoneFraction(
            balance: balance,
            mediumThreshold: effectiveRef)
    }

    // MARK: - Attention Inbox snooze (persists until midnight next day)

    private static let snoozeKeysKey = "attentionInbox.snoozedKeys"

    private func saveSnoozedCards(_ cards: [AttentionCard]) {
        // Additive + permanent: merge new keys with whatever was already stored.
        // Cards stay dismissed until the underlying detection key changes (e.g.
        // amount/count in duplicate → new snoozeKey → new card).
        let newKeys = cards.map(\.snoozeKey)
        let existing = UserDefaults.standard.stringArray(forKey: Self.snoozeKeysKey) ?? []
        let merged = Array(Set(existing).union(newKeys))
        UserDefaults.standard.set(merged, forKey: Self.snoozeKeysKey)
    }

    private func filterSnoozed(_ cards: [AttentionCard]) -> [AttentionCard] {
        let keys = Set(UserDefaults.standard.stringArray(forKey: Self.snoozeKeysKey) ?? [])
        guard !keys.isEmpty else { return cards }
        return cards.filter { !keys.contains($0.snoozeKey) }
    }

    /// Cache-Key für die Attention-Inbox. Nutzt `MAX(updated_at)` aus der DB als
    /// Input-Hash — jede Tx-Mutation (Upsert, Merchant-Amendment, Reminder-Verknüpfung,
    /// Flag-Toggle, Note-Edit) geht durch `upsert()`/`set*()`-Methoden, die alle
    /// `updated_at` bumpen. Damit ändert sich die Signature bei wirklich jedem
    /// fachlich relevanten Input-Wechsel, nicht nur bei Count/Datum.
    private func computeAttentionSignature() -> String {
        let isDemoMode = demoMode
        let isUnified = vm.isUnifiedMode
        let slotIds: [String] = isDemoMode
            ? ["demo-main", "demo-daily", "demo-bills"]
            : (isUnified ? MultibankingStore.shared.slots.map { $0.id } : [TransactionsDatabase.activeSlotId])
        let maxUpdated = (try? TransactionsDatabase.maxUpdatedAt(slots: slotIds, bankId: activeBankId)) ?? ""
        let snoozeHash = (UserDefaults.standard.stringArray(forKey: Self.snoozeKeysKey) ?? []).sorted().joined(separator: "|")
        return "\(slotIds.sorted().joined(separator: ",")):\(maxUpdated):\(snoozeHash):\(isDemoMode)"
    }

    private func recomputeAttentionInbox() {
        // Wenn AttentionInbox vom User deaktiviert ist: gar nicht erst rechnen.
        // Spart CPU + verhindert dass cards gefilled werden während die UI sie
        // nicht zeigt (sonst würde ein späteres Re-Enable veraltete cards zeigen).
        guard attentionInboxEnabled else {
            attentionCards = []
            attentionCacheSignature = ""
            return
        }
        // Cache-Fast-Path: wenn sich nichts geändert hat, die vorhandenen Cards wiederverwenden.
        let signature = computeAttentionSignature()
        if signature == attentionCacheSignature, !attentionCards.isEmpty {
            return
        }
        attentionCacheSignature = signature

        // Capture MainActor-bound values before going off-thread
        inboxGeneration &+= 1
        let generation = inboxGeneration
        let isDemoMode = demoMode
        let recent = vm.transactions
        let isUnified = vm.isUnifiedMode
        let slotId = isDemoMode ? "demo-main" : (MultibankingStore.shared.activeSlot?.id ?? "legacy")
        let enrichBankId = activeBankId
        let nonDemoSlots: [String]? = isUnified
            ? MultibankingStore.shared.slots.map { $0.id }
            : [TransactionsDatabase.activeSlotId]

        Task {
            let cards = await Task.detached(priority: .userInitiated) { () -> [AttentionCard] in
                let history: [TransactionsResponse.Transaction]
                if isDemoMode {
                    history = (try? TransactionsDatabase.loadUnifiedTransactions(
                        slots: ["demo-main", "demo-daily", "demo-bills"], days: 90, bankId: "demo"
                    )) ?? recent
                } else {
                    history = (try? TransactionsDatabase.loadUnifiedTransactions(
                        slots: nonDemoSlots, days: 90
                    )) ?? recent
                }
                let cfg = BankSlotSettingsStore.load(slotId: slotId)
                var cards = AttentionInboxDetector.analyze(
                    recent: recent, history: history,
                    salaryDay: cfg.effectiveSalaryDay,
                    salaryToleranceBefore: cfg.salaryDayToleranceBefore,
                    salaryToleranceAfter: cfg.salaryDayToleranceAfter
                )
                // Transactions with an active EventKit reminder → Reminder cards in attention inbox.
                // Enrichment-Keys sind jetzt `slotId|txID` — Buchung matchen wir über den
                // txID-Suffix und, falls vorhanden, den Slot.
                let enrichment = (try? TransactionsDatabase.loadEnrichmentData(bankId: enrichBankId)) ?? [:]
                let reminderEntries: [(slotId: String, txID: String)] = enrichment
                    .filter { $0.value.reminderId != nil }
                    .compactMap { (k, _) in
                        let parts = k.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts.count == 2 else { return nil }
                        return (String(parts[0]), String(parts[1]))
                    }
                if !reminderEntries.isEmpty {
                    let allTx = recent + history
                    for entry in reminderEntries {
                        guard let tx = allTx.first(where: {
                            TransactionRecord.fingerprint(for: $0) == entry.txID
                            && ($0.slotId ?? TransactionsDatabase.activeSlotId) == entry.slotId
                        }) else { continue }
                        let merchant = MerchantResolver.resolve(transaction: tx).effectiveMerchant
                        let amt = tx.parsedAmount
                        let fmtAmt = String(format: "%.2f €", abs(amt))
                        cards.append(AttentionCard(
                            type: .reminder,
                            priority: 2,
                            title: L10n.t("Erinnerung: \(merchant)", "Reminder: \(merchant)"),
                            body: L10n.t(
                                "Du hast diese Buchung markiert (\(fmtAmt)).",
                                "You flagged this transaction (\(fmtAmt))."
                            ),
                            detail: fmtAmt,
                            relatedTxId: TransactionRecord.fingerprint(for: tx),
                            snoozeKey: "reminder-\(entry.slotId)-\(entry.txID)"
                        ))
                    }
                }
                return cards
            }.value
            guard generation == inboxGeneration else { return }  // stale-result guard
            attentionCards = filterSnoozed(cards)
        }
    }

    /// Returns the slot's display color: custom > generated > fallback gray.
    private func slotDisplayColor(for slot: BankSlot) -> Color {
        if let hex = slot.customColor, let c = Color(hex: hex) { return c }
        if let logoId = slot.logoId, let hex = BankLogoAssets.primaryColor(forLogoId: logoId), let c = Color(hex: hex) { return c }
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
            deepOverdraftThreshold: normalizedBalanceThresholds.deepOverdraftThreshold * Double(slotCount),
            lowUpperBound: normalizedBalanceThresholds.lowUpperBound * Double(slotCount),
            mediumUpperBound: normalizedBalanceThresholds.mediumUpperBound * Double(slotCount),
            veryGoodLowerBound: normalizedBalanceThresholds.veryGoodLowerBound * Double(slotCount)
        )
        // Aggregat bewusst NEUTRAL (keine grün/orange-Money-Heat) — sonst springt
        // die Farbe beim Wechsel Einzelkonto↔Aggregat.
        let uDark = activeColorScheme == .dark
        let uLevel: BalanceSignalLevel = .unknown
        let uStyle = BalanceSignal.style(for: uLevel)
        let uWash = BalanceWash.colors(level: uLevel, style: uStyle, dark: uDark)
        let totalSignalColor: Color = uWash.balance

        let leftContent = VStack(alignment: .leading, spacing: 8) {
            // Row 1: „Alle Konten"-Header (harmonisiert mit der Einzelkarte —
            // keine Konten-Aufschlüsselung/Pillen mehr, nur der Gesamt-Saldo).
            HStack(spacing: 8) {
                // Aggregat-Kopf folgt dem Theme (BTX: Mosaik-Block statt Stapel-Symbol).
                // Ein Mosaik-Block ist kein Textkommando, deshalb hängt er an
                // `lofiTypography` und nicht an `glyphControls`.
                if ThemeChrome.lofi {
                    BTXMosaicIcon(category: .sonstiges, side: 18)
                } else if let logo = ThemeChrome.globalLogoImage {
                    // Siehe Flyout: „für alle Konten" schließt die Aggregat-Karte ein.
                    Image(nsImage: logo).resizable().scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                Text(L10n.t("Alle Konten", "All accounts"))
                    .font(themed ? ThemeFonts.flyoutBody(size: lofi ? 15 : 13) : .system(size: 13))
                    .textCase(ThemeChrome.textCase)
                    .foregroundColor(themed ? Color.themedInk.opacity(0.9) : Color(NSColor.secondaryLabelColor))
                Spacer()
            }

            // Row 2: aggregated balance — same size as single-account card
            if let total = totalBalance {
                Text(formatBalance(total, currency: displayCurrency))
                    .font(lofi ? ThemeFonts.flyoutHeading(size: 50, weight: .bold)
                         : themed ? ThemeFonts.flyoutHeading(size: 38, weight: .bold)
                                  : .system(size: 38, weight: .bold, design: .default))
                    .tracking(lofi ? 1.0 : -0.6)
                    // Negatives Aggregat auch im Theme in Warnfarbe (BTX-Rot).
                    .foregroundColor(themed
                                     ? (total < 0 ? .themedExpense : .themedInk)
                                     : totalSignalColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .scaleEffect(x: 1, y: lofi ? 1.15 : 1.0, anchor: .leading)
                    .frame(height: lofi ? 58 : ThemeFonts.lineHeight(forSize: 38, weight: .bold), alignment: .leading)
            } else if slotBalances.isEmpty || slotBalances.allSatisfy({ $0.balance == nil }) {
                Text("--,-- €")
                    .font(themed ? ThemeFonts.flyoutHeading(size: 32, weight: .bold)
                                 : .system(size: 32, weight: .bold, design: .default))
                    .foregroundColor(themed ? Color.themedInk.opacity(0.7) : .secondary)
                    .padding(.trailing, 0)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(slotBalances.prefix(2), id: \.slot.id) { item in
                        if let b = item.balance {
                            Text(formatBalance(b, currency: item.slot.currency ?? "EUR"))
                                .font(themed ? ThemeFonts.flyoutHeading(size: 22, weight: .bold)
                                             : .system(size: 22, weight: .bold))
                                .foregroundColor(themed
                                                 ? (b < 0 ? .themedExpense : (b > 0 ? .themedIncome : .themedInk))
                                                 : (b < 0 ? Color.expenseRed : (b > 0 ? Color.incomeGreen : .primary)))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.trailing, 0)
            }
            // Kein leftToPay-Untertitel im Aggregat: pro-Slot-Summen gegen EINEN
            // Gehaltstag zu rechnen ist fachlich falsch (zeigte fälschlich „alles
            // gebucht", obwohl einzelne Konten Vormerkungen haben).
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)   // wie Einzelkarte → Pillen darunter auf gleicher Höhe

        let ringVisible = ThemeChrome.kontoringSichtbar(nutzerSchalter: monthRingEnabled)
            && !vm.isUnifiedMode
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
                        // GreenRing reflects the real balance.
                        let parsed = AmountParser.parseCurrencyDisplayOrNil(vm.currentBalance)
                        GreenZoneRing(fraction: greenZoneFraction,
                                      balance: parsed,
                                      dispoLimit: activeSlotSettings.dispoLimit,
                                      showDispo: greenZoneShowDispo)
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        // Randlose Money-Heat wie die Einzelkonto-Karte (Aggregat-Temperatur), oben bis
        // hinter die Titelleiste, unten weicher Fade in den Listen-Hintergrund.
        .background(
            LinearGradient(
                stops: [
                    .init(color: uWash.top, location: 0.0),
                    .init(color: uWash.bottom, location: 0.52),
                    .init(color: activePanelBg, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(.container, edges: .top)
        )
    }

    private var defaultThemeBalanceCard: some View {
        let parsedBalance = AmountParser.parseCurrencyDisplayOrNil(vm.currentBalance)
        let level = BalanceSignal.classify(balance: parsedBalance, thresholds: normalizedBalanceThresholds)
        let style = BalanceSignal.style(for: level)
        let displayBalance = parsedBalance == nil ? "--,-- €" : (vm.currentBalance ?? "--,-- €")
        // Flyout-Look: Temperatur-Wash (randlos) statt Glas-Karte. Ring bleibt (Punkt 3.1).
        let dark = activeColorScheme == .dark
        let wash = BalanceWash.colors(level: level, style: style, dark: dark)
        // Aktives Theme (nicht Default): Money-Heat AUS → flache Theme-Fläche + Ink + Font.
        let themed = !isDefaultTheme
        let fillTop:    Color = themed ? .themedSurfaceOrClear : wash.top
        let fillMid:    Color = themed ? .themedSurfaceOrClear : wash.bottom
        // Negativer Saldo trägt auch im Theme die Warnfarbe (BTX-Rot) — Blau würde
        // die wichtigste Information der Karte verschlucken.
        let balanceColor: Color = themed
            ? ((parsedBalance ?? 0) < 0 ? .themedExpense : .themedInk)
            : wash.balance
        let detailColor:  Color = themed ? Color.themedInk.opacity(0.72) : wash.detail
        let headerColor:  Color = themed ? Color.themedInk.opacity(0.9) : Color(NSColor.secondaryLabelColor)
        // Demo-Referenz (2a, 460 px breit): Kontostand 50–52 px VT323 + scaleY(1.15)
        // („double height"-Steuerzeichen) — NUR im Lo-Fi-Modus (BTX). Farb-Themes
        // behalten die 38-pt-Metrik des Defaults.
        let balanceFont: Font = lofi ? ThemeFonts.flyoutHeading(size: 50, weight: .bold)
                              : themed ? ThemeFonts.flyoutHeading(size: 38, weight: .bold)
                                        : .system(size: 38, weight: .bold, design: .default)
        let headerFont:  Font = themed ? ThemeFonts.flyoutBody(size: lofi ? 15 : 13) : .system(size: 13)

        let balanceBrand = BankLogoAssets.resolve(displayName: vm.connectedBankDisplayName,
                                                   logoID: vm.connectedBankLogoID,
                                                   iban: vm.connectedBankIBAN)
        let isPayPal = multibankingStore.activeSlot?.isPayPal == true
        let headerName = isPayPal ? "PayPal" : vm.connectedBankDisplayName
        let leftContent = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !ThemeChrome.bankLogosEnabled {
                    // BTX: keine Bildmarke über dem Kontostand — neutraler Mosaik-Block.
                    BTXMosaicIcon(category: .sonstiges, side: 18)
                } else if let logo = ThemeChrome.globalLogoImage {
                    // Globales Theme-Logo — für alle Konten gleich, deshalb ohne die
                    // marken-abhängige Invertierung (siehe `logoDark`).
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else if let img = (isPayPal ? PayPalLogoAsset.image : nil) ?? vm.connectedBankLogoImage ?? logoStore.image(for: balanceBrand) {
                    BankMark(image: img, brandId: balanceBrand?.id, size: 18,
                             cornerRadius: 3, dark: activeColorScheme == .dark)
                } else {
                    Image(systemName: "wallet.pass")
                        .font(.system(size: 16))
                        .foregroundColor(detailColor)
                }
                Text(formatBankHeader(
                    nickname: vm.connectedBankNickname,
                    bankName: headerName,
                    date: vm.currentBalanceFetchedAt
                ))
                    .font(headerFont)
                    .textCase(ThemeChrome.textCase)
                    .foregroundColor(headerColor)
                // BTX: blinkendes Telefon-Steuerzeichen neben der Bank (wie Demo-Kopf).
                // Zierrat, kein Bedienelement — folgt `lofiTypography`.
                if ThemeChrome.lofi {
                    BTXBlinkingPhone(size: 14)
                }
                Spacer()
            }

            Text(displayBalance)
                .font(balanceFont)
                .tracking(lofi ? 1.0 : -0.6)
                .foregroundColor(balanceColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // BTX „double height": vertikale Streckung wie das Steuerzeichen (Demo).
                .scaleEffect(x: 1, y: lofi ? 1.15 : 1.0, anchor: .leading)
                // Feste Zeilenhöhe im Lo-Fi-Modus: minimumScaleFactor darf die
                // Layout-Höhe NIE von der Länge des Kontostands abhängen lassen.
                .frame(height: lofi ? 58 : ThemeFonts.lineHeight(forSize: 38, weight: .bold), alignment: .leading)

            if isPayPal { panelPayPalSubtitle(detail: detailColor) } else { leftToPaySubtitle }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // Aggregat und PayPal bleiben außen vor — nicht als Gestaltungsfrage, sondern
        // weil der Ring dort nichts Wahres zeigen kann: Über mehrere Konten hinweg gibt
        // es keinen gemeinsamen Gehaltstag, und PayPal hat gar keinen.
        let ringVisible = ThemeChrome.kontoringSichtbar(nutzerSchalter: monthRingEnabled)
            && !vm.isUnifiedMode && !isPayPal
        return HStack(alignment: .center, spacing: 0) {
            leftContent
                // Oben ausgerichtet, damit Header/Betrag NICHT springen, wenn der
                // Inhalt unterschiedlich hoch ist (Bank-Untertitel vs. Händler-Toggle).
                .frame(minHeight: 90, alignment: .top)
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
                GreenZoneRing(fraction: greenZoneFraction,
                              balance: parsedBalance,
                              dispoLimit: activeSlotSettings.dispoLimit)
                    .padding(.leading, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: panelIsWide)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        // Randlose Fläche bis an ALLE Fensterkanten — oben hinter der Titelleiste
        // (Ampel/Icons sitzen darauf). Unten läuft sie als 3-Stop-Verlauf weich in den
        // Listen-Hintergrund aus → fließender Übergang zur Umsatzliste (kein harter Rand).
        // Bei aktivem Theme sind alle Stops die flache Theme-Farbe.
        .background(
            LinearGradient(
                stops: [
                    .init(color: fillTop, location: 0.0),
                    .init(color: fillMid, location: 0.52),
                    .init(color: activePanelBg, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(.container, edges: .top)
        )
    }

    // MARK: - REWE eBon (Balance-Card + Einkaufsliste im Panel)

    private func reweEuro(_ c: Int) -> String { String(format: "%.2f €", Double(c) / 100) }
    private func reweDate(_ iso: String) -> String {
        let p = String(iso.prefix(10)).split(separator: "-")
        return p.count == 3 ? "\(p[2]).\(p[1]).\(p[0])" : String(iso.prefix(10))
    }
    private var reweMonthCents: Int {
        let cal = Calendar.current; let now = Date()
        let ym = String(format: "%04d-%02d", cal.component(.year, from: now), cal.component(.month, from: now))
        return reweReceipts.filter { !$0.cancelled && $0.timestamp.hasPrefix(ym) }.reduce(0) { $0 + $1.totalCents }
    }
    private var reweYearCents: Int {
        let y = String(format: "%04d", Calendar.current.component(.year, from: Date()))
        return reweReceipts.filter { !$0.cancelled && $0.timestamp.hasPrefix(y) }.reduce(0) { $0 + $1.totalCents }
    }
    private var reweLastYearString: String { String(format: "%04d", Calendar.current.component(.year, from: Date()) - 1) }
    private var reweLastYearReceipts: [ReweReceipt] {
        reweReceipts.filter { !$0.cancelled && $0.timestamp.hasPrefix(reweLastYearString) }
    }
    private var reweLastYearCents: Int { reweLastYearReceipts.reduce(0) { $0 + $1.totalCents } }
    private var reweHasLastYear: Bool { !reweLastYearReceipts.isEmpty }
    private var reweMonthLabel: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "LLLL"
        return f.string(from: Date())
    }
    /// 0 = Monat, 1 = Jahr, 2 = Vorjahr.
    private var reweRangeLabel: String {
        switch reweRange {
        case 1: return String(format: "%04d", Calendar.current.component(.year, from: Date()))
        case 2: return reweLastYearString
        default: return reweMonthLabel
        }
    }
    private var reweRangeAmount: String {
        switch reweRange { case 1: return reweEuro(reweYearCents); case 2: return reweEuro(reweLastYearCents); default: return reweEuro(reweMonthCents) }
    }
    private func cycleReweRange() {
        if reweRange == 0 { reweRange = 1 }
        else if reweRange == 1 { reweRange = reweHasLastYear ? 2 : 0 }
        else { reweRange = 0 }
    }
    /// Top-4-Ring-Segmente + Datum des letzten Bons (für die Balance-Card).
    private var reweRingSegments: [ReceiptRingSegment] {
        guard let last = reweReceipts.first else { return [] }
        return ReceiptCategoryRing.segments(forItems: last.items, source: receiptSource)
    }
    private var reweLastReceiptDate: Date? {
        guard let last = reweReceipts.first else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(last.timestamp.prefix(10)))
    }
    /// Zeit der letzten Aktualisierung (Sync) für den eBon-Header — aus dem
    /// `fetchedAt` des neuesten Bons (NICHT die Bank-Abrufzeit, die hier leer ist).
    private var receiptFetchedDate: Date? {
        guard let stamp = reweReceipts.first?.fetchedAt else { return nil }
        return ISO8601DateFormatter().date(from: stamp)
    }
    /// Hintergrund-Sync scheiterte (Login abgelaufen) → „Login erneuern" statt Uhrzeit.
    private var receiptNeedsLogin: Bool {
        guard let id = multibankingStore.activeSlot?.id else { return false }
        return AppDelegate.receiptNeedsLogin(id)
    }

    func loadReweReceipts() {
        guard let active = multibankingStore.activeSlot, active.isReceiptSlot else { reweReceipts = []; return }
        reweReceipts = (try? ReweReceiptStore.all(slotId: active.id)) ?? []
    }

    /// eBon-Balance-Card im EXAKTEN Layout der Bank-Karte (Header + großer Betrag,
    /// Kategorien-Ring rechts, darunter Einkäufe Monat/Jahr/Vorjahr-Toggle).
    /// Gleiche minHeight (108).
    private var reweBalanceCard: some View {
        // Marken-Wash (REWE/Amazon/dm) statt Glas, randlos mit 3-Stop-Übergang in die
        // Liste (wie defaultThemeBalanceCard). Ausgaben-Heat auf der Monatssumme.
        let wash = MerchantWash.colors(for: receiptSource)
        let budgetCents = activeSlotSettings.merchantMonthlyBudget * 100
        let spendLevel = SpendSignal.classify(spentCents: reweMonthCents, budgetCents: budgetCents)
        let heat = SpendSignal.heatColor(spendLevel)
        let showHeat = reweRange == 0 && spendLevel != .noBudget
        let toggleColor: Color = showHeat ? heat : Color(NSColor.secondaryLabelColor)
        let budgetBadge = reweRange == 0
            ? SpendSignal.badge(spentCents: reweMonthCents, budgetCents: budgetCents, level: spendLevel)
            : nil
        let leftContent = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // BTX: Warenkorb-Mosaik statt Marken-Logo (Bildmarken gab es nicht).
                if themed && !ThemeChrome.merchantLogosEnabled {
                    BTXMosaicIcon(category: .essenAlltag, side: 18)
                } else if let logo = receiptLogo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: "cart.fill").font(.system(size: 16)).foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                if receiptNeedsLogin {
                    Text("⚠︎ " + L10n.t("Login erneuern", "Sign in again"))
                        .font(themed ? ThemeFonts.flyoutBody(size: lofi ? 15 : 13) : .system(size: 13))
                        .textCase(ThemeChrome.textCase)
                        .foregroundColor(themed ? .themedExpense : .orange)
                } else {
                    Text(formatBankHeader(nickname: nil, bankName: receiptBrandName, date: receiptFetchedDate))
                        .font(themed ? ThemeFonts.flyoutBody(size: lofi ? 15 : 13) : .system(size: 13))
                        .textCase(ThemeChrome.textCase)
                        .foregroundColor(themed ? Color.themedInk.opacity(0.9) : Color(NSColor.secondaryLabelColor))
                }
                Spacer()
            }
            Text(vm.currentBalance ?? "--,-- €")
                .font(lofi ? ThemeFonts.flyoutHeading(size: 50, weight: .bold)
                     : themed ? ThemeFonts.flyoutHeading(size: 38, weight: .bold)
                              : .system(size: 38, weight: .bold, design: .default))
                .tracking(lofi ? 1.0 : -0.6)
                .foregroundColor(themed ? .themedInk : wash.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .scaleEffect(x: 1, y: lofi ? 1.15 : 1.0, anchor: .leading)
                .frame(height: lofi ? 58 : ThemeFonts.lineHeight(forSize: 38, weight: .bold), alignment: .leading)
            Button { cycleReweRange() } label: {
                HStack(spacing: 6) {
                    if ThemeChrome.glyphControls {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                    }
                    Text("\(L10n.t("Einkäufe", "Purchases")) \(reweRangeLabel): \(reweRangeAmount)")
                        .font(ThemeFonts.rowBody(size: 12, lofiSize: 14))
                        .textCase(ThemeChrome.textCase)
                    if let badge = budgetBadge {
                        Text(badge)
                            .font(ThemeFonts.rowBody(size: 10, weight: .semibold, lofiSize: 12))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(999))
                                    .fill(lofi ? Color.clear : heat.opacity(0.15))
                                    .overlay(
                                        lofi
                                        ? RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(999))
                                            .stroke(Color.themedInk.opacity(0.5), lineWidth: 1)
                                        : nil
                                    )
                            )
                            .foregroundColor(themed ? Color.themedInk.opacity(0.85) : heat)
                    }
                }
                .foregroundColor(themed ? Color.themedInk.opacity(0.85) : toggleColor)
            }
            .buttonStyle(.plain)
            .help(L10n.t("Tippen: Monat / Jahr / Vorjahr", "Tap: month / year / last year"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return HStack(alignment: .center, spacing: 0) {
            leftContent.frame(minHeight: 90, alignment: .top)   // wie Bank-Karte: oben ausgerichtet
            ReceiptCategoryRing(segments: reweRingSegments, date: reweLastReceiptDate)
                .padding(.leading, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(
            Group {
                if lofi {
                    // BTX: flache Theme-Fläche statt Marken-Verlauf.
                    Color.themedSurfaceOrClear
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: wash.top, location: 0.0),
                            .init(color: wash.bottom, location: 0.52),
                            .init(color: activePanelBg, location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        )
    }

    /// Einkaufsliste im Bank-Umsatz-Look, nach TAGEN gruppiert (Datums-Header
    /// wie in der echten Umsatzliste), Klick auf Einkauf → Warenkorb.
    private var reweReceiptDayGroups: [(day: String, items: [ReweReceipt])] {
        Dictionary(grouping: reweReceipts, by: { String($0.timestamp.prefix(10)) })
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }   // neuester Tag oben
    }

    private var reweReceiptScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if reweReceipts.isEmpty {
                    Text(L10n.t("Noch keine Bons. Im \(receiptBrandName)-Fenster synchronisieren.",
                                "No receipts yet. Sync in the \(receiptBrandName) window."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    ForEach(reweReceiptDayGroups, id: \.day) { group in
                        Text(formatDateDE(group.day))
                            .font(ThemeFonts.rowHeading(size: 13, lofiSize: 17))
                            .textCase(ThemeChrome.textCase)
                            .foregroundColor(themed ? .themedExpense : .secondary)
                            .padding(.top, 8).padding(.bottom, 4).padding(.horizontal, 12)
                        ForEach(group.items) { r in
                            reweRow(r)
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// Kategorie → Ring-Farbe (nur die Top-4 des letzten Bons sind im Ring gefärbt).
    /// Erlaubt, die Balken in der Kategorien-Ansicht passend zum Ring einzufärben,
    /// sodass man Farbe ↔ Kategorie zuordnen kann.
    private var ringColorByLabel: [String: Color] {
        Dictionary(uniqueKeysWithValues: reweRingSegments.compactMap { seg in
            Color(hex: seg.colorHex).map { (seg.label, $0) }
        })
    }

    /// Quelle-abhängige Kategorie-Aufschlüsselung, vereinheitlicht auf ein
    /// gemeinsames Tupel (REWE = Lebensmittel-Wörterbuch, dm = Drogerie).
    private var receiptCategoryBreakdown: [(label: String, symbol: String, totalCents: Int, count: Int)] {
        switch receiptSource {
        case .dm:
            return DMItemCategorizer.breakdown(reweReceipts)
                .map { (label: $0.category.rawValue, symbol: $0.category.symbol, totalCents: $0.totalCents, count: $0.count) }
        case .amazon:
            return AmazonItemCategorizer.breakdown(reweReceipts)
                .map { (label: $0.category.rawValue, symbol: $0.category.symbol, totalCents: $0.totalCents, count: $0.count) }
        default:
            return ReweItemCategorizer.breakdown(reweReceipts)
                .map { (label: $0.category.rawValue, symbol: $0.category.symbol, totalCents: $0.totalCents, count: $0.count) }
        }
    }

    /// „Was kaufst du ein?" — Kategorien-Aufschlüsselung (Summe + Anteils-Balken).
    private var reweCategoryView: some View {
        let breakdown = receiptCategoryBreakdown
        let total = max(1, breakdown.reduce(0) { $0 + $1.totalCents })
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if breakdown.isEmpty {
                    Text(L10n.t("Noch keine Artikel.", "No items yet."))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    ForEach(breakdown, id: \.label) { entry in
                        let frac = Double(entry.totalCents) / Double(total)
                        // Ring-Farbe der Kategorie (nur Top-4 des letzten Bons); sonst neutral.
                        let ringColor = ringColorByLabel[entry.label]
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                // BTX: Farbblock statt SF-Symbol — die Farbe verknüpft
                                // Balken und Segmentleiste, das Symbol wäre eine Bildmarke.
                                if themed && !ThemeChrome.categoryIconsEnabled {
                                    Rectangle()
                                        .fill(ringColor ?? Color.themedInk.opacity(0.35))
                                        .frame(width: 10, height: 10)
                                        .frame(width: 20)
                                } else {
                                    Image(systemName: entry.symbol)
                                        .font(.system(size: 13)).foregroundColor(ringColor ?? .secondary).frame(width: 20)
                                }
                                Text(entry.label)
                                    .font(ThemeFonts.rowHeading(size: 14, weight: .medium))
                                    .textCase(ThemeChrome.textCase)
                                    .foregroundColor(themed ? .themedInk : .primary)
                                Text("· \(entry.count)")
                                    .font(ThemeFonts.rowBody(size: 11, lofiSize: 13))
                                    .foregroundColor(themed ? Color.themedInk.opacity(0.7) : Color(NSColor.tertiaryLabelColor))
                                Spacer()
                                Text(reweEuro(entry.totalCents))
                                    .font(ThemeFonts.rowHeading(size: 14, weight: .medium, lofiSize: 16))
                                    .foregroundColor(themed ? .themedInk : .primary)
                                    .monospacedDigit()
                            }
                            GeometryReader { geo in
                                // BTX: eckige Balken statt Kapseln.
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(999))
                                        .fill(themed ? Color.themedInk.opacity(0.15) : Color.secondary.opacity(0.12))
                                        .frame(height: lofi ? 7 : 5)
                                    RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(999))
                                        .fill((ringColor ?? (themed ? Color.themedAccent : Color.accentColor))
                                            .opacity(ringColor == nil && !lofi ? 0.45 : 0.85))
                                        .frame(width: max(4, geo.size.width * frac), height: lofi ? 7 : 5)
                                }
                            }
                            .frame(height: lofi ? 7 : 5)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func reweRow(_ r: ReweReceipt) -> some View {
        let isOpen = reweExpanded.contains(r.receiptId)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isOpen { reweExpanded.remove(r.receiptId) } else { reweExpanded.insert(r.receiptId) }
            } label: {
                HStack(spacing: 10) {
                    // BTX: Warenkorb-Mosaik statt Händler-Logo, Texte in VT323/Ink.
                    if themed && !ThemeChrome.merchantLogosEnabled {
                        BTXMosaicIcon(category: .essenAlltag)
                    } else if let logo = receiptLogo {
                        Image(nsImage: logo).resizable().scaledToFill().frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                    } else {
                        Image(systemName: "cart.fill").font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary).frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.marketName ?? receiptBrandName)
                            .font(ThemeFonts.rowHeading(size: 14, weight: .medium))
                            .textCase(ThemeChrome.textCase)
                            .foregroundColor(themed ? .themedInk : .primary).lineLimit(1)
                        Text("\(r.items.count) Artikel")
                            .font(ThemeFonts.rowBody(size: 11, lofiSize: 13))
                            .textCase(ThemeChrome.textCase)
                            .foregroundColor(themed ? Color.themedInk.opacity(0.85) : .secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(reweEuro(r.totalCents))
                        .font(ThemeFonts.rowHeading(size: 14, weight: .medium, lofiSize: 17))
                        .monospacedDigit()
                        .foregroundColor(themed ? .themedInk : .primary)
                    if themed && !ThemeChrome.glyphControls {
                        Text(isOpen ? "v" : ">")
                            .font(ThemeFonts.flyoutBody(size: 13))
                            .foregroundColor(Color.themedInk.opacity(0.7))
                    } else {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    if r.items.isEmpty {
                        Text(L10n.t("Kein Warenkorb (Bon nicht geparst).", "No basket (receipt not parsed)."))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    } else {
                        ForEach(Array(r.items.enumerated()), id: \.offset) { _, it in
                            HStack(spacing: 8) {
                                Text(it.name).font(.system(size: 12)).foregroundColor(.primary)
                                if let q = it.quantity {
                                    Text(q).font(.system(size: 10)).foregroundColor(Color(NSColor.tertiaryLabelColor))
                                }
                                Spacer()
                                Text(reweEuro(it.totalCents)).font(.system(size: 12)).monospacedDigit().foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.leading, 30).padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
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

    /// Renders the header line next to the bank logo, replacing the old "Aktualisiert …" text.
    /// Format: "{displayName} · {hour} Uhr" (DE) / "{displayName} · {hour}:00" (EN).
    /// - `displayName` = nickname if set, otherwise bank display name.
    /// - If no fetch timestamp is available, only the name is shown without the time suffix.
    private func formatBankHeader(nickname: String?, bankName: String?, date: Date?) -> String {
        let name: String = {
            if let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty {
                return nick
            }
            if let bn = bankName?.trimmingCharacters(in: .whitespacesAndNewlines), !bn.isEmpty {
                return bn
            }
            return L10n.t("Kontostand", "Balance")
        }()
        guard let date else { return name }
        let hour = Calendar.current.component(.hour, from: date)
        return L10n.t("\(name) · \(hour) Uhr", "\(name) · \(hour):00")
    }

    private func formatDateDE(_ dateStr: String) -> String {
        guard let date = Self.inputDateFormatter.date(from: dateStr) else { return dateStr }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Heute" }
        if calendar.isDateInYesterday(date) { return "Gestern" }
        if let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: Date()),
           calendar.isDate(date, inSameDayAs: twoDaysAgo) { return "Vorgestern" }

        return Self.dayFormatter.string(from: date)
    }
    
    private func dateKey(_ t: TransactionsResponse.Transaction) -> String {
        t.bookingDate ?? t.valueDate ?? ""
    }

    private func amountDouble(_ t: TransactionsResponse.Transaction) -> Double {
        let raw = t.parsedAmount
        guard roundupView.isActive else { return raw }
        let currency = t.amount?.currency ?? "EUR"
        let lensed = RoundupCalculator.displayedAmount(
            originalAmount: Decimal(raw),
            currency: currency,
            stepCents: roundupView.stepCents
        )
        return NSDecimalNumber(decimal: lensed).doubleValue
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
        // Nur im Lo-Fi-Modus (BTX) tragen die Theme-Farben die Zeilenbeträge —
        // Farb-Themes (Game Boy/Sunrise) behalten die Default-Tokens wie zuvor.
        if v < 0 { return themed ? .themedExpense : .expenseRed }
        if v > 0 { return themed ? .themedIncome : .incomeGreen }
        return themed ? Color.themedInk.opacity(0.5) : Color(NSColor.tertiaryLabelColor)
    }

    /// Im Sparmode: Original → Aufgerundet (z.B. „32,00 €" → „35,00 €") für Zeilen,
    /// die tatsächlich aufgerundet werden (EUR-Lastschrift, kein glattes Vielfaches).
    /// `nil` → Zeile zeigt den normalen Betrag (Einnahmen, glatte Beträge, Normalmodus).
    private func roundupDisplay(_ t: TransactionsResponse.Transaction) -> (original: String, rounded: String)? {
        guard roundupView.isActive else { return nil }
        // Nur EUR rundet auf — Fremdwährung zeigt den normalen Betrag (kein Pfeil, kein „€").
        let currency = (t.amount?.currency ?? "EUR")
        guard currency.uppercased() == "EUR" else { return nil }
        let raw = Decimal(t.parsedAmount)
        let cents = RoundupCalculator.roundupCents(amount: raw, stepCents: roundupView.stepCents)
        guard cents > 0 else { return nil }
        let rounded = RoundupCalculator.displayedAmount(originalAmount: raw, currency: currency, stepCents: roundupView.stepCents)
        let origAbs = abs(NSDecimalNumber(decimal: raw).doubleValue)
        let roundedAbs = abs(NSDecimalNumber(decimal: rounded).doubleValue)
        let origStr = (Self.amountFormatter.string(from: NSNumber(value: origAbs)) ?? "") + " €"
        let roundedStr = (Self.amountFormatter.string(from: NSNumber(value: roundedAbs)) ?? "") + " €"
        return (origStr, roundedStr)
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

                let raw = value.translation.height
                let damped = pullMaxVisualOffset * (1 - exp(-raw * 0.35 / pullMaxVisualOffset))
                pullDragOffset = damped
            }
            .onEnded { value in
                guard !isPullRefreshing else { return }
                let canRefresh = isAtTopOfList && abs(value.translation.width) < 90
                let shouldRefresh = canRefresh && value.translation.height >= pullTriggerDistance

                if shouldRefresh {
                    Task { await triggerPullRefresh() }
                } else {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
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
        .offset(y: showIndicator ? max(2, min(20, pullListOffset * 0.5)) : -20)
        .animation(.easeOut(duration: 0.14), value: pullDragOffset)
        .animation(.easeOut(duration: 0.14), value: isPullRefreshing)
        .allowsHitTesting(false)
    }


    /// Konto-Indikatoren (Slot-Dots + „Alle Konten"). Von Normal- und Sparmode-Layout
    /// geteilt (im Sparmode in der RoundupOverlay-Steuerzeile, sonst eigene Zeile).
    @ViewBuilder
    /// Temperaturfarbe des aktiven Kontos (wie der Balance-Wash) — Tönung der aktiven Pille.
    private var headerTint: Color {
        let parsed = AmountParser.parseCurrencyDisplayOrNil(vm.currentBalance)
        let level = BalanceSignal.classify(balance: parsed, thresholds: normalizedBalanceThresholds)
        let style = BalanceSignal.style(for: level)
        return BalanceWash.colors(level: level, style: style, dark: activeColorScheme == .dark).balance
    }

    /// Fenster-Chrome (ersetzt die NSToolbar): Refresh · Pin · Einstellungen, oben
    /// rechts im Titelleisten-Streifen auf der Money-Heat.
    private var headerControls: some View {
        HStack(spacing: 15) {
            Button { Task { await onRefresh() } } label: {
                Image(systemName: ThemeChrome.symbol(for: .refresh))
            }
            .help(L10n.t("Aktuelles Konto aktualisieren", "Refresh current account"))
            Button {
                onTogglePin?()
                isPinnedLocal.toggle()
            } label: {
                Image(systemName: ThemeChrome.symbol(for: .pin, active: isPinnedLocal))
                    .foregroundColor(isPinnedLocal ? Color.themeAccent : .secondary)
            }
            .help(L10n.t("Oben halten", "Keep on top"))
            Button { onSettings?() } label: {
                Image(systemName: ThemeChrome.symbol(for: .settings))
            }
            .help(L10n.t("Einstellungen", "Settings"))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.secondary)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func slotLogoTile(_ slot: BankSlot, size: CGFloat) -> some View {
        let brand = BankLogoAssets.resolve(displayName: slot.displayName, logoID: slot.logoId,
                                           iban: slot.isReceiptSlot ? nil : slot.iban)
        // Händler-/PayPal-Slots: Marken-Logo direkt (nicht über BankLogoAssets).
        let img: NSImage? = slot.brandLogoImage ?? logoStore.image(for: brand)
        if let img {
            // Konto-Umschalter: Hier greift `bankLogoStyle` — anders als bei der Marke
            // über dem Kontostand, die ein Theme per `logo` farbig setzen darf.
            BankMark(image: img, brandId: brand?.id,
                     size: size, cornerRadius: size * 0.28)
        } else {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(slotDisplayColor(for: slot))
                .frame(width: size, height: size)
                .overlay(Text(String((slot.nickname?.isEmpty == false ? slot.nickname! : slot.displayName).prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .bold)).foregroundColor(.white))
        }
    }

    /// Konto-Umschalter als Logo-Pillen (wie im Flyout): aktive gefüllte Pille + kleinere
    /// Logo-Pillen; „Alle Konten" als kleine Icon-Pille (nur bei ≥2 echten Konten).
    /// Kann vom aktiven Slot überwiesen werden? eBon-Slots (REWE/dm/Amazon) haben kein
    /// Konto, PayPal ist ein reiner Lese-Zugang — beide zeigen keinen Senden-Button
    /// (gleiche Regel wie im Flyout).
    private var slotSupportsTransfer: Bool {
        guard let slot = multibankingStore.activeSlot else { return true }
        return !slot.isReceiptSlot && !slot.isPayPal
    }

    private var accountDotsBar: some View {
        // Bei aktivem Theme folgen Pillen + Text der Theme-Fläche (statt Weiß, das auf
        // der flachen Theme-Farbe fremd wirkt) — analog zum Flyout.
        let themed = !isDefaultTheme
        let tint = themed ? Color.themedInk : headerTint
        let activeFill = themed
            ? Color.themedInk.opacity(activeColorScheme == .dark ? 0.30 : 0.18)
            : (activeColorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
        let inactiveFill = themed
            ? Color.themedInk.opacity(0.08)
            : (activeColorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
        // BTX-Variante: reine Text-Umschalter ohne Pillen-Chrome und ohne Bank-Icon.
        // Aktiv = Leitfarbe + Unterstreichung, inaktiv gedämpft — „Blättern" per Klick.
        if !ThemeChrome.glyphControls {
            return AnyView(HStack(spacing: 14) {
                ForEach(Array(multibankingStore.slots.enumerated()), id: \.offset) { idx, slot in
                    let isActive = !vm.unifiedModeEnabled && idx == multibankingStore.activeIndex
                    Text(slot.nickname?.isEmpty == false ? slot.nickname! : slot.displayName)
                        .font(ThemeFonts.flyoutBody(size: 15))
                        .textCase(.uppercase)
                        .foregroundColor(isActive ? Color.themedAccent : Color.themedInk.opacity(0.85))
                        .underline(isActive)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if vm.unifiedModeEnabled { vm.unifiedModeEnabled = false }
                            accountNav.onSwitchToIndex?(idx)
                        }
                }
                if multibankingStore.realSlotCount > 1 {
                    let unifiedActive = vm.unifiedModeEnabled
                    Text(L10n.t("Alle", "All"))
                        .font(ThemeFonts.flyoutBody(size: 15))
                        .textCase(.uppercase)
                        .foregroundColor(unifiedActive ? Color.themedAccent : Color.themedInk.opacity(0.85))
                        .underline(unifiedActive)
                        .contentShape(Rectangle())
                        .onTapGesture { if !unifiedActive { vm.unifiedModeEnabled = true } }
                }
                Spacer(minLength: 0)
            })
        }
        return AnyView(HStack(spacing: 6) {
            ForEach(Array(multibankingStore.slots.enumerated()), id: \.offset) { idx, slot in
                let isActive = !vm.unifiedModeEnabled && idx == multibankingStore.activeIndex
                if isActive {
                    // Aktive Pille ausgeschrieben (Logo + Name) — wie im Flyout.
                    HStack(spacing: 5) {
                        slotLogoTile(slot, size: 16)
                        Text(slot.nickname?.isEmpty == false ? slot.nickname! : slot.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(tint)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(activeFill)
                        .shadow(color: Color.black.opacity(0.10), radius: 1.5, x: 0, y: 1))
                } else {
                    slotLogoTile(slot, size: 15)
                        .padding(5)
                        .background(Capsule(style: .continuous).fill(inactiveFill))
                        .contentShape(Capsule())
                        .onTapGesture {
                            if vm.unifiedModeEnabled { vm.unifiedModeEnabled = false }
                            accountNav.onSwitchToIndex?(idx)
                        }
                }
            }
            if multibankingStore.realSlotCount > 1 {
                let unifiedActive = vm.unifiedModeEnabled
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(unifiedActive ? tint : Color(NSColor.secondaryLabelColor))
                    .frame(width: 26, height: 26)
                    .background(Capsule(style: .continuous).fill(unifiedActive ? activeFill : inactiveFill))
                    .contentShape(Capsule())
                    .onTapGesture { if !unifiedActive { vm.unifiedModeEnabled = true } }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: multibankingStore.activeIndex)
        .animation(.easeInOut(duration: 0.2), value: vm.unifiedModeEnabled))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Balance Card
            Group {
                if receiptActive {
                    reweBalanceCard
                } else if roundupView.isActive {
                    RoundupSavingsCard(compact: false)
                } else if vm.isUnifiedMode {
                    unifiedBalanceCard
                } else {
                    // Default = Money-Heat, aktive Themes = flache Theme-Farbe — beide
                    // randlos über dieselbe Geometrie (kein Inset/Rahmen bei Themes mehr).
                    defaultThemeBalanceCard
                }
            }
            .rippleEffect(trigger: vm.rippleTrigger,
                          defaultOrigin: CGPoint(x: 190, y: 65),
                          enabled: ThemeChrome.rippleEnabled)
            // Randlos (0 Außen-Padding) für alle Saldo-/Marken-Karten; nur Roundup
            // behält das 16/-9-Inset-Layout.
            .padding(.horizontal, !roundupView.isActive ? 0 : 16)
            .padding(.top, !roundupView.isActive ? 0 : -9)
            .padding(.bottom, multibankingStore.slots.count > 1 ? 4 : 6)

            // Account dot indicators — slot dots + "Alle Konten" dot. Eigene Zeile in
            // beiden Modi (im Sparmode darüber der Steuerzeile, damit die Step-Pills
            // nicht beschnitten werden).
            if multibankingStore.slots.count > 1 {
                accountDotsBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }

            // Search + Icons — same row. Im Sparmode + REWE-Slot ausgeblendet
            // (bank-spezifische Suche/Filter/Kategorien dort nicht sinnvoll).
            if !roundupView.isActive && !receiptActive {
            HStack(spacing: 8) {
                // Search field — flexible. Bei BTX eckig (keine Rundung) und ohne
                // Lupen-/Löschen-Icon; das Feld selbst trägt VT323 und einen
                // Großbuchstaben-Platzhalter.
                HStack(spacing: 6) {
                    if ThemeChrome.glyphControls {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundColor(Color(NSColor.placeholderTextColor))
                    }
                    // System-Platzhalter folgt dem (ggf. dunklen) Appearance-Modus und
                    // wäre auf dem hellen BTX-Feld weiß = unlesbar. Prompt-Farben
                    // ignoriert das Plain-TextField auf macOS — daher bei Theme den
                    // Prompt leeren und einen eigenen Platzhalter überlegen.
                    TextField(L10n.t("Händler, Betrag, Monat …", "Merchant, amount, month …"),
                              text: $vm.query,
                              prompt: lofi ? Text("") : nil)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(ThemeFonts.rowBody(size: 13, lofiSize: 14))
                        .foregroundColor(themed ? .themedInk : .primary)
                        .overlay(alignment: .leading) {
                            if lofi && vm.query.isEmpty {
                                Text(L10n.t("Händler, Betrag, Monat …", "Merchant, amount, month …"))
                                    .font(ThemeFonts.flyoutBody(size: 14))
                                    .foregroundColor(Color.themedInk.opacity(0.45))
                                    .allowsHitTesting(false)
                            }
                        }
                    if !vm.query.isEmpty {
                        Button(action: { vm.query = "" }) {
                            if ThemeChrome.glyphControls {
                                Image(systemName: ThemeChrome.symbol(for: .clear))
                                    .foregroundColor(Color(NSColor.placeholderTextColor))
                            } else {
                                BTXTextControl(text: "X")
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    // BTX-Lo-Fi: heller Block + harter 2-px-Tintenrahmen (wie der
                    // Eingabebereich einer BTX-Seite). Sonstige Themes: eine leichte
                    // Aufhellung der Ink-Farbe statt der System-Kartenfarbe — die stand
                    // vorher als heller Kasten auf jeder dunklen Theme-Fläche.
                    RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(8))
                        .fill(lofi ? Color.white.opacity(0.65)
                              : (themed ? Color.themedInk.opacity(0.10) : Color.cardBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: ThemeChrome.cornerRadius(8))
                                .stroke(themed ? Color.themedInk.opacity(lofi ? 1 : 0.30)
                                               : Color.clear,
                                        lineWidth: lofi ? 2 : 1)
                        )
                )

                // Icons
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                }
                Button(action: { showFilterPills.toggle() }) {
                    if ThemeChrome.glyphControls {
                        Image(systemName: ThemeChrome.symbol(for: .filter, active: showFilterPills))
                            .font(.system(size: 15))
                            .foregroundColor(showFilterPills || vm.activeFilter != .all
                                             ? .accentColor : .secondary)
                    } else {
                        BTXTextControl(text: L10n.t("Filter", "Filter"),
                                       active: showFilterPills || vm.activeFilter != .all)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .help(showFilterPills
                      ? L10n.t("Filter ausblenden", "Hide filters")
                      : L10n.t("Filter einblenden", "Show filters"))
                Button(action: { showCategories.toggle() }) {
                    if ThemeChrome.glyphControls {
                        Image(systemName: ThemeChrome.symbol(for: .categories, active: showCategories))
                            .font(.system(size: 14))
                            .foregroundColor(showCategories ? .accentColor : .secondary)
                    } else {
                        BTXTextControl(text: L10n.t("Kat.", "Cat."), active: showCategories)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .help(showCategories
                      ? L10n.t("Kategorien ausblenden", "Hide categories")
                      : L10n.t("Kategorien anzeigen", "Show categories"))
                if !vm.isUnifiedMode && !receiptActive && multibankingStore.activeSlot?.isPayPal != true {
                    Button(action: { toggleRoundupView() }) {
                        if ThemeChrome.glyphControls {
                            Image(systemName: ThemeChrome.symbol(for: .savings, active: roundupView.isActive))
                                .font(.system(size: 15))
                                .foregroundColor(roundupView.isActive ? Color.roundupAccent : .secondary)
                        } else {
                            BTXTextControl(text: L10n.t("Sparen", "Save"), active: roundupView.isActive)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L10n.t("Aufrunden-Ansicht — Beträge aufgerundet anzeigen (aktiviert Aufrunden für dieses Konto)",
                                 "Round-up view — show amounts rounded up (enables round-up for this account)"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            }

            // Filter-Pills — direkte Schnellfilter unter der Suche (toggelbar via Filter-Button).
            // `.all` wird nicht als Pill gerendert: Klick auf einen aktiven Pill setzt zurück
            // auf `.all`, der „Alle"-Slot spart einen sichtbaren Pill ein. Edge-Fade an beiden
            // Seiten signalisiert dass die Reihe scrollbar ist; ScrollViewReader scrollt den
            // aktiven Pill automatisch in die Mitte sobald er aktiviert wird.
            if showFilterPills && !roundupView.isActive {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(TxFilter.allCases.filter { $0 != .all }, id: \.self) { filter in
                                FilterPill(filter: filter, active: vm.activeFilter == filter) {
                                    vm.activeFilter = (vm.activeFilter == filter) ? .all : filter
                                }
                                .id(filter)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.04),
                                .init(color: .black, location: 0.96),
                                .init(color: .clear, location: 1.0)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .onChange(of: vm.activeFilter) { newFilter in
                        guard newFilter != .all else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(newFilter, anchor: .center)
                        }
                    }
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Error
            if let err = vm.error {
                HStack(spacing: 6) {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.expenseRed)
                    Spacer(minLength: 0)
                    Button {
                        // Bei abgelehnten Zugangsdaten wäre ein weiterer Abruf nur der
                        // nächste Fehlversuch bei der Bank — hier führt der Weg zum
                        // Zugangsdaten-Dialog statt zu einem erneuten Login.
                        if vm.errorNeedsCredentialUpdate {
                            NotificationCenter.default.post(name: .changeBankCredentials, object: nil)
                        } else {
                            Task { await onRefresh() }
                        }
                    } label: {
                        if vm.errorNeedsCredentialUpdate {
                            Text(L10n.t("Zugangsdaten aktualisieren", "Update credentials"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.expenseRed)
                        } else if vm.errorNeedsReconnect {
                            Text(L10n.t("Erneut verbinden", "Reconnect"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.expenseRed)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.expenseRed)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(vm.errorNeedsCredentialUpdate
                          ? L10n.t("Neuen Anmeldenamen / neue PIN hinterlegen", "Store new login name / PIN")
                          : vm.errorNeedsReconnect
                            ? L10n.t("Erneut verbinden und Freigabe bestätigen", "Reconnect and confirm authorization")
                            : L10n.t("Aktualisieren", "Refresh"))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // TAN/2FA pending
            if vm.isTanPending {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundColor(.sbOrangeStrong)
                    Text("Bitte bestätige in deiner Banking-App")
                        .font(.caption)
                        .foregroundColor(.sbOrangeStrong)
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if !receiptActive && (vm.isSearchActive || vm.activeFilter != .all) {
                HStack(spacing: 6) {
                    Text("\(vm.filteredTransactions.count) Ergebnisse")
                        .font(ThemeFonts.rowBody(size: 12, weight: .semibold, lofiSize: 14))
                        .textCase(ThemeChrome.textCase)
                        .foregroundColor(themed ? Color.themedInk.opacity(0.85) : .secondary)
                    if vm.activeFilter != .all {
                        Text("· \(vm.activeFilter.label)")
                            .font(ThemeFonts.rowBody(size: 12, lofiSize: 14))
                            .textCase(ThemeChrome.textCase)
                            .foregroundColor(themed ? Color.themedInk.opacity(0.85) : .secondary)
                        Button(action: { vm.activeFilter = .all }) {
                            if ThemeChrome.glyphControls {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            } else {
                                BTXTextControl(text: "X", size: 13)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            
            if roundupView.isActive, let activeSlot = multibankingStore.activeSlot {
                RoundupOverlay(
                    slotId: activeSlot.id,
                    bankId: activeBankId,
                    onClose: { roundupView.deactivate() }
                )
            }

            // eBon: Umschalter Einkäufe ⇄ Kategorien (Aktualisieren liegt jetzt
            // global im Header-Toolbar neben dem Pin-Button).
            if receiptActive {
                // BTX: Text-Umschalter (unterstrichen = aktiv) statt Segmented Control.
                if themed && !ThemeChrome.glyphControls {
                    HStack(spacing: 16) {
                        ForEach([(0, "Einkäufe", "Purchases"), (1, "Kategorien", "Categories")], id: \.0) { tag, de, en in
                            Text(L10n.t(de, en))
                                .font(ThemeFonts.flyoutBody(size: 15))
                                .textCase(.uppercase)
                                .foregroundColor(reweTab == tag ? Color.themedAccent : Color.themedInk.opacity(0.6))
                                .underline(reweTab == tag)
                                .contentShape(Rectangle())
                                .onTapGesture { reweTab = tag }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                } else {
                    Picker("", selection: $reweTab) {
                        Text(L10n.t("Einkäufe", "Purchases")).tag(0)
                        Text(L10n.t("Kategorien", "Categories")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }

            // Transactions List (grouped by date) with pull-to-refresh indicator
            ZStack(alignment: .top) {
                if receiptActive {
                    if reweTab == 0 { reweReceiptScroll } else { reweCategoryView }
                } else {
                ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        // Erzwingt Overlay-Scroller mit Autohide (on-demand) auf der
                        // umschließenden NSScrollView — unabhängig von System-Pref/Maus.
                        OverlayScrollerConfigurator()
                            .frame(width: 0, height: 0)
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

                            // Date Section Header — Datum + Trennlinie am Tageswechsel.
                            // Bei aktivem Theme in Theme-Schrift und -Farbe; BTX setzt
                            // seine Datumsköpfe rot und unterstrichen, was exakt dieser
                            // vorhandenen Kombination aus Text und Linie entspricht.
                            HStack(spacing: 10) {
                                Text(formatDateDE(group.date))
                                    .font(ThemeFonts.rowHeading(size: 13, lofiSize: 17))
                                    .textCase(ThemeChrome.textCase)
                                    .foregroundColor(themed ? .themedExpense : .secondary)
                                    .fixedSize()
                                // Lo-Fi (BTX): KEINE Trennlinie nach dem Datum — nur der Text.
                                if lofi {
                                    Spacer(minLength: 0)
                                } else {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.18))
                                        .frame(height: 1)
                                }
                            }
                            // Linksbündig mit den Zeilen (deren Gutter bei Themes 0 ist):
                            // Datumskopf und Transaktion beginnen auf gleicher Höhe.
                            .padding(.leading, lofi ? 14 : 16)
                            .padding(.trailing, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 6)

                            // Transactions for this date
                            ForEach(group.transactions, id: \.stableIdentifier) { t in
                                let txID = TransactionRecord.fingerprint(for: t)
                                let txSlotId = t.slotId ?? TransactionsDatabase.activeSlotId
                                let enrichment = vm.enrichmentData[TxEnrichmentKey.make(slotId: txSlotId, txID: txID)]
                                let resolution = MerchantResolver.resolve(transaction: t)
                                let rowSlotColor: Color? = vm.isUnifiedMode ? slotColor(for: t) : nil
                                let isTransfer = vm.isUnifiedMode && vm.internalTransferIDs.contains(txID)
                                let txIsUnread = enrichment?.isUnread ?? false
                                let txHasReminder = enrichment?.reminderId != nil
                                let txReminderId = enrichment?.reminderId
                                HStack(spacing: 0) {
                                    // Left gutter — unread dot. Bei Themes (BTX) auf 0,
                                    // damit die Zeile linksbündig mit dem Datumskopf sitzt
                                    // (Demo: alle Einträge auf einer Höhe, kein Einzug).
                                    // Der Ungelesen-Marker wandert dann als eckiger Block
                                    // in ein Overlay AUF der Zeile — sonst läge der Kreis
                                    // mit Gutter-Breite 0 auf dem gelben Zierrahmen.
                                    ZStack {
                                        if txIsUnread && !lofi {
                                            Circle()
                                                .fill(Color.accentColor)
                                                .frame(width: 8, height: 8)
                                        }
                                    }
                                    .frame(width: lofi ? 0 : 16)

                                    // Transaction card
                                    SwipeableTransactionRow(
                                        txID: txID,
                                        isUnread: txIsUnread,
                                        hasReminder: txHasReminder,
                                        activeSwipedID: $activeSwipedTxID,
                                        onToggleUnread: { toggleUnread(txID: txID, slotId: txSlotId, bankId: activeBankId) },
                                        onReminderAction: {
                                            if txHasReminder {
                                                removeReminder(txID: txID, slotId: txSlotId, reminderId: txReminderId, bankId: activeBankId)
                                            } else {
                                                reminderPickerTxID = txID
                                                reminderPickerBankId = activeBankId
                                                reminderPickerSlotId = txSlotId
                                            }
                                        }
                                    ) {
                                        TransactionRowNew(
                                            transaction: t,
                                            category: category(for: t),
                                            name: recipientName(t),
                                            normalizedMerchant: resolution.normalizedMerchant,
                                            amount: amountText(t),
                                            amountColor: amountColor(t),
                                            roundupDisplay: roundupDisplay(t),
                                            matchBadges: vm.searchMatchBadges(for: t),
                                            userNote: enrichment?.note,
                                            attachmentCount: enrichment?.attachmentCount ?? 0,
                                            bankId: activeBankId,
                                            onEnrichmentChanged: { vm.loadEnrichmentData(bankId: activeBankId) },
                                            isWide: panelIsWide,
                                            slotColor: rowSlotColor,
                                            isInternalTransfer: isTransfer,
                                            showCategories: roundupView.isActive ? false : showCategories,
                                            isUnread: txIsUnread,
                                            hasReminder: txHasReminder,
                                            reminderId: txReminderId,
                                            isSelected: selectedTxID == txID,
                                            onReminderAction: {
                                                reminderPickerTxID = txID
                                                reminderPickerBankId = activeBankId
                                                reminderPickerSlotId = txSlotId
                                            },
                                            onEnrichmentChangedWithRemover: { vm.loadEnrichmentData(bankId: activeBankId) },
                                            onSelect: {
                                                if activeSwipedTxID != nil {
                                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                                        activeSwipedTxID = nil
                                                    }
                                                } else {
                                                    selectedTxID = selectedTxID == txID ? nil : txID
                                                }
                                            }
                                        )
                                    }

                                    // Right gutter — reminder bell. Bei Themes 0, damit
                                    // die Beträge weiter nach rechts rücken (wie Demo).
                                    ZStack {
                                        if txHasReminder {
                                            Image(systemName: ThemeChrome.symbol(for: .inbox, active: true))
                                                .font(.system(size: 10))
                                                .foregroundColor(.orange)
                                        }
                                    }
                                    .frame(width: lofi ? 0 : 16)
                                }
                                .opacity(t.status == "pending" ? 0.65 : 1.0)
                                // BTX-Ungelesen-Marker: eckiger Block in Leitfarbe am
                                // linken Zeilenrand — innerhalb der Zeile, nicht auf dem
                                // Zierrahmen (Overlay verbraucht keinen Layout-Platz).
                                .overlay(alignment: .leading) {
                                    if lofi && txIsUnread {
                                        Rectangle()
                                            .fill(Color.themedAccent)
                                            .frame(width: 6, height: 6)
                                            .offset(x: 4)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(highlightedTxStableId == t.stableIdentifier
                                                ? Color.accentColor
                                                : Color.clear,
                                                lineWidth: 2)
                                )
                                .scaleEffect(highlightedTxStableId == t.stableIdentifier
                                             ? highlightBounce : 1.0)
                                .zIndex(highlightedTxStableId == t.stableIdentifier ? 1 : 0)
                                .animation(.easeOut(duration: 0.3), value: highlightedTxStableId)
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
                                    .font(ThemeFonts.rowBody(size: 11, weight: .medium, lofiSize: 14))
                                    .textCase(ThemeChrome.textCase)
                                    .foregroundColor(themed ? Color.themedInk.opacity(0.85) : .secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        }
                    }
                    .id(vm.page) // Erzwingt komplette Neuzeichnung der Liste pro Seite
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .coordinateSpace(name: "transactionsScroll")
                .offset(y: pullListOffset)
                // `.offset` verschiebt nur das Rendering, nicht das Layout — ohne
                // Clipping ragt der (beim Pull/Overscroll) verschobene Listeninhalt
                // unter den Footer und scheint dort durch (#3). Auf den Layout-Frame
                // zurückclippen, Pull-Indikator (separat in der ZStack) bleibt sichtbar.
                .clipped()
                .onPreferenceChange(TransactionsTopOffsetPreferenceKey.self) { topSentinelOffset = $0 }
                .simultaneousGesture(pullToRefreshGesture)
                .onChange(of: scrollTarget) { target in
                    guard let target else { return }
                    withAnimation { scrollProxy.scrollTo(target.id, anchor: .center) }
                    highlightedTxStableId = target.id
                    highlightBounce = 1.0  // reset so the row rendert erst bei 1.0

                    // Phase 1: skaliere hoch (nachdem das Highlight schon rendert)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.5)) {
                            highlightBounce = 1.10
                        }
                    }
                    // Phase 2: zurück auf 1.0 (Bounce)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.55)) {
                            highlightBounce = 1.0
                        }
                    }
                    // Phase 3: Highlight ausblenden
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        highlightedTxStableId = nil
                    }
                }
                } // end ScrollViewReader

                pullRefreshIndicator
                } // end else (Bank-Liste)
            }
            
            Spacer(minLength: 0)

            // Footer — schmal. Icons linksbündig, „Mehr ▾" ganz rechts.
            HStack(spacing: 16) {
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

                // Dashboard — ein Einstieg statt verstreuter Einzel-Menüeinträge
                Button(action: { onOpenDashboard?(.overview) }) {
                    if ThemeChrome.glyphControls {
                        Image(systemName: ThemeChrome.symbol(for: .dashboard))
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    } else {
                        BTXTextControl(text: L10n.t("Auswertung", "Reports"))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .help(L10n.t("Dashboard", "Dashboard"))

                // Inbox mit Badge
                if attentionInboxEnabled {
                    Button(action: {
                        recomputeAttentionInbox()
                        showAttentionInbox = true
                    }) {
                        if !ThemeChrome.glyphControls {
                            // Badge als Text-Klammer: „INBOX (2)" statt Glocke mit Punkt.
                            BTXTextControl(
                                text: attentionCards.isEmpty
                                    ? L10n.t("Inbox", "Inbox")
                                    : L10n.t("Inbox (\(min(attentionCards.count, 9)))",
                                             "Inbox (\(min(attentionCards.count, 9)))"),
                                active: !attentionCards.isEmpty)
                        } else {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: attentionCards.isEmpty ? "bell" : "bell.fill")
                                .font(.system(size: 15))
                                .foregroundColor(attentionCards.isEmpty ? .secondary : .primary)
                            if !attentionCards.isEmpty {
                                ZStack {
                                    Circle()
                                        .fill(Color.sbOrangeStrong)
                                        .frame(width: 14, height: 14)
                                    Text("\(min(attentionCards.count, 9))")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L10n.t("Attention Inbox", "Attention Inbox"))
                }

                // Mehr ▾ — links, neben der Glocke/Inbox
                Menu {
                        Button(action: { markAllTransactionsRead() }) {
                            Label(L10n.t("Alle als gelesen markieren", "Mark all as read"), systemImage: "checkmark.circle")
                        }
                        .disabled(!hasAnyUnreadTransaction)

                        Menu {
                            Button(L10n.t("Als CSV exportieren", "Export as CSV")) {
                                exportTransactionsCSV(vm.transactions)
                            }
                            Button(L10n.t("Als OFX exportieren", "Export as OFX")) {
                                exportTransactionsOFX(vm.transactions)
                            }
                            Divider()
                            let months: [ReportMonth] = [.current, .current.previous, .current.previous.previous]
                            ForEach(Array(months.enumerated()), id: \.offset) { _, month in
                                let label = "simple.report (\(String(format: "%02d", month.month)).\(String(month.year).suffix(2)))"
                                Button(label) {
                                    exportSimpleReport(month: month)
                                }
                            }
                        } label: {
                            Label(L10n.t("Exportieren", "Export"), systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        Button(action: {
                            if let url = URL(string: "https://ko-fi.com/N4N11K1NC") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Label(L10n.t("Projekt unterstützen", "Support the project"), systemImage: "cup.and.saucer")
                        }
                    } label: {
                        Text(L10n.t("Mehr ▾", "More ▾"))
                            .font(ThemeFonts.rowBody(size: 13, weight: .medium))
                            .textCase(ThemeChrome.textCase)
                            .foregroundColor(themed ? Color.themedInk.opacity(0.75) : .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    // Menu-Item-Icons monochrom statt Accent-Blau. Der Tint überstimmt
                    // auch die Label-Farbe — im Dark-Mode wäre `.primary` Weiß und
                    // damit auf der hellen BTX-Fläche unlesbar; Themes tinten in Ink.
                    .tint(themed ? Color.themedInk : .primary)

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

                // simplesend — Geld senden, ganz rechts (wie im Flyout-Footer).
                // Nur für Slots, von denen überhaupt überwiesen werden kann.
                if simplesendVisible, slotSupportsTransfer {
                    Button(action: {
                        NotificationCenter.default.post(
                            name: Notification.Name("simplebanking.openTransferSheet"),
                            object: nil)
                    }) {
                        if ThemeChrome.glyphControls {
                            Image(systemName: ThemeChrome.symbol(for: .send))
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                        } else {
                            BTXTextControl(text: L10n.t("Senden", "Send"))
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L10n.t("simplesend: Geld senden", "simplesend: Send Money"))
                }
            }
            .padding(.horizontal, lofi ? 26 : 20)
            .padding(.top, 10)
            // Bei aktiver CRT-Blende mehr Abstand, sonst kleben die Footer-Kommandos
            // an der dicken Schmucklinie.
            .padding(.bottom, lofi ? 14 : 6)
            .background(activePanelBg)
        }
        .frame(minWidth: 348, idealWidth: 348, maxWidth: 840, minHeight: 620, idealHeight: 620, maxHeight: 620)
        // Wallpaper zuunterst, bis in die Titelleiste. `activePanelBg` wird unter einem
        // Wallpaper durchsichtig und lässt es stehen.
        .background {
            ZStack {
                ThemeWallpaper(flaeche: panelIsWide ? .listeBreit : .listeSchmal)
                activePanelBg
            }
            .ignoresSafeArea(.all, edges: .top)
        }
        // „Bildschirmrand" des BTX-Themes: liegt als Overlay INNEN auf der Fläche,
        // verbraucht also keinen Platz und verschiebt nichts. Themes ohne
        // `screenBorder` bekommen hier nichts.
        .overlay {
            if let border = Color.themedScreenBorder {
                BTXScreenBezel(color: border, thickness: 6, innerRadius: 12)
                    .ignoresSafeArea(.all, edges: .top)
            }
        }
        // Fenster-Chrome oben rechts im Titelleisten-Streifen (auf der Money-Heat),
        // ersetzt die entfernte NSToolbar. ignoresSafeArea → sitzt im Titel-Bereich.
        .overlay(alignment: .topTrailing) {
            headerControls
                .padding(.top, 9)
                .padding(.trailing, 16)
                .ignoresSafeArea(.container, edges: .top)
        }
        // CRT-Easter-Egg (nur BTX): NACH Blende und Fenster-Chrome, damit der
        // Shader das komplette Bild wölbt — wie eine echte Röhre.
        .btxCRTEffect()
        .onAppear { isPinnedLocal = isPinnedProvider?() ?? false }
        // Wechsel auf einen Händler-/eBon-Slot: Bank-Filter und Suche zurücksetzen —
        // Bons kennen weder Einnahmen/Abos-Filter noch die Umsatzsuche; ein aktiver
        // Filter würde sonst beim Rückwechsel unerwartet weiterwirken.
        .onChange(of: receiptActive) { active in
            if active {
                vm.activeFilter = .all
                vm.query = ""
            }
        }
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
        // Ein Themewechsel baut ab hier alles neu (siehe `themeRevision`).
        //
        // Die Stelle ist entscheidend, und ich hatte sie erst falsch: `.id` erneuert nur,
        // was UNTER ihr in der Kette steht. Saß sie vor dem Wallpaper-Hintergrund, wurde
        // die Liste zwar neu gebaut, das Wallpaper aber nicht — beim Themewechsel blieb
        // das Bild des vorigen Themes stehen, während die Farben schon wechselten.
        //
        // Sie muss also HINTER dem Wallpaper und den Overlays stehen, aber VOR
        // `.background(notificationObservers)` — sonst nähme der Neubau die Beobachter
        // mit, die ihn auslösen, und er fände genau einmal statt.
        .id(themeRevision)
        .background(notificationObservers)
        .onAppear {
            loadReweReceipts()
            resetInfiniteWindowIfNeeded()
            if demoMode {
                // Demo: mark all transactions as unread in-memory
                var enrichment: [String: TxEnrichment] = [:]
                for t in vm.transactions {
                    let txID = TransactionRecord.fingerprint(for: t)
                    let slotId = t.slotId ?? TransactionsDatabase.activeSlotId
                    let key = TxEnrichmentKey.make(slotId: slotId, txID: txID)
                    enrichment[key] = TxEnrichment(note: nil, attachmentCount: 0, isUnread: true, isFlagged: false)
                }
                vm.enrichmentData = enrichment
            } else {
                vm.loadEnrichmentData(bankId: activeBankId)
            }
            if UserDefaults.standard.bool(forKey: "rippleAlwaysOn") {
                vm.rippleTrigger += 1
            }
            recomputeGreenZone()
            recomputeAttentionInbox()
            installScrollWheelMonitor()
        }
        .onDisappear {
            removeScrollWheelMonitor()
        }
        .onChange(of: vm.transactions.count) { _ in
            recomputeGreenZone()
            recomputeAttentionInbox()
            if roundupView.isActive {
                roundupView.setTransactions(vm.transactions)
            }
        }
        // Slot-Wechsel: Ring neu rechnen, auch wenn die Transaktions-ANZAHL zufällig
        // gleich bleibt (z. B. PayPal/REWE → Bank) — sonst bleibt der gecachte
        // Ring-Wert des vorigen Slots stehen.
        .onChange(of: multibankingStore.activeIndex) { _ in recomputeGreenZone() }
        .onChange(of: vm.currentBalance) { _ in recomputeGreenZone() }
        .onChange(of: infiniteScrollEnabled) { _ in
            resetInfiniteWindowIfNeeded()
        }
        .onChange(of: vm.unifiedModeEnabled) { newValue in
            // Aufrunden-View ist nur per-slot sinnvoll — beim Wechsel in Unified deaktivieren.
            if newValue, roundupView.isActive { roundupView.deactivate() }
            // Only refresh when switching INTO unified mode.
            // Switching OUT (to a specific slot) is handled by switchToSlot() — no double refresh.
            if newValue {
                Task { await onRefresh() }
            }
        }
        .onChange(of: multibankingStore.activeIndex) { _ in
            // Slot-Switch: View-Mode auto-aus (Roundup ist slot-spezifisch).
            if roundupView.isActive { roundupView.deactivate() }
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
        .sheet(isPresented: $showAttentionInbox) {
            AttentionInboxView(cards: attentionCards, onViewTransaction: { fingerprint in
                showAttentionInbox = false
                // Delay scroll until the sheet dismiss animation settles; otherwise the
                // ScrollViewProxy change fires while the list is still reloading and the
                // target row isn't yet rendered on the new page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if let stableId = vm.jumpToTransaction(matchingFingerprint: fingerprint) {
                        scrollTarget = ScrollTarget(id: stableId, nonce: UUID())
                    }
                }
            }, onMarkAllRead: {
                saveSnoozedCards(attentionCards)
                attentionCards = []
            })
        }

        .onChange(of: showAttentionInbox) { isShown in
            if isShown { recomputeAttentionInbox() }
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
        .sheet(isPresented: Binding(
            get: { reminderPickerTxID != nil },
            set: { if !$0 { reminderPickerTxID = nil } }
        )) {
            ReminderPickerSheet(
                date: $reminderPickerDate,
                onConfirm: { date in
                    guard let txID = reminderPickerTxID else { return }
                    let bankId = reminderPickerBankId
                    let slotId = reminderPickerSlotId
                    let tx = vm.transactions.first { TransactionRecord.fingerprint(for: $0) == txID }
                    let merchant = tx.map { MerchantResolver.resolve(transaction: $0).effectiveMerchant } ?? txID
                    let amount = tx.map { amountText($0) } ?? ""
                    let title = "\(merchant) \(amount)".trimmingCharacters(in: .whitespaces)
                    reminderPickerTxID = nil
                    setReminder(txID: txID, slotId: slotId, bankId: bankId, dueDate: date, title: title)
                },
                onCancel: { reminderPickerTxID = nil }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(activePanelBg)
        .overlay(alignment: .topLeading) {
            if currentTintStyle == .sidebar, let color = bankAccentForOverlay {
                // 4 px Streifen am linken Rand — von oben (BalanceBar) bis knapp
                // OBERHALB der Iconbar. Der Footer ist ~52 pt hoch (padding.top 28 +
                // Icons + padding.bottom 4) und deckend; der Streifen wird unten um
                // diese Höhe gekürzt, sonst liefe er hinter die Iconbar.
                Rectangle()
                    .fill(color)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    // Oben weich ausfaden (Übergang in die Money-Heat), unten bis an die
                    // echte Fensterkante durch — unabhängig von Frame/Footer.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.30)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .ignoresSafeArea(.all, edges: .vertical)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Notification-/Change-Observer gebündelt (eigener Type-Check-Scope, hält die
    /// Haupt-`body`-Kette kurz genug für den Compiler).
    private var notificationObservers: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MerchantRulesChanged"))) { _ in
                vm.objectWillChange.send()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TransactionCategoriesChanged"))) { _ in
                vm.objectWillChange.send()
            }
            .onReceive(NotificationCenter.default.publisher(for: .bankTintChanged)) { _ in
                vm.objectWillChange.send()
            }
            .onReceive(NotificationCenter.default.publisher(for: ThemeManager.didChangeNotification)) { _ in
                // Reicht nicht, nur das ViewModel anzustoßen: Schrift, Ink und Wallpaper
                // liest jede Zeile selbst aus `ThemeChrome`, ohne dass es als Eingabe
                // sichtbar wäre. SwiftUI übersähe unveränderte Zeilen. Die Kennung baut
                // die Liste deshalb vollständig neu.
                themeRevision &+= 1
                vm.objectWillChange.send()
            }
            .onChange(of: multibankingStore.activeIndex) { _ in loadReweReceipts() }
            .onReceive(NotificationCenter.default.publisher(for: .reweReceiptsChanged)) { _ in loadReweReceipts() }
            .onReceive(NotificationCenter.default.publisher(for: .transactionsPanelHeaderRefresh), perform: handleHeaderRefresh)
    }

    /// Header-↻ nutzt denselben Pull-to-Refresh-Pfad → gleicher Spinner.
    private func handleHeaderRefresh(_ note: Notification) {
        Task { await triggerPullRefresh() }
    }

    private func triggerPullRefresh() async {
        guard !isPullRefreshing else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
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
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            isPullRefreshing = false
            pullDragOffset = 0
        }
    }

    // MARK: - Scroll Wheel Gesture Monitor (Trackpad)

    private func installScrollWheelMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { event in
            // Nur Events DIESES Fensters behandeln. Sonst greift der app-weite
            // Monitor auch Scroll-/Tasten-Events im Settings-Fenster ab und scrollt
            // die Umsatzliste dahinter mit (#5).
            guard event.window?.identifier?.rawValue == TransactionsPanel.panelWindowIdentifier else {
                return event
            }
            if event.type == .keyDown {
                return handleKeyDown(event)
            }
            handleScrollWheelEvent(event)
            return event
        }
    }

    private func removeScrollWheelMonitor() {
        if let m = scrollWheelMonitor {
            NSEvent.removeMonitor(m)
            scrollWheelMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // ⌘R → Refresh
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers == "r" else { return event }
        guard !isPullRefreshing else { return nil }
        Task { await triggerPullRefresh() }
        return nil // consume
    }

    private func handleScrollWheelEvent(_ event: NSEvent) {
        // Ignore momentum (coasting after finger lift) — only active finger contact counts.
        guard event.momentumPhase == [] || event.momentumPhase == .ended else {
            // During momentum at top, don't let residual velocity build overscroll.
            if event.momentumPhase != .ended && overscrollAccum > 0 {
                resetOverscrollState()
            }
            return
        }

        let dy = event.scrollingDeltaY
        let dx = event.scrollingDeltaX

        // ── Phase management ──
        if event.phase == .began {
            // Only arm overscroll if list is already at top when the NEW gesture starts.
            // This prevents accidental triggers from scrolling that just reaches the top.
            overscrollActive = isAtTopOfList
            overscrollAccum = 0
            overscrollStartTime = nil
            swipeAccumX = 0
            swipeTriggered = false
        }

        // ── Vertical: Pull-to-refresh (rubber-band) ──
        //
        // Three-layer protection against accidental triggers:
        //  1) overscrollActive — must be at top when gesture begins
        //  2) per-event cap — fast flick can't blow through threshold
        //  3) minimum hold duration — must sustain pull ≥350ms
        //
        if overscrollActive && !isPullRefreshing && dy > 0 && event.phase != .ended {
            // Cap each event's contribution so fast swipes accumulate slowly.
            let capped = min(dy, overscrollPerEventCap)
            overscrollAccum += capped

            // Record when overscroll accumulation first started.
            if overscrollStartTime == nil { overscrollStartTime = Date() }

            // Dead zone: first N pts are absorbed without visual feedback.
            let effective = max(0, overscrollAccum - overscrollDeadZone)
            pullDragOffset = rubberBandOffset(effective)

        } else if overscrollActive && dy < 0 && overscrollAccum > 0 && !isPullRefreshing {
            // User reversing direction → reduce accumulation.
            overscrollAccum = max(0, overscrollAccum - min(abs(dy), overscrollPerEventCap))
            let effective = max(0, overscrollAccum - overscrollDeadZone)
            pullDragOffset = rubberBandOffset(effective)
            if overscrollAccum == 0 { overscrollStartTime = nil }
        }

        // Gesture ended → check both threshold AND hold duration, then fire or snap back.
        if event.phase == .ended {
            let effective = max(0, overscrollAccum - overscrollDeadZone)
            let held = overscrollStartTime.map { Date().timeIntervalSince($0) } ?? 0
            let shouldFire = overscrollActive
                && effective >= scrollOverscrollThreshold
                && held >= overscrollMinDuration
                && !isPullRefreshing

            if shouldFire {
                overscrollAccum = 0
                overscrollActive = false
                overscrollStartTime = nil
                Task { await triggerPullRefresh() }
            } else if pullDragOffset > 0 && !isPullRefreshing {
                resetOverscrollState()
            }
        }

        // Horizontal account switch removed — account switch only via dot indicators.
    }

    private func resetOverscrollState() {
        overscrollAccum = 0
        overscrollActive = false
        overscrollStartTime = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            pullDragOffset = 0
        }
    }

    /// Rubber-band mapping: raw overscroll offset → visual pull distance.
    /// Starts ~1:1 for small values, flattens toward `pullMaxVisualOffset`.
    private func rubberBandOffset(_ raw: CGFloat) -> CGFloat {
        guard raw > 0 else { return 0 }
        let limit = pullMaxVisualOffset
        let k: CGFloat = 4.5
        return limit * (1 - exp(-raw * k / limit))
    }

    private func switchToNextSlot() {
        let store = multibankingStore

        if vm.unifiedModeEnabled {
            vm.unifiedModeEnabled = false
            accountNav.onSwitchToIndex?(0)
        } else {
            let next = store.activeIndex + 1
            if next < store.slots.count {
                accountNav.onSwitchToIndex?(next)
            } else {
                // Wrap → unified mode
                vm.unifiedModeEnabled = true
            }
        }
    }

    private func switchToPrevSlot() {
        let store = multibankingStore

        if vm.unifiedModeEnabled {
            // Unified → last individual slot
            vm.unifiedModeEnabled = false
            accountNav.onSwitchToIndex?(store.slots.count - 1)
        } else {
            let prev = store.activeIndex - 1
            if prev >= 0 {
                accountNav.onSwitchToIndex?(prev)
            } else {
                // Wrap → unified mode
                vm.unifiedModeEnabled = true
            }
        }
    }

    // MARK: - Roundup View Toggle

    private func toggleRoundupView() {
        // Aufrunden ist für PayPal deaktiviert (nicht sinnvoll).
        if multibankingStore.activeSlot?.isPayPal == true { return }
        if roundupView.isActive {
            roundupView.deactivate()
        } else if let slotId = multibankingStore.activeSlot?.id {
            // Aufrunden per Button direkt aktivieren — kein Umweg über die
            // Einstellungen. Ist es für den Slot noch aus, schalten wir es hier ein.
            var s = BankSlotSettingsStore.load(slotId: slotId)
            if !s.roundupEnabled {
                s.roundupEnabled = true
                BankSlotSettingsStore.save(s, slotId: slotId)
            }
            // Aktive Suche/Filter zurücksetzen: im Sparmodus sind sie ausgeblendet, der
            // Spartopf rechnet aber aus ALLEN Buchungen — sonst zeigt die Liste einen
            // stillen Ausschnitt, der nicht zur Spar-Summe passt.
            vm.query = ""
            vm.activeFilter = .all
            roundupView.activate(slotId: slotId, bankId: activeBankId, transactions: vm.transactions)
        }
    }

    // MARK: - Swipe Flag Helpers

    private var hasAnyUnreadTransaction: Bool {
        vm.enrichmentData.values.contains { $0.isUnread }
    }

    private func markAllTransactionsRead() {
        let bankId = activeBankId
        // Scope: in der Single-Account-Ansicht nur den aktiven Slot; in Unified alle Slots.
        // Ohne Scope würden Buchungen aus Konten, die gerade nicht sichtbar sind,
        // stumm als gelesen markiert.
        let scopedSlots: [String]?
        if vm.isUnifiedMode {
            scopedSlots = nil                               // Unified → alle Slots
        } else {
            scopedSlots = [TransactionsDatabase.activeSlotId]
        }
        if demoMode {
            for (key, value) in vm.enrichmentData where value.isUnread {
                var e = value
                e.isUnread = false
                vm.enrichmentData[key] = e
            }
            return
        }
        Task {
            try? TransactionsDatabase.markAllRead(bankId: bankId, slotIds: scopedSlots)
            await MainActor.run { vm.loadEnrichmentData(bankId: bankId) }
        }
    }

    private func toggleUnread(txID: String, slotId: String, bankId: String) {
        let key = TxEnrichmentKey.make(slotId: slotId, txID: txID)
        let current = vm.enrichmentData[key]?.isUnread ?? false
        let newValue = !current
        if demoMode {
            // Demo: in-memory only, no DB
            var e = vm.enrichmentData[key] ?? TxEnrichment(note: nil, attachmentCount: 0, isUnread: false, isFlagged: false)
            e.isUnread = newValue
            vm.enrichmentData[key] = e
        } else {
            try? TransactionsDatabase.setUnread(txID: txID, slotId: slotId, bankId: bankId, value: newValue)
            vm.loadEnrichmentData(bankId: bankId)
        }
    }

    private func setReminder(txID: String, slotId: String, bankId: String, dueDate: Date, title: String) {
        guard !demoMode else { return }
        Task {
            do {
                let id = try await ReminderService.shared.createReminder(title: title, dueDate: dueDate)
                try TransactionsDatabase.setReminderId(txID: txID, slotId: slotId, bankId: bankId, reminderId: id)
                await MainActor.run { vm.loadEnrichmentData(bankId: bankId) }
            } catch {
                // Permission denied oder EventKit-Fehler — sichtbar machen statt still schlucken.
                AppLogger.log("Reminder-Erstellung fehlgeschlagen: \(error)", category: "Reminder", level: "WARN")
            }
        }
    }

    private func removeReminder(txID: String, slotId: String, reminderId: String?, bankId: String) {
        guard !demoMode else { return }
        Task {
            if let id = reminderId {
                await ReminderService.shared.deleteReminder(id: id)
            }
            try? TransactionsDatabase.setReminderId(txID: txID, slotId: slotId, bankId: bankId, reminderId: nil)
            await MainActor.run { vm.loadEnrichmentData(bankId: bankId) }
        }
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

    // MARK: - OFX Export

    private static let ofxDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func exportTransactionsOFX(_ transactions: [TransactionsResponse.Transaction]) {
        let now = Self.ofxDateFormatter.string(from: Date())
        let iban = (vm.connectedBankIBAN ?? "").replacingOccurrences(of: " ", with: "")
        let currency = vm.connectedBankCurrency ?? "EUR"
        let bankName = vm.connectedBankDisplayName.isEmpty ? "simplebanking" : vm.connectedBankDisplayName

        // Compute date range from transactions
        let dates = transactions.compactMap { tx -> String? in tx.bookingDate ?? tx.valueDate }
            .sorted()
        let dtStart = dates.first.map { Self.ofxDateFormatter.string(from: parseOFXDate($0) ?? Date()) } ?? now
        let dtEnd   = dates.last.map  { Self.ofxDateFormatter.string(from: parseOFXDate($0) ?? Date()) } ?? now

        var lines: [String] = []

        // OFX 1.x SGML header (no XML, maximum compatibility)
        lines += [
            "OFXHEADER:100",
            "DATA:OFXSGML",
            "VERSION:151",
            "SECURITY:NONE",
            "ENCODING:UTF-8",
            "CHARSET:1252",
            "COMPRESSION:NONE",
            "OLDFILEUID:NONE",
            "NEWFILEUID:NONE",
            "",
            "<OFX>",
            "<SIGNONMSGSRSV1>",
            "<SONRS>",
            "<STATUS><CODE>0<SEVERITY>INFO",
            "<DTSERVER>\(now)",
            "<LANGUAGE>GER",
            "<FI><ORG>\(ofxEscape(bankName))</FI>",
            "</SONRS>",
            "</SIGNONMSGSRSV1>",
            "<BANKMSGSRSV1>",
            "<STMTTRNRS>",
            "<TRNUID>1001",
            "<STATUS><CODE>0<SEVERITY>INFO",
            "<STMTRS>",
            "<CURDEF>\(currency)",
            "<BANKACCTFROM>",
        ]
        if !iban.isEmpty {
            lines.append("<ACCTID>\(iban)")
        }
        lines += [
            "<ACCTTYPE>CHECKING",
            "</BANKACCTFROM>",
            "<BANKTRANLIST>",
            "<DTSTART>\(dtStart)",
            "<DTEND>\(dtEnd)",
        ]

        for tx in transactions {
            let rawDate = tx.bookingDate ?? tx.valueDate ?? ""
            let dtPosted = parseOFXDate(rawDate).map { Self.ofxDateFormatter.string(from: $0) } ?? rawDate
            let amount = tx.parsedAmount
            let trnType = amount >= 0 ? "CREDIT" : "DEBIT"
            let amountStr = String(format: "%.2f", amount)
            let fitid = ofxEscape(tx.stableIdentifier)
            let name = ofxEscape(
                String((tx.creditor?.name ?? tx.debtor?.name ?? "").prefix(32))
            )
            let memo = ofxEscape(
                (tx.remittanceInformation ?? []).joined(separator: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            )

            lines += [
                "<STMTTRN>",
                "<TRNTYPE>\(trnType)",
                "<DTPOSTED>\(dtPosted)",
                "<TRNAMT>\(amountStr)",
                "<FITID>\(fitid)",
            ]
            if !name.isEmpty { lines.append("<NAME>\(name)") }
            if !memo.isEmpty { lines.append("<MEMO>\(memo)") }
            lines.append("</STMTTRN>")
        }

        lines += [
            "</BANKTRANLIST>",
            "</STMTRS>",
            "</STMTTRNRS>",
            "</BANKMSGSRSV1>",
            "</OFX>",
        ]

        let ofxString = lines.joined(separator: "\r\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ofx") ?? .data]
        panel.nameFieldStringValue = "transaktionen.ofx"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ofxString.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.t("OFX-Export fehlgeschlagen", "OFX export failed")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func parseOFXDate(_ s: String) -> Date? {
        // Handles ISO 8601 "2024-03-15" and compact "20240315"
        let compact = s.replacingOccurrences(of: "-", with: "")
        return Self.ofxDateFormatter.date(from: compact.prefix(8).description)
    }

    private func ofxEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - simple.report Export

    private func exportSimpleReport(month: ReportMonth) {
        let allTxs: [TransactionsResponse.Transaction]
        let slot: BankSlot

        if demoMode {
            let demoSlots = ["demo-main", "demo-daily", "demo-bills"]
            let loaded = try? TransactionsDatabase.loadUnifiedTransactions(slots: demoSlots, days: 365, bankId: "demo")
            allTxs = (loaded?.isEmpty == false) ? loaded! : vm.transactions
            slot = multibankingStore.activeSlot
                ?? BankSlot(id: "demo-main", iban: "DE89200400600284202600", displayName: "Klotzbrocken AG", logoId: nil, nickname: "Hauptkonto")
        } else {
            guard let realSlot = multibankingStore.activeSlot else { return }
            // Load 90 days for recurring/fixed-cost detection — same window as FixedCostsView.
            // vm.transactions only covers fetchDays (default 60) which misses early-month
            // subscriptions and cuts off quarterly patterns entirely.
            let slotIds: [String]? = vm.isUnifiedMode
                ? MultibankingStore.shared.slots.map { $0.id }
                : [TransactionsDatabase.activeSlotId]
            allTxs = (try? TransactionsDatabase.loadUnifiedTransactions(slots: slotIds, days: 90))
                ?? vm.transactions
            // Im Unified-Mode aggregieren wir Tx aus allen Slots — der Header darf
            // dann nicht den active-slot-displayName/IBAN zeigen (wirkt für User
            // „willkürlich"). Synthesierter Aggregat-Slot für den Header.
            let unifiedName = L10n.t("Alle Konten", "All accounts")
            slot = vm.isUnifiedMode
                ? BankSlot(id: "unified", iban: "", displayName: unifiedName,
                           logoId: nil, nickname: unifiedName)
                : realSlot
        }

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

        // Consent-Gate (default aus): Freitext-Fragen senden Umsatzdaten des aktiven
        // Kontos an den gewählten KI-Anbieter — nur mit expliziter Freigabe.
        guard UserDefaults.standard.bool(forKey: "aiChatEnabled") else {
            chatState = .failed("Die KI-Chat-Funktion ist deaktiviert. Aktiviere sie in den Einstellungen → KI-Assistent. Dabei werden Umsatzdaten des aktiven Kontos an den gewählten KI-Anbieter gesendet.")
            return
        }

        let key = vm.anthropicApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = key, !apiKey.isEmpty else {
            chatState = .failed("API-Key ist noch nicht verfügbar. Öffne die Umsatzliste nach dem Entsperren erneut oder setze den Key in den Einstellungen.")
            return
        }

        let slotId = MultibankingStore.shared.activeSlot?.id ?? "legacy"

        Task {
            do {
                let answer = try await LLMService.ask(question: question, apiKey: apiKey, slotId: slotId)
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

private struct FilterPill: View {
    let filter: TxFilter
    let active: Bool
    let onTap: () -> Void

    private var themed: Bool { !ThemeManager.shared.currentTheme.isDefault }
    private var lofi: Bool { themed && ThemeChrome.lofi }

    @ViewBuilder
    var body: some View {
        if lofi {
            // BTX/Theme: kein Icon, VT323 in Großbuchstaben, ausreichender Kontrast —
            // aktiv als gefüllte Fläche in Leitfarbe mit Schirmfarbe als Text, inaktiv
            // Ink-Text mit Rahmen. Eckig bei `squareControls`.
            let radius = ThemeChrome.cornerRadius(999)
            Button(action: onTap) {
                Text(filter.label)
                    .font(ThemeFonts.flyoutBody(size: 14))
                    .textCase(.uppercase)
                    .foregroundColor(active ? Color.themedSurface : Color.themedInk.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(active ? Color.themedAccent : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .stroke(Color.themedInk.opacity(active ? 0 : 0.5), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(active ? L10n.t("Filter aufheben", "Clear filter") : filter.label)
        } else {
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: filter.icon)
                        .font(.system(size: 11, weight: .medium))
                    Text(filter.label)
                        .font(.system(size: 11, weight: .medium))
                    if active {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .foregroundColor(active ? .white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(active ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(active ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(active
                  ? L10n.t("Filter aufheben", "Clear filter")
                  : filter.label)
        }
    }
}

private struct TransactionRowNew: View {
    let transaction: TransactionsResponse.Transaction
    let category: TransactionCategory
    let name: String
    let normalizedMerchant: String
    let amount: String
    let amountColor: Color
    /// Sparmode: wenn gesetzt, zeigt die Zeile „Original → Aufgerundet" statt `amount`.
    var roundupDisplay: (original: String, rounded: String)? = nil
    let matchBadges: [String]
    let userNote: String?
    let attachmentCount: Int
    let bankId: String
    let onEnrichmentChanged: () -> Void
    var isWide: Bool = false
    var slotColor: Color? = nil
    var isInternalTransfer: Bool = false
    var showCategories: Bool = false
    var isUnread: Bool = false
    var hasReminder: Bool = false
    var reminderId: String? = nil
    var isSelected: Bool = false
    var onReminderAction: (() -> Void)? = nil
    var onEnrichmentChangedWithRemover: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil

    private var isPending: Bool { transaction.status == "pending" }
    /// „Vorgemerkt" als Kapsel zeigen. Eine Nutzereinstellung, keine Theme-Sache: Sie
    /// ändert nicht das Aussehen, sondern ob die Information überhaupt erscheint —
    /// wer viele vorgemerkte Buchungen hat, findet die Kapsel in jeder zweiten Zeile.
    @AppStorage("pendingAsPill") private var pendingAsPill: Bool = true

    @ObservedObject private var logoService = MerchantLogoService.shared
    @State private var showDetail: Bool = false

    /// Eigene Beobachtung des Themes: die Zeile ist ein eigener View-Wert, dessen Body
    /// SwiftUI ohne geänderte Eingaben nicht neu auswertet. Ohne `@AppStorage` bliebe
    /// sie nach einem Theme-Wechsel im alten Look stehen, bis sich die Liste ändert.
    @AppStorage(ThemeManager.storageKey) private var themeId: String = ThemeManager.defaultThemeID
    private var themed: Bool { themeId != ThemeManager.defaultThemeID }
    /// Zeilen-Umgestaltung (Schrift/Ink/Größen) nur im Lo-Fi-Modus (BTX) —
    /// Farb-Themes lassen die Zeilen unangetastet wie vor 2.0.
    private var lofi: Bool { themed && ThemeChrome.lofi }

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

    /// Row-Hintergrund: Selektion > Bank-Tint-Style > cardBackground. Im Aufrunden-View
    /// (Mint-Modus) wird der Bank-Tint unterdrückt — der Mint-Hintergrund des Panels
    /// übernimmt die visuelle Mode-Signalisierung.
    ///
    /// Tint-Style-spezifisch (nur ausserhalb Roundup-View):
    /// • soft        → Bank-Soft-Tint (Bestandsverhalten)
    /// • cardOnPanel → cardBackground (weiße Card schwebt auf Bank-getöntem Panel)
    /// • sidebar     → cardBackground (Bank-Akzent nur als 4 px Streifen am Panel)
    private var rowFillColor: Color {
        // Prototyp „Ton in Ton": keine schwebende Card mehr — nur die Selektion wird
        // hervorgehoben, sonst scheint der Panel-/Listen-Hintergrund durch.
        if isSelected { return Color.accentColor.opacity(0.12) }
        return .clear
    }

    /// Card-Shadow nur im `.cardOnPanel`-Style sichtbar — gibt den Rows
    /// den schwebenden Look auf Bank-Soft-Panel.
    private var rowShadowRadius: CGFloat {
        guard !RoundupViewState.shared.isActive,
              BankTintStyle.current == .cardOnPanel else { return 0 }
        return 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 10) {
                    // Reihenfolge und Platz sind fix (20×20) — nur der Inhalt wechselt.
                    // Ein Theme ohne Bildmarken (BTX) setzt hier Mosaik-Semigrafik.
                    if let logo = merchantLogo, ThemeChrome.merchantLogosEnabled {
                        Image(nsImage: logo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                    } else if ThemeChrome.categoryIconsEnabled {
                        Image(systemName: category.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(ThemeChrome.categoryIconColor(
                                Color(nsColor: AppTheme.color(from: BTXMosaic.style(for: category).hex,
                                                              fallback: .secondaryLabelColor))))
                            .frame(width: 20, height: 20)
                    } else {
                        BTXMosaicIcon(category: category)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(ThemeFonts.rowHeading(size: 14, weight: .medium))
                            .textCase(ThemeChrome.textCase)
                            .lineLimit(1)
                            .foregroundColor(themed ? .themedInk : .primary)
                        if showCategories {
                            Text(category.rawValue)
                                .font(ThemeFonts.rowBody(size: 10, lofiSize: 13))
                                .textCase(ThemeChrome.textCase)
                                .foregroundColor(themed ? Color.themedInk.opacity(0.85) : .secondary)
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
                        .font(ThemeFonts.rowBody(size: 11))
                        .textCase(ThemeChrome.textCase)
                        .foregroundStyle(themed ? Color.themedInk.opacity(0.72) : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .padding(.leading, 8)
                } else if ThemeChrome.dottedLeaders {
                    // Punkt-Führungslinie aus der BTX-Originalseite — sie sitzt exakt
                    // dort, wo sonst der leere Zwischenraum steht, und verbindet Name
                    // und Betrag. Gleiche Position, gleiche Reihenfolge.
                    BTXDottedRule()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6)
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
                    if let rd = roundupDisplay {
                        // Sparmode: Original → aufgerundetes Ziel. Bei Themes (BTX) in
                        // Theme-Schrift/-Farben und mit Text-Pfeil „>" statt SF-Symbol;
                        // das Mint des Default-Looks passt nicht in die BTX-Farbwelt.
                        HStack(spacing: 4) {
                            Text(rd.original)
                                .font(ThemeFonts.rowBody(size: 12, weight: .regular, lofiSize: 13))
                                .foregroundColor(themed ? Color.themedInk.opacity(0.6) : .sbTextSecondary)
                            if lofi {
                                Text(">")
                                    .font(ThemeFonts.flyoutBody(size: 13))
                                    .foregroundColor(Color.themedInk.opacity(0.6))
                            } else {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.sbTextSecondary)
                            }
                            Text(rd.rounded)
                                .font(ThemeFonts.rowHeading(size: 14, weight: .semibold, lofiWeight: .medium))
                                .foregroundColor(themed ? Color.themedIncome : Color.roundupAccent)
                        }
                    } else {
                        Text(amount)
                            .font(ThemeFonts.rowHeading(size: 14, weight: .medium, lofiSize: 17))
                            .foregroundColor(amountColor)
                    }
                    if isPending, pendingAsPill {
                        // BTX: reiner Text ohne Kapsel/Rahmen — die Zeile ist ohnehin
                        // schon auf 65 % gedimmt, das Wort genügt.
                        Text(L10n.t("Vorgemerkt", "Pending"))
                            .font(ThemeFonts.rowBody(size: 10, weight: .semibold, lofiSize: 12))
                            .textCase(ThemeChrome.textCase)
                            .foregroundColor(themed ? Color.themedInk.opacity(0.85) : .sbOrangeStrong)
                            .padding(.horizontal, lofi ? 0 : 6)
                            .padding(.vertical, 2)
                            .background(
                                // Das feste Orange stand bisher auf jeder Theme-Fläche;
                                // mit Theme nimmt die Kapsel die Ink-Farbe leicht getönt.
                                lofi ? nil
                                     : Capsule().fill(themed ? Color.themedInk.opacity(0.16)
                                                             : Color.sbOrangeSoft)
                            )
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
                .fill(rowFillColor)
                .shadow(color: Color.black.opacity(rowShadowRadius > 0 ? 0.08 : 0),
                        radius: rowShadowRadius, x: 0, y: 1)
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
        .onTapGesture(count: 1) {
            onSelect?()
        }
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            guard attachmentCount < 3 else { return false }
            let txID = TransactionRecord.fingerprint(for: transaction)
            let slotId = transaction.slotId ?? TransactionsDatabase.activeSlotId
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        guard let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in
                            _ = try? TransactionsDatabase.addAttachment(txID: txID, slotId: slotId, bankId: bankId, sourceURL: url)
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
                isUnread: isUnread,
                hasReminder: hasReminder,
                reminderId: reminderId,
                onEnrichmentChanged: {
                    onEnrichmentChanged()
                    onEnrichmentChangedWithRemover?()
                }
            )
        }
        .onAppear {
            MerchantLogoService.shared.preload(normalizedMerchant: logoKey)
        }
    }
}

/// Erzwingt Overlay-Scroller mit Autohide auf der umschließenden NSScrollView —
/// unabhängig von System-Einstellung/angeschlossener Maus. Dadurch blendet die
/// vertikale Scrollbar wieder on-demand aus (wie früher) statt dauerhaft zu bleiben.
private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        configure(from: v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        configure(from: nsView)
    }
    private func configure(from view: NSView, attempt: Int = 0) {
        // Die umschließende NSScrollView hängt beim ersten Layout evtl. noch nicht in
        // der Hierarchie → ein paar verzögerte Versuche, bis sie gefunden wird.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.15) { [weak view] in
            guard let view else { return }
            var node: NSView? = view.superview
            while let cur = node, !(cur is NSScrollView) { node = cur.superview }
            if let scroll = node as? NSScrollView {
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
                scroll.verticalScroller?.alphaValue = 0
            } else if attempt < 6 {
                configure(from: view, attempt: attempt + 1)
            }
        }
    }
}

// MARK: - Trackpad Horizontal Swipe Overlay (2-finger scrollWheel → offset)

/// NSView overlay that intercepts horizontal-dominant 2-finger trackpad swipes
/// and forwards them as offset deltas. Vertical scrolls pass through to ScrollView.
private struct TrackpadSwipeOverlay: NSViewRepresentable {
    @Binding var offset: CGFloat
    @Binding var activeSwipedID: String?
    let txID: String
    let revealWidth: CGFloat
    let maxDrag: CGFloat
    let threshold: CGFloat
    let onSnap: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackpadSwipeNSView {
        let v = TrackpadSwipeNSView()
        v.autoresizingMask = [.width, .height]
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: TrackpadSwipeNSView, context: Context) {
        context.coordinator.offset = offset
        context.coordinator.activeSwipedID = activeSwipedID
        context.coordinator.txID = txID
        context.coordinator.revealWidth = revealWidth
        context.coordinator.maxDrag = maxDrag
        context.coordinator.threshold = threshold
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor final class Coordinator {
        var parent: TrackpadSwipeOverlay
        var offset: CGFloat = 0
        var activeSwipedID: String?
        var txID: String = ""
        var revealWidth: CGFloat = 60
        var maxDrag: CGFloat = 80
        var threshold: CGFloat = 50
        fileprivate var accumX: CGFloat = 0
        fileprivate var accumY: CGFloat = 0
        fileprivate enum TrackState { case idle, pending, horizontal, rejected }
        fileprivate var trackState: TrackState = .idle

        init(parent: TrackpadSwipeOverlay) { self.parent = parent }

        func handleScroll(_ event: NSEvent) -> Bool {
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            // ── Phase began: reset, enter pending state ──
            if event.phase == .began {
                accumX = 0
                accumY = 0
                trackState = .pending
                return false // don't consume yet — let ScrollView start too
            }

            // ── Rejected or idle: pass through ──
            if trackState == .idle || trackState == .rejected {
                return false
            }

            // ── End / cancel: snap if we were tracking horizontal ──
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                if trackState == .horizontal {
                    let currentOffset = offset + accumX
                    let snap: CGFloat
                    if abs(currentOffset) > threshold {
                        snap = currentOffset > 0 ? revealWidth : -revealWidth
                        parent.activeSwipedID = txID
                    } else {
                        snap = 0
                        if parent.activeSwipedID == txID { parent.activeSwipedID = nil }
                    }
                    parent.onSnap(snap)
                    trackState = .idle
                    accumX = 0
                    accumY = 0
                    return true
                }
                trackState = .idle
                accumX = 0
                accumY = 0
                return false
            }

            // ── Pending: accumulate until direction is clear ──
            if trackState == .pending {
                accumX += dx
                accumY += abs(dy)
                let totalH = abs(accumX)
                let totalV = accumY

                // Need at least 4pt total movement to decide
                guard totalH + totalV > 4 else { return false }

                if totalH > totalV * 1.2 {
                    // Horizontal wins — claim this gesture
                    trackState = .horizontal
                    accumX = offset + accumX // start from current offset
                } else {
                    // Vertical wins — reject, let ScrollView handle
                    trackState = .rejected
                    return false
                }
            }

            // ── Horizontal tracking: update offset ──
            if trackState == .horizontal {
                accumX += dx

                // Rubber-band beyond max
                let clamped: CGFloat
                if accumX > 0 {
                    clamped = accumX <= maxDrag ? accumX : maxDrag + (accumX - maxDrag) * 0.3
                } else {
                    clamped = accumX >= -maxDrag ? accumX : -maxDrag + (accumX + maxDrag) * 0.3
                }

                // Close other swiped row
                if parent.activeSwipedID != nil && parent.activeSwipedID != txID {
                    parent.activeSwipedID = nil
                }
                parent.offset = clamped
                return true
            }

            return false
        }
    }

    @MainActor final class TrackpadSwipeNSView: NSView {
        weak var coordinator: Coordinator?
        private var monitor: Any?

        // Return nil so clicks/drags pass through to SwiftUI gestures underneath
        override func hitTest(_ aPoint: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window else { return event }
                    let loc = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(loc) else { return event }
                    if let coord = self.coordinator, coord.handleScroll(event) {
                        return nil // consumed — don't forward to ScrollView
                    }
                    return event // vertical — pass through
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        nonisolated deinit {
            MainActor.assumeIsolated {
                if let m = monitor { NSEvent.removeMonitor(m) }
            }
        }
    }
}

// MARK: - Swipeable Transaction Row (iMessage-style, click+drag + trackpad)

private struct SwipeableTransactionRow<Content: View>: View {
    let txID: String
    let isUnread: Bool
    let hasReminder: Bool
    @Binding var activeSwipedID: String?
    let onToggleUnread: () -> Void
    let onReminderAction: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var lockedDirection: SwipeDirection?

    private enum SwipeDirection { case left, right }
    private let revealWidth: CGFloat = 60
    private let threshold: CGFloat = 50
    private let maxDrag: CGFloat = 80

    private var isRevealed: Bool { abs(offset) >= revealWidth - 1 }

    var body: some View {
        ZStack {
            // Left action (swipe right reveals) — Unread
            HStack(spacing: 0) {
                Button {
                    onToggleUnread()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        offset = 0
                        activeSwipedID = nil
                    }
                } label: {
                    ZStack {
                        Color.accentColor
                        VStack(spacing: 3) {
                            Image(systemName: isUnread ? "circle" : "circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text(isUnread ? "Gelesen" : "Ungelesen")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(.white)
                    }
                    .frame(width: revealWidth)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .opacity(offset > 0 ? 1 : 0)

            // Right action (swipe left reveals) — Reminder
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    onReminderAction()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        offset = 0
                        activeSwipedID = nil
                    }
                } label: {
                    ZStack {
                        Color.orange
                        VStack(spacing: 3) {
                            Image(systemName: hasReminder ? "bell.slash.fill" : "bell.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text(hasReminder ? "Entfernen" : "Erinnern")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(.white)
                    }
                    .frame(width: revealWidth)
                }
                .buttonStyle(.plain)
            }
            .opacity(offset < 0 ? 1 : 0)

            // Row content
            content()
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            let dx = value.translation.width

                            // Lock direction on first significant movement
                            if lockedDirection == nil {
                                if abs(dx) > 12 {
                                    // Reject mostly-vertical drags
                                    if abs(value.translation.height) > abs(dx) * 1.5 {
                                        return
                                    }
                                    lockedDirection = dx > 0 ? .right : .left
                                } else {
                                    return
                                }
                            }

                            // Close other swiped row
                            if activeSwipedID != nil && activeSwipedID != txID {
                                activeSwipedID = nil
                            }

                            // Apply with rubber-band beyond max
                            let clamped: CGFloat
                            switch lockedDirection {
                            case .right:
                                clamped = dx <= maxDrag ? max(0, dx) : maxDrag + (dx - maxDrag) * 0.3
                            case .left:
                                clamped = dx >= -maxDrag ? min(0, dx) : -maxDrag + (dx + maxDrag) * 0.3
                            case .none:
                                clamped = 0
                            }
                            offset = clamped
                        }
                        .onEnded { _ in
                            let snap: CGFloat
                            if abs(offset) > threshold {
                                snap = offset > 0 ? revealWidth : -revealWidth
                                activeSwipedID = txID
                            } else {
                                snap = 0
                                if activeSwipedID == txID { activeSwipedID = nil }
                            }
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                offset = snap
                            }
                            lockedDirection = nil
                        }
                )
                .onTapGesture {
                    if isRevealed {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            offset = 0
                            activeSwipedID = nil
                        }
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            TrackpadSwipeOverlay(
                offset: $offset,
                activeSwipedID: $activeSwipedID,
                txID: txID,
                revealWidth: revealWidth,
                maxDrag: maxDrag,
                threshold: threshold,
                onSnap: { snap in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        offset = snap
                    }
                    lockedDirection = nil
                }
            )
        )
        .onChange(of: activeSwipedID) { newID in
            if newID != txID && offset != 0 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    offset = 0
                }
            }
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
                        .foregroundColor(.sbOrangeStrong)
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
        .frame(minWidth: 348, idealWidth: 348, maxWidth: 840, minHeight: 620, idealHeight: 620, maxHeight: 620)
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
    /// eBon-Slot (REWE/dm/Amazon) manuell aktualisieren (kleiner Button in der Liste).
    @Published var onReceiptRefresh: (() -> Void)? = nil
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
    /// Aktuelles Window-Frame — wird vom BalanceBar genutzt, um abhängige
    /// Sheets (TransferSheet) seitlich neben dem Panel zu positionieren.
    var frame: NSRect { panel.frame }
    private let vm: TransactionsViewModel
    let accountNav: AccountNavModel

    // Umsatzliste startet so schmal wie der Flyout (348); grüner Zoom-Button
    // togglet auf breit (840) und zurück — wie früher, nur schmaler als Default.
    nonisolated static let narrowWidth: CGFloat = 348
    nonisolated static let wideWidth:   CGFloat = 840
    nonisolated static let panelHeight: CGFloat = 620
    /// Window-Identifier des Umsatz-Panels — der Scroll-Monitor reagiert nur auf dieses Fenster.
    nonisolated static let panelWindowIdentifier = "simplebanking.transactions.panel"
    private var toolbarDelegate: TransactionsPanelToolbarDelegate?
    private var cancellables: Set<AnyCancellable> = []
    private let onSettings: (() -> Void)?
    private let onOpenDashboard: ((DashboardTab) -> Void)?

    // MARK: - Stay on Top

    private static let stayOnTopKey = "transactionsPanel.stayOnTop"
    private static let frameAutosaveName = "simplebanking.transactionsPanel"
    /// true, sobald eine Position gesetzt wurde (gespeichert oder einmalig zentriert).
    private var positionRestored = false

    private var isPinned: Bool {
        get { UserDefaults.standard.bool(forKey: Self.stayOnTopKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.stayOnTopKey)
            applyWindowLevel()
        }
    }

    private func applyWindowLevel() {
        panel.level = isPinned ? .floating : .normal
    }

    fileprivate func togglePin() {
        isPinned.toggle()
        toolbarDelegate?.refreshPinButton()
    }

    init(vm: TransactionsViewModel, onRefresh: @escaping () async -> Void = {}, onSettings: (() -> Void)? = nil,
         onOpenDashboard: ((DashboardTab) -> Void)? = nil) {
        self.vm = vm
        self.onSettings = onSettings
        self.onOpenDashboard = onOpenDashboard
        self.accountNav = AccountNavModel()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "simplebanking"
        // Eindeutige ID, damit der app-weite Scroll-Monitor NUR Events dieses
        // Fensters verarbeitet (sonst scrollt das Settings-Fenster die Liste mit).
        panel.identifier = NSUserInterfaceItemIdentifier(Self.panelWindowIdentifier)
        // Fensterposition merken: AppKit persistiert/restauriert das Frame bei
        // Move/Resize. positionRestored=true, wenn eine gespeicherte Position
        // angewandt wurde → show() zentriert dann nicht mehr.
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        positionRestored = panel.setFrameUsingName(Self.frameAutosaveName)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Theme-aware panel background — picks light/dark based on appearance
        panel.backgroundColor = NSColor(name: nil) { appearance in
            let theme = ThemeManager.shared.currentTheme
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? theme.panelDarkColor
                : theme.panelLightColor
        }
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        // Transparente Titelleiste ohne Trennlinie — die SwiftUI-Money-Heat füllt den
        // oberen Streifen (keine NSToolbar mehr, s. configureTitlebar()).
        panel.titlebarSeparatorStyle = .none

        // Fullscreen deaktivieren — grüner Button wird zum Breiten-Toggle
        panel.collectionBehavior = [.fullScreenNone, .managed]

        let h = Self.panelHeight
        let w = Self.narrowWidth
        panel.setContentSize(NSSize(width: w, height: h))
        // Start schmal fix; der grüne Zoom-Button + windowDidResize passen min/max
        // dann an die jeweilige Breite (schmal/breit) an.
        panel.minSize = NSSize(width: w, height: h)
        panel.maxSize = NSSize(width: w, height: h)

        super.init()

        panel.delegate = self
        applyWindowLevel()   // restore persisted stay-on-top state
        configureTitlebar()
        let host = NSHostingView(rootView: TransactionsPanelView(
            vm: vm, onRefresh: onRefresh, accountNav: accountNav, onOpenDashboard: onOpenDashboard,
            onSettings: onSettings,
            onTogglePin: { [weak self] in self?.isPinned.toggle() },
            isPinnedProvider: { [weak self] in self?.isPinned ?? false }
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
        // Nur beim allerersten Öffnen zentrieren; danach gemerkte Position behalten
        // (auch über Konto-Wechsel hinweg — show() wird bei jedem Switch gerufen).
        if !positionRestored {
            panel.center()
            positionRestored = true
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        configureOverlayScrollers(retriesLeft: 10)
    }

    /// Erzwingt Overlay-Scroller mit Autohide auf ALLEN NSScrollViews im Fenster —
    /// überstimmt die System-Einstellung „Bildlaufleisten: Immer". SwiftUI legt die
    /// ScrollView erst beim Layout an → ein paar verzögerte Versuche.
    private func configureOverlayScrollers(retriesLeft: Int) {
        guard let content = panel.contentView else { return }
        var found = false
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView {
                s.scrollerStyle = .overlay
                s.autohidesScrollers = true
                s.verticalScroller?.alphaValue = 0
                found = true
            }
            v.subviews.forEach(walk)
        }
        walk(content)
        if !found && retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.configureOverlayScrollers(retriesLeft: retriesLeft - 1)
            }
        }
    }

    func close() {
        panel.orderOut(nil)
    }

    // MARK: - Ampel nur bei aktivem Fenster
    //
    // Die Fensterknöpfe (Schließen/Minimieren/Zoom) sind nur sichtbar, solange das
    // Panel das aktive Fenster ist — inaktiv wirkt die Karte aufgeräumter und die
    // Knöpfe kleben nicht sichtbar auf der Theme-Fläche bzw. der CRT-Blende.
    private func setTrafficLights(hidden: Bool) {
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = hidden
        }
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated { setTrafficLights(hidden: false) }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { setTrafficLights(hidden: true) }
    }

    // MARK: - NSWindowDelegate: Zoom-Toggle (grüner Button)

    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Block manual edge-drag resizing — nur der grüne Zoom-Button (über
        // windowWillUseStandardFrame + setFrame) ändert die Größe (Breiten-Toggle).
        return sender.frame.size
    }

    /// Grüner Zoom-Button: Breiten-Toggle schmal (348) ↔ breit (wideWidth), Höhe bleibt.
    nonisolated func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        MainActor.assumeIsolated {
            let narrow = TransactionsPanel.narrowWidth
            let wide   = TransactionsPanel.wideWidth
            let height = window.frame.height
            let isNarrow = window.frame.width < (narrow + wide) / 2
            let targetWidth: CGFloat = isNarrow ? wide : narrow
            let x = window.frame.midX - targetWidth / 2
            let y = window.frame.minY
            let screen = window.screen?.visibleFrame ?? defaultFrame
            let clampedX = max(screen.minX, min(x, screen.maxX - targetWidth))
            return NSRect(x: clampedX, y: y, width: targetWidth, height: height)
        }
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
        // AppKit guarantees window delegate callbacks on the main thread.
        MainActor.assumeIsolated {
            // Auf die aktuelle Breite (schmal/breit) einrasten, Höhe fix.
            let narrow = TransactionsPanel.narrowWidth
            let wide   = TransactionsPanel.wideWidth
            let snap: CGFloat = window.frame.width > (narrow + wide) / 2 ? wide : narrow
            let frameHeight = window.frame.height
            window.minSize = NSSize(width: snap, height: frameHeight)
            window.maxSize = NSSize(width: snap, height: frameHeight)
        }
    }

    private func configureTitlebar() {
        // Money-Heat bis ganz oben: KEINE NSToolbar mehr — ihr Material verdeckte den
        // Wash im oberen Streifen. Refresh/Pin/Einstellungen leben jetzt als
        // SwiftUI-Buttons im Header (auf der Money-Heat), die Ampel sitzt darauf.
        panel.toolbar = nil
    }

    // Clippy-Easter-Egg in v1.5.0 entfernt — Header-Click ist jetzt no-op.
    @objc private func onBankHeaderClicked(_ sender: NSClickGestureRecognizer) {
        guard sender.state == .ended else { return }
    }
}

extension Notification.Name {
    /// Header-Toolbar „Aktualisieren" → löst den Pull-to-Refresh-Pfad aus.
    static let transactionsPanelHeaderRefresh = Notification.Name("simplebanking.transactionsPanelHeaderRefresh")
}

@MainActor
private final class TransactionsPanelToolbarDelegate: NSObject, NSToolbarDelegate {
    private let settingsIdentifier = NSToolbarItem.Identifier("simplebanking.transactions.settings")
    private let pinIdentifier      = NSToolbarItem.Identifier("simplebanking.transactions.pin")
    private let refreshIdentifier  = NSToolbarItem.Identifier("simplebanking.transactions.refresh")
    private let onSettings: (() -> Void)?
    private let onTogglePin: (() -> Void)?
    private let onRefresh: (() -> Void)?
    private let isPinnedProvider: () -> Bool
    private weak var pinButton: NSButton?

    init(
        onSettings: (() -> Void)?,
        onTogglePin: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        isPinnedProvider: @escaping () -> Bool = { false }
    ) {
        self.onSettings = onSettings
        self.onTogglePin = onTogglePin
        self.onRefresh = onRefresh
        self.isPinnedProvider = isPinnedProvider
        super.init()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, refreshIdentifier, pinIdentifier, settingsIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, refreshIdentifier, pinIdentifier, settingsIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == refreshIdentifier {
            let item = NSToolbarItem(itemIdentifier: refreshIdentifier)
            let button = NSButton()
            button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Aktualisieren")
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.target = self
            button.action = #selector(refreshTapped)
            button.toolTip = "Aktuelles Konto aktualisieren"
            item.view = button
            item.label = ""
            item.paletteLabel = "Aktualisieren"
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
            item.label = ""
            item.paletteLabel = "Einstellungen"
            return item
        }
        if itemIdentifier == pinIdentifier {
            let item = NSToolbarItem(itemIdentifier: pinIdentifier)
            let button = NSButton()
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.target = self
            button.action = #selector(pinTapped)
            item.view = button
            item.label = ""
            item.paletteLabel = "Oben halten"
            self.pinButton = button
            applyPinState(to: button)
            return item
        }
        return nil
    }

    /// Updates the existing pin button's icon + tooltip to reflect the current state.
    func refreshPinButton() {
        guard let button = pinButton else { return }
        applyPinState(to: button)
    }

    private func applyPinState(to button: NSButton) {
        let pinned = isPinnedProvider()
        button.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: "Oben halten"
        )
        button.contentTintColor = pinned ? NSColor.controlAccentColor : nil
        button.toolTip = pinned
            ? "Oben fixiert — klicken zum Lösen"
            : "Oben halten"
    }

    @objc private func settingsTapped() {
        onSettings?()
    }

    @objc private func pinTapped() {
        onTogglePin?()
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }
}

// MARK: - Reminder Picker Sheet

struct ReminderPickerSheet: View {
    @Binding var date: Date
    let onConfirm: (Date) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Erinnerung setzen")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
            }

            DatePicker("Datum & Uhrzeit", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()

            HStack(spacing: 12) {
                Button("Abbrechen") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Erinnerung erstellen") { onConfirm(date) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

// MARK: - Filter Menu Button (NSViewRepresentable)

private struct FilterMenuButton: NSViewRepresentable {
    let activeFilter: TxFilter
    let showCategories: Bool
    let onSelect: (TxFilter) -> Void
    let onToggleCategories: () -> Void

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
        context.coordinator.showCategories = showCategories
        context.coordinator.onSelect = onSelect
        context.coordinator.onToggleCategories = onToggleCategories
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

    @MainActor final class Coordinator: NSObject {
        var activeFilter: TxFilter = .all
        var showCategories: Bool = false
        var onSelect: (TxFilter) -> Void = { _ in }
        var onToggleCategories: () -> Void = {}

        // Tag-Offset: Filter-Items 0…(n-1), Kategorien-Toggle = 1000
        private let categoriesTag = 1000

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

            // Kategorien-Toggle — visuell abgehoben durch Separator
            menu.addItem(.separator())
            let catItem = NSMenuItem(
                title: showCategories
                    ? NSLocalizedString("Kategorien ausblenden", comment: "")
                    : NSLocalizedString("Kategorien anzeigen", comment: ""),
                action: #selector(itemSelected(_:)),
                keyEquivalent: ""
            )
            catItem.target = self
            catItem.tag = categoriesTag
            catItem.state = showCategories ? .on : .off
            if let img = NSImage(systemSymbolName: "tag", accessibilityDescription: nil) {
                img.isTemplate = true
                catItem.image = img
            }
            menu.addItem(catItem)

            let bounds = sender.bounds
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.maxY), in: sender)
        }

        @objc func itemSelected(_ sender: NSMenuItem) {
            if sender.tag == categoriesTag {
                onToggleCategories()
                return
            }
            guard let filter = TxFilter(rawValue: sender.tag) else { return }
            onSelect(filter)
        }
    }
}

// MARK: - Color from hex

extension Color {
    /// Initialize from a hex string. Accepts 6 chars ("RRGGBB"), 8 chars
    /// ("RRGGBBAA" — alpha suffix), or 3 chars ("RGB" → expanded). Optional
    /// `#` prefix. Falls back to nil for any other format.
    ///
    /// 8-char-Variante wichtig für den YAXI-Bank-Catalog: dort stehen Farben
    /// oft als `#0949cfff` (z.B. C24 Bank) inkl. Alpha-Suffix.
    init?(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let rgbHex: String
        let alpha: Double
        switch h.count {
        case 3:
            rgbHex = h.map { "\($0)\($0)" }.joined()
            alpha = 1.0
        case 6:
            rgbHex = h
            alpha = 1.0
        case 8:
            rgbHex = String(h.prefix(6))
            if let a = UInt8(h.suffix(2), radix: 16) {
                alpha = Double(a) / 255.0
            } else {
                alpha = 1.0
            }
        default:
            return nil
        }
        guard let value = UInt64(rgbHex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }
}
