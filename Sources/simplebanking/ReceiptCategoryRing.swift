import SwiftUI
import AppKit

/// Ein Segment des eBon-Kategorien-Rings.
struct ReceiptRingSegment: Equatable {
    var label: String
    var fraction: Double   // 0…1, bereits auf die Summe der Top-Segmente normiert
    var colorHex: String
}

/// Ring für eBon-Slots (REWE/dm): statt des Saldo-Greenrings zeigt er die
/// **Top-4-Warengruppen des LETZTEN Einkaufs** als bis zu 4 farbige Segmente.
/// Mitte = Datum des letzten Bons. 72×72 wie `GreenZoneRing` (Größen-Invariante).
struct ReceiptCategoryRing: View {
    let segments: [ReceiptRingSegment]
    let date: Date?

    /// 4er-Palette (Tableau-artig, gut unterscheidbar).
    static let palette: [String] = ["4E79A7", "F28E2B", "59A14F", "B07AA1"]

    private static let gap = 0.010   // kleine Lücke zwischen Segmenten

    /// Kategorie-Label eines Postens je nach eBon-Quelle.
    static func categoryLabel(for item: ReweLineItem, source: SlotSource) -> String {
        switch source {
        case .dm: return DMItemCategorizer.category(for: item).rawValue
        case .amazon: return AmazonItemCategorizer.category(for: item).rawValue
        default: return ReweItemCategorizer.category(for: item).rawValue
        }
    }

    /// Baut die Top-4-Segmente aus den Posten des letzten Bons. Gewichtung nach
    /// Preis (Cent); fehlen Preise (dm liefert evtl. 0), nach Stückzahl.
    static func segments(forItems items: [ReweLineItem], source: SlotSource) -> [ReceiptRingSegment] {
        guard !items.isEmpty else { return [] }
        var cents: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for it in items {
            let label = categoryLabel(for: it, source: source)
            cents[label, default: 0] += it.totalCents
            counts[label, default: 0] += 1
        }
        let useCounts = cents.values.reduce(0, +) == 0
        let weights = useCounts ? counts : cents
        let top = weights.sorted { $0.value > $1.value }.prefix(4)
        let sum = max(1, top.reduce(0) { $0 + $1.value })
        return top.enumerated().map { idx, entry in
            ReceiptRingSegment(label: entry.key,
                               fraction: Double(entry.value) / Double(sum),
                               colorHex: palette[idx % palette.count])
        }
    }

    /// BTX-Theme: statt des Kreisrings eine Mosaik-Segmentleiste — die Warengruppen
    /// als proportionale, farbige Blöcke in einer Zeile (gleiche 72×72-Fläche).
    private var btxSegmentBar: some View {
        VStack(spacing: 5) {
            if let date {
                Text(String(format: "%02d", Calendar.current.component(.day, from: date)))
                    .font(ThemeFonts.flyoutHeading(size: 22, weight: .bold)).monospacedDigit()
                    .foregroundColor(.themedInk)
                Text(monthAbbrev(date).uppercased())
                    .font(ThemeFonts.flyoutBody(size: 11))
                    .foregroundColor(Color.themedInk.opacity(0.8))
            }
            HStack(spacing: 1) {
                if segments.isEmpty {
                    Rectangle().fill(Color.themedInk.opacity(0.18)).frame(width: 60, height: 8)
                } else {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle()
                            .fill(Color(hex: seg.colorHex) ?? .gray)
                            .frame(width: max(3, 60 * seg.fraction), height: 8)
                    }
                }
            }
        }
        .frame(width: 72, height: 72)
    }

    var body: some View {
        Group {
            if ThemeChrome.lofi {
                // Blockleiste statt Ring — siehe GreenZoneRing.
                btxSegmentBar
            } else {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.12), lineWidth: 7)
                    ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                        Circle()
                            .trim(from: arc.start, to: arc.end)
                            .stroke(Color(hex: arc.hex) ?? .gray,
                                    style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    }
                    center
                }
            }
        }
        .frame(width: 72, height: 72)
        .help(helpText)
    }

    /// Tooltip beim Mouse-Over: Kategorien des letzten Bons in Ring-Reihenfolge
    /// (größtes Segment zuerst) mit Prozent-Anteil.
    private var helpText: String {
        guard !segments.isEmpty else { return "" }
        return segments
            .map { "\($0.label) · \(Int(($0.fraction * 100).rounded())) %" }
            .joined(separator: "\n")
    }

    @ViewBuilder private var center: some View {
        if let date {
            VStack(spacing: 1) {
                Text(String(format: "%02d", Calendar.current.component(.day, from: date)))
                    .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundColor(.primary)
                Text(monthAbbrev(date).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        } else {
            Image(systemName: "cart.fill").font(.system(size: 18)).foregroundColor(.secondary)
        }
    }

    /// Kumulierte Start/Ende-Positionen (0…1) inkl. kleiner Lücke pro Segment.
    private var arcs: [(start: Double, end: Double, hex: String)] {
        var out: [(Double, Double, String)] = []
        var cursor = 0.0
        let multi = segments.count > 1
        for seg in segments {
            let end = cursor + seg.fraction
            let g = multi ? Self.gap : 0
            out.append((min(1, cursor + g / 2), max(0, end - g / 2), seg.colorHex))
            cursor = end
        }
        return out
    }

    private func monthAbbrev(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "de_DE")
        df.dateFormat = "MMM"
        return df.string(from: date)
    }
}
