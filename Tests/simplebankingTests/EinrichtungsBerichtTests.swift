import XCTest
@testable import simplebanking

// MARK: - Bericht über die letzte Einrichtung
//
// Eine Ersteinrichtung lässt sich nicht nachspielen — jeder Lauf kostet echte Freigaben.
// Der Bericht wird deshalb im Nachhinein aus dem zusammengelesen, was mitgeschrieben
// wurde. Diese Tests sichern die Auswahllogik: Welche Datei ist der letzte Versuch, und
// welche Traces gehören zeitlich dazu.

final class EinrichtungsBerichtTests: XCTestCase {

    private var ordner: URL!

    override func setUpWithError() throws {
        ordner = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sb-einrichtung-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: ordner)
    }

    /// Fester Bezugspunkt statt `Date()` an jeder Stelle — sonst liegen Dateizeit und
    /// Fenstergrenze Millisekunden auseinander und der Grenzfall ist nicht prüfbar.
    private let jetzt = Date(timeIntervalSince1970: 1_780_000_000)

    private func datei(_ name: String, alter: TimeInterval) throws -> URL {
        let url = ordner.appendingPathComponent(name)
        try "inhalt".write(to: url, atomically: true, encoding: .utf8)
        let zeitpunkt = jetzt.addingTimeInterval(-alter)
        try FileManager.default.setAttributes(
            [.creationDate: zeitpunkt, .modificationDate: zeitpunkt], ofItemAtPath: url.path)
        return url
    }

    // MARK: Zeitfenster

    /// Der Kern: Nur Traces aus dem Zeitfenster des Versuchs gehören in den Bericht.
    /// Wären es alle, läge der HVB-Trace von letzter Woche im Anhang — und der Empfänger
    /// sucht am falschen Tag.
    func test_nurTracesImZeitfenster() throws {
        _ = try datei("yaxi-trace-alt.txt", alter: 7 * 86_400)
        let passend = try datei("yaxi-trace-passend.txt", alter: 60)
        _ = try datei("yaxi-trace-zukunft.txt", alter: -3600)

        let gefunden = SetupDiagnosticsReport.tracesImFensterFuerTests(
            ordner: ordner,
            von: jetzt.addingTimeInterval(-300),
            bis: jetzt
        )
        XCTAssertEqual(gefunden.map(\.lastPathComponent), [passend.lastPathComponent])
    }

    /// Die Grenzen gehören dazu — sonst fällt genau der Trace heraus, der zur ersten
    /// Sekunde des Versuchs geschrieben wurde.
    func test_grenzenSindEinschliessend() throws {
        let genauJetzt = try datei("yaxi-trace-grenze.txt", alter: 100)
        let gefunden = SetupDiagnosticsReport.tracesImFensterFuerTests(
            ordner: ordner,
            von: jetzt.addingTimeInterval(-100),
            bis: jetzt.addingTimeInterval(-100)
        )
        XCTAssertEqual(gefunden.count, 1, "die Grenze selbst muss zählen")
        XCTAssertEqual(gefunden.first?.lastPathComponent, genauJetzt.lastPathComponent)
    }

    /// Nur .txt — im selben Ordner können Reste anderer Art liegen.
    func test_nurTextdateien() throws {
        _ = try datei("yaxi-trace.bin", alter: 10)
        let gefunden = SetupDiagnosticsReport.tracesImFensterFuerTests(
            ordner: ordner, von: jetzt.addingTimeInterval(-60), bis: jetzt)
        XCTAssertTrue(gefunden.isEmpty)
    }

    // MARK: Der jüngste Versuch

    func test_juengsterVersuchGewinnt() throws {
        _ = try datei("simplebanking-setup-alt.txt", alter: 3600)
        let neu = try datei("simplebanking-setup-neu.txt", alter: 30)
        _ = try datei("simplebanking-setup-mittel.txt", alter: 600)

        let gewaehlt = SetupDiagnosticsReport.juengsteDateiFuerTests(ordner: ordner)
        XCTAssertEqual(gewaehlt?.lastPathComponent, neu.lastPathComponent)
    }

    /// Ohne Versuch soll es einen benannten Fehler geben statt eines leeren Berichts,
    /// den niemand als solchen erkennt.
    func test_ohneVersuch_klarerFehler() {
        let leer = ordner.appendingPathComponent("gibtesnicht")
        XCTAssertNil(SetupDiagnosticsReport.juengsteDateiFuerTests(ordner: leer))
        XCTAssertNotNil(SetupDiagnosticsReport.Fehler.keinVersuchGefunden.errorDescription)
    }
}
