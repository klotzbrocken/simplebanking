import SwiftUI

extension View {
    @ViewBuilder
    func rippleEffect(trigger: Int, defaultOrigin: CGPoint) -> some View {
        if #available(macOS 14.0, *) {
            self.modifier(RippleEffect(trigger: trigger, defaultOrigin: defaultOrigin))
        } else {
            self
        }
    }
}

/// Water-ripple distortion. Increment `trigger` to fire; captures tap location as origin.
@available(macOS 14.0, *)
struct RippleEffect: ViewModifier {
    /// External trigger (e.g. new transactions). Fires ripple from `defaultOrigin`.
    var trigger: Int
    /// Center of the view — used when trigger fires (not a tap).
    var defaultOrigin: CGPoint

    @State private var rippleStart: Date? = nil
    @State private var origin: CGPoint = .zero

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: rippleStart == nil)) { tl in
            let elapsed = rippleStart.map { tl.date.timeIntervalSince($0) } ?? 0.0
            content
                .layerEffect(
                    ShaderLibrary.ripple(
                        .float2(origin),
                        .float(elapsed),
                        .float(12),    // amplitude  — pixel displacement
                        .float(10),    // frequency  — waves per second (fewer, wider waves)
                        .float(6),     // decay      — wave fade rate (slower fade)
                        .float(650)    // speed      — propagation (points/s, slow travel)
                    ),
                    maxSampleOffset: CGSize(width: 12, height: 12),
                    isEnabled: elapsed > 0 && elapsed < 1.5
                )
                .onTapGesture { location in
                    origin = location
                    rippleStart = Date()
                }
        }
        .onAppear {
            origin = defaultOrigin
            if trigger > 0 { rippleStart = Date() }
        }
        .onChange(of: trigger) { _, _ in
            origin = defaultOrigin
            rippleStart = Date()
        }
    }
}
