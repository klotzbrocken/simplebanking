import AppKit
import SwiftUI

private struct SubscriptionMatch: Identifiable {
    let id: String
    let displayName: String
    let amount: Double
    let bookingDate: Date
    let cancellationEntry: CancellationLinks.Entry
}

private enum SubscriptionFinder {
    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func find(in transactions: [TransactionsResponse.Transaction], days: Int = 60, now: Date = Date()) -> [SubscriptionMatch] {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else {
            return []
        }

        var latestByService: [String: SubscriptionMatch] = [:]

        for transaction in transactions {
            let amount = transaction.parsedAmount
            guard amount < 0 else { continue }

            guard let dateString = transaction.bookingDate ?? transaction.valueDate,
                  let bookingDate = isoDateFormatter.date(from: dateString),
                  bookingDate >= cutoff
            else {
                continue
            }

            let resolvedMerchant = MerchantResolver.resolve(transaction: transaction).effectiveMerchant
            let rawMerchant = transaction.creditor?.name ?? transaction.debtor?.name ?? ""
            let remittance = (transaction.remittanceInformation ?? []).joined(separator: " ")
            guard let entry = CancellationLinks.find(merchant: resolvedMerchant, remittance: remittance)
                ?? CancellationLinks.find(merchant: rawMerchant, remittance: remittance)
            else {
                continue
            }

            let match = SubscriptionMatch(
                id: transaction.stableIdentifier,
                displayName: entry.displayName,
                amount: abs(amount),
                bookingDate: bookingDate,
                cancellationEntry: entry
            )

            if let existing = latestByService[entry.displayName] {
                if bookingDate > existing.bookingDate {
                    latestByService[entry.displayName] = match
                }
            } else {
                latestByService[entry.displayName] = match
            }
        }

        return latestByService.values.sorted { lhs, rhs in
            if lhs.bookingDate == rhs.bookingDate {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.bookingDate > rhs.bookingDate
        }
    }
}

struct SubscriptionsView: View {
    let transactions: [TransactionsResponse.Transaction]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var logoStore = SubscriptionLogoStore.shared

    private static let amountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private var subscriptions: [SubscriptionMatch] {
        SubscriptionFinder.find(in: transactions, days: 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Abos")
                        .font(.system(size: 22, weight: .bold))
                    Text("Erkannte Abos der letzten 60 Tage")
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

            if subscriptions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                    Text("Keine passenden Abos in den letzten 60 Tagen gefunden.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(subscriptions) { subscription in
                            SubscriptionRow(subscription: subscription)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(width: 420, height: 620)
        .background(Color.panelBackground)
        .onAppear {
            let names = subscriptions.map(\.displayName)
            logoStore.preloadInitial(displayNames: names)
        }
    }

    private static func amountText(_ value: Double) -> String {
        amountFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f €", value)
    }

    private static func dateText(_ date: Date) -> String {
        displayDateFormatter.string(from: date)
    }

    private struct SubscriptionRow: View {
        let subscription: SubscriptionMatch

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    SubscriptionLogo(displayName: subscription.displayName)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(subscription.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Letzte Buchung: \(SubscriptionsView.dateText(subscription.bookingDate))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(SubscriptionsView.amountText(subscription.amount))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                }

                HStack {
                    Spacer()
                    Button("Kündigen") {
                        NSWorkspace.shared.open(subscription.cancellationEntry.url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
            )
        }
    }

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
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
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
