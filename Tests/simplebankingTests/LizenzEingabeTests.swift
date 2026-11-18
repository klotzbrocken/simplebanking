import XCTest
@testable import simplebanking

// MARK: - Was als Lizenz-Key durchgeht
//
// Gemeldet am 17.11.2026: Ein Kunde hatte zehn Minuten vorher bezahlt, tippte sechs
// Zeichen in das Feld und bekam „Lizenz-Key nicht gefunden". Das ist die Antwort des
// Servers (HTTP 404) auf einen Schlüssel, den es nicht gibt, und sie klingt nach einem
// verlorenen Kauf statt nach einer Verwechslung. Dazu war das Feld ein Punktefeld: Sechs
// eingetippte Zeichen sahen aus wie vierzig.
//
// Die Längenprüfung ist mit Absicht großzügig. Ein Muster, das Polar morgen anders
// erzeugt, sperrte sonst zahlende Kunden aus.
final class LizenzEingabeTests: XCTestCase {

    func testEchterKeyGehtDurch() {
        XCTAssertTrue(LicenseClipboardScanner.koennteKeySein(
            "SMPLBNKNG-4F2A9C01-1B2C-4D3E-9F10-ABCDEF123456"))
        XCTAssertTrue(LicenseClipboardScanner.koennteKeySein(
            "4f2a9c01-1b2c-4d3e-9f10-abcdef123456"))
    }

    func testBestellnummerUndBruchstueckeNicht() {
        XCTAssertFalse(LicenseClipboardScanner.koennteKeySein("123456"))
        XCTAssertFalse(LicenseClipboardScanner.koennteKeySein("SMPLBNKNG"))
        XCTAssertFalse(LicenseClipboardScanner.koennteKeySein(""))
        XCTAssertFalse(LicenseClipboardScanner.koennteKeySein("   "))
    }

    /// Leerzeichen und Zeilenumbrüche aus dem Kopieren zählen nicht mit, weder für
    /// die Länge noch später beim Senden.
    func testRaenderZaehlenNichtMit() {
        XCTAssertFalse(LicenseClipboardScanner.koennteKeySein("  1234  \n"))
        XCTAssertTrue(LicenseClipboardScanner.koennteKeySein(
            "\n  SMPLBNKNG-4F2A9C01-1B2C-4D3E-9F10-ABCDEF123456  \n"))
    }

    /// Die Erkennung in der Zwischenablage bleibt strenger als die Längenprüfung:
    /// Sie darf nur anbieten, was wirklich wie ein Key aussieht.
    func testZwischenablageBleibtStreng() {
        let text = "Deine Bestellung 06675d99 ist da. License key: SMPLBNKNG-4F2A9C01-1B2C-4D3E-9F10-ABCDEF123456"
        XCTAssertEqual(LicenseClipboardScanner.extractKey(from: text),
                       "SMPLBNKNG-4F2A9C01-1B2C-4D3E-9F10-ABCDEF123456")
        XCTAssertNil(LicenseClipboardScanner.extractKey(from: "Bestellnummer 06675d99-f56d"))
    }
}
