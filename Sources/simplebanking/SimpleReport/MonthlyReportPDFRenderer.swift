import AppKit
import CoreText

// MARK: - MonthlyReportPDFRenderer

struct MonthlyReportPDFRenderer {

    func render(report: MonthlyReport) -> Data {
        loadFonts()

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var mediaBox = CGRect(x: 0, y: 0, width: R.pageWidth, height: R.pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        // Split allTransactions into pages of ~55 rows
        let txs = report.allTransactions
        let rowsPerPage = 55
        let extraPageCount = txs.isEmpty ? 0 : Int(ceil(Double(txs.count) / Double(rowsPerPage)))
        let totalPages = 2 + extraPageCount

        // Page 1
        ctx.beginPDFPage(nil)
        drawPage1(ctx: ctx, report: report, totalPages: totalPages)
        ctx.endPDFPage()

        // Page 2
        ctx.beginPDFPage(nil)
        drawPage2(ctx: ctx, report: report, totalPages: totalPages)
        ctx.endPDFPage()

        // Page 3+
        for pageIdx in 0..<extraPageCount {
            let start = pageIdx * rowsPerPage
            let end   = min(start + rowsPerPage, txs.count)
            let slice = Array(txs[start..<end])
            ctx.beginPDFPage(nil)
            drawTxListPage(ctx: ctx, report: report, rows: slice,
                           pageNum: 3 + pageIdx, totalPages: totalPages)
            ctx.endPDFPage()
        }

        ctx.closePDF()
        return data as Data
    }

    // MARK: - Font loading

    private func loadFonts() {
        for name in ["SpaceMono-Regular", "SpaceMono-Bold"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

// MARK: - Design tokens

private enum R {
    static let pageWidth:  CGFloat = 595
    static let pageHeight: CGFloat = 842
    static let marginL:    CGFloat = 56
    static let marginR:    CGFloat = 56
    static let contentW:   CGFloat = pageWidth - marginL - marginR

    static let bg         = CGColor(srgbRed: 0.929, green: 0.910, blue: 0.863, alpha: 1) // #EDE8DC
    static let red        = CGColor(srgbRed: 0.800, green: 0.067, blue: 0.067, alpha: 1)
    static let green      = CGColor(srgbRed: 0.165, green: 0.478, blue: 0.310, alpha: 1)
    static let teal       = CGColor(srgbRed: 0.102, green: 0.439, blue: 0.439, alpha: 1)
    static let barTeal    = CGColor(srgbRed: 0.353, green: 0.541, blue: 0.541, alpha: 1)
    static let labelGray  = CGColor(srgbRed: 0.40,  green: 0.40,  blue: 0.40,  alpha: 1)
    static let ruleGray   = CGColor(srgbRed: 0.70,  green: 0.68,  blue: 0.63,  alpha: 1)
    static let textBlack  = CGColor(srgbRed: 0.12,  green: 0.12,  blue: 0.12,  alpha: 1)
    static let kpiBox     = CGColor(srgbRed: 0.80,  green: 0.78,  blue: 0.74,  alpha: 0.5)

    static let rainbow: [CGColor] = [
        CGColor(srgbRed: 0.902, green: 0.224, blue: 0.275, alpha: 1),
        CGColor(srgbRed: 0.957, green: 0.635, blue: 0.380, alpha: 1),
        CGColor(srgbRed: 0.914, green: 0.769, blue: 0.412, alpha: 1),
        CGColor(srgbRed: 0.322, green: 0.718, blue: 0.533, alpha: 1),
        CGColor(srgbRed: 0.165, green: 0.616, blue: 0.561, alpha: 1),
        CGColor(srgbRed: 0.284, green: 0.584, blue: 0.937, alpha: 1),
        CGColor(srgbRed: 0.608, green: 0.365, blue: 0.898, alpha: 1),
    ]

    static func mono(_ size: CGFloat, bold: Bool = false) -> CTFont {
        let name = (bold ? "SpaceMono-Bold" : "SpaceMono-Regular") as CFString
        let font = CTFontCreateWithName(name, size, nil)
        // Check if we got the right font (not a fallback)
        let resultName = CTFontCopyPostScriptName(font) as String
        if resultName.lowercased().contains("spacemono") { return font }
        // Fallback to Courier
        let fallback = (bold ? "Courier-Bold" : "Courier") as CFString
        return CTFontCreateWithName(fallback, size, nil)
    }

    static func sans(_ size: CGFloat, bold: Bool = false) -> CTFont {
        let name = (bold ? ".AppleSystemUIFontBold" : ".AppleSystemUIFont") as CFString
        return CTFontCreateWithName(name, size, nil)
    }
}

// MARK: - CGContext drawing helpers

private func fillRect(_ ctx: CGContext, _ rect: CGRect, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(rect)
}

private func strokeRect(_ ctx: CGContext, _ rect: CGRect, _ color: CGColor, _ lw: CGFloat = 0.5) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lw)
    ctx.stroke(rect)
}

private func drawLine(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat = 0.5) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.beginPath()
    ctx.move(to: from)
    ctx.addLine(to: to)
    ctx.drawPath(using: .stroke)
}

/// Draw text. `baseline` is y in CG coordinates (from bottom of page).
@discardableResult
private func drawText(
    _ ctx: CGContext,
    _ text: String,
    x: CGFloat,
    baseline: CGFloat,
    font: CTFont,
    color: CGColor,
    maxWidth: CGFloat = 9999,
    align: NSTextAlignment = .left
) -> CGFloat {
    let attrStr = NSAttributedString(string: text, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: color
    ])
    let line = CTLineCreateWithAttributedString(attrStr)
    let lineW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let drawX: CGFloat
    switch align {
    case .right:  drawX = x - min(lineW, maxWidth)
    case .center: drawX = x - min(lineW, maxWidth) / 2
    default:      drawX = x
    }
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: drawX, y: baseline)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    return min(lineW, maxWidth)
}

