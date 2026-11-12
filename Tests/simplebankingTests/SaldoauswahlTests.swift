import XCTest
import RoutexModels
@testable import simplebanking

/// Gemeldet am 20.10.2026: Bei der Postbank hing der Kontostand hinter der Banking-App
/// zurück. Dieselben drei Überweisungen standen in beiden Apps als **gebucht**, der
/// Saldo der Bank enthielt sie, unserer nicht. Vormerkungen gab es keine, der Abruf war
/// erfolgreich (2846 ms laut Diagnose) — die übliche Erklärung „gebucht vs. vorgemerkt"
/// griff also nicht.
///
/// YAXI am 21.10.2026 dazu:
///
/// > richtig, neueres Available sollte älteres Booked schlagen. In diesem Fall ist
/// > Booked der Endsaldo des Vortags.
///
/// Die alte Regel nahm den ersten `Booked` ohne Blick aufs Datum. Diese Tests halten die
/// vier Stufen der von YAXI empfohlenen Auswahl fest.
final class SaldoauswahlTests: XCTestCase {

    private let jetzt = Date(timeIntervalSince1970: 1_792_500_000)   // 20.10.2026, nachmittags
    private var gestern: Date { jetzt.addingTimeInterval(-26 * 3600) }
    private var heuteFrueh: Date { jetzt.addingTimeInterval(-6 * 3600) }

    private func saldo(_ betrag: Decimal, _ typ: BalanceType,
                       am datum: Date? = nil, dispo: Bool? = false) -> Balance {
        Balance(amount: betrag, currency: "EUR", balanceType: typ,
                creditLimitIncluded: dispo, dateTime: datum)
    }

    private func gewaehlt(_ salden: [Balance]) -> Balance? {
        Saldoauswahl.waehle(aus: salden, jetzt: jetzt)
    }

    // MARK: - Der gemeldete Fall

    /// Postbank: gebuchter Tagesabschluss von gestern, aktuelleres Available von heute.
    func test_neueresAvailableSchlaegtAelteresBooked() {
        let gewinner = gewaehlt([
            saldo(521.34, .booked, am: gestern),
            saldo(389.12, .available, am: heuteFrueh)
        ])
        XCTAssertEqual(gewinner?.amount, 389.12)
        XCTAssertEqual(gewinner?.balanceType, .available)
    }

    /// Und das Gegenstück: Ist der gebuchte Saldo der jüngere, gewinnt er.
    func test_neueresBookedSchlaegtAelteresAvailable() {
        let gewinner = gewaehlt([
            saldo(100, .available, am: gestern),
            saldo(250, .booked, am: heuteFrueh)
        ])
        XCTAssertEqual(gewinner?.amount, 250)
    }

    // MARK: - Stufe 1: nur Booked und Available

    /// `Expected` nettet auch eingehende, noch nicht garantierte Beträge und würde den
    /// Kontostand schönrechnen — selbst wenn es der aktuellste Eintrag ist.
    func test_expectedWirdNieGewaehlt() {
        let gewinner = gewaehlt([
            saldo(100, .booked, am: gestern),
            saldo(999, .expected, am: jetzt)
        ])
        XCTAssertEqual(gewinner?.amount, 100)
    }

    func test_nurExpected_ergibtNichts() {
        XCTAssertNil(gewaehlt([saldo(999, .expected, am: jetzt)]))
    }

    func test_leereListe_ergibtNichts() {
        XCTAssertNil(gewaehlt([]))
    }

    // MARK: - Stufe 2: keine eingerechnete Dispo-Linie

    /// Der Grund, aus dem früher hart `Booked` bevorzugt wurde — hier sauber abgefangen,
    /// ohne die Datumsregel zu opfern.
    func test_dispoLinieVerliert_auchWennAktueller() {
        let gewinner = gewaehlt([
            saldo(500, .booked, am: gestern, dispo: false),
            saldo(2500, .available, am: heuteFrueh, dispo: true)
        ])
        XCTAssertEqual(gewinner?.amount, 500, "2500 € enthalten die Dispo-Linie")
    }

