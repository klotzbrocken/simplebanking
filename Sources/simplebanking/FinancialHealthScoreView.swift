import SwiftUI

private struct Ring: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat
    var shadow: Bool = false

    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            
            // Active ring
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [color.opacity(0.8), color]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * progress)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: shadow ? color.opacity(0.3) : .clear, radius: 5, x: 0, y: 0)
        }
    }
}

struct FinancialHealthScoreView: View {
    let transactions: [TransactionsResponse.Transaction]
    let salaryDay: Int
    let dispoLimit: Int
    let targetBuffer: Int
    let targetSavingsRate: Int
    var stabilityOutlierMultiplier: Double = 3.0
    var coverageRatioWeight: Double = 0.6
    var fixedCostWarningRatio: Double = 0.70
    
    @Environment(\.dismiss) private var dismiss
    @State private var animProgress: Double = 0
    @State private var calculatedScore: FinancialHealthScore?
    
    private var score: FinancialHealthScore {
        calculatedScore ?? FinancialHealthScore(
            overall: 0, incomeCoverage: 0, savingsRate: 0, stability: 0,
            daysInDispo: 0, avgDispoUsage: 0, maxDispoUsage: 0, dispoUtilization: 0,
            savingsTransferAmount: 0,
            fixedCostRatio: 0, variableExpenseRatio: 0, actualSavingsRatio: 0
        )
    }
    
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private func formatCurrency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value)) €"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aktivität")
                            .font(.system(size: 24, weight: .bold))
                        Text("Finanzielle Gesundheit")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal)

                // The Rings
                ZStack {
                    Ring(progress: score.incomeCoverage * animProgress, color: .green, lineWidth: 28, shadow: true)
                        .frame(width: 240, height: 240)
                    Ring(progress: score.savingsRate * animProgress, color: .cyan, lineWidth: 28, shadow: true)
                        .frame(width: 182, height: 182)
                    Ring(progress: score.stability * animProgress, color: .expenseRed, lineWidth: 28, shadow: true)
                        .frame(width: 124, height: 124)
                }
                .padding(.vertical, 10)

                // Legend / Info
                VStack(alignment: .leading, spacing: 16) {
                    InfoRow(color: .green, title: "Einnahmen", text: "Deckung deiner monatlichen Kosten (Puffer: \(targetBuffer)€).", value: "\(Int(score.incomeCoverage * 100))%")
                    InfoRow(color: .cyan, title: "Sparrate", text: "Effizienz deines Cashflows (Ziel: \(targetSavingsRate)% Überschuss).", value: "\(Int(score.savingsRate * 100))%")
                    InfoRow(color: .expenseRed, title: "Stabilität", text: "Nur variable Ausgaben, keine Fixkosten.", value: "\(Int(score.stability * 100))%")
                }
                .padding(.horizontal)
                
                // 50/30/20 Budgetregel
                Divider()
                    .background(Color.secondary.opacity(0.3))
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "chart.pie.fill")
                            .foregroundColor(.purple)
                        Text("Budgetverteilung")
                            .font(.system(size: 18, weight: .bold))
                    }
                    
                    // 50/30/20 Balken
                    VStack(spacing: 12) {
                        BudgetBarRow(
                            title: "Fixkosten",
                            actual: score.fixedCostRatio,
                            target: 0.50,
                            color: .orange
                        )
                        BudgetBarRow(
                            title: "Variable Ausgaben",
                            actual: score.variableExpenseRatio,
                            target: 0.30,
                            color: .blue
                        )
                        BudgetBarRow(
                            title: "Sparen",
                            actual: score.actualSavingsRatio,
                            target: Double(targetSavingsRate) / 100.0,
                            color: .green
                        )
                    }
                    
                    // Info-Text
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                        Text("Faustregel: 50% Fixkosten, 30% Freizeit, 20% Sparen")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                
                // Dispo-Statistik (nur wenn konfiguriert oder Dispo genutzt)
                if dispoLimit > 0 || score.daysInDispo > 0 {
                    Divider()
                        .background(Color.secondary.opacity(0.3))
                        .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Dispositionskredit")
                                .font(.system(size: 18, weight: .bold))
                        }
                        
                        HStack(spacing: 20) {
                            DispoStatBox(
                                title: "Tage im Minus",
                                value: "\(score.daysInDispo)",
                                color: score.daysInDispo > 10 ? .red : (score.daysInDispo > 5 ? .orange : .green)
                            )
                            DispoStatBox(
                                title: "Ø Nutzung",
                                value: formatCurrency(score.avgDispoUsage),
                                color: .orange
                            )
                            DispoStatBox(
                                title: "Maximum",
                                value: formatCurrency(score.maxDispoUsage),
                                color: .red
                            )
                        }
                        
                        if dispoLimit > 0 {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Dispo-Auslastung")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(Int(score.dispoUtilization * 100))% von \(dispoLimit) €")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.secondary.opacity(0.2))
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(score.dispoUtilization > 0.8 ? Color.red : (score.dispoUtilization > 0.5 ? Color.orange : Color.green))
                                            .frame(width: geo.size.width * CGFloat(score.dispoUtilization * animProgress))
                                    }
                                }
                                .frame(height: 8)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                
                Spacer(minLength: 20)
            }
            .padding(.top, 24)
        }
        .frame(width: 420, height: 680)
        .background(Color(white: 0.05).edgesIgnoringSafeArea(.all)) // Black background for "Activity" look
        .preferredColorScheme(.dark)
        .onAppear {
            // Berechne Score einmal beim Erscheinen
            calculatedScore = FinancialHealthScorer.score(
                transactions: transactions,
                salaryDay: salaryDay,
                dispoLimit: dispoLimit,
                targetBuffer: targetBuffer,
                targetSavingsRate: targetSavingsRate,
                stabilityOutlierMultiplier: stabilityOutlierMultiplier,
                coverageRatioWeight: coverageRatioWeight,
                fixedCostWarningRatio: fixedCostWarningRatio
            )
            // Starte Animation nach kurzer Verzögerung
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 1.5, dampingFraction: 0.7, blendDuration: 0)) {
                    animProgress = 1.0
                }
            }
        }
    }
}

private struct DispoStatBox: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct InfoRow: View {
    let color: Color
    let title: String
    let text: String
    var value: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(color)
                    Spacer()
                    if let value = value {
                        Text(value)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(color)
                    }
                }
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct BudgetBarRow: View {
    let title: String
    let actual: Double
    let target: Double
    let color: Color
    
    private var status: (text: String, color: Color) {
        let diff = actual - target
        if abs(diff) < 0.05 {
            return ("✓", .green)
        } else if actual > target {
            return ("↑", actual > target * 1.5 ? .red : .orange)
        } else {
            return ("↓", .green)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(Int(actual * 100))%")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)
                Text("(Ziel: \(Int(target * 100))%)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(status.text)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(status.color)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                    
                    // Target marker
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat(min(target, 1.0)) - 1)
                    
                    // Actual bar
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(min(actual, 1.0)))
                }
            }
            .frame(height: 8)
        }
    }
}