private func drawRainbow(_ ctx: CGContext, y: CGFloat) {
    let segW = R.pageWidth / CGFloat(R.rainbow.count)
    for (i, color) in R.rainbow.enumerated() {
        fillRect(ctx, CGRect(x: CGFloat(i) * segW, y: y, width: segW, height: 6), color)
    }
}

private func drawRule(_ ctx: CGContext, y: CGFloat) {
    drawLine(ctx, from: CGPoint(x: R.marginL, y: y),
             to: CGPoint(x: R.pageWidth - R.marginR, y: y), color: R.ruleGray)
}

private func drawSectionHeader(_ ctx: CGContext, _ title: String, x: CGFloat, baseline: CGFloat) {
    drawText(ctx, "▸ ", x: x, baseline: baseline, font: R.sans(13, bold: true), color: R.red)
    let triW = CGFloat(CTLineGetTypographicBounds(
        CTLineCreateWithAttributedString(NSAttributedString(string: "▸ ", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: R.sans(13, bold: true)
        ])), nil, nil, nil))
    drawText(ctx, title, x: x + triW, baseline: baseline, font: R.sans(13, bold: true), color: R.textBlack)
}

private func currencyFmt() -> NumberFormatter {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.numberStyle = .currency
    f.currencyCode = "EUR"
    f.maximumFractionDigits = 2
    return f
}
private let fmt = currencyFmt()
private func fmtAmt(_ d: Decimal) -> String {
    fmt.string(from: d as NSDecimalNumber) ?? "\(d) €"
}

// MARK: - Page 1

