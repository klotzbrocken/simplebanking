import SwiftUI

// MARK: - MMI Ring View

struct MMIRingView: View {
    let components: MMIComponents
    var size: CGFloat = 148
    var lineWidth: CGFloat = 16
    /// Animate from 0→1 on appear
    var animProgress: Double = 1.0

    private let gapDeg: Double = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.1), lineWidth: lineWidth)

            let p = components.ringProportions
            let available = (360.0 - gapDeg * 3) * animProgress

            Group {
                if p.expenses > 0.01 {
                    MMIRingArc(
                        start: 0,
                        end: p.expenses * available,
                        lineWidth: lineWidth
                    )
                    .stroke(MMIColors.expense,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
                if p.savings > 0.01 {
                    MMIRingArc(
                        start: p.expenses * available + gapDeg * animProgress,
                        end: (p.expenses + p.savings) * available + gapDeg * animProgress,
                        lineWidth: lineWidth
                    )
                    .stroke(MMIColors.savings,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
                if p.liquid > 0.01 {
                    MMIRingArc(
                        start: (p.expenses + p.savings) * available + gapDeg * 2 * animProgress,
                        end: (p.expenses + p.savings + p.liquid) * available + gapDeg * 2 * animProgress,
                        lineWidth: lineWidth
                    )
                    .stroke(MMIColors.liquid,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }

            // Zentrum-Hierarchie
            VStack(spacing: 1) {
                Text("MMI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(components.rating.rawValue)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(components.rating.color)
                Text(String(format: "%.2f", components.score))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Ring Arc Shape

struct MMIRingArc: Shape {
    var start: Double
    var end: Double
    var lineWidth: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = (min(rect.width, rect.height) - lineWidth) / 2
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                 radius: r,
                 startAngle: .degrees(start - 90),
                 endAngle:   .degrees(end   - 90),
                 clockwise: false)
        return p
    }
}
