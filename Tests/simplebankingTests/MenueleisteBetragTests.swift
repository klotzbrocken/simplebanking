import XCTest
@testable import simplebanking

/// Gemeldet am 04.10.2026: „Das Tausendertrennzeichen ist eine Stelle zu weit links
/// (also eher ein Zehntausendertrennzeichen, bspw. 1.2345)."
///
/// Zutreffend. Im Aggregat-Titel der Menüleiste stand eine von Hand gebaute Gruppierung:
///
///     text.reversed().enumerated()
///         .map { $0.offset > 0 && $0.offset % 3 == 0 ? ".\($0.element)" : String($0.element) }
///         .reversed().joined()
///
/// Eine Umkehrung zu viel. Das Trennzeichen wurde im rückwärts gelesenen Text **vor** die
/// Ziffer gesetzt; nach dem Zurückdrehen der Liste stand es dann davor statt dahinter.
/// Aus 12345 wurde „1.2345", aus 1234567 sogar „.123.4567" mit führendem Punkt.
@MainActor
final class MenueleisteBetragTests: XCTestCase {

    private func formatiert(_ v: Double) -> String {
        AppDelegate.ganzzahlFormatter.string(from: NSNumber(value: v)) ?? "—"
    }

    // MARK: - Der gemeldete Fall

    func test_fuenfstellig() {
        XCTAssertEqual(formatiert(12345), "12.345")
    }

    func test_siebenstellig_hatKeinenFuehrendenPunkt() {
        XCTAssertEqual(formatiert(1_234_567), "1.234.567")
    }

    // MARK: - Die Ränder

    /// Unter tausend darf gar kein Trennzeichen stehen.
    func test_dreistellig_ohneTrennzeichen() {
        XCTAssertEqual(formatiert(999), "999")
    }

    func test_genauTausend() {
        XCTAssertEqual(formatiert(1000), "1.000")
    }

    func test_null() {
        XCTAssertEqual(formatiert(0), "0")
    }

    /// Das Vorzeichen setzen die Aufrufer selbst (sie stellen das Währungszeichen davor),
    /// deshalb bekommt der Formatierer nur Beträge ohne Vorzeichen. Käme doch einer
    /// durch, darf er nicht stillschweigend verschwinden.
    func test_negativBleibtNegativ() {
        XCTAssertEqual(formatiert(-12345), "-12.345")
    }

    // MARK: - Keine Nachkommastellen

    /// In der Leiste steht der Saldo ohne Nachkommastellen — das ist der Grund, warum die
    /// Maske „•••.••" falsch war: Sie zeigte zwei Stellen, die es dort nicht gibt.
    func test_keineNachkommastellen() {
        XCTAssertEqual(formatiert(1234.56), "1.235")
        XCTAssertEqual(formatiert(1234.49), "1.234")
    }

    /// Deutsche Schreibweise, unabhängig von der Systemsprache. Der Nutzer, der das
    /// gemeldet hat, führte als zweite Beobachtung an, der Punkt in der Maske sehe nach
    /// angelsächsischer Dezimaltrennung aus — genau diese Verwechslung soll nicht
    /// entstehen.
    func test_deutschesTrennzeichen() {
        XCTAssertTrue(formatiert(12345).contains("."))
        XCTAssertFalse(formatiert(12345).contains(","))
    }
}