private func drawPage1(ctx: CGContext, report: MonthlyReport, totalPages: Int) {
    fillRect(ctx, CGRect(x: 0, y: 0, width: R.pageWidth, height: R.pageHeight), R.bg)

    // Top stripe
    drawRainbow(ctx, y: R.pageHeight - 10)

    // Logo row  (baseline ≈ 808)
    let logoY: CGFloat = 808
    drawText(ctx, "simple.report", x: R.marginL, baseline: logoY,
             font: R.mono(15, bold: true), color: R.red)
    drawText(ctx, "■  MONATSÜBERSICHT",
             x: R.pageWidth - R.marginR, baseline: logoY,
             font: R.mono(8), color: R.labelGray, align: .right)

    // Rule
    drawRule(ctx, y: logoY - 8)

    // Month + account  (baseline ≈ 784)
    let monthY: CGFloat = 784
    drawText(ctx, report.header.monthTitle,
             x: R.marginL, baseline: monthY,
             font: R.sans(16, bold: true), color: R.textBlack)
    let acctLine1 = report.header.bankName
    let acctLine2 = report.header.maskedIBAN ?? ""
    drawText(ctx, acctLine1,
             x: R.pageWidth - R.marginR, baseline: monthY,
             font: R.mono(8), color: R.labelGray, align: .right)
    if !acctLine2.isEmpty {
        drawText(ctx, acctLine2,
                 x: R.pageWidth - R.marginR, baseline: monthY - 13,
                 font: R.mono(8), color: R.labelGray, align: .right)
    }

    // Rule
    drawRule(ctx, y: monthY - 22)

    // KPI boxes  (top of boxes at ≈ 742)
    let kpiTop: CGFloat = 742
    drawKPIRow(ctx: ctx, top: kpiTop, summary: report.summary)

    // Zusammenfassung
    var y: CGFloat = kpiTop - 68
    drawSectionHeader(ctx, "Zusammenfassung", x: R.marginL, baseline: y)
    y -= 20
    y = drawNarrative(ctx: ctx, baseline: y, narrative: report.narrative)
    y -= 18

    // Cashflow
    drawSectionHeader(ctx, "Cashflow", x: R.marginL, baseline: y)
    y -= 20
    y = drawCashflow(ctx: ctx, baseline: y, cashflow: report.cashflow)
    y -= 18

    // Auffälligkeiten
    drawSectionHeader(ctx, "Auffälligkeiten", x: R.marginL, baseline: y)
    y -= 20
    drawInsights(ctx: ctx, baseline: y, insights: report.insights)

    // Footer
    drawRainbow(ctx, y: 10)
    drawText(ctx, "simple.report", x: R.marginL, baseline: 20, font: R.mono(7.5), color: R.labelGray)
    drawText(ctx, "SEITE 1 / \(totalPages)", x: R.pageWidth - R.marginR, baseline: 20,
             font: R.mono(7.5), color: R.labelGray, align: .right)
}

private func drawKPIRow(ctx: CGContext, top: CGFloat, summary: ReportSummaryData) {
    let boxW  = R.contentW / 4
    let boxH: CGFloat = 52

    let labels = ["EINNAHMEN", "AUSGABEN", "SALDO", "BUCHUNGEN"]
    let values = [fmtAmt(summary.incomeTotal), fmtAmt(abs(summary.expenseTotal)),
                  fmtAmt(abs(summary.netTotal)), "\(summary.transactionCount)"]
    let colors: [CGColor] = [
        R.green, R.red,
        summary.netTotal >= 0 ? R.teal : R.red,
        R.textBlack
    ]
    for i in 0..<4 {
        let bx = R.marginL + CGFloat(i) * boxW
        let boxRect = CGRect(x: bx, y: top - boxH, width: boxW - 1, height: boxH)
        fillRect(ctx, boxRect, R.kpiBox)
        strokeRect(ctx, boxRect, R.ruleGray)
        drawText(ctx, labels[i], x: bx + 8, baseline: top - 16, font: R.mono(7.5), color: R.labelGray)
        let valFont = i == 3 ? R.mono(18, bold: true) : R.mono(13, bold: true)
        drawText(ctx, values[i], x: bx + 8, baseline: top - 40, font: valFont, color: colors[i], maxWidth: boxW - 16)
    }
}

@discardableResult
private func drawNarrative(ctx: CGContext, baseline: CGFloat, narrative: NarrativeData) -> CGFloat {
    var y = baseline
    let lineH: CGFloat = 14
    let totalH = CGFloat(narrative.lines.count) * lineH + 4

    // Left border
    fillRect(ctx, CGRect(x: R.marginL + 1, y: y - totalH, width: 1.5, height: totalH), R.ruleGray)

    for line in narrative.lines {
        drawText(ctx, line, x: R.marginL + 12, baseline: y,
                 font: R.mono(9), color: R.textBlack, maxWidth: R.contentW - 14)
        y -= lineH
    }
    return y
}

