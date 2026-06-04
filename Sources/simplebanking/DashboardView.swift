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

    init(tab: DashboardTab = .overview,
         transactions: [TransactionsResponse.Transaction] = [],
         balance: Double = 0) {
        self.tab = tab
        self.transactions = transactions
        self.balance = balance
    }
}

/// The single overview surface — replaces the five separate sheets (Financial Health, Fixkosten,
/// Kalender, Abos, Geld-Alter) with one tabbed window.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
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
                    CalendarHeatmapView(mode: .spending, embedded: true)
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
