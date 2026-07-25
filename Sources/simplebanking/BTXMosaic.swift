import SwiftUI

/// Mosaik-Semigrafik für das BTX-Theme.
///
/// Bildschirmtext konnte keine Bildmarken darstellen. Händler wurden über Blöcke
/// gesetzt, die aus der Unterteilung einer Zeichenzelle in ein 2×3-Raster entstanden.
/// Das Theme greift das mit 3×3-Rastern auf: **die Form trägt die Kategorie, die Farbe
/// unterscheidet** — Muster und Farbwerte stammen aus der Vorlage des Theme-Pakets
/// (`quelle/BTX Theme.dc.html`, Konstanten `S` und die `lt(...)`-Zeilen).
///
/// Die Komponente füllt exakt den Platz, an dem sonst Logo oder Symbol steht — sie
/// verschiebt nichts.
enum BTXMosaic {

    /// 3×3-Muster; `x` = gefüllte Zelle. Bezeichner wie in der Vorlage.
    enum Shape: String, CaseIterable {
        case cup    // Tasse — Bäckerei, Café
        case pump   // Zapfsäule — Tankstelle
        case bag    // Tüte — Einzelhandel, Drogerie
        case cart   // Warenkorb — Supermarkt
        case bank   // Bank, Telekommunikation, neutraler Rückfall

        var rows: [String] {
            switch self {
            case .cup:  return ["x.x", "xxx", ".x."]
            case .pump: return ["xx.", "xxx", "xx."]
            case .bag:  return [".x.", "xxx", "xxx"]
            case .cart: return ["x.x", "xxx", "x.x"]
            case .bank: return ["xxx", "x.x", "xxx"]
            }
        }
    }

    /// Kategorie → Form und Farbe.
    ///
    /// Die Vorlage unterscheidet die Farbe pro Marke (Aral blau, Shell gelb). Ohne
    /// Markenzuordnung wäre das geraten, deshalb entscheidet hier die Kategorie —
    /// die README sieht den neutralen Bank-Block ausdrücklich als Rückfall vor.
    static func style(for category: TransactionCategory) -> (shape: Shape, hex: String) {
        switch category {
        case .essenAlltag:              return (.cart, "#c00000")   // Supermarkt, Rot
        case .gastronomie:              return (.cup,  "#8a5a1a")   // Café, Braun
        case .mobilitaet:               return (.pump, "#0033b0")   // Tankstelle, Blau
        case .shopping:                 return (.bag,  "#0a7a24")   // Einzelhandel, Grün
        case .gesundheit:               return (.bag,  "#a00050")   // Drogerie, Magenta
        case .freizeit:                 return (.bag,  "#c81ec8")   // Sport, Magenta hell
        case .einkommen, .gehalt:       return (.bank, "#0a7a24")   // Eingang, Grün
        case .abosDigital,
             .versicherungen,
             .wohnenKredit,
             .sparen,
             .umbuchung,
             .sonstiges:                return (.bank, "#0033b0")   // neutral, Blau
        }
    }
}

/// Textkürzel als Ersatz für ein grafisches Bedien-Icon (BTX kannte keine Icons).
/// Wird nur dort gezeichnet, wo `glyphControls=off` ist; die Farbe folgt dem Theme
/// (aktiv = BTX-Blau als Leitfarbe, sonst gedämpftes Ink).
struct BTXTextControl: View {
    let text: String
    var active: Bool = false
    // VT323 rendert bei gegebener Punktgröße optisch kleiner als eine Systemschrift —
    // die Bedien-Labels brauchen deshalb mehr Größe, um lesbar zu sein.
    var size: CGFloat = 15

    var body: some View {
        Text(text)
            .font(ThemeFonts.flyoutBody(size: size))
            .textCase(.uppercase)
            .foregroundColor(active ? Color(nsColor: ThemeManager.shared.currentTheme.accentColor)
                                    : Color.themedInk.opacity(0.9))
            .lineLimit(1)
            .fixedSize()
    }
}

/// „Bildschirmrand" des BTX-Themes als gefüllte CRT-Blende: außen füllt sie bis an die
/// Fensterkante (die Fensterrundung schneidet sie sauber ab — keine helle Außenlinie,
/// keine dünnen Ecken), innen ist sie gerundet ausgestanzt wie die Maske einer Röhre.
struct BTXScreenBezel: View {
    let color: Color
    var thickness: CGFloat = 6
    var innerRadius: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.addRect(CGRect(origin: .zero, size: geo.size))
                p.addRoundedRect(
                    in: CGRect(origin: .zero, size: geo.size)
                        .insetBy(dx: thickness, dy: thickness),
                    cornerSize: CGSize(width: innerRadius, height: innerRadius)
                )
            }
            .fill(color, style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }
}

/// Hart blinkendes Telefon-Glyph in der Kopfzeile — BTX-Steuerzeichen „Blinken", das
/// im Sekundentakt ohne Zwischenstufen umschaltet (BTX kannte kein Fade). VT323 enthält
/// kein ☎, deshalb wird das Zeichen in Systemschrift gesetzt, aber monochrom in der
/// Ink-Farbe — es bleibt Text, keine Bildmarke.
struct BTXBlinkingPhone: View {
    var size: CGFloat = 14

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.6)) { context in
            // Harte Stufen über die Sekunden-Phase, keine Animation.
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            Text("\u{260E}")
                .font(.system(size: size))
                .foregroundColor(Color.themedInk)
                .opacity(on ? 1 : 0)
                .accessibilityHidden(true)
        }
    }
}

/// Gepunktete Führungslinie zwischen Name und Betrag — direkt aus der BTX-Originalseite
/// übernommen. Sie füllt den Zwischenraum, den die Zeile ohnehin hat, und ersetzt dort
/// nur den leeren `Spacer`.
struct BTXDottedRule: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let y = geo.size.height / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
            .foregroundColor(Color.themedInk.opacity(0.55))
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Zeichnet ein Mosaik-Raster in der Größe, die sonst Logo oder Symbol einnimmt.
struct BTXMosaicIcon: View {
    let category: TransactionCategory
    /// Kantenlänge des Gesamtrasters. Die Zellgröße leitet sich daraus ab, damit das
    /// Mosaik in jeden vorhandenen Platz passt, ohne ihn zu verändern.
    var side: CGFloat = 20

    var body: some View {
        let style = BTXMosaic.style(for: category)
        let rows = style.shape.rows
        // Ganzzahlige Zellgröße — sonst franst das Raster durch Teilpixel aus, und
        // genau die harten Kanten machen die BTX-Anmutung.
        let cell = max(1, (side / 3).rounded(.down))
        let color = Color(nsColor: AppTheme.color(from: style.hex, fallback: .labelColor))

        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, ch in
                        Rectangle()
                            .fill(ch == "x" ? color : Color.clear)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
