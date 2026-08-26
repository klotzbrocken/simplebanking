import XCTest
@testable import simplebanking

// MARK: - Theme-Auswahl im Assistenten
//
// Zur Wahl stehen nur die vier mitgelieferten Themes. Mehr wäre eine Bibliothek im
// Programm, und die gehört auf die Website: Dort steht die Galerie, dort wächst die
// Auswahl, ohne dass jemand die App aktualisieren muss.

@MainActor
final class ThemeAuswahlTests: XCTestCase {

    /// Genau diese vier liegen im Programm. Kommt eines dazu oder fällt eines weg, muss
    /// die Liste im Assistenten mitwandern — sonst zeigt er eine leere Kachel oder
    /// unterschlägt ein vorhandenes Theme.
    func test_vierThemesSindMitgeliefert() {
        let eingebaut = Set(ThemeManager.builtInThemes.keys)
        XCTAssertEqual(eingebaut, ["default.cfg", "sunrise.cfg", "gameboy.cfg", "btx.cfg"])
    }

    /// Die im Assistenten angebotenen Kennungen müssen sich auch laden lassen.
    func test_angeboteneThemesExistieren() {
        let angeboten = ["default", "sunrise", "gameboy", "btx"]
        let vorhanden = Set(ThemeManager.shared.availableThemes().map(\.id))
        for id in angeboten {
            XCTAssertTrue(vorhanden.contains(id),
                          "\(id) wird im Assistenten angeboten, ist aber nicht ladbar")
        }
    }

    /// Die Vorschau zeichnet aus den Werten des Themes. Sie muss deshalb für jedes Theme
    /// eine Kartenfarbe und eine Schriftfarbe bekommen — sonst wäre die Kachel leer oder
    /// unlesbar.
    func test_jedesThemeLiefertVorschaufarben() {
        for theme in ThemeManager.shared.availableThemes() {
            for dunkel in [true, false] {
                let flaeche = theme.surfaceColor(dark: dunkel)
                let tinte = theme.inkColor(dark: dunkel)
                XCTAssertNotEqual(flaeche, tinte,
                                  "\(theme.id) (dunkel=\(dunkel)): Schrift und Fläche gleich — die Vorschau wäre leer")
            }
            XCTAssertNotNil(theme.accentColor)
        }
    }
}
