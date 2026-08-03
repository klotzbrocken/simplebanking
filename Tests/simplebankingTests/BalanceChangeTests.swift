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

    private func gehalt() -> BalanceChange.Bezug { .seitGehalt(stichtag) }

    // MARK: Normalfall

    /// 3.500 beim Gehaltseingang, seitdem 500 ausgegeben → 3.000, also −14,3 %.
    func test_normalfall_prozent() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: 3_000,
            gebuchteSeitStichtag: [-200, -300],
            bezug: gehalt(),
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
            bezug: gehalt(),
            historieReichtBis: historieAlt
        )
        XCTAssertTrue(ergebnis.steigt)
        XCTAssertEqual(BalanceChange.text(ergebnis), "▲ 5,0 %")
    }

    /// Nichts passiert ist eine gültige Aussage — nicht dasselbe wie „keine Daten".
    func test_keineBewegung_istNullProzentUndNichtNichts() {
        let ergebnis = BalanceChange.berechne(
            aktuellerStand: 2_000, gebuchteSeitStichtag: [],
            bezug: gehalt(), historieReichtBis: historieAlt
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
            bezug: gehalt(),
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
            bezug: gehalt(),
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
            bezug: gehalt(),
            historieReichtBis: heute.addingTimeInterval(-10 * 86_400)   // erst 10 Tage
        )
        XCTAssertEqual(ergebnis, .nichts)
        XCTAssertNil(BalanceChange.text(ergebnis))
    }

    func test_ohneSaldo_zeigtNichts() {
        XCTAssertEqual(
            BalanceChange.berechne(aktuellerStand: nil, gebuchteSeitStichtag: [-10],
                                   bezug: gehalt(), historieReichtBis: historieAlt),
            .nichts
        )
    }

    /// Vorgemerkte Buchungen sind im Bank-Saldo nicht enthalten. Der Aufrufer filtert
    /// sie heraus; dieser Test hält fest, dass die Rechnung genau das erwartet — mit
    /// Pending in der Liste käme ein anderer Vergangenheitswert heraus.
    func test_nurGebuchteGehenEin() {
        let nurGebucht = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500],
            bezug: gehalt(), historieReichtBis: historieAlt
        )
        let mitPending = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500, -200],
            bezug: gehalt(), historieReichtBis: historieAlt
        )
        XCTAssertNotEqual(nurGebucht, mitPending,
                          "wenn das gleich wäre, würde der Filter beim Aufrufer nichts ändern")
    }

    // MARK: Bezug wird mitgeführt

    /// Der Tooltip muss sagen können, welcher Zeitraum gerade gilt — die Anzeige selbst
    /// sieht bei beiden gleich aus.
    func test_bezugSteckImErgebnis() {
        let ausGehalt = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500],
            bezug: .seitGehalt(stichtag), historieReichtBis: historieAlt
        )
        let ausFenster = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500],
            bezug: .letzte30Tage(stichtag), historieReichtBis: historieAlt
        )
        XCTAssertEqual(ausGehalt.bezug, .seitGehalt(stichtag))
        XCTAssertEqual(ausFenster.bezug, .letzte30Tage(stichtag))
        XCTAssertEqual(BalanceChange.text(ausGehalt), BalanceChange.text(ausFenster),
                       "die Anzeige ist identisch — nur der Tooltip unterscheidet sich")
        XCTAssertNil(BalanceChange.Anzeige.nichts.bezug)
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
            bezug: .letzte30Tage(datum("2026-06-01"))
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
            bezug: .letzte30Tage(datum("2026-06-01"))
        )
        XCTAssertEqual(euro, -100, accuracy: 0.001, "vorgemerkte Buchungen sind mitgezählt worden")
    }

    func test_erklaerungNenntBetragUndZeitraum() {
        let ausGehalt = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500],
            bezug: .seitGehalt(stichtag), historieReichtBis: historieAlt
        )
        let text = BalanceChange.erklaerung(ausGehalt, bewegungEuro: -500) ?? ""
        XCTAssertTrue(text.contains("500"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Gehalt"), text)

        let ausFenster = BalanceChange.berechne(
            aktuellerStand: 3_000, gebuchteSeitStichtag: [-500],
            bezug: .letzte30Tage(stichtag), historieReichtBis: historieAlt
        )
        XCTAssertTrue(BalanceChange.erklaerung(ausFenster, bewegungEuro: -500)?
            .contains("30") ?? false)
        XCTAssertNil(BalanceChange.erklaerung(.nichts, bewegungEuro: 0))
    }
}
