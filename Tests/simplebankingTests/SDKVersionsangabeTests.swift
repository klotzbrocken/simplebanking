import XCTest
@testable import simplebanking

/// Die SDK-Version im Fehlerreport darf keine handgepflegte Konstante sein.
///
/// Bis 2.2.2 gab `ErrorReportStore.routexSDKVersion()` den festen String
/// „0.4.1" zurück, mit dem Kommentar, man möge ihn beim Upgrade mitziehen.
/// Beim Sprung auf 0.5 und 0.6 ist das nicht passiert, also meldete jeder
/// Fehlerreport und jeder Einrichtungsbericht die falsche Version an YAXI.
/// Aufgefallen am 15.11.2026, als der Support einen Bankfehler gegen 0.4.1
/// einordnete, obwohl 0.6.0 lief.
///
/// Der Fehler lässt sich nicht ausführen: in der Testumgebung gibt es die
/// Info.plist des gebauten Bundles nicht, die Funktion liefert hier immer
/// „unknown". Prüfbar ist nur die Zusage am Quelltext selbst.
final class SDKVersionsangabeTests: XCTestCase {

    /// Keine Versionsnummer als Literal in der Funktion.
    func testDieVersionStehtNichtFestImQuelltext() throws {
        let quelle = Quelltext.ohneKommentare(try Quelltext.datei("ErrorReportStore.swift"))
        guard let start = quelle.range(of: "func routexSDKVersion()") else {
            return XCTFail("routexSDKVersion() nicht gefunden, Test an den neuen Namen anpassen")
        }
        let rumpf = quelle[start.upperBound...].prefix(600)
        XCTAssertTrue(
            rumpf.contains("SBRoutexVersion"),
            "Die Version muss aus der Info.plist kommen, die build-app.sh aus Package.resolved füllt"
        )
        XCTAssertNil(
            rumpf.range(of: #""[0-9]+\.[0-9]+\.[0-9]+""#, options: .regularExpression),
            "Keine fest eingetragene SDK-Version: genau die wurde zwei Minor-Versionen lang nicht mitgezogen"
        )
    }

    /// Nur eine Fassung. Die zweite in `DiagnosticSession` war die Ursache.
    func testEsGibtNurEineQuelleFuerDieAngabe() throws {
        let quelle = Quelltext.ohneKommentare(try Quelltext.datei("DiagnosticSession.swift"))
        XCTAssertFalse(
            quelle.contains("SBRoutexVersion"),
            "DiagnosticSession soll ErrorReportStore.routexSDKVersion() aufrufen, nicht die Plist selbst lesen"
        )
    }

    /// Ohne Bundle-Plist eine ehrliche Antwort, keine erfundene Zahl.
    func testOhneInfoPlistKommtUnknown() {
        XCTAssertEqual(ErrorReportStore.routexSDKVersion(), "unknown")
    }
}
