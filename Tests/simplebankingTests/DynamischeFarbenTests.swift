import AppKit
import XCTest
@testable import simplebanking

/// Gemeldet am 25.09.2026: Im Dunkelmodus stand die Zeile „<Bank> verbunden" am Ende
/// der Einrichtung als schwarze Schrift auf dunklem Grund.
///
/// Ursache war kein Tippfehler in einem Farbwert, sondern eine Eigenschaft von AppKit,
/// die man kennen muss: `withAlphaComponent` löst eine dynamische Systemfarbe **sofort**
/// auf — gegen das Erscheinungsbild, das beim Aufruf gerade gilt. Die Ansichten des
/// Assistenten entstehen, bevor sie in einem Fenster hängen, also im Hellmodus. Danach
/// bleibt die Farbe schwarz, egal worauf sie gezeichnet wird.
///
/// Diese Tests halten die Eigenschaft fest, damit das Muster nicht zurückkommt.
final class DynamischeFarbenTests: XCTestCase {

    /// Farbe unter einem bestimmten Erscheinungsbild ausrechnen.
    private func rgb(_ farbe: NSColor, unter name: NSAppearance.Name) -> (r: CGFloat, a: CGFloat) {
        var ergebnis: (CGFloat, CGFloat) = (0, 0)
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            let aufgeloest = farbe.usingColorSpace(.deviceRGB)
            ergebnis = (aufgeloest?.redComponent ?? -1, aufgeloest?.alphaComponent ?? -1)
        }
        return ergebnis
    }

    /// Die unveränderte Systemfarbe richtet sich nach dem Erscheinungsbild: im Hellmodus
    /// schwarz, im Dunkelmodus weiß.
    func test_labelColor_folgtDemErscheinungsbild() {
        XCTAssertEqual(rgb(.labelColor, unter: .aqua).r, 0.0, accuracy: 0.01)
        XCTAssertEqual(rgb(.labelColor, unter: .darkAqua).r, 1.0, accuracy: 0.01)
    }

    /// Der Kern des Fehlers: einmal im Hellmodus abgeschwächt, bleibt die Farbe schwarz —
    /// auch im Dunkelmodus.
    func test_withAlphaComponent_friertDasErscheinungsbildEin() {
        var eingefroren = NSColor.labelColor
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            eingefroren = NSColor.labelColor.withAlphaComponent(0.8)
        }
        XCTAssertEqual(rgb(eingefroren, unter: .darkAqua).r, 0.0, accuracy: 0.01,
                       "Bleibt die Farbe schwarz, steht die Schrift im Dunkelmodus unlesbar auf dunklem Grund.")
    }

    /// Der gewählte Ausweg: Alpha auf der Ansicht statt auf der Farbe. Die Farbe bleibt
    /// dynamisch, die Abschwächung wirkt trotzdem.
    func test_alphaAufDerAnsicht_laesstDieFarbeDynamisch() {
        let feld = NSTextField(labelWithString: "N26 verbunden")
        feld.textColor = .labelColor
        feld.alphaValue = 0.8

        XCTAssertEqual(feld.alphaValue, 0.8, accuracy: 0.001)
        XCTAssertEqual(rgb(feld.textColor ?? .clear, unter: .aqua).r, 0.0, accuracy: 0.01)
        XCTAssertEqual(rgb(feld.textColor ?? .clear, unter: .darkAqua).r, 1.0, accuracy: 0.01)
    }
}
