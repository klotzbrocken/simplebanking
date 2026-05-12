import XCTest
import Routex
@testable import simplebanking

/// Sichert die Error-Klassifizierung ab, auf der die Catch-Branch-Reihenfolge
/// in `fetchBalances` / `fetchTransactions` / `sendTransfer` aufbaut:
///   - `.Unauthorized` und `.ConsentExpired` müssen `true` liefern, damit der
///     Yaxi-empfohlene „retry ohne ConnectionData"-Branch greift.
///   - `.UnexpectedError` darf NICHT als ConnectionReset zählen — sonst würde
///     der Revolut/Open-Banking-Quirk-Pfad (Stale-Session-Retry) ausfallen.
///   - Andere RoutexClientError-Cases und Nicht-Routex-Errors → `false`.
///
/// Hintergrund: bei 1822direkt-Usern hat eine falsche Branch-Reihenfolge
/// dazu geführt, dass der Stale-Session-Retry vor dem Auth-Retry griff und
/// mit der bereits ungültigen ConnectionData erneut `Unauthorized` warf
/// (2026-05). Diese Tests halten die Klassifizierungs-Tabelle stabil.
final class RoutexClientErrorClassificationTests: XCTestCase {

    func test_unauthorized_isConnectionReset() {
        let err = RoutexClientError.Unauthorized(userMessage: nil)
        XCTAssertTrue(YaxiService.isConnectionResetError(err))
    }

    func test_unauthorized_withMessage_isConnectionReset() {
        let err = RoutexClientError.Unauthorized(userMessage: "Consent invalid")
        XCTAssertTrue(YaxiService.isConnectionResetError(err))
    }

    func test_consentExpired_isConnectionReset() {
        let err = RoutexClientError.ConsentExpired(userMessage: nil)
        XCTAssertTrue(YaxiService.isConnectionResetError(err))
    }

    func test_unexpectedError_withMessage_isNotConnectionReset() {
        // HBCI-Transient-Errors wie „FGW Gatewaywechsel" kommen als
        // UnexpectedError MIT Message — die brauchen NICHT clearAll,
        // nur clearSessionsOnly (Volksbank-Pfad). Branch in isHBCITransientError.
        let err = RoutexClientError.UnexpectedError(userMessage: "FGW Gatewaywechsel")
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_unexpectedError_withDialogkontextMessage_isNotConnectionReset() {
        let err = RoutexClientError.UnexpectedError(userMessage: "Fehlender Dialogkontext")
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_unexpectedError_nilMessage_isConnectionReset() {
        // Build-181-Logik (NetworkService.swift, bei Migration verloren):
        // UnexpectedError ohne userMessage = stale ConnectionData.
        // Muss retry-ohne-CD + Full-Reset triggern — sonst Sparkasse-Bug.
        let err = RoutexClientError.UnexpectedError(userMessage: nil)
        XCTAssertTrue(YaxiService.isConnectionResetError(err))
    }

    func test_unexpectedError_emptyStringMessage_isNotConnectionReset() {
        // Empty-String userMessage ist nicht das gleiche wie nil — wenn die
        // Bank explizit "" sendet, ist das kein „leer = stale CD"-Signal.
        // Bleibt im HBCI-Transient-Pfad.
        let err = RoutexClientError.UnexpectedError(userMessage: "")
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_invalidCredentials_isNotConnectionReset() {
        // Falsche Credentials = User-Fehler, kein Auth-Reset.
        let err = RoutexClientError.InvalidCredentials(userMessage: nil)
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_serviceBlocked_isNotConnectionReset() {
        let err = RoutexClientError.ServiceBlocked(userMessage: nil, code: nil)
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_requestError_isNotConnectionReset() {
        // Netzwerkfehler: eigener Retry-Pfad (isRequestError), nicht Auth.
        let err = RoutexClientError.RequestError(error: "timeout")
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_canceled_isNotConnectionReset() {
        XCTAssertFalse(YaxiService.isConnectionResetError(RoutexClientError.Canceled))
    }

    func test_nonRoutexError_isNotConnectionReset() {
        let err = NSError(domain: "Test", code: 42, userInfo: nil)
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }
}
