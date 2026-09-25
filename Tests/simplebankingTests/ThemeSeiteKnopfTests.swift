import AppKit
import XCTest
@testable import simplebanking

/// Gemeldet am 25.09.2026: Die letzte Seite des Einrichtungs-Assistenten
/// („Wie soll es aussehen?") ließ sich nicht bestätigen — sie hatte keinen Knopf.
/// Erst dieser Knopf schreibt das Konto weg, also war jede Ersteinrichtung verloren.
///
/// Zwei Dinge müssen stimmen, und das zweite ist das heimtückischere: Das Panel ist auf
/// 460×520 festgenagelt (`minSize == maxSize`). Ein Knopf, den es gibt, der aber unter
/// den Fensterrand rutscht, wäre für den Nutzer derselbe Fehler wie gar kein Knopf.
@MainActor
final class ThemeSeiteKnopfTests: XCTestCase {

    /// Die Panels wieder schließen. Ein Testlauf baut hier mehrere Fenster auf; bleiben
    /// sie offen, ändert das die Lage für spätere Tests — `ModalRunLoopDeliveryTests`
    /// misst das Verhalten der Hauptschleife im Modal-Mode und kippte dadurch.
    private var offeneFenster: [NSWindow] = []

    override func tearDown() {
        for fenster in offeneFenster { fenster.close() }
        offeneFenster.removeAll()
        super.tearDown()
    }

    /// Die Aktionen sind `private`, ihr Name ist es nicht — danach wird verglichen.
    private func knoepfe(_ panel: SetupFlowPanel, mitAktion name: String) -> [NSButton] {
        panel.debugKnoepfe().filter { $0.action.map(NSStringFromSelector) == name }
    }

    private func panelMitThemeSeite() -> SetupFlowPanel {
        let panel = SetupFlowPanel(connectAction: { _, _, _, _ in throw CancellationError() })
        panel.debugAufbauen(onboardingSeite: 3)
        if let f = panel.debugInhalt?.window { offeneFenster.append(f) }
        return panel
    }

    func test_themeSeite_hatEinenBestaetigungsknopf() {
        let bestaetigen = knoepfe(panelMitThemeSeite(), mitAktion: "onOnboardingNext:")
        XCTAssertEqual(bestaetigen.count, 1,
                       "Ohne genau einen Knopf auf onOnboardingNext endet die Ersteinrichtung in einer Sackgasse.")
        XCTAssertTrue(bestaetigen.first?.isEnabled ?? false)
    }

    func test_bestaetigungsknopf_reagiertAufDieEingabetaste() {
        let bestaetigen = knoepfe(panelMitThemeSeite(), mitAktion: "onOnboardingNext:").first
        XCTAssertEqual(bestaetigen?.keyEquivalent, "\r",
                       "Der Melder kam weder mit Maus noch Tastatur weiter — die Eingabetaste gehört dazu.")
    }

    /// Der Test, den ein Blick auf den Quelltext nicht ersetzt: Liegt der Knopf im
    /// sichtbaren Bereich des Fensters?
    func test_bestaetigungsknopf_liegtImSichtbarenFenster() throws {
        let panel = panelMitThemeSeite()
        let inhalt = try XCTUnwrap(panel.debugInhalt)
        let knopf = try XCTUnwrap(knoepfe(panel, mitAktion: "onOnboardingNext:").first)

        let rahmen = knopf.convert(knopf.bounds, to: inhalt)
        XCTAssertTrue(inhalt.bounds.contains(rahmen),
                      "Knopf bei \(rahmen) liegt nicht vollständig im Fenster \(inhalt.bounds) — "
                      + "das Panel ist auf feste 520 Punkt Höhe genagelt und wächst nicht mit.")
        XCTAssertGreaterThan(rahmen.height, 0)
        XCTAssertGreaterThan(rahmen.width, 0)
    }

    /// Gegenprobe: Auch der Galerie-Verweis und die vier Theme-Kacheln müssen sichtbar
    /// bleiben. Ein Knopf, der die Kacheln aus dem Fenster drückt, wäre kein Fortschritt.
    func test_themeKachelnUndGalerieBleibenSichtbar() throws {
        let panel = panelMitThemeSeite()
        let inhalt = try XCTUnwrap(panel.debugInhalt)
        let kacheln = knoepfe(panel, mitAktion: "onThemeGewaehlt:")
        XCTAssertEqual(kacheln.count, 4, "Vier mitgelieferte Themes stehen zur Wahl.")
        for kachel in kacheln {
            let rahmen = kachel.convert(kachel.bounds, to: inhalt)
            XCTAssertTrue(inhalt.bounds.contains(rahmen), "Theme-Kachel bei \(rahmen) ragt aus dem Fenster.")
        }
    }
}
