import XCTest
@testable import simplebanking

/// Sichert, dass der Fortschrittstext der Einrichtung zur SCA-Methode passt:
/// Tipp-TAN (`field`) → „Code eingeben", Push/Decoupled → „Banking-App öffnen…",
/// und der Vor-Fetch-Zustand neutral bleibt. Regression zum HVB-Tipp-TAN-Bug,
/// bei dem eine Code-Eingabe fälschlich als App-Freigabe angekündigt wurde.
final class SCAProgressTextTests: XCTestCase {

    func test_enteringCode_isNotAnAppApprovalMessage() {
        let p = SetupProgress.enteringCode
        XCTAssertTrue(p.displayText.lowercased().contains("code"))
        XCTAssertFalse(p.subtitle.lowercased().contains("app"),
                       "Code-Eingabe darf nicht nach Banking-App-Freigabe klingen")
    }

    func test_requestingApproval_keepsAppMessage() {
        // Push/Decoupled-Bank: Hinweis auf die Banking-App muss erhalten bleiben.
        XCTAssertTrue(SetupProgress.requestingApproval.subtitle.lowercased().contains("app"))
    }

    func test_authenticating_isNeutral() {
        let p = SetupProgress.authenticating
        XCTAssertFalse(p.subtitle.lowercased().contains("app"))
        XCTAssertFalse(p.subtitle.lowercased().contains("code"))
        XCTAssertNotEqual(p.subtitle, SetupProgress.requestingApproval.subtitle)
        XCTAssertNotEqual(p.subtitle, SetupProgress.enteringCode.subtitle)
    }

    func test_distinctIconsForMethods() {
        XCTAssertNotEqual(SetupProgress.enteringCode.iconName, SetupProgress.requestingApproval.iconName)
        XCTAssertNotEqual(SetupProgress.authenticating.iconName, SetupProgress.requestingApproval.iconName)
    }

    /// Spiegelt die Mapping-Logik aus `performSetupConnection`: field → enteringCode,
    /// decoupled → requestingApproval.
    func test_methodHintMapping() {
        func progress(for hint: SCAMethodHint) -> SetupProgress {
            hint == .fieldInput ? .enteringCode : .requestingApproval
        }
        XCTAssertEqual(progress(for: .fieldInput).displayText, SetupProgress.enteringCode.displayText)
        XCTAssertEqual(progress(for: .decoupledApproval).subtitle, SetupProgress.requestingApproval.subtitle)
    }
}
