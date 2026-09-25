import AppKit
import XCTest
@testable import simplebanking

/// Gemeldet am 25.09.2026: Auf der Seite „100 % sicher" lief der Fließtext deutlich
/// näher an die rechte Fensterkante als alles andere.
///
/// Ursache ist eine AppKit-Eigenheit mit Folgen: `rootStack` richtet seine Kinder am
/// linken Rand aus und zieht sie **nicht** auf die volle Breite. Ein umbrechendes Label
/// bekommt damit seine natürliche Breite — die einer ungebrochenen Zeile — und sucht
/// sich den Umbruch selbst, notfalls jenseits des Seitenrands. Sichtbar wurde es am
/// längsten Absatz; die kurzen fielen nicht auf.
///
/// Der Test misst deshalb die Ränder, statt sich auf den Augenschein zu verlassen.
@MainActor
final class AssistentRaenderTests: XCTestCase {

    /// Seitenrand von `rootStack.edgeInsets`.
    private let rand: CGFloat = 40

    /// Ein `NSTextField` ist zwei Punkt breiter als die Schrift darin — sein Rahmen
    /// beginnt links davon und endet rechts danach. Gemessen wird der Rahmen, gemeint
    /// ist die Schrift, also darf die Prüfung diese zwei Punkt zulassen. Ohne die
    /// Beschränkung im Quelltext lag der Wert bei 462 in einem 460 Punkt breiten
    /// Fenster, also 42 Punkt über dem Rand — daran scheitert diese Toleranz nicht.
    private let felderRand: CGFloat = 2.5

    /// Die Panels wieder schließen. Ein Testlauf baut hier mehrere Fenster auf; bleiben
    /// sie offen, ändert das die Lage für spätere Tests — `ModalRunLoopDeliveryTests`
    /// misst das Verhalten der Hauptschleife im Modal-Mode und kippte dadurch.
    private var offeneFenster: [NSWindow] = []

    override func tearDown() {
        for fenster in offeneFenster { fenster.close() }
        offeneFenster.removeAll()
        super.tearDown()
    }

    private func texte(_ v: NSView) -> [NSTextField] {
        (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(texte)
    }

    private func seite(_ nummer: Int) throws -> (inhalt: NSView, felder: [NSTextField]) {
        let panel = SetupFlowPanel(connectAction: { _, _, _, _ in throw CancellationError() })
        panel.debugAufbauen(onboardingSeite: nummer)
        if let f = panel.debugInhalt?.window { offeneFenster.append(f) }
        let inhalt = try XCTUnwrap(panel.debugInhalt)
        inhalt.layoutSubtreeIfNeeded()
        return (inhalt, texte(inhalt))
    }

    /// Kein Text darf über den Seitenrand hinausragen.
    func test_seite2_textBleibtInnerhalbDerRaender() throws {
        let (inhalt, felder) = try seite(2)
        XCTAssertFalse(felder.isEmpty)

        let erlaubt = inhalt.bounds.width - rand + felderRand
        for feld in felder where !feld.stringValue.isEmpty {
            let rahmen = feld.convert(feld.bounds, to: inhalt)
            XCTAssertLessThanOrEqual(
                rahmen.maxX, erlaubt,
                "„\(feld.stringValue.prefix(40))…" + "\" endet bei \(rahmen.maxX), erlaubt sind \(erlaubt).")
            XCTAssertGreaterThanOrEqual(rahmen.minX, rand - felderRand,
                                        "„\(feld.stringValue.prefix(40))…\" beginnt links vom Rand.")
        }
    }

    /// Dieselbe Prüfung für die Seite mit denselben Merkmalszeilen.
    func test_seite1_textBleibtInnerhalbDerRaender() throws {
        let (inhalt, felder) = try seite(1)
        let erlaubt = inhalt.bounds.width - rand + felderRand
        for feld in felder where !feld.stringValue.isEmpty {
            let rahmen = feld.convert(feld.bounds, to: inhalt)
            XCTAssertLessThanOrEqual(rahmen.maxX, erlaubt,
                                     "„\(feld.stringValue.prefix(40))…\" ragt über den Rand.")
        }
    }

    /// Der Untertitel auf Seite 2 wiederholte wörtlich die Überschrift. Er ist gestrichen —
    /// dieser Test hält fest, dass er nicht zurückkommt.
    func test_seite2_wiederholtDieUeberschriftNicht() throws {
        let (_, felder) = try seite(2)
        let texte = felder.map(\.stringValue)
        XCTAssertTrue(texte.contains { $0.contains("Deine Daten gehören dir") },
                      "Die Überschrift fehlt — dann prüft dieser Test nichts mehr.")
        XCTAssertFalse(texte.contains { $0.contains("Deine Finanzdaten gehören nur dir") },
                       "Der Untertitel sagt dasselbe wie die Überschrift eine Zeile darüber.")
    }

    /// Zwei Hauptsätze mit bloßem Komma aneinandergehängt — der Fehler, der gemeldet wurde.
    func test_keinKommafehlerImSicherheitstext() throws {
        let (_, felder) = try seite(2)
        let cloud = try XCTUnwrap(felder.map(\.stringValue).first { $0.contains("simplebanking-Backend") })
        XCTAssertFalse(cloud.contains("Open Banking, KI-Funktionen"),
                       "Komma zwischen zwei Hauptsätzen; dort gehört ein Semikolon hin.")
    }
}
