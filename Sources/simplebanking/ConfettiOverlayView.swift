import SwiftUI

enum ConfettiEffect: Int, CaseIterable {
    case money = 2
    case sparkle = 3
    case fire = 4

    static var allCases: [ConfettiEffect] {
        [.money, .sparkle, .fire]
    }

    var label: String {
        switch self {
        case .money:
            return L10n.t("Money Mode", "Money Mode")
        case .sparkle:
            return L10n.t("Glitzer", "Sparkle")
        case .fire:
            return L10n.t("Feuer", "Fire")
        }
    }
}

struct ConfettiOverlayView: View {
    let trigger: Int
    let effectRawValue: Int

    @State private var particles: [ConfettiParticle] = []
    @State private var animateBurst = false
    @State private var lastTrigger = 0
    @State private var activeBurstToken = 0

    private static let confettiPalette: [Color] = [
        .red,
        .orange,
        .yellow,
        .green,
        .mint,
        .blue,
        .cyan,
        .pink,
    ]

    private static let moneyPalette: [Color] = [
        Color(red: 0.16, green: 0.48, blue: 0.22),
        Color(red: 0.27, green: 0.67, blue: 0.34),
        Color(red: 0.59, green: 0.76, blue: 0.22),
        Color(red: 0.84, green: 0.72, blue: 0.26),
    ]

    private var selectedEffect: ConfettiEffect {
        if let exact = ConfettiEffect(rawValue: effectRawValue) {
            return exact
        }
        // Legacy mapping: old Burst/Rain values fall back to Sparkle.
        if effectRawValue == 0 || effectRawValue == 1 {
            return .sparkle
        }
        return .money
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(particles) { particle in
                    ConfettiPiece(particle: particle)
                        .position(
                            x: animateBurst ? particle.endX : particle.startX,
                            y: animateBurst ? particle.endY : particle.startY
                        )
                        .rotationEffect(.degrees(animateBurst ? particle.rotation : 0))
                        .scaleEffect(animateBurst ? particle.endScale : particle.startScale)
                        .opacity(animateBurst ? particle.endOpacity : particle.startOpacity)
                        .animation(
                            .timingCurve(0.20, 0.85, 0.20, 1.00, duration: particle.duration)
                                .delay(particle.delay),
                            value: animateBurst
                        )
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .onAppear {
                guard trigger != lastTrigger else { return }
                lastTrigger = trigger
                spawnConfetti(in: proxy.size)
            }
            .onChange(of: trigger) { newValue in
                guard newValue != lastTrigger else { return }
                lastTrigger = newValue
                spawnConfetti(in: proxy.size)
            }
        }
        .allowsHitTesting(false)
    }

