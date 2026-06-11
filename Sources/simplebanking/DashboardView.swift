import SwiftUI

/// Tabs of the unified Dashboard. „Fixkosten" ist bewusst kein eigener Tab mehr — Fixkosten sind
/// die Verträge-/Verbindlichkeiten-Tabs innerhalb „Abos & Verträge".
enum DashboardTab: String, CaseIterable, Identifiable {
    case overview       // Financial Health / MMI
    case subscriptions  // Abos & Verträge (inkl. Fixkosten + Kalender + Stats)
    case calendar       // Ausgaben-Heatmap
    case moneyAge       // Geld-Alter
    case rules          // Regeln & Zuordnungen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:      return "Übersicht"
        case .subscriptions: return "Abos & Verträge"
        case .calendar:      return "Kalender"
        case .moneyAge:      return "Geld-Alter"
        case .rules:         return "Regeln"
        }
    }

    var icon: String {
        switch self {
        case .overview:      return "heart.text.square"
        case .subscriptions: return "repeat"
        case .calendar:      return "calendar"
        case .moneyAge:      return "hourglass"
        case .rules:         return "slider.horizontal.3"
        }
    }
}

/// State shared between the `DashboardPanel` host and the SwiftUI `DashboardView`. The host updates
/// the snapshot (transactions/balance) + the active tab when opening; the view reacts.
@MainActor
final class DashboardModel: ObservableObject {
    @Published var tab: DashboardTab
    @Published var transactions: [TransactionsResponse.Transaction]
    @Published var balance: Double
    /// Bank-Kontext DIESES Snapshots. Der Header liest den Slot aus dem Model —
    /// nicht live aus `MultibankingStore` — damit Logo/Name, Saldo und Transaktionen
    /// IMMER zum selben Konto gehören (sonst zeigt das offene Dashboard nach einem
    /// Slot-Wechsel Bank B im Kopf, rechnet aber weiter mit Bank A).
    @Published var slot: BankSlot?

    init(tab: DashboardTab = .overview,
         transactions: [TransactionsResponse.Transaction] = [],
         balance: Double = 0,
         slot: BankSlot? = nil) {
        self.tab = tab
        self.transactions = transactions
        self.balance = balance
        self.slot = slot
    }

    /// Setzt Bank-Kontext + Daten ATOMAR (ein Objekt-Update). Nutzung beim Öffnen
    /// und bei jedem Slot-Wechsel, solange das Panel offen ist.
    func apply(transactions: [TransactionsResponse.Transaction], balance: Double, slot: BankSlot?) {
        self.transactions = transactions
        self.balance = balance
        self.slot = slot
    }
}

/// The single overview surface — replaces the five separate sheets (Financial Health, Fixkosten,
/// Kalender, Abos, Geld-Alter) with one tabbed window.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    private func bankLogo(for slot: BankSlot) -> NSImage? {
        let brand = BankLogoAssets.resolve(displayName: slot.displayName, logoID: nil, iban: nil)
        BankLogoStore.shared.preload(brand: brand)
        return BankLogoStore.shared.image(for: brand)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                // Aktive Bank — Logo + Name vor den Tabs. Quelle = Model-Snapshot (atomar
                // mit Saldo/Transaktionen), NICHT der Live-Store.
                if let slot = model.slot {
                    HStack(spacing: 6) {
                        if let logo = bankLogo(for: slot) {
                            Image(nsImage: logo).resizable().scaledToFit()
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(slot.nickname?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? slot.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    Divider().frame(height: 16).padding(.trailing, 2)
                }
                ForEach(DashboardTab.allCases) { tab in
                    let active = model.tab == tab
                    Button { model.tab = tab } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon).font(.system(size: 12))
                            Text(tab.label).font(.system(size: 13, weight: active ? .semibold : .regular))
                        }
                        .foregroundColor(active ? .primary : .secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(active ? Color.cardBackground : Color.clear)
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(active ? Color.sbBorder : Color.clear, lineWidth: 1))
                                .shadow(color: .black.opacity(active ? 0.05 : 0), radius: 1, y: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.sbInputTint))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch model.tab {
                case .overview:
                    FinancialHealthScoreView(transactions: model.transactions, balance: model.balance, embedded: true)
                case .subscriptions:
                    SubscriptionsView(transactions: model.transactions, embedded: true)
                case .calendar:
                    CalendarHeatmapView(mode: .spending, embedded: true,
                                        injectedTransactions: model.transactions)
                        .id(model.slot?.id ?? "—")   // Re-Init bei Slot-Wechsel → frischer Snapshot
                case .moneyAge:
                    MoneyAgeSheet(transactions: model.transactions, embedded: true)
                case .rules:
                    RulesManagerView(embedded: true, transactions: model.transactions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.panelBackground)
    }
}
