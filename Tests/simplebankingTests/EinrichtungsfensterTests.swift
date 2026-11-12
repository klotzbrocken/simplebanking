import XCTest
@testable import simplebanking

/// Gemeldet am 11.11.2026: Die beiden Fenster der Einrichtung waren verschieden
/// groß, und beim Übergang sprang das Fenster. Die Maße liegen seitdem an **einer**
/// Stelle; die Zusage hier ist, dass `SetupFlowPanel` sie von dort nimmt.
final class EinrichtungsfensterTests: XCTestCase {

    private func setupFlowOhneKommentare() throws -> String {
        Quelltext.ohneKommentare(try Quelltext.datei("SetupFlowPanel.swift"))
    }

    func testBeideAssistentenHolenIhreGroesseAusEinerQuelle() throws {
        let quelle = try setupFlowOhneKommentare()
        XCTAssertTrue(quelle.contains("InitialSetupExtensionPanel.fensterBreite"),
                      "Die Breite gehört dem Folge-Assistenten, nicht einer zweiten Zahl")
        XCTAssertTrue(quelle.contains("InitialSetupExtensionPanel.fensterHoehe"))
        XCTAssertFalse(quelle.contains("panelWidth: CGFloat = 460"),
                       "Die alte, eigene Breite ist weg")
    }

    func testDerLetzteKnopfBehauptetDasEndeNurWennEsEinsIst() throws {
        let quelle = try setupFlowOhneKommentare()
        XCTAssertTrue(quelle.contains("InitialSetupExtensionPanel.folgtNoch"),
                      "„Los geht's!\" darf nur stehen, wenn danach nichts mehr kommt")
    }

    /// Die Beschriftung hängt an demselben Schlüssel, den der Folge-Assistent setzt.
    func testDerSchluesselStehtNurAnEinerStelle() throws {
        let balanceBar = Quelltext.ohneKommentare(try Quelltext.datei("BalanceBar.swift"))
        XCTAssertFalse(balanceBar.contains("\"simplebanking.initialWizardCompleted\""),
                       "Der Schlüssel gehört InitialSetupExtensionPanel")
    }
}
