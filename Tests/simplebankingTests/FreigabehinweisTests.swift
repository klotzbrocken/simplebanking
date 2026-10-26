import XCTest
@testable import simplebanking

/// Gefragt am 26.10.2026: „Zeigen wir beim Einrichten an, wo die Freigabe zu
/// bestätigen ist, z.B. die s-pushTAN-App bei der Sparkasse?" Antwort war nein —
/// obwohl die Bank beides mitschickt, ihren eigenen Satz (`dialogMsg`) und den
/// Namen des Verfahrens. Beides landete nur im Protokoll.
final class FreigabehinweisTests: XCTestCase {

    // MARK: - Was die Bank sagt, hat Vorrang

    func test_bankhinweisSchlaegtDenAllgemeinenText() {
        let mitHinweis = SetupProgress.requestingApproval(
            bankhinweis: "Bitte bestätigen Sie den Auftrag in der S-pushTAN-App.",
            verfahren: "S-pushTAN")
        XCTAssertEqual(mitHinweis.subtitle, "Bitte bestätigen Sie den Auftrag in der S-pushTAN-App.")
    }

    func test_ohneBankhinweisKommtDerVerfahrensname() {
        let nurVerfahren = SetupProgress.requestingApproval(bankhinweis: nil, verfahren: "S-pushTAN")
        XCTAssertTrue(nurVerfahren.subtitle.contains("S-pushTAN"),
                      "Der Name des Verfahrens ist der einzige Anhaltspunkt, den der Nutzer dann hat")
    }

    func test_ohneAllesBleibtEsBeimAltenSatz() {
        let leer = SetupProgress.requestingApproval(bankhinweis: nil, verfahren: nil)
        XCTAssertTrue(leer.subtitle.lowercased().contains("app"),
                      "Ohne Angaben muss der bisherige Hinweis stehen bleiben")
    }

    /// Leerzeichen sind kein Hinweis. Eine Bank, die einen leeren String schickt,
    /// darf den Nutzer nicht vor einer leeren Zeile stehen lassen.
    func test_leererBankhinweisZaehltNicht() {
        let leer = SetupProgress.requestingApproval(bankhinweis: "   \n ", verfahren: nil)
        XCTAssertFalse(leer.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Manche Banken schicken an dieser Stelle halbe Hilfeseiten. Die gehören nicht
    /// in eine Untertitelzeile.
    func test_ueberlangerBankhinweisWirdVerworfen() {
        let roman = String(repeating: "x", count: 400)
        let p = SetupProgress.requestingApproval(bankhinweis: roman, verfahren: "photoTAN")
        XCTAssertNotEqual(p.subtitle, roman)
        XCTAssertTrue(p.subtitle.contains("photoTAN"))
    }

    // MARK: - Welche Verfahrensnamen taugen für einen Satz

    func test_technischeKuerzelErgebenKeinenSatz() {
        for roh in ["decoupled", "Decoupled TAN", "TAN", "app", "PUSH", "M1", "2", "", "   "] {
            XCTAssertNil(Verfahrensname.lesbar(aus: roh),
                         "„\(roh)" + "\" benennt nichts, was man in einen Satz setzen kann")
        }
    }

    func test_echteNamenGehenDurch() {
        XCTAssertEqual(Verfahrensname.lesbar(aus: "S-pushTAN"), "S-pushTAN")
        XCTAssertEqual(Verfahrensname.lesbar(aus: "photoTAN"), "photoTAN")
        XCTAssertEqual(Verfahrensname.lesbar(aus: "  VR SecureGo plus  "), "VR SecureGo plus")
    }

    /// Die gemischte Schreibweise der Banken bleibt, aber reine Großschreibung
    /// schreit in einem Satz.
    func test_durchgehendeGrossschreibungWirdGeglaettet() {
        XCTAssertEqual(Verfahrensname.lesbar(aus: "SECUREGO"), "Securego")
        XCTAssertEqual(Verfahrensname.lesbar(aus: "photoTAN"), "photoTAN")
    }

    func test_ganzeSaetzeSindKeinVerfahrensname() {
        XCTAssertNil(Verfahrensname.lesbar(
            aus: "Bitte öffnen Sie Ihre Banking-App und bestätigen Sie dort den Auftrag"))
    }

    // MARK: - Die Code-Eingabe bleibt unberührt

    func test_codeEingabeKlingtNichtNachAppFreigabe() {
        XCTAssertFalse(SetupProgress.enteringCode.subtitle.lowercased().contains("app"))
    }
}
