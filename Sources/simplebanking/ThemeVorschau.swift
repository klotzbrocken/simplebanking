import AppKit

// MARK: - Miniatur eines Themes
//
// **Warum gerendert und nicht abfotografiert.**
//
// Eine Auswahl aus Screenshots kann nur zeigen, was mitgeliefert wird. Der Sinn von
// Theme-Builder und Galerie ist aber, dass Nutzer eigene mitbringen — für die gäbe es nie
// ein Bild. Dazu kommt: Ein Screenshot veraltet still, sobald sich ein Theme ändert.
//
// Diese Ansicht zeichnet stattdessen aus den Werten des Themes selbst: Kartenfarbe,
// Schriftfarbe, Leitfarbe, Blende. Sie ist damit immer aktuell und funktioniert für jedes
// Theme, auch für ein gerade importiertes.
//
// Sie ist bewusst eine Andeutung, keine Nachbildung des Flyouts: Wer die echte Wirkung
// sehen will, wählt es aus — das dauert einen Klick und ist ehrlicher als eine Miniatur,
// die mehr verspricht, als sie zeigt.
final class ThemeVorschauView: NSView {

    private let theme: AppTheme
    private(set) var ausgewaehlt: Bool

    init(theme: AppTheme, ausgewaehlt: Bool) {
        self.theme = theme
        self.ausgewaehlt = ausgewaehlt
        super.init(frame: NSRect(x: 0, y: 0, width: 132, height: 84))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 132).isActive = true
        heightAnchor.constraint(equalToConstant: 84).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    func setzeAuswahl(_ an: Bool) {
        ausgewaehlt = an
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dunkel = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let karte = theme.surfaceColor(dark: dunkel)
        let tinte = theme.inkColor(dark: dunkel)
        let leit  = theme.accentColor

        let rand = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        karte.setFill()
        rand.fill()

        // Die Blende, falls das Theme eine hat — sie prägt den Eindruck stärker als jede
        // Farbe und darf in der Vorschau nicht fehlen.
        if let hex = theme.screenBorderHex {
            AppTheme.color(from: hex, fallback: .clear).setStroke()
            rand.lineWidth = 3
            rand.stroke()
        }

        // Andeutung: große Zahl, darunter eine Zeile, rechts ein Ring in der Leitfarbe.
        let zahl = "1.234,56 €"
        let zahlAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: tinte
        ]
        zahl.draw(at: NSPoint(x: 12, y: 44), withAttributes: zahlAttr)

        let unterzeile = NSRect(x: 12, y: 32, width: 62, height: 5)
        tinte.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: unterzeile, xRadius: 2.5, yRadius: 2.5).fill()

        let ring = NSBezierPath(ovalIn: NSRect(x: 96, y: 30, width: 24, height: 24))
        ring.lineWidth = 4
        leit.setStroke()
        ring.stroke()

        for i in 0..<3 {
            let pille = NSRect(x: 12 + CGFloat(i) * 26, y: 14, width: 22, height: 8)
            (i == 0 ? leit : tinte.withAlphaComponent(0.20)).setFill()
            NSBezierPath(roundedRect: pille, xRadius: 4, yRadius: 4).fill()
        }

        if ausgewaehlt {
            NSColor.controlAccentColor.setStroke()
            let auswahl = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                                       xRadius: 8, yRadius: 8)
            auswahl.lineWidth = 3
            auswahl.stroke()
        }
    }
}