@discardableResult
private func drawCashflow(ctx: CGContext, baseline: CGFloat, cashflow: CashflowData) -> CGFloat {
    let maxVal = max(cashflow.incomeTotal, cashflow.expenseTotalAbs)
    let maxBarW: CGFloat = R.contentW * 0.55
    let labelX = R.marginL
    let barX   = R.marginL + 38
    let amtX   = R.pageWidth - R.marginR
    var y = baseline

    // EIN
    drawText(ctx, "EIN", x: labelX, baseline: y, font: R.mono(8), color: R.labelGray)
    let einW = maxVal > 0 ? CGFloat(truncating: (cashflow.incomeTotal / maxVal) as NSDecimalNumber) * maxBarW : 0
    // dotted bar
    let barRect = CGRect(x: barX, y: y - 2, width: einW, height: 10)
    fillRect(ctx, barRect, R.barTeal.copy(alpha: 0.18) ?? R.barTeal)
    ctx.saveGState()
    ctx.setStrokeColor(R.barTeal.copy(alpha: 0.45) ?? R.barTeal)
    ctx.setLineWidth(0.4)
    var dx = barX
    while dx < barX + einW {
        ctx.beginPath(); ctx.move(to: CGPoint(x: dx, y: y - 2)); ctx.addLine(to: CGPoint(x: dx, y: y + 8)); ctx.drawPath(using: .stroke)
        dx += 3.5
    }
    ctx.restoreGState()
    drawText(ctx, fmtAmt(cashflow.incomeTotal), x: amtX, baseline: y, font: R.mono(9), color: R.textBlack, align: .right)
    y -= 19

    // AUS
    drawText(ctx, "AUS", x: labelX, baseline: y, font: R.mono(8), color: R.labelGray)
    let ausW = maxVal > 0 ? CGFloat(truncating: (cashflow.expenseTotalAbs / maxVal) as NSDecimalNumber) * maxBarW : 0
    fillRect(ctx, CGRect(x: barX, y: y - 2, width: ausW, height: 10), R.barTeal.copy(alpha: 0.65) ?? R.barTeal)
    drawText(ctx, fmtAmt(cashflow.expenseTotalAbs), x: amtX, baseline: y, font: R.mono(9), color: R.textBlack, align: .right)
    y -= 19

    // NET
    drawText(ctx, "NET", x: labelX, baseline: y, font: R.mono(8), color: R.labelGray)
    let netColor = cashflow.netTotal >= 0 ? R.green : R.red
    drawText(ctx, fmtAmt(cashflow.netTotal), x: amtX, baseline: y,
             font: R.mono(9, bold: true), color: netColor, align: .right)
    y -= 14
    return y
}

private func drawInsights(ctx: CGContext, baseline: CGFloat, insights: [InsightItem]) {
    var y = baseline
    for insight in insights {
        let dotColor: CGColor
        switch insight.kind {
        case .largestExpense: dotColor = R.red
        case .largestIncome:  dotColor = R.green
        case .netSummary:     dotColor = insight.text.contains("gespart") ? R.green : R.red
        default:              dotColor = R.labelGray
        }
        ctx.setFillColor(dotColor)
        ctx.fillEllipse(in: CGRect(x: R.marginL + 1, y: y - 2, width: 5, height: 5))
        drawText(ctx, insight.text, x: R.marginL + 13, baseline: y,
                 font: R.mono(9), color: R.textBlack, maxWidth: R.contentW - 14)
        y -= 16
    }
}

// MARK: - Page 2

