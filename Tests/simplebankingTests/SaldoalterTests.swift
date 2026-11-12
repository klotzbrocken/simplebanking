import XCTest
@testable import simplebanking

// MARK: - Das Alter eines Kontostands
//
// Gemeldet am 06.11.2026 („ING zeigt einen anderen Kontostand"): Die Frage war mit der
// damaligen Anzeige nicht zu beantworten, weil das Alter der Zahl nicht ablesbar war.
// Diese Tests halten die drei Stellen fest, an denen es schiefgegangen ist.

final class SaldoalterTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Eigene Domäne, damit der Test nichts von der echten Installation anfasst.
        defaults = UserDefaults(suiteName: "SaldoalterTests")!
        defaults.removePersistentDomain(forName: "SaldoalterTests")
    }

    func testOhneAbrufKeinZeitpunkt() {
        XCTAssertNil(Saldoalter.zeitpunkt(slotId: "ing", defaults: defaults))
    }

    func testGemerkterZeitpunktKommtZurueck() {
        let jetzt = Date(timeIntervalSince1970: 1_762_000_000)
        Saldoalter.merken(slotId: "ing", jetzt: jetzt, defaults: defaults)
        let gelesen = Saldoalter.zeitpunkt(slotId: "ing", defaults: defaults)
        XCTAssertEqual(gelesen?.timeIntervalSince1970 ?? 0, jetzt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Der eigentliche Fehler im Diagnosebericht: Schreiber und Leser benutzten
    /// verschiedene Schlüssel, und nichts schlug fehl.
    func testZeitpunktGiltJeKonto() {
        Saldoalter.merken(slotId: "ing", defaults: defaults)
        XCTAssertNotNil(Saldoalter.zeitpunkt(slotId: "ing", defaults: defaults))
        XCTAssertNil(Saldoalter.zeitpunkt(slotId: "sparkasse", defaults: defaults))
    }

    // MARK: - Beschriftung

    private var kalender: Calendar {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return k
    }

    func testHeuteZeigtNurDieUhrzeit() {
        let jetzt = kalender.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 18, minute: 30))!
        let vorhin = kalender.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 7))!
        let text = Saldoalter.beschriftung(vorhin, jetzt: jetzt, kalender: kalender)
        XCTAssertEqual(text, "14:07")
    }

    /// Der Kern: „14 Uhr" war von gestern nicht zu unterscheiden.
    func testGesternIstAlsGesternZuErkennen() {
        let jetzt = kalender.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9, minute: 0))!
        let gestern = kalender.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 14, minute: 7))!
        let text = Saldoalter.beschriftung(gestern, jetzt: jetzt, kalender: kalender)
        XCTAssertNotEqual(text, "14:07", "gestern darf nicht wie heute aussehen")
        XCTAssertTrue(text.contains("14:07"), "die Uhrzeit bleibt: \(text)")
    }

    func testAelteresTraegtSeinDatum() {
        let jetzt = kalender.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9, minute: 0))!
        let lange = kalender.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 14, minute: 7))!
        let text = Saldoalter.beschriftung(lange, jetzt: jetzt, kalender: kalender)
        XCTAssertTrue(text.contains("29"), "ohne Datum ist ein acht Tage alter Stand nicht erkennbar: \(text)")
    }
}
