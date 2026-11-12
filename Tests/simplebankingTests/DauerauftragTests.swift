import XCTest
import RoutexClient
@testable import simplebanking

/// Prüft die Umrechnung eines Bank-Dauerauftrags in die Form, die die App anzeigt.
///
/// Der Takt ist eine Zuordnung mit Lücken — `PaymentFrequency` kennt vier Werte, die
/// Bank schickt beliebige Abstände. Die nächste Fälligkeit ist echte Rechnung, und zwar
/// die, bei der man sich vertut: Wer Monate auf *heute* addiert statt auf das
/// Startdatum, verliert bei einem Auftrag zum 31. ab Februar den Tag für immer.
final class DauerauftragTests: XCTestCase {

    private var kalender: Calendar {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return k
    }

    private func tag(_ iso: String) throws -> Date {
        try ISODate(iso).date(in: TimeZone(identifier: "Europe/Berlin")!)
    }

    private func auftrag(
        start: String,
        ende: String? = nil,
        frequenz: Frequency? = .months(1),
        tagImMonat: UInt8? = nil,
        betrag: Decimal = 42,
        empfaenger: String? = "Stadtwerke",
        kennung: String? = nil,
        zweck: [String] = []
    ) throws -> StandingOrder {
        StandingOrder(
            startDate: try ISODate(start),
            endDate: try ende.map { try ISODate($0) },
            frequency: frequenz,
            day: tagImMonat,
            endToEndID: kennung,
            amount: Amount(amount: betrag, currency: "EUR"),
            creditor: Party(name: empfaenger, iban: "DE02120300000000202051"),
            remittanceInformation: zweck
        )
    }

    // MARK: - Takt

    func test_takt_monateDirekt() {
        XCTAssertEqual(Dauerauftrag.takt(.months(1)), .monthly)
        XCTAssertEqual(Dauerauftrag.takt(.months(3)), .quarterly)
        XCTAssertEqual(Dauerauftrag.takt(.months(12)), .yearly)
    }

    func test_takt_halbjaehrlichHatKeineEntsprechung() {
        // Sechs Monate gibt es in `PaymentFrequency` nicht. Lieber „unregelmäßig" als
        // auf „vierteljährlich" runden — das wäre eine falsche Zahl in der Vorschau.
        XCTAssertEqual(Dauerauftrag.takt(.months(6)), .irregular)
    }

    func test_takt_tagesabstaendeWerdenZuMonaten() {
        // Ein Monat ist keine feste Zahl von Tagen; Banken schicken 30 oder 31.
        XCTAssertEqual(Dauerauftrag.takt(.days(30)), .monthly)
        XCTAssertEqual(Dauerauftrag.takt(.days(31)), .monthly)
        XCTAssertEqual(Dauerauftrag.takt(.days(91)), .quarterly)
        XCTAssertEqual(Dauerauftrag.takt(.days(365)), .yearly)
    }

    func test_takt_woechentlichBleibtUnregelmaessig() {
        XCTAssertEqual(Dauerauftrag.takt(.days(7)), .irregular)
        XCTAssertEqual(Dauerauftrag.takt(.days(14)), .irregular)
    }

    func test_takt_ausgewaehlteMonateUeberDieAnzahl() {
        XCTAssertEqual(Dauerauftrag.takt(.variableMonths(Month.allCases)), .monthly)
        XCTAssertEqual(Dauerauftrag.takt(.variableMonths([.march, .june, .september, .december])), .quarterly)
        XCTAssertEqual(Dauerauftrag.takt(.variableMonths([.july])), .yearly)
        XCTAssertEqual(Dauerauftrag.takt(.variableMonths([.march, .september])), .irregular)
    }

    func test_takt_ohneAngabe() {
        XCTAssertEqual(Dauerauftrag.takt(nil), .irregular)
    }

    // MARK: - Nächste Fälligkeit

