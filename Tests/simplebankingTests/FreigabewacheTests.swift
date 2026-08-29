import XCTest
@testable import simplebanking

// MARK: - Eine Bankfreigabe zur Zeit
//
// Gemeldet am 29.08.2026: bunq verlangte bei **jedem** Abruf eine neue Freigabe. Im
// Protokoll standen 44 geöffnete Freigabe-Seiten. Die Kette war:
//
//   Abruf → Freigabe-Seite öffnet → Nutzer bestätigt gerade → Kontowechsel bricht ab
//   → nächster Abruf → neue Freigabe-Seite → …
//
// Zwei Sperren beenden das: keine zweite Seite, solange eine aussteht, und ein
// Kontowechsel bricht eine laufende Freigabe nicht mehr ab. Diese Tests halten die erste
// fest; die zweite hängt an derselben Auskunft.

final class FreigabewacheTests: XCTestCase {

    func test_ersterVorgangDarf() async {
        let wache = Freigabewache()
        let darf = await wache.beginnen("bunq")
        XCTAssertTrue(darf)
    }

    /// Der Kern: Solange eine Freigabe aussteht, darf keine zweite Seite aufgehen.
    func test_zweiterVorgangDarfNicht() async {
        let wache = Freigabewache()
        _ = await wache.beginnen("bunq")
        let zweiter = await wache.beginnen("bunq")
        XCTAssertFalse(zweiter, "eine zweite Freigabe-Seite macht die begonnene wertlos")
    }

    /// Ein anderes Konto ist ein anderer Vorgang — die Sperre gilt je Konto.
    func test_anderesKontoIstNichtGesperrt() async {
        let wache = Freigabewache()
        _ = await wache.beginnen("bunq")
        let anderes = await wache.beginnen("sparkasse")
        XCTAssertTrue(anderes)
    }

    func test_nachDemBeendenDarfWieder() async {
        let wache = Freigabewache()
        _ = await wache.beginnen("bunq")
        await wache.beenden("bunq")
        let erneut = await wache.beginnen("bunq")
        XCTAssertTrue(erneut)
    }

    /// **Ohne Verfall bliebe ein abgestürzter Vorgang für immer stehen** und das Konto
    /// wäre dauerhaft blockiert — schlimmer als das Problem, das die Sperre löst.
    func test_vergessenerVorgangVerfaellt() async {
        let wache = Freigabewache()
        let start = Date()
        _ = await wache.beginnen("bunq", jetzt: start)

        let kurzDanach = start.addingTimeInterval(Freigabewache.hoechstdauer - 1)
        let nochGesperrt = await wache.beginnen("bunq", jetzt: kurzDanach)
        XCTAssertFalse(nochGesperrt, "innerhalb der Frist bleibt es gesperrt")

        let spaeter = start.addingTimeInterval(Freigabewache.hoechstdauer + 1)
        let wiederFrei = await wache.beginnen("bunq", jetzt: spaeter)
        XCTAssertTrue(wiederFrei, "nach der Frist muss es weitergehen")
    }

    /// Die Auskunft, an der der Kontowechsel hängt.
    func test_laeuftIrgendwo() async {
        let wache = Freigabewache()
        var irgendwo = await wache.laeuftIrgendwo()
        XCTAssertFalse(irgendwo)

        _ = await wache.beginnen("bunq")
        irgendwo = await wache.laeuftIrgendwo()
        XCTAssertTrue(irgendwo, "solange das wahr ist, darf ein Kontowechsel nichts abbrechen")

        await wache.beenden("bunq")
        irgendwo = await wache.laeuftIrgendwo()
        XCTAssertFalse(irgendwo)
    }
}
