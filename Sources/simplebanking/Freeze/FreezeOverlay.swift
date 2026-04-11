import SwiftUI

// MARK: - Freeze Overlay (sticky active-filter banner)

struct FreezeOverlay: View {
    let items: [FreezeItem]
    @Binding var excludedCategories: Set<FreezeCategory>
    let onDeactivate: () -> Void
    @State private var isExpanded: Bool = true

    private var activeTotal: Double {
        FreezeAnalyzer.monthlyTotal(items: items, excludedCategories: excludedCategories)
    }

    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 0
        return f
    }()

    private func formatEur(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value)) €"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (tap to collapse/expand)
            HStack(spacing: 8) {
                Image(systemName: "snowflake")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.teal)
                Text("Freeze aktiv")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.teal)
                if activeTotal > 0 {
                    Text("· \(formatEur(activeTotal))/Mo.")
                        .font(.system(size: 13))
                        .foregroundColor(Color.teal.opacity(0.85))
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                Button(action: onDeactivate) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            }

            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)
                    .opacity(0.4)

                // 3 category toggles — Abos / Verträge / Sparen
                VStack(spacing: 0) {
                    ForEach(FreezeCategory.allCases, id: \.self) { cat in
                        categoryRow(cat)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(red: 0.12, green: 0.19, blue: 0.27, alpha: 1)  // dark
                : NSColor(red: 0.918, green: 0.945, blue: 0.973, alpha: 1)  // #EAF1F8
        }))
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.cyan.opacity(0.2))
        }
    }

    @ViewBuilder
    private func categoryRow(_ cat: FreezeCategory) -> some View {
        let isExcluded = excludedCategories.contains(cat)
        let total = FreezeAnalyzer.categoryTotal(items: items, category: cat)

        HStack(spacing: 10) {
            Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(isExcluded ? Color(NSColor.tertiaryLabelColor) : Color.teal)

            Image(systemName: cat.icon)
                .font(.system(size: 12))
                .foregroundColor(isExcluded ? Color(NSColor.tertiaryLabelColor) : Color.teal.opacity(0.8))
                .frame(width: 16)

            Text(cat.rawValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isExcluded ? .secondary : .primary)

            Spacer()

            Text(total > 0 ? "\(formatEur(total))/Mo." : "–")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isExcluded ? Color(NSColor.secondaryLabelColor) : Color.teal)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.12)) {
                if isExcluded {
                    excludedCategories.remove(cat)
                } else {
                    excludedCategories.insert(cat)
                }
            }
        }
    }
}