    func test_naechsteFaelligkeit_monatlichAbStartdatum() throws {
        let d = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-15"), frequenz: .months(1), tag: 15,
            ende: nil, heute: try tag("2026-10-31"), kalender: kalender
        )
        XCTAssertEqual(d, try tag("2026-11-15"))
    }

    func test_naechsteFaelligkeit_heuteIstFaelligkeitstag() throws {
        // Der heutige Tag zählt noch, nicht erst der nächste Monat: Die Bank bucht im
        // Laufe des Tages, und ein Auftrag, der heute läuft, ist keine Vergangenheit.
        let d = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-15"), frequenz: .months(1), tag: 15,
            ende: nil, heute: try tag("2026-10-15"), kalender: kalender
        )
        XCTAssertEqual(d, try tag("2026-10-15"))
    }

    func test_naechsteFaelligkeit_startInDerZukunft() throws {
        // Der Fall, den die Heuristik nie sehen kann: Ein Auftrag, der noch nie gebucht
        // wurde. Genau dafür lohnt der Abruf bei der Bank.
        let d = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2027-03-01"), frequenz: .months(1), tag: 1,
            ende: nil, heute: try tag("2026-10-31"), kalender: kalender
        )
        XCTAssertEqual(d, try tag("2027-03-01"))
    }

    func test_naechsteFaelligkeit_zum31ImFebruarGekapptDanachWiederGanz() throws {
        // Die Regression, um die es geht. Im Februar kappt die Bank auf den 28., im
        // März muss wieder der 31. stehen. Wer von Termin zu Termin Monate addiert,
        // bleibt ab Februar für immer auf dem 28.
        let februar = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-31"), frequenz: .months(1), tag: 31,
            ende: nil, heute: try tag("2026-02-01"), kalender: kalender
        )
        XCTAssertEqual(februar, try tag("2026-02-28"))

        let maerz = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-31"), frequenz: .months(1), tag: 31,
            ende: nil, heute: try tag("2026-03-01"), kalender: kalender
        )
        XCTAssertEqual(maerz, try tag("2026-03-31"))
    }

    func test_naechsteFaelligkeit_ausgelaufenGibtNil() throws {
        let d = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-15"), frequenz: .months(1), tag: 15,
            ende: try tag("2026-06-15"), heute: try tag("2026-10-31"), kalender: kalender
        )
        XCTAssertNil(d, "Ein Auftrag, der im Juni endete, hat keine nächste Ausführung")
    }

    func test_naechsteFaelligkeit_endeAmFaelligkeitstagZaehltNoch() throws {
        let d = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-15"), frequenz: .months(1), tag: 15,
            ende: try tag("2026-11-15"), heute: try tag("2026-10-31"), kalender: kalender
        )
        XCTAssertEqual(d, try tag("2026-11-15"), "Das Enddatum ist der Tag der letzten Ausführung")
    }

    func test_naechsteFaelligkeit_tagesabstand() throws {
        // 01.10. + 14 Tage: 15.10., 29.10., 12.11. — ab dem 31.10. ist der 12.11. dran.
        let d = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-10-01"), frequenz: .days(14), tag: nil,
            ende: nil, heute: try tag("2026-10-31"), kalender: kalender
        )
        XCTAssertEqual(d, try tag("2026-11-12"))
    }

    func test_naechsteFaelligkeit_nurBestimmteMonate() throws {
        // März und September, Tag 1. Am 31.10.2026 ist der nächste der 01.03.2027.
        let d = Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-03-01"), frequenz: .variableMonths([.march, .september]), tag: 1,
            ende: nil, heute: try tag("2026-10-31"), kalender: kalender
        )
        XCTAssertEqual(d, try tag("2027-03-01"))
    }

    func test_naechsteFaelligkeit_ohneTaktKeineVorhersage() throws {
        // `frequency` ist im SDK optional. Ohne sie lässt sich nichts hochrechnen, und
        // ein geratener Termin wäre schlechter als keiner.
        XCTAssertNil(Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-15"), frequenz: nil, tag: 15,
            ende: nil, heute: try tag("2026-10-31"), kalender: kalender
        ))
    }

    func test_naechsteFaelligkeit_abstandNullLaeuftNichtEndlos() throws {
        // Eine krumme Angabe darf die Schleife nicht festhalten.
        XCTAssertNil(Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-15"), frequenz: .months(0), tag: 15,
            ende: nil, heute: try tag("2026-10-31"), kalender: kalender
        ))
        XCTAssertNil(Dauerauftrag.naechsteFaelligkeit(
            start: try tag("2026-01-15"), frequenz: .days(0), tag: nil,
            ende: nil, heute: try tag("2026-10-31"), kalender: kalender
        ))
    }

    // MARK: - Ganze Umrechnung

    func test_aus_uebernimmtDieFelder() throws {
        let o = try auftrag(start: "2026-01-05", frequenz: .months(1), tagImMonat: 5,
                            betrag: 123.45, empfaenger: "Stadtwerke München",
                            kennung: "E2E-7", zweck: ["Miete", "Wohnung 3"])
        let dauer = Dauerauftrag.aus(o, heute: try tag("2026-10-31"),
                                     zeitzone: TimeZone(identifier: "Europe/Berlin")!)

        XCTAssertEqual(dauer.id, "E2E-7")
        XCTAssertEqual(dauer.empfaenger, "Stadtwerke München")
        XCTAssertEqual(dauer.empfaengerIban, "DE02120300000000202051")
        XCTAssertEqual(dauer.betrag, 123.45, accuracy: 0.001)
        XCTAssertEqual(dauer.waehrung, "EUR")
        XCTAssertEqual(dauer.takt, .monthly)
        XCTAssertEqual(dauer.naechsteFaelligkeit, try tag("2026-11-05"))
        XCTAssertEqual(dauer.zweck, "Miete Wohnung 3")
    }

    func test_aus_betragImmerPositiv() throws {
        // Ein Dauerauftrag geht raus; das Vorzeichen trägt keine Information und die
        // Banken halten es nicht einheitlich.
        let raus = try auftrag(start: "2026-01-05", betrag: -99)
        XCTAssertEqual(Dauerauftrag.aus(raus).betrag, 99, accuracy: 0.001)
    }

    func test_aus_ohneKennungStabileId() throws {
        // Ohne `endToEndId` muss die Kennung aus den Daten entstehen — und bei zwei
        // Abrufen desselben Auftrags dieselbe sein, sonst springt die Liste.
        let o = try auftrag(start: "2026-01-05", betrag: 50, kennung: nil)
        let a = Dauerauftrag.aus(o, heute: try tag("2026-10-31"))
        let b = Dauerauftrag.aus(o, heute: try tag("2026-11-30"))
        XCTAssertEqual(a.id, b.id)
        XCTAssertFalse(a.id.isEmpty)
    }

    func test_aus_ohneEmpfaengernameBleibtLesbar() throws {
        let o = try auftrag(start: "2026-01-05", empfaenger: nil)
        XCTAssertFalse(Dauerauftrag.aus(o).empfaenger.isEmpty,
                       "Eine leere Zeile in der Liste ist schlimmer als ein Platzhalter")
    }

    // MARK: - Zusammenführen mit der Erkennung

    func test_passtZu_erkennungKuerztDenNamen() throws {
        let o = try auftrag(start: "2026-01-05", empfaenger: "Stadtwerke München GmbH")
        let d = Dauerauftrag.aus(o)
        XCTAssertTrue(d.passtZu(displayName: "Stadtwerke München"))
        XCTAssertTrue(d.passtZu(displayName: "stadtwerke münchen gmbh"))
    }

    func test_passtZu_fremderEmpfaengerNicht() throws {
        let o = try auftrag(start: "2026-01-05", empfaenger: "Stadtwerke München")
        XCTAssertFalse(Dauerauftrag.aus(o).passtZu(displayName: "Telekom Deutschland"))
    }

    func test_passtZu_kurzeNamenZaehlenNicht() throws {
        // „eon" steckt in „Leonberg" — unter vier Zeichen ist der Teilstring-Vergleich
        // wertlos, also lieber kein Treffer als ein falscher.
        let o = try auftrag(start: "2026-01-05", empfaenger: "EON")
        XCTAssertFalse(Dauerauftrag.aus(o).passtZu(displayName: "Leonberger Bauverein"))
    }

    // MARK: - Als Kandidat der Abo-Liste

    func test_alsKandidat_traegtDenNaechstenTerminUndVolleSicherheit() throws {
        let o = try auftrag(start: "2026-01-05", frequenz: .months(1), tagImMonat: 5, betrag: 980)
        let k = Dauerauftrag.aus(o, heute: try tag("2026-10-31"),
                                 zeitzone: TimeZone(identifier: "Europe/Berlin")!).alsKandidat()

        XCTAssertTrue(k.vonDerBank)
        XCTAssertEqual(k.lastDate, try tag("2026-11-05"), "Bei der Bank ist das Datum die nächste Ausführung")
        XCTAssertGreaterThanOrEqual(k.confidence, 10, "Ein geführter Auftrag ist bestätigt, nicht „möglich“")
        XCTAssertEqual(k.lastAmount, 980, accuracy: 0.001)
        XCTAssertTrue(k.matchedTransactions.isEmpty)
    }

    func test_alsKandidat_vorschauFindetDenTerminWieder() throws {
        // Der Grund, warum `lastDate` den nächsten Termin trägt: `AbosForecast` nimmt
        // ihn als Anker und liefert den ersten Termin ab heute — das ist er selbst.
        let o = try auftrag(start: "2026-01-05", frequenz: .months(1), tagImMonat: 5)
        let k = Dauerauftrag.aus(o, heute: try tag("2026-10-31")).alsKandidat()
        let naechster = AbosForecast.nextPaymentDate(
            after: try tag("2026-10-31"),
            lastDate: AbosForecast.dayKey(k.lastDate),
            frequency: k.cadence
        )
        XCTAssertEqual(naechster.map(AbosForecast.dayKey), AbosForecast.dayKey(k.lastDate))
    }

    // MARK: - Speicherform

    func test_codable_ueberlebtDieRundreise() throws {
        // Der Speicher legt JSON in die UserDefaults. `takt` ist ein Aufzählungswert
        // mit deutschem Rohwert — bricht der, ist die gespeicherte Liste still leer.
        let o = try auftrag(start: "2026-01-05", frequenz: .months(3), tagImMonat: 5, kennung: "E2E-1")
        let vorher = Dauerauftrag.aus(o, heute: try tag("2026-10-31"))
        let nachher = try JSONDecoder().decode(
            Dauerauftrag.self, from: try JSONEncoder().encode(vorher)
        )
        XCTAssertEqual(vorher, nachher)
    }

    func test_beispiele_zeigenBeideFaelle() {
        let b = Dauerauftrag.beispiele(heute: Date())
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b.map(\.takt), [.monthly, .yearly])
        for auftrag in b {
            XCTAssertNotNil(auftrag.naechsteFaelligkeit)
            XCTAssertGreaterThan(auftrag.naechsteFaelligkeit ?? .distantPast, Date().addingTimeInterval(-86400))
        }
    }
}
