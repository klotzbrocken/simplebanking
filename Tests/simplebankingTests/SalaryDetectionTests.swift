import XCTest
@testable import simplebanking

// MARK: - Gehaltserkennung für den Zyklusstart
//
// Der erkannte Gehaltseingang verschiebt den Zyklusstart. Ein Fehlalarm lässt
// „Noch offen" bereits gebuchte Fixkosten ein zweites Mal zählen — die Zahl wird
// zu hoch. Deshalb sind Fehlalarme hier teurer als verpasste Treffer: ohne
// Erkennung greift schlicht der eingestellte Gehaltstag.

final class SalaryDetectionTests: XCTestCase {

    private func isSalary(_ text: String, purposeCode: String? = nil) -> Bool {
        AppDelegate.isSalaryCredit(purposeCode: purposeCode, remittance: text, additional: nil)
    }

    // MARK: Echte Gehaltseingänge

    func test_recognisesSalaryWordings() {
        for text in ["GEHALT 07/2026", "Lohn Juli", "GEHALTSZAHLUNG JULI",
                     "Lohnzahlung 07/26", "Bezüge Juli 2026", "gehalt"] {
            XCTAssertTrue(isSalary(text), "nicht erkannt: \(text)")
        }
    }

    /// Der ISO-Code ist eindeutig und gilt unabhängig vom Text.
    func test_isoPurposeCodeAlone() {
        XCTAssertTrue(isSalary("Überweisung", purposeCode: "SALA"))
        XCTAssertTrue(isSalary("", purposeCode: "sala"))
    }

    // MARK: Fehlalarme — der eigentliche Grund für diesen Test

    /// Der konkrete Auslöser: eine Lohnsteuer-Erstattung ist eine Gutschrift,
    /// beginnt mit „LOHN" und verschob den Zyklus.
    func test_lohnsteuerErstattung_isNotSalary() {
        XCTAssertFalse(isSalary("LOHNSTEUER-ERSTATTUNG 2025"))
        XCTAssertFalse(isSalary("Lohnsteuerjahresausgleich"))
        XCTAssertFalse(isSalary("ERSTATTUNG LOHNSTEUER FINANZAMT"))
    }

    func test_otherNonSalaryCredits() {
        for text in ["KURZARBEITERGELD JUNI", "LOHNPFÄNDUNG", "GEHALTSPFÄNDUNG",
                     "LOHNERSATZLEISTUNG", "Rückzahlung", "Zinsgutschrift",
                     "MIETE EINGANG", "PayPal Erstattung"] {
            XCTAssertFalse(isSalary(text), "Fehlalarm: \(text)")
        }
    }

    /// Regression gegen die alte Implementierung: sie prüfte `contains` ohne
    /// Wortgrenze, „VERGLEICHSLOHN" o.ä. hätte mitten im Wort gezündet.
    func test_salaryWordInsideAnotherWord_isNotSalary() {
        XCTAssertFalse(isSalary("VERGLEICHSLOHN ABRECHNUNG"))
        XCTAssertFalse(isSalary("STUNDENLOHN NACHWEIS"))
    }

    /// Der Ausschluss darf einen echten Gehaltseingang in derselben Zeile nicht
    /// mitnehmen — deshalb prüfen wir hier die Reihenfolge bewusst mit.
    func test_exclusionWins_whenBothPresent() {
        // Bewusst dokumentiert: steht beides drin, gewinnt der Ausschluss.
        // Fehlerkosten-Abwägung — lieber der eingestellte Gehaltstag als eine
        // verschobene Zyklusgrenze.
        XCTAssertFalse(isSalary("GEHALT UND LOHNSTEUERAUSGLEICH"))
    }

    func test_additionalInformationIsAlsoChecked() {
        XCTAssertTrue(AppDelegate.isSalaryCredit(purposeCode: nil, remittance: "",
                                                 additional: "GEHALT 07/2026"))
        XCTAssertFalse(AppDelegate.isSalaryCredit(purposeCode: nil, remittance: "",
                                                  additional: "LOHNSTEUERERSTATTUNG"))
    }

    func test_emptyInput() {
        XCTAssertFalse(isSalary(""))
        XCTAssertFalse(AppDelegate.isSalaryCredit(purposeCode: nil, remittance: "", additional: nil))
    }
}
