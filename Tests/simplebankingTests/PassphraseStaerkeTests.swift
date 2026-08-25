import XCTest
@testable import simplebanking

// MARK: - Einschätzung der Passphrase
//
// Die Anzeige darf in eine Richtung irren: Sie soll eher warnen als beruhigen. Eine
// schwache Passphrase als „gut" auszuweisen wäre der teuerste Fehler an dieser Stelle —
// die Sicherung enthält die Zugangsdaten, und es gibt keine Hintertür.

final class PassphraseStaerkeTests: XCTestCase {

    private func stufe(_ s: String) -> PassphraseStaerke.Stufe { PassphraseStaerke.pruefen(s).stufe }

    func test_zuKurzSchlaegtAllesAndere() {
        XCTAssertEqual(stufe("aB3$x"), .zuKurz)
        XCTAssertEqual(stufe(""), .zuKurz)
        XCTAssertEqual(stufe("kurz!1A"), .zuKurz, "sieben Zeichen sind zu wenig, egal wie bunt")
    }

    /// Länge allein genügt nicht — Wiederholung wird abgestraft.
    func test_wiederholungGiltNichtAlsLaenge() {
        XCTAssertEqual(stufe("aaaaaaaaaaaaaaaaaaaa"), .schwach,
                       "zwanzig gleiche Zeichen sind in Sekunden geraten")
    }

    /// Tastaturmuster und übliche Wörter bekommen einen Abschlag.
    func test_bekannteMusterWerdenAbgewertet() {
        XCTAssertLessThanOrEqual(stufe("passwort1234"), .brauchbar)
        XCTAssertLessThanOrEqual(stufe("qwertzuiop"), .brauchbar)
    }

    /// Der empfohlene Fall: mehrere Wörter. Muss oben herauskommen, sonst empfiehlt die
    /// App etwas, das sie selbst schlecht bewertet.
    func test_mehrereWoerterSindGut() {
        XCTAssertEqual(stufe("korrekt-pferd-batterie-klammer"), .gut)
    }

    func test_kurzAberZufaelligIstNichtGut() {
        XCTAssertLessThanOrEqual(stufe("k7#pQm2z"), .brauchbar,
                                 "acht Zeichen sollten nicht als gut durchgehen")
    }

    /// Die Bewertung darf nie behaupten, etwas sei besser als es ist.
    func test_bitsSteigenNichtOhneGrund() {
        let kurz = PassphraseStaerke.pruefen("abcdefgh").bits
        let lang = PassphraseStaerke.pruefen("abcdefghabcdefgh").bits
        XCTAssertGreaterThanOrEqual(lang, kurz)
    }

    /// Jede Stufe braucht einen Text — die Anzeige zeigt ihn direkt an.
    func test_jedeStufeHatEinenText() {
        for probe in ["kurz", "aaaaaaaaaa", "k7#pQm2z", "korrekt-pferd-batterie-klammer"] {
            XCTAssertFalse(PassphraseStaerke.pruefen(probe).text.isEmpty, probe)
        }
    }
}
