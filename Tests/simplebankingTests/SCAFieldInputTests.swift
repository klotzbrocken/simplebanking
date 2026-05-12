import XCTest
import Routex
@testable import simplebanking

/// Tests für die pure Validierungs-/Hint-Logik des SCA-`.field`-Inputs.
/// UI (`SCAFieldInputPresenter`) wird manuell verifiziert.
final class SCAFieldInputTests: XCTestCase {

    private func spec(
        type: InputType = .number,
        secrecy: SecrecyLevel = .otp,
        min: UInt32? = 6,
        max: UInt32? = 8
    ) -> SCAFieldInput.Spec {
        .init(
            type: type, secrecyLevel: secrecy,
            minLength: min, maxLength: max,
            bankDisplayName: "Test", slotEpochAtRequest: 0
        )
    }

    func test_empty_invalid() {
        XCTAssertFalse(SCAFieldInput.isValid("", spec: spec()))
    }

    func test_underMin_invalid() {
        XCTAssertFalse(SCAFieldInput.isValid("12345", spec: spec()))
    }

    func test_atMin_valid() {
        XCTAssertTrue(SCAFieldInput.isValid("123456", spec: spec()))
    }

    func test_atMax_valid() {
        XCTAssertTrue(SCAFieldInput.isValid("12345678", spec: spec()))
    }

    func test_overMax_invalid() {
        XCTAssertFalse(SCAFieldInput.isValid("123456789", spec: spec()))
    }

    func test_numberType_rejectsLetters() {
        XCTAssertFalse(SCAFieldInput.isValid("12345A", spec: spec(type: .number)))
    }

    func test_textType_acceptsLetters() {
        XCTAssertTrue(SCAFieldInput.isValid("ABCDEF", spec: spec(type: .text)))
    }

    func test_phoneType_acceptsPunctuation() {
        XCTAssertTrue(SCAFieldInput.isValid("+49 30 1234567",
                                            spec: spec(type: .phone, min: 6, max: 20)))
        XCTAssertFalse(SCAFieldInput.isValid("call me", spec: spec(type: .phone)))
    }

    func test_whitespaceOnly_invalid() {
        XCTAssertFalse(SCAFieldInput.isValid("        ", spec: spec()))
    }

    func test_hint_singleLength() {
        XCTAssertEqual(SCAFieldInput.hint(for: spec(min: 6, max: 6)), "6 Zeichen")
    }

    func test_hint_range() {
        XCTAssertEqual(SCAFieldInput.hint(for: spec(min: 6, max: 8)), "6 bis 8 Zeichen")
    }

    func test_hint_minOnly() {
        XCTAssertEqual(SCAFieldInput.hint(for: spec(min: 6, max: nil)),
                       "mindestens 6 Zeichen")
    }

    func test_hint_noBounds_empty() {
        XCTAssertEqual(SCAFieldInput.hint(for: spec(min: nil, max: nil)), "")
    }
}
