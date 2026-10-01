import XCTest
@testable import simplebanking

/// Gemeldet am 01.10.2026: „Fixkosten offen" bei der Sparkasse Siegen stand auf 1240,52 €,
/// und die Zahl ließ sich nicht nachrechnen.
///
/// Die Aufschlüsselung im Diagnose-Bericht hat sie aufgeklärt. Die Arithmetik war richtig,
/// der Zyklus auch — aber unter den Posten standen Abos, deren Termin **im vorigen Zyklus**
/// verstrich, ohne dass etwas abgebucht wurde: Consors Finanz zuletzt 15.07., Rossmann
/// 04.08., DisneyPlus 11.08. Das Prädikat verlangte nur „nächste Fälligkeit ≤ Zyklusende",
/// nie „≥ Zyklusanfang". Ein eingestelltes Abo erfüllte das für immer und stand damit
/// dauerhaft in „Noch offen" — mit jedem Monat ein Posten mehr.
///
/// Die Grenze verläuft zwischen zwei Arten von „überfällig":
/// - **in diesem Zyklus** überfällig: zählt weiter mit, das ist vielleicht nur ein paar
///   Tage Verzug.
/// - **vor diesem Zyklus** überfällig: zählt nicht mehr mit, da kommt nichts.
final class ErloschenePostenTests: XCTestCase {

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func tag(_ s: String) -> Date { Self.iso.date(from: s)! }

    private func posten(_ merchant: String,
                        zuletzt: String,
                        betrag: Double = 10,
                        frequenz: PaymentFrequency = .monthly,
                        konfidenz: Double = 0.9) -> RecurringPayment {
        RecurringPayment(merchant: merchant, groupKey: merchant.lowercased(),
                         averageAmount: betrag, occurrences: 4, months: 4,
                         frequency: frequenz, lastDate: zuletzt,
                         category: .other, confidence: konfidenz)
    }

    /// Zyklus wie im gemeldeten Fall: Gehalt am 15., heute der 1.
    private let start = "2026-09-15"
    private let ende = "2026-10-15"

    private func offen(_ p: [RecurringPayment]) -> [String] {
        LeftToPayCalculator.countedPayments(payments: p,
                                           cycleStart: tag(start),
                                           cycleEnd: tag(ende))
            .map(\.merchant)
    }

    // MARK: - Der gemeldete Fehler

    func test_terminImVorigenZyklus_verstrichen_zaehltNichtMehr() {
        // Zuletzt 15.07. → nächster Termin 15.08., also vor dem Zyklusanfang 15.09.
        XCTAssertEqual(offen([posten("Consors Finanz", zuletzt: "2026-07-15", konfidenz: 0.70)]), [])
    }

    /// Die anderen beiden aus dem Bericht — knapper Abstand, derselbe Fehler.
    func test_knappVorDemZyklusanfang_zaehltNichtMehr() {
        XCTAssertEqual(offen([posten("Rossmann", zuletzt: "2026-08-04", konfidenz: 0.79),
                              posten("DisneyPlus", zuletzt: "2026-08-11", konfidenz: 0.70)]), [])
    }

    /// Und die Summe, um die es ging: Diese drei machten 80,16 € der 1240,52 € aus.
    func test_dieDreiAusDemBericht_fallenGemeinsamRaus() {
        let alle = [posten("Consors Finanz", zuletzt: "2026-07-15", betrag: 31.50, konfidenz: 0.70),
                    posten("Rossmann", zuletzt: "2026-08-04", betrag: 41.67, konfidenz: 0.79),
                    posten("DisneyPlus", zuletzt: "2026-08-11", betrag: 6.99, konfidenz: 0.70)]
        XCTAssertEqual(LeftToPayCalculator.compute(payments: alle, salaryDay: 15,
                                                   today: tag("2026-10-01")),
                       0, accuracy: 0.001)
    }

    // MARK: - Was weiter zählen muss

    /// Der Normalfall, und der wichtigste Test hier: Ein Posten, dessen Termin noch
    /// bevorsteht, bleibt offen. Wäre das Prädikat zu streng, verschwände die halbe Liste.
    func test_terminStehtNochAus_bleibtOffen() {
        // Zuletzt 14.09. (voriger Zyklus) → nächster Termin 14.10., mitten im Zyklus.
        XCTAssertEqual(offen([posten("Unbekannt", zuletzt: "2026-09-14", betrag: 600, konfidenz: 1.0)]),
                       ["Unbekannt"])
    }

    /// Innerhalb des Zyklus überfällig: Termin war der 25.09., heute ist der 01.10., es
    /// kam nichts. Das kann Verzug sein — bleibt drin. Genau hier verläuft die Grenze.
    func test_imZyklusUeberfaellig_bleibtOffen() {
        XCTAssertEqual(offen([posten("Zalando", zuletzt: "2026-08-25", betrag: 63.30, konfidenz: 0.70)]),
                       ["Zalando"])
    }

    /// Direkt am Rand: Termin genau am Zyklusanfang zählt noch.
    func test_terminGenauAmZyklusanfang_zaehltMit() {
        XCTAssertEqual(offen([posten("Grenzfall", zuletzt: "2026-08-15")]), ["Grenzfall"])
    }

    /// Und am anderen Rand: Termin genau am Zyklusende zählt auch noch.
    func test_terminGenauAmZyklusende_zaehltMit() {
        XCTAssertEqual(offen([posten("Grenzfall", zuletzt: "2026-09-15")]), [])
        // 15.09. ist der Zyklusanfang selbst — nicht „noch nicht gebucht". Einen Tag
        // davor schon:
        XCTAssertEqual(offen([posten("Grenzfall", zuletzt: "2026-09-14")]), ["Grenzfall"])
    }

    // MARK: - Längere Takte

    /// Bei vierteljährlichen Posten darf die neue Schranke nicht zuschlagen, nur weil der
    /// letzte Termin lange her ist — der nächste ist das Maß.
    func test_vierteljaehrlich_naechsterTerminImZyklus() {
        XCTAssertEqual(offen([posten("Provinzial", zuletzt: "2026-07-01", frequenz: .quarterly)]),
                       ["Provinzial"])
    }

    /// Gegenprobe: vierteljährlich, aber der Termin verstrich einen Zyklus zu früh.
    func test_vierteljaehrlich_terminVorbei_zaehltNicht() {
        XCTAssertEqual(offen([posten("Alt", zuletzt: "2026-05-04", frequenz: .quarterly)]), [])
    }

    func test_jaehrlich_naechsterTerminImZyklus() {
        XCTAssertEqual(offen([posten("Kfz", zuletzt: "2025-10-01", frequenz: .yearly)]), ["Kfz"])
    }

    // MARK: - Unverändert

    func test_unregelmaessigZaehltWeiterNicht() {
        XCTAssertEqual(offen([posten("Tankstelle", zuletzt: "2026-09-14", frequenz: .irregular)]), [])
    }

    func test_niedrigeKonfidenzZaehltWeiterNicht() {
        XCTAssertEqual(offen([posten("Zufall", zuletzt: "2026-09-14", konfidenz: 0.59)]), [])
    }
}
