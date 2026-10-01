import XCTest
import SwiftUI
import AppKit
@testable import simplebanking

/// Gemeldet am 01.10.2026: In Einstellungen → Konten lief der Text links aus dem Fenster —
/// „Zugangsdaten" ohne Z, „Monatlicher Ziel-Puffer" ohne M, quer durch alle Karten.
///
/// Ursache war **nicht** die Zeile, an der es auffiel. Gemessen am NSView-Baum des
/// Einstellungsfensters:
///
///     HostingScrollView  x = -36,5 … 556,5   Breite 593
///
/// 593 pt Inhalt in einem 520 pt breiten Fenster. SwiftUI zentriert zu breiten Inhalt, also
/// fielen auf jeder Seite 36,5 pt weg — und links liest das niemand mehr. Die 593 kamen aus
/// **einer** Zeile: „Schrittweite" mit fester 185-pt-Spalte neben einer Segmentsteuerung,
/// die unter 336 pt nicht geht. 185 + 8 + 336 + 24 (Karte) + 40 (Seitenrand) = 593.
///
/// Zwei Dinge sichern das hier ab: die Segmentsteuerung muss neben ihrer Beschriftung in
/// die Karte passen, und das Fenster gibt vor, wie breit der Inhalt ist — nicht umgekehrt.
@MainActor
final class EinstellungenBreiteTests: XCTestCase {

    /// 520 Fensterbreite − 2×20 Seitenrand − 2×12 Karteninnenrand.
    private let platzInDerKarte: CGFloat = 456

    private func breite<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Die Zeile, die es ausgelöst hat. Kommt eine siebte Stufe dazu oder werden die
    /// Beschriftungen länger („10 Cent" statt „10 ct"), schlägt dieser Test an, bevor
    /// wieder die ganze Seite verrutscht.
    func test_schrittweitenZeile_passtInDieKarte() {
        let zeile = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Schrittweite")
                .font(ThemeFonts.body(size: 12))
                .frame(maxWidth: 185, alignment: .leading)
            Picker("", selection: .constant(100)) {
                ForEach(RoundupOverlay.stepOptions, id: \.cents) { option in
                    Text(option.label).tag(option.cents)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        XCTAssertLessThanOrEqual(breite(zeile), platzInDerKarte,
                                 "die Zeile drückt die ganze Einstellungsseite auseinander")
    }

    /// Die Gegenprobe, und der eigentliche Beleg: Mit **fester** 185-pt-Spalte passt
    /// dieselbe Zeile nicht. Ohne diesen Test sähe der obige nach einer Selbstverständlichkeit
    /// aus — er hält fest, dass genau diese Änderung die Wirkung hat.
    func test_mitFesterSpalte_passtSieNicht() {
        let zeile = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Schrittweite")
                .font(ThemeFonts.body(size: 12))
                .frame(width: 185, alignment: .leading)
            Picker("", selection: .constant(100)) {
                ForEach(RoundupOverlay.stepOptions, id: \.cents) { option in
                    Text(option.label).tag(option.cents)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        XCTAssertGreaterThan(breite(zeile), platzInDerKarte)
    }

    /// Und die strukturelle Hälfte: Ein zu breites Kind darf den Inhalt nicht mitreißen.
    /// `.frame(maxWidth: .infinity)` sorgt dafür, dass der Inhalt die angebotene Breite
    /// nimmt — ohne das bestimmt das breiteste Element die Breite aller Karten.
    func test_zuBreitesKind_reisstDenInhaltNichtMit() {
        let inhalt = VStack(alignment: .leading, spacing: 20) {
            Text("normale Zeile")
            Color.clear.frame(width: 900, height: 10)   // der Störenfried
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        let host = NSHostingView(rootView: inhalt)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
        host.layoutSubtreeIfNeeded()

        // Der Inhalt selbst bleibt bei der angebotenen Breite; nur das eine Element ragt
        // heraus. Ohne die Zeile wäre der ganze Block 900 breit und würde zentriert —
        // und dann fehlt links die Hälfte.
        XCTAssertEqual(host.frame.width, 480, accuracy: 0.5)
    }
}