    /// Bleibt nur ein Betrag mit Dispo-Linie übrig, ist er besser als nichts.
    func test_nurDispo_wirdGenommen() {
        XCTAssertEqual(gewaehlt([saldo(2500, .available, am: heuteFrueh, dispo: true)])?.amount, 2500)
    }

    // MARK: - Stufe 3: Zukunft wird nachgeordnet, nicht verworfen

    /// Eine Vorausberechnung der Bank oder eine verstellte Uhr — als „aktueller
    /// Kontostand" taugt beides nicht, solange es etwas anderes gibt.
    func test_zukunftVerliertGegenGegenwart() {
        let gewinner = gewaehlt([
            saldo(100, .booked, am: heuteFrueh),
            saldo(777, .available, am: jetzt.addingTimeInterval(48 * 3600))
        ])
        XCTAssertEqual(gewinner?.amount, 100)
    }

    /// Der ING-Fall vom 06.11.2026: Die Bank schickt **einen** Saldo und stempelt ihn
    /// mit Ortszeit, kennzeichnet ihn aber als UTC — gemessen 19:00:04Z zu einer
    /// Protokollzeile um 18:00:04Z, also genau eine Stunde voraus. Als Ausschluss
    /// gelesen hieß das: kein Kontostand, nur eine Meldung. Die verstellte Uhr macht den
    /// Betrag aber nicht falsch.
    func test_nurZukunft_wirdGenommen() {
        let gewinner = gewaehlt([saldo(604.12, .booked, am: jetzt.addingTimeInterval(3600))])
        XCTAssertEqual(gewinner?.amount, 604.12)
    }

    /// Und die Gegenprobe zu Stufe 2: Dispo wiegt schwerer als die Uhr. Ein
    /// zukunftsdatierter Betrag ohne Dispo-Linie ist eher ein Kontostand als ein
    /// gegenwärtiger mit.
    func test_dispoVerliertAuchGegenZukunft() {
        let gewinner = gewaehlt([
            saldo(2500, .available, am: heuteFrueh, dispo: true),
            saldo(300, .booked, am: jetzt.addingTimeInterval(3600), dispo: false)
        ])
        XCTAssertEqual(gewinner?.amount, 300)
    }

    /// Ein Eintrag ohne Datum lässt sich nicht einordnen und landet hinter jedem
    /// datierten — verwerfen wäre falsch, manche Banken liefern gar kein Datum.
    func test_ohneDatum_verliertGegenDatiert() {
        let gewinner = gewaehlt([
            saldo(100, .booked, am: nil),
            saldo(250, .available, am: gestern)
        ])
        XCTAssertEqual(gewinner?.amount, 250)
    }

    func test_ohneDatum_wirdGenommenWennEsNichtsAnderesGibt() {
        XCTAssertEqual(gewaehlt([saldo(100, .booked, am: nil)])?.amount, 100)
    }

    // MARK: - Stufe 4: bei Gleichstand gewinnt Booked

    func test_gleichesDatum_bookedGewinnt() {
        let gewinner = gewaehlt([
            saldo(200, .available, am: heuteFrueh),
            saldo(180, .booked, am: heuteFrueh)
        ])
        XCTAssertEqual(gewinner?.balanceType, .booked)
        XCTAssertEqual(gewinner?.amount, 180)
    }

    /// Die Reihenfolge der Einträge ist laut YAXI nicht zugesichert — sie darf das
    /// Ergebnis also unter keinen Umständen beeinflussen. Genau daran lag der Fehler.
    func test_reihenfolgeEntscheidetNicht() {
        let a = saldo(521.34, .booked, am: gestern)
        let b = saldo(389.12, .available, am: heuteFrueh)
        XCTAssertEqual(gewaehlt([a, b])?.amount, gewaehlt([b, a])?.amount)
    }
}