private func drawPage2(ctx: CGContext, report: MonthlyReport, totalPages: Int) {
    fillRect(ctx, CGRect(x: 0, y: 0, width: R.pageWidth, height: R.pageHeight), R.bg)

    drawRainbow(ctx, y: R.pageHeight - 10)

    let titleY: CGFloat = 808
    let h2 = report.header.monthTitle + " — " + report.header.accountName
    drawText(ctx, h2, x: R.marginL, baseline: titleY, font: R.sans(13, bold: true), color: R.textBlack)
    drawText(ctx, "■  DETAILS", x: R.pageWidth - R.marginR, baseline: titleY,
             font: R.mono(8), color: R.labelGray, align: .right)
    drawRule(ctx, y: titleY - 8)

    var y: CGFloat = titleY - 26

    // Ausgabenübersicht
    drawSectionHeader(ctx, "Ausgabenübersicht", x: R.marginL, baseline: y)
    y -= 18
    y = drawCategories(ctx: ctx, baseline: y, categories: report.categories)
    y -= 14

    // Fixkosten
    drawSectionHeader(ctx, "Fixkosten", x: R.marginL, baseline: y)
    y -= 18
    y = drawFixkosten(ctx: ctx, baseline: y, recurring: report.recurring)
    y -= 14

    // Wichtige Buchungen
    drawSectionHeader(ctx, "Wichtige Buchungen", x: R.marginL, baseline: y)
    y -= 18
    drawHighlights(ctx: ctx, baseline: y, highlights: report.highlights)

    drawRainbow(ctx, y: 10)
    drawText(ctx, "simple.report", x: R.marginL, baseline: 20, font: R.mono(7.5), color: R.labelGray)
    drawText(ctx, "SEITE 2 / \(totalPages)", x: R.pageWidth - R.marginR, baseline: 20,
             font: R.mono(7.5), color: R.labelGray, align: .right)
}

@discardableResult
private func drawCategories(ctx: CGContext, baseline: CGFloat, categories: [CategoryRow]) -> CGFloat {
    guard !categories.isEmpty else { return baseline }
    let maxAmt = categories.map { $0.amount }.max() ?? 1
    let maxBarW: CGFloat = R.contentW * 0.38
    let catX  = R.marginL
    let barX  = R.marginL + 108
    let amtX  = barX + maxBarW + 68
    let pctX  = amtX + 30
    let dltX  = R.pageWidth - R.marginR
    var y = baseline

    for row in categories {
        let barW = CGFloat(truncating: (row.amount / maxAmt) as NSDecimalNumber) * maxBarW
        drawText(ctx, row.category.uppercased(), x: catX, baseline: y,
                 font: R.mono(7.5), color: R.labelGray, maxWidth: 105)
        fillRect(ctx, CGRect(x: barX, y: y - 2, width: barW, height: 9),
                 R.barTeal.copy(alpha: 0.70) ?? R.barTeal)
        drawText(ctx, fmtAmt(row.amount), x: amtX, baseline: y,
                 font: R.mono(8), color: R.textBlack, align: .right)
        drawText(ctx, "\(Int(row.share * 100))%", x: pctX + 22, baseline: y,
                 font: R.mono(8), color: R.labelGray, align: .right)
        if let delta = row.deltaVsPreviousMonth, row.amount > 0 {
            let pct = Int(abs(Double(truncating: (delta / row.amount * 100) as NSDecimalNumber)))
            let sign = delta >= 0 ? "↑" : "↓"
            let col  = delta >= 0 ? R.red : R.green
            drawText(ctx, "\(sign)\(pct)%", x: dltX, baseline: y,
                     font: R.mono(8), color: col, align: .right)
        }
        y -= 15
    }
    return y
}

@discardableResult
private func drawFixkosten(ctx: CGContext, baseline: CGFloat, recurring: [RecurringRow]) -> CGFloat {
    guard !recurring.isEmpty else { return baseline }
    let half  = Int(ceil(Double(recurring.count) / 2.0))
    let left  = Array(recurring.prefix(half))
    let right = Array(recurring.dropFirst(half))
    let colW  = R.contentW / 2
    let col2X = R.marginL + colW
    var y = baseline

    for i in 0..<max(left.count, right.count) {
        if i < left.count {
            drawText(ctx, left[i].merchant.uppercased(), x: R.marginL, baseline: y,
                     font: R.mono(7.5), color: R.labelGray, maxWidth: colW - 68)
            drawText(ctx, fmtAmt(left[i].amount), x: R.marginL + colW - 8, baseline: y,
                     font: R.mono(8), color: R.textBlack, align: .right)
            dashedLine(ctx, from: CGPoint(x: R.marginL, y: y - 9),
                       to: CGPoint(x: R.marginL + colW - 10, y: y - 9))
        }
        if i < right.count {
            drawText(ctx, right[i].merchant.uppercased(), x: col2X, baseline: y,
                     font: R.mono(7.5), color: R.labelGray, maxWidth: colW - 68)
            drawText(ctx, fmtAmt(right[i].amount), x: R.pageWidth - R.marginR, baseline: y,
                     font: R.mono(8), color: R.textBlack, align: .right)
            dashedLine(ctx, from: CGPoint(x: col2X, y: y - 9),
                       to: CGPoint(x: R.pageWidth - R.marginR, y: y - 9))
        }
        y -= 16
    }
    return y
}