    private func spawnConfetti(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        activeBurstToken += 1
        let burstToken = activeBurstToken

        switch selectedEffect {
        case .money:
            particles = moneyParticles(in: size)
        case .sparkle:
            particles = sparkleParticles(in: size)
        case .fire:
            particles = fireParticles(in: size)
        }

        animateBurst = false
        DispatchQueue.main.async {
            animateBurst = true
        }

        let maxDuration = particles.map { $0.delay + $0.duration }.max() ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration + 0.25) {
            guard activeBurstToken == burstToken else { return }
            particles = []
            animateBurst = false
        }
    }

    private func moneyParticles(in size: CGSize) -> [ConfettiParticle] {
        (0..<44).map { _ in
            let x = CGFloat.random(in: 16...(size.width - 16))
            return ConfettiParticle(
                startX: x,
                startY: CGFloat.random(in: -100 ... -28),
                endX: x + CGFloat.random(in: -70...70),
                endY: size.height + 90,
                size: CGFloat.random(in: 15...22),
                delay: Double.random(in: 0...0.28),
                duration: Double.random(in: 1.9...3.2),
                rotation: Double.random(in: -25...25),
                color: Self.moneyPalette.randomElement() ?? .green,
                piece: .money,
                startOpacity: 1.0,
                endOpacity: 0.05,
                startScale: 0.92,
                endScale: 1.12
            )
        }
    }

    private func sparkleParticles(in size: CGSize) -> [ConfettiParticle] {
        // Keep sparkle focused around the top card area (balance card), not center.
        (0..<56).map { _ in
            let x = CGFloat.random(in: size.width * 0.08 ... size.width * 0.92)
            let y = CGFloat.random(in: size.height * 0.06 ... size.height * 0.32)
            return ConfettiParticle(
                startX: x,
                startY: y,
                endX: x + CGFloat.random(in: -18...18),
                endY: y + CGFloat.random(in: -18...18),
                size: CGFloat.random(in: 8...16),
                delay: Double.random(in: 0...0.34),
                duration: Double.random(in: 0.7...1.3),
                rotation: Double.random(in: 20...240),
                color: Self.confettiPalette.randomElement() ?? .yellow,
                piece: .star,
                startOpacity: 1.0,
                endOpacity: 0.0,
                startScale: 0.35,
                endScale: 1.2
            )
        }
    }

    private func fireParticles(in size: CGSize) -> [ConfettiParticle] {
        let baseY = size.height * 0.74
        return (0..<48).map { _ in
            let startX = CGFloat.random(in: size.width * 0.18 ... size.width * 0.82)
            let startY = CGFloat.random(in: baseY ... min(size.height - 20, baseY + 70))
            let endY = CGFloat.random(in: size.height * 0.32 ... size.height * 0.56)
            let flameColor = [Color.red, Color.orange, Color.yellow].randomElement() ?? .orange
            return ConfettiParticle(
                startX: startX,
                startY: startY,
                endX: startX + CGFloat.random(in: -40...40),
                endY: endY,
                size: CGFloat.random(in: 12...22),
                delay: Double.random(in: 0...0.22),
                duration: Double.random(in: 0.8...1.55),
                rotation: Double.random(in: -14...14),
                color: flameColor,
                piece: .flame,
                startOpacity: 0.95,
                endOpacity: 0.0,
                startScale: 0.85,
                endScale: 1.32
            )
        }
    }
}

private struct ConfettiParticle: Identifiable {
    let id = UUID()
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let size: CGFloat
    let delay: Double
    let duration: Double
    let rotation: Double
    let color: Color
    let piece: ConfettiPieceKind
    let startOpacity: Double
    let endOpacity: Double
    let startScale: CGFloat
    let endScale: CGFloat
}

private enum ConfettiPieceKind {
    case shape(Int)
    case star
    case money
    case flame
}

private struct ConfettiPiece: View {
    let particle: ConfettiParticle

    var body: some View {
        Group {
            switch particle.piece {
            case .shape(let shape):
                switch shape {
                case 0:
                    Circle()
                        .frame(width: particle.size, height: particle.size)
                case 1:
                    Capsule(style: .continuous)
                        .frame(width: particle.size * 0.62, height: particle.size * 1.62)
                default:
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .frame(width: particle.size * 0.76, height: particle.size * 1.44)
                }
            case .star:
                StarShape(points: 5)
                    .frame(width: particle.size, height: particle.size)
            case .money:
                Text("€")
                    .font(.system(size: particle.size, weight: .heavy, design: .rounded))
            case .flame:
                Image(systemName: "flame.fill")
                    .font(.system(size: particle.size, weight: .heavy))
            }
        }
        .foregroundStyle(particle.color)
        .shadow(color: particle.color.opacity(0.35), radius: 1.4, x: 0, y: 1)
    }
}

private struct StarShape: Shape {
    let points: Int

    func path(in rect: CGRect) -> Path {
        let safePoints = max(points, 3)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) * 0.5
        let inner = outer * 0.44

        var path = Path()
        var angle = -Double.pi / 2
        let step = Double.pi / Double(safePoints)

        let start = CGPoint(
            x: center.x + cos(angle) * outer,
            y: center.y + sin(angle) * outer
        )
        path.move(to: start)

        for i in 1..<(safePoints * 2) {
            angle += step
            let radius = i.isMultiple(of: 2) ? outer : inner
            path.addLine(to: CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            ))
        }

        path.closeSubpath()
        return path
    }
}
