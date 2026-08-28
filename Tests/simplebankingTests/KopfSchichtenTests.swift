import XCTest
@testable import simplebanking

// MARK: - Suche und Filter im Kopf der Umsatzliste
//
// Beide Schichten sitzen an derselben Stelle. Das dauerhafte Suchfeld ist entfallen — es
// kostete rund 34 Punkte Höhe für eine Funktion, die man selten braucht —, und die Lupe
// blendet es jetzt bei Bedarf ein.
//
// Der wichtigste Test ist der letzte: Wird die Suche geschlossen, muss die Eingabe weg.
// Solange das Feld dauerhaft stand, konnte niemand eine unsichtbare Suche übersehen.

final class KopfSchichtenTests: XCTestCase {

    func test_lupeOeffnetUndSchliesstWieder() {
        let zu = KopfSchichten()
        let offen = zu.nachLupe()
        XCTAssertTrue(offen.suche)
        XCTAssertFalse(offen.nachLupe().suche, "zweiter Druck schließt")
    }

    func test_filterOeffnetUndSchliesstWieder() {
        let offen = KopfSchichten().nachFilter()
        XCTAssertTrue(offen.filter)
        XCTAssertFalse(offen.nachFilter().filter)
    }

    /// Der Kern: nie beide gleichzeitig.
    func test_dieEineSchichtSchliesstDieAndere() {
        let mitFilter = KopfSchichten(suche: false, filter: true)
        let nachLupe = mitFilter.nachLupe()
        XCTAssertTrue(nachLupe.suche)
        XCTAssertFalse(nachLupe.filter, "die Filterpillen müssen weichen")

        let mitSuche = KopfSchichten(suche: true, filter: false)
        let nachFilter = mitSuche.nachFilter()
        XCTAssertTrue(nachFilter.filter)
        XCTAssertFalse(nachFilter.suche, "die Suche muss weichen")
    }

    func test_nieBeideGleichzeitig() {
        for suche in [true, false] {
            for filter in [true, false] {
                let start = KopfSchichten(suche: suche, filter: filter)
                for danach in [start.nachLupe(), start.nachFilter()] {
                    XCTAssertFalse(danach.suche && danach.filter,
                                   "aus (\(suche), \(filter)) wurden beide offen")
                }
            }
        }
    }

    /// Wird die Suche geschlossen, muss die Eingabe geleert werden — sonst filtert eine
    /// unsichtbare Suche die Liste weiter, und es sieht aus, als fehlten Buchungen.
    func test_schliessenDerSucheWirdGemeldet() {
        let offen = KopfSchichten(suche: true, filter: false)

        XCTAssertTrue(offen.nachLupe().schliesstDieSuche(gegenueber: offen),
                      "zweiter Druck auf die Lupe")
        XCTAssertTrue(offen.nachFilter().schliesstDieSuche(gegenueber: offen),
                      "Filter verdrängt die Suche")

        let zu = KopfSchichten()
        XCTAssertFalse(zu.nachLupe().schliesstDieSuche(gegenueber: zu),
                       "Öffnen darf die Eingabe nicht leeren")
    }
}