private func drawHighlights(ctx: CGContext, baseline: CGFloat, highlights: [TransactionHighlight]) {
    // Layout columns (all x = absolute from left):
    //   DATE  : marginL         → ~50 pt wide
    //   TITLE : marginL + 52    → ~165 pt wide
    //   SUB   : marginL + 220   → ~115 pt, right-aligned within zone
    //   AMT   : pageWidth - marginR  (right-aligned)
    let dateX     = R.marginL
    let titleX    = R.marginL + 52
    let titleMaxW: CGFloat = 160
    let subLeftX  = titleX + titleMaxW + 6  // subtitle starts here
    let amtX      = R.pageWidth - R.marginR
    let subMaxW   = amtX - 68 - subLeftX    // fills gap between sub zone and amount
    var y = baseline

    for h in highlights {
        guard y > 40 else { break }
        let amtStr   = (h.direction == .income ? "+" : "-") + fmtAmt(h.amount)
        let amtColor = h.direction == .income ? R.green : R.red

        drawText(ctx, h.date, x: dateX, baseline: y, font: R.mono(7.5), color: R.labelGray)
        drawText(ctx, h.title.uppercased(), x: titleX, baseline: y,
                 font: R.mono(8), color: R.textBlack, maxWidth: titleMaxW)
        if let sub = h.subtitle {
            let truncated = truncate(sub, font: R.mono(7.5), maxWidth: subMaxW)
            drawText(ctx, truncated, x: amtX - 68, baseline: y,
                     font: R.mono(7.5), color: R.labelGray, maxWidth: subMaxW, align: .right)
        }
        drawText(ctx, amtStr, x: amtX, baseline: y, font: R.mono(8), color: amtColor, align: .right)
        dashedLine(ctx, from: CGPoint(x: R.marginL, y: y - 9),
                   to: CGPoint(x: R.pageWidth - R.marginR, y: y - 9))
        y -= 16
    }
}

private func truncate(_ text: String, font: CTFont, maxWidth: CGFloat) -> String {
    let attrs: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font]
    let full = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(full)
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    guard w > maxWidth else { return text }
    let ellipsis = NSAttributedString(string: "…", attributes: attrs)
    let token = CTLineCreateWithAttributedString(ellipsis)
    if let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) {
        // Recover the string from the truncated line
        if let runs = CTLineGetGlyphRuns(truncated) as? [CTRun],
           let firstRun = runs.first,
           let runAttrs = CTRunGetAttributes(firstRun) as? [NSAttributedString.Key: Any],
           let _ = runAttrs[.font] {
            // Approximate: trim characters until it fits, then add ellipsis
        }
    }
    // Simple fallback: binary-search trim
    var result = text
    while result.count > 1 {
        result = String(result.dropLast())
        let candidate = result + "…"
        let candidateStr = NSAttributedString(string: candidate, attributes: attrs)
        let cLine = CTLineCreateWithAttributedString(candidateStr)
        let cW = CGFloat(CTLineGetTypographicBounds(cLine, nil, nil, nil))
        if cW <= maxWidth { return candidate }
    }
    return "…"
}

private func dashedLine(_ ctx: CGContext, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.setStrokeColor(R.ruleGray.copy(alpha: 0.45) ?? R.ruleGray)
    ctx.setLineWidth(0.3)
    ctx.setLineDash(phase: 0, lengths: [2, 2])
    ctx.beginPath()
    ctx.move(to: from)
    ctx.addLine(to: to)
    ctx.drawPath(using: .stroke)
    ctx.restoreGState()
}

// MARK: - Page 3+ (full transaction list)

