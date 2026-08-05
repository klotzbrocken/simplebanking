import XCTest
@testable import simplebanking

// MARK: - Kontostand-Veränderung
//
// Prozent auf einen Kontostand ist mathematisch heikel: Die Basis kann nahe null liegen
// oder negativ sein, und dann sagt der Prozentwert etwas anderes, als er soll. Genau
// diese Fälle stehen hier — die naive Formel `(jetzt − damals) / damals` würde bei
// mehreren davon durchfallen.

final class BalanceChangeTests: XCTestCase {

    private let heute = Date(timeIntervalSince1970: 1_780_000_000)
    private var stichtag: Date { heute.addingTimeInterval(-30 * 86_400) }
    private var historieAlt: Date { heute.addingTimeInterval(-90 * 86_400) }

    private func bezug() -> BalanceChange.Bezug { .init(stichtag: stichtag) }

    // MARK: Normalfall

    /// 3.500 beim Gehaltseingang, seitdem 500 ausgegeben → 3.000, also −14,3 %.
    func test_normalfall_prozent() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: 3_000,
            gebuchteSeitStichtag: [-200, -300],
            bezug: bezug(),
            historieReichtBis: historieAlt
        )
        guard case .prozent(let wert, _) = ergebnis else { return XCTFail("\(ergebnis)") }
        XCTAssertEqual(wert, -500.0 / 3_500.0 * 100, accuracy: 0.01)
        XCTAssertFalse(ergebnis.steigt)
        XCTAssertEqual(BalanceChange.text(ergebnis), "▼ 14,3 %")
    }

    func test_steigenderStand() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: 2_100,
            gebuchteSeitStichtag: [+100],
            bezug: bezug(),
            historieReichtBis: historieAlt
        )
        XCTAssertTrue(ergebnis.steigt)
        XCTAssertEqual(BalanceChange.text(ergebnis), "▲ 5,0 %")
    }

    /// Nichts passiert ist eine gültige Aussage — nicht dasselbe wie „keine Daten".
    func test_keineBewegung_istNullProzentUndNichtNichts() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: 2_000, gebuchteSeitStichtag: [],
            bezug: bezug(), historieReichtBis: historieAlt
        )
        XCTAssertEqual(BalanceChange.text(ergebnis), "▲ 0,0 %")
        XCTAssertNotEqual(ergebnis, .nichts)
    }

    // MARK: Die Prozent-Falle

    /// Basis 10 €: Die Formel lieferte +1000 % — richtig gerechnet, als Aussage neben
    /// einem Kontostand aber unbrauchbar. Deshalb Euro.
    func test_kleineBasis_weichtAufEuroAus() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: 110,
            gebuchteSeitStichtag: [+100],
            bezug: bezug(),
            historieReichtBis: historieAlt
        )
        guard case .euro(let wert, _) = ergebnis else { return XCTFail("\(ergebnis)") }
        XCTAssertEqual(wert, 100)
        // `\u{00A0}` ist kein Tippfehler: Der de_DE-Währungsformatter setzt ein
        // GESCHÜTZTES Leerzeichen vor das €. Mit einem normalen sieht der Vergleich
        // identisch aus und schlägt trotzdem fehl.
        XCTAssertEqual(BalanceChange.text(ergebnis), "▲ 100\u{00A0}€")
    }

    /// **Der Test, der die naive Formel widerlegt.** Von −100 € auf −50 € ist eine
    /// Verbesserung. `(−50 − (−100)) / (−100) = −0,5` ergäbe „▼ 50 %" — also genau die
    /// gegenteilige Aussage. Erwartet wird Euro UND ein steigender Pfeil.
    func test_negativeBasis_kehrtDieAussageNichtUm() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: -50,
            gebuchteSeitStichtag: [+50],
            bezug: bezug(),
            historieReichtBis: historieAlt
        )
        guard case .euro(let wert, _) = ergebnis else {
            return XCTFail("bei negativer Basis darf nicht in Prozent gerechnet werden: \(ergebnis)")
        }
        XCTAssertEqual(wert, 50)
        XCTAssertTrue(ergebnis.steigt, "Schuldenabbau ist eine Verbesserung")
        XCTAssertEqual(BalanceChange.text(ergebnis), "▲ 50\u{00A0}€")
    }

    /// Die Grenze selbst ist eine bewusst gewählte Zahl.
    func test_grenzeDerProzentBasis() {
        XCTAssertEqual(BalanceChange.minimaleProzentBasis, 100)
        XCTAssertTrue(BalanceChange.prozentTraegt(basis: 100))
        XCTAssertFalse(BalanceChange.prozentTraegt(basis: 99.99))
        XCTAssertFalse(BalanceChange.prozentTraegt(basis: 0))
        XCTAssertFalse(BalanceChange.prozentTraegt(basis: -1))
    }

    // MARK: Datengrenzen

    /// Reicht die lokale Historie nicht bis zum Stichtag, fehlen Buchungen — das
    /// Ergebnis wäre zu klein und niemand sähe es der Zahl an. Lieber nichts zeigen.
    func test_zuKurzeHistorie_zeigtNichts() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: 3_000,
            gebuchteSeitStichtag: [-500],
            bezug: bezug(),
            historieReichtBis: heute.addingTimeInterval(-10 * 86_400)   // erst 10 Tage
        )
        XCTAssertEqual(ergebnis, .nichts)
        XCTAssertNil(BalanceChange.text(ergebnis))
    }

    func test_ohneSaldo_zeigtNichts() {
        XCTAssertEqual(
            BalanceChange.berechne(aktuellerStand: nil, gebuchteSeitStichtag: [-10],
                                   bezug: bezug(), historieReichtBis: historieAlt),
            .nichts
        )
    }

    /// Vorgemerkte Buchungen sind im Bank-Saldo nicht enthalten. Der Aufrufer filtert
    /// sie heraus; dieser Test hält fest, dass die Rechnung genau das erwartet — mit
    /// Pending in der Liste käme ein anderer Vergangenheitswert heraus.
    func test_nurGebuchteGehenEin() {
        let nurGebucht = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500],
            bezug: bezug(), historieReichtBis: historieAlt
        )
        let mitPending = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500, -200],
            bezug: bezug(), historieReichtBis: historieAlt
        )
        XCTAssertNotEqual(nurGebucht, mitPending,
                          "wenn das gleich wäre, würde der Filter beim Aufrufer nichts ändern")
    }

    // MARK: Bezug wird mitgeführt

    /// **Kalendarisch, nicht 30 Tage.** Der 3. August vergleicht sich mit dem 3. Juli —
    /// nicht mit dem 4. Juli. Nur so liegt jeder monatliche Posten (Gehalt, Miete)
    /// genau einmal im Fenster; sonst springt der Wert um dessen vollen Betrag, sobald
    /// er durch einen 31-Tage-Monat hinein- oder herausrutscht.
    func test_bezugIstDerselbeTagImVormonat() {
        let kal = Calendar(identifier: .gregorian)
        let bezug = BalanceChange.Bezug.vormonat(von: datum("2026-08-03"), kalender: kal)
        XCTAssertEqual(kal.startOfDay(for: bezug.stichtag), kal.startOfDay(for: datum("2026-07-03")))
    }

    /// Der 31. hat im Vormonat oft keine Entsprechung. `Calendar` kürzt auf den letzten
    /// Tag — geprüft, weil ein Absturz oder ein Sprung ins Vorvormonat hier teuer wäre.
    func test_monatsende_wirdGekuerzt() {
        let kal = Calendar(identifier: .gregorian)
        let bezug = BalanceChange.Bezug.vormonat(von: datum("2026-03-31"), kalender: kal)
        let komponenten = kal.dateComponents([.year, .month, .day], from: bezug.stichtag)
        XCTAssertEqual(komponenten.month, 2)
        XCTAssertEqual(komponenten.day, 28, "2026 ist kein Schaltjahr")
    }

    // MARK: Der Filter in BalanceBar.berechneVeraenderung

    private func datum(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s) ?? Date()
    }

    private func tx(_ betrag: String, _ datum: String, status: String) -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: datum, valueDate: datum, status: status, endToEndId: nil,
            amount: .init(currency: "EUR", amount: betrag),
            creditor: nil, debtor: nil, remittanceInformation: nil,
            additionalInformation: nil, purposeCode: nil
        )
    }

    /// Der Fehler, der beim Sichttest auffiel: Die Demo-Daten schreiben Booked mit
    /// grossem B. Ein Filter auf `== "booked"` warf damit ALLES weg und das Abzeichen
    /// blieb kommentarlos leer. Geprueft wird deshalb auf "nicht pending", case-insensitiv.
    func test_filter_akzeptiertGrossgeschriebenesBooked() {
        let (anzeige, euro) = BalanceChange.ausHistorie(
            [tx("-10,00",  "2026-05-01", status: "Booked"),   // vor dem Stichtag: nur Reichweite
             tx("-100,00", "2026-06-15", status: "Booked"),
             tx("-50,00",  "2026-06-20", status: "booked")],
            stand: 1_000,
            bezug: .init(stichtag: datum("2026-06-01"))
        )
        XCTAssertNotEqual(anzeige, .nichts, "gross geschriebenes Booked darf nicht durchfallen")
        XCTAssertEqual(euro, -150, accuracy: 0.001)
    }

    /// Vorgemerkte bleiben draußen — egal wie die Bank sie schreibt.
    func test_filter_schliesstPendingAus() {
        let (_, euro) = BalanceChange.ausHistorie(
            [tx("-10,00",  "2026-05-01", status: "Booked"),
             tx("-100,00", "2026-06-15", status: "Booked"),
             tx("-999,00", "2026-06-16", status: "pending"),
             tx("-999,00", "2026-06-17", status: "PENDING")],
            stand: 1_000,
            bezug: .init(stichtag: datum("2026-06-01"))
        )
        XCTAssertEqual(euro, -100, accuracy: 0.001, "vorgemerkte Buchungen sind mitgezählt worden")
    }

    // MARK: Welche Historie zählt

    /// Gemeldet am 05.08.2026 als „geht nicht mehr": Im Multi-Banking-Demo blieb das
    /// Abzeichen leer, im Single-Banking-Demo erschien es. Der Grund war kein Fehler in
    /// der Rechnung, sondern dass sie im Multi-Zweig nie aufgerufen wurde.
    func test_einzelkonto_nimmtDasAktive() throws {
        let a = [tx("-10,00", "2026-06-01", status: "Booked")]
        let b = [tx("-20,00", "2026-06-02", status: "Booked")]
        let c = [tx("-30,00", "2026-06-03", status: "Booked")]
        let gewaehlt = BalanceChange.massgeblicheHistorie(
            proKonto: [a, b, c], aktivIndex: 1, aggregiert: false)
        XCTAssertEqual(gewaehlt.count, 1)
        XCTAssertEqual(try XCTUnwrap(gewaehlt.first).parsedAmount, -20, accuracy: 0.001)
    }

    func test_aggregat_nimmtAlle() {
        let a = [tx("-10,00", "2026-06-01", status: "Booked")]
        let b = [tx("-20,00", "2026-06-02", status: "Booked")]
        let gewaehlt = BalanceChange.massgeblicheHistorie(
            proKonto: [a, b], aktivIndex: 0, aggregiert: true)
        XCTAssertEqual(gewaehlt.count, 2)
    }

    /// Der Index kann ins Leere zeigen, wenn gerade ein Konto entfernt wurde. Dann lieber
    /// nichts zeigen als die Zahlen eines fremden Kontos.
    func test_indexAusserhalb_liefertNichts() {
        let a = [tx("-10,00", "2026-06-01", status: "Booked")]
        XCTAssertTrue(BalanceChange.massgeblicheHistorie(
            proKonto: [a], aktivIndex: 7, aggregiert: false).isEmpty)
        XCTAssertTrue(BalanceChange.massgeblicheHistorie(
            proKonto: [], aktivIndex: 0, aggregiert: false).isEmpty)
    }

    /// Der Tooltip nennt den Eurobetrag, weil die Anzeige ein Prozentwert sein kann.
    func test_erklaerungNenntDenEurobetrag() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500],
            bezug: .init(stichtag: stichtag), historieReichtBis: historieAlt
        )
        let text = BalanceChange.erklaerung(ergebnis, bewegungEuro: -500) ?? ""
        XCTAssertTrue(text.contains("500"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Monat"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("weniger"), text)

        let plus = BalanceChange.erklaerung(ergebnis, bewegungEuro: 500) ?? ""
        XCTAssertTrue(plus.localizedCaseInsensitiveContains("mehr"), plus)

        XCTAssertNil(BalanceChange.erklaerung(.nichts, bewegungEuro: 0))
    }
}
