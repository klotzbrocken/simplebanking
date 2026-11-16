import XCTest
@testable import simplebanking

// MARK: - Wer eine echte Bank einrichtet, verlässt die Demo
//
// Gemeldet am 16.11.2026: Ein Nutzer hatte im Begrüßungsschirm „Demo" gewählt, danach
// zweimal seine eigene Bank eingerichtet und zweimal die Demo zurückbekommen. Umsätze,
// die er nicht kannte, kein Kontostand von seiner Bank, und nach dem Neustart war sein
// Konto weg und die Demo-Bank wieder da.
//
// Die Ursache war eine einzige fehlende Zuweisung: `demoMode` ließ sich nur über das
// Menü („Demo aus") zurücknehmen, und der Start stellt die Marke über vorhandene
// Zugangsdaten. Jeder Weg in den Einrichtungsassistenten muss sie deshalb vorher
// löschen.
//
// Das ist am Verhalten nicht prüfbar — `BalanceBar` ist das Fenster selbst, mit
// `NSStatusItem` und modalen Blättern. Also prüfen wir den Quelltext, wie bei den
// anderen Zusagen dieser Art (siehe `Quelltext`).

final class DemoModusVerlassenTests: XCTestCase {

    private func balanceBarOhneKommentare() throws -> String {
        Quelltext.ohneKommentare(try Quelltext.datei("BalanceBar.swift"))
    }

    /// Alle drei Einstiege in eine echte Einrichtung rufen `verlasseDemoModus()`.
    ///
    /// `connect()` zählt mit: Dort entscheidet sich, ob die **Ersteinrichtung** läuft
    /// oder „weiteres Konto". Während Demo-Slots eingehängt sind, liefert
    /// `CredentialsStore.exists()` `false` — die Entscheidung fiel also auf
    /// Ersteinrichtung, und die richtet auf dem Slot „legacy" ein. Genau dort lagen die
    /// Zugangsdaten des Melders.
    func testJederEinstiegVerlaesstVorherDieDemo() throws {
        let quelle = try balanceBarOhneKommentare()
        for funktion in ["private func runSetupWizardIfNeeded() {",
                         "private func _runSetupWizardForAddingAccount(",
                         "@objc private func connect() {"] {
            let koerper = Quelltext.abschnitt(quelle, von: funktion, bis: "\n    }")
            XCTAssertFalse(koerper.isEmpty, "\(funktion) nicht gefunden — Test anpassen")
            XCTAssertTrue(
                koerper.contains("verlasseDemoModus()"),
                "\(funktion) richtet eine echte Bank ein, ohne vorher die Demo zu verlassen")
        }
    }

    /// Die Marke wird an genau einer Stelle zurückgenommen. Zwei Stellen heißt: eine
    /// davon vergisst den Abbau der Demo-Slots oder die Umsatzliste.
    func testDemoModusWirdNurAnEinerStelleAbgeschaltet() throws {
        let quelle = try balanceBarOhneKommentare()
        let zuweisungen = quelle.components(separatedBy: "demoMode = false").count - 1
        XCTAssertEqual(zuweisungen, 1,
                       "`demoMode = false` steht \(zuweisungen)× in BalanceBar — gehört in `verlasseDemoModus`")
        let kern = Quelltext.abschnitt(quelle, von: "private func verlasseDemoModus() {", bis: "\n    }")
        XCTAssertTrue(kern.contains("demoMode = false"), "`verlasseDemoModus` nimmt die Marke nicht zurück")
        XCTAssertTrue(kern.contains("tearDownDemoSlots()"), "ohne Abbau bleiben die Demo-Slots eingehängt")
    }

    /// Das Kennzeichen steht in beiden Fenstern, nicht nur im Tooltip. Der Melder hat
    /// ein Jahr erfundener Umsätze für seine gehalten.
    func testDemoKennzeichenImFlyoutUndInDerUmsatzliste() throws {
        let flyout = Quelltext.ohneKommentare(try Quelltext.datei("BalanceBar.swift"))
        let liste = Quelltext.ohneKommentare(try Quelltext.datei("TransactionsPanelView.swift"))
        XCTAssertTrue(flyout.contains("DemoBadge()"), "Flyout-Karte ohne Demo-Kennzeichen")
        XCTAssertTrue(liste.contains("DemoBadge()"), "Umsatzliste ohne Demo-Kennzeichen")
    }
}