private func drawTxListPage(
    ctx: CGContext,
    report: MonthlyReport,
    rows: [TransactionsResponse.Transaction],
    pageNum: Int,
    totalPages: Int
) {
    fillRect(ctx, CGRect(x: 0, y: 0, width: R.pageWidth, height: R.pageHeight), R.bg)
    drawRainbow(ctx, y: R.pageHeight - 10)

    // Header
    let titleY: CGFloat = 808
    let h2 = report.header.monthTitle + " — " + report.header.accountName
    drawText(ctx, h2, x: R.marginL, baseline: titleY, font: R.sans(13, bold: true), color: R.textBlack)
    drawText(ctx, "■  ALLE UMSÄTZE", x: R.pageWidth - R.marginR, baseline: titleY,
             font: R.mono(8), color: R.labelGray, align: .right)
    drawRule(ctx, y: titleY - 8)

    // Column header
    let colHeaderY: CGFloat = titleY - 22
    let dateX    = R.marginL
    let merchantX = R.marginL + 52
    let catX     = R.marginL + 260
    let amtX     = R.pageWidth - R.marginR
    let merchantMaxW: CGFloat = 200
    let catMaxW: CGFloat = 110

    drawText(ctx, "DATUM",   x: dateX,     baseline: colHeaderY, font: R.mono(7), color: R.labelGray)
    drawText(ctx, "BUCHUNG", x: merchantX, baseline: colHeaderY, font: R.mono(7), color: R.labelGray)
    drawText(ctx, "KATEGORIE", x: catX,    baseline: colHeaderY, font: R.mono(7), color: R.labelGray)
    drawText(ctx, "BETRAG",  x: amtX,      baseline: colHeaderY, font: R.mono(7), color: R.labelGray, align: .right)
    drawRule(ctx, y: colHeaderY - 5)

    // Rows
    var y: CGFloat = colHeaderY - 18
    let rowH: CGFloat = 13

    for tx in rows {
        guard y > 30 else { break }
        let dateStr = txShortDate(tx)
        let merchant = txMerchantName(tx)
        let cat  = tx.category ?? "Sonstiges"
        let amt  = txAmount(tx)
        let amtStr = (amt >= 0 ? "+" : "") + fmtAmt(amt)
        let amtColor: CGColor = amt >= 0 ? R.green : R.textBlack

        drawText(ctx, dateStr,          x: dateX,     baseline: y, font: R.mono(7.5), color: R.labelGray)
        drawText(ctx, merchant.uppercased(), x: merchantX, baseline: y,
                 font: R.mono(7.5), color: R.textBlack, maxWidth: merchantMaxW)
        drawText(ctx, cat.uppercased(), x: catX,      baseline: y,
                 font: R.mono(7), color: R.labelGray, maxWidth: catMaxW)
        drawText(ctx, amtStr,           x: amtX,      baseline: y,
                 font: R.mono(7.5), color: amtColor, align: .right)
        y -= rowH
    }

    // Footer
    drawRainbow(ctx, y: 10)
    drawText(ctx, "simple.report", x: R.marginL, baseline: 20, font: R.mono(7.5), color: R.labelGray)
    drawText(ctx, "SEITE \(pageNum) / \(totalPages)", x: R.pageWidth - R.marginR, baseline: 20,
             font: R.mono(7.5), color: R.labelGray, align: .right)
}

private func txShortDate(_ tx: TransactionsResponse.Transaction) -> String {
    let iso = tx.bookingDate ?? tx.valueDate ?? ""
    guard iso.count >= 10 else { return iso }
    let parts = iso.prefix(10).split(separator: "-")
    guard parts.count == 3, let d = Int(parts[2]), let m = Int(parts[1]) else { return iso }
    let months = ["", "Jan", "Feb", "Mär", "Apr", "Mai", "Jun",
                  "Jul", "Aug", "Sep", "Okt", "Nov", "Dez"]
    let mon = m < months.count ? months[m] : "\(m)"
    return String(format: "%02d. %@", d, mon)
}

private func txMerchantName(_ tx: TransactionsResponse.Transaction) -> String {
    if let name = tx.creditor?.name, !name.isEmpty { return name }
    if let name = tx.debtor?.name,  !name.isEmpty { return name }
    return tx.remittanceInformation?.first ?? "Unbekannt"
}

private func txAmount(_ tx: TransactionsResponse.Transaction) -> Decimal {
    Decimal(string: tx.amount?.amount ?? "0") ?? 0
}
