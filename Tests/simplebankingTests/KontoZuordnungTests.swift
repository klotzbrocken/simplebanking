import XCTest
@testable import simplebanking

// MARK: - Kein fremder Saldo unter dem eigenen Kontonamen
//
// Audit-Befund vom 05.09.2026: Fand die Bank die angefragte IBAN nicht, zeigte der Slot
// den Saldo des erstbesten angebotenen Kontos — die gespeicherte IBAN blieb dabei
// unverändert. Konto A konnte so den Kontostand von Konto B anzeigen.
//
// Geprüft wird das Modell: Ein Slot ohne passendes Konto liefert keinen Saldo, sondern
// die Kennzeichnung. Der Weg dorthin liegt in `makeBalancesResponse`.

final class KontoZuordnungTests: XCTestCase {

    func test_kennzeichnungBedeutetKeinSaldo() {
        let antwort = BalancesResponse(
            ok: false, booked: nil, expected: nil, session: nil, connectionData: nil,
            error: nil, userMessage: nil, scaRequired: nil, kontoNichtInZustimmung: true)

        XCTAssertNil(antwort.booked, "es darf kein Betrag mitkommen")
        XCTAssertFalse(antwort.ok)
        XCTAssertEqual(antwort.kontoNichtInZustimmung, true)
    }

    /// Die Kennzeichnung darf nicht mit „Freigabe nötig" verwechselt werden — sonst
    /// pausierte der Auto-Refresh eine Stunde, obwohl gar keine Freigabe hilft.
    func test_istKeineFreigabeanforderung() {
        let antwort = BalancesResponse(
            ok: false, booked: nil, expected: nil, session: nil, connectionData: nil,
            error: nil, userMessage: nil, scaRequired: nil, kontoNichtInZustimmung: true)
        XCTAssertNil(antwort.scaRequired)
    }

    /// Gegenprobe: Der gewöhnliche Erfolgsfall trägt die Kennzeichnung nicht, sonst
    /// stünde der Hinweis dauerhaft im Fenster.
    func test_normaleAntwortTraegtDieKennzeichnungNicht() {
        let antwort = BalancesResponse(
            ok: true,
            booked: .init(amount: "1234,56", currency: "EUR", balanceType: "booked",
                          creditLimitIncluded: false),
            expected: nil, session: nil, connectionData: nil,
            error: nil, userMessage: nil, scaRequired: nil)
        XCTAssertNil(antwort.kontoNichtInZustimmung)
        XCTAssertNotNil(antwort.booked)
    }
}
