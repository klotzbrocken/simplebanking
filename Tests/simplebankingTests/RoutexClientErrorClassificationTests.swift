import XCTest
import Foundation
import RoutexClient
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
        let err = RoutexError.unauthorized(userMessage: nil)
        XCTAssertTrue(YaxiService.isConnectionResetError(err))
    }

    func test_unauthorized_withMessage_isConnectionReset() {
        let err = RoutexError.unauthorized(userMessage: "Consent invalid")
        XCTAssertTrue(YaxiService.isConnectionResetError(err))
    }

    func test_consentExpired_isConnectionReset() {
        let err = RoutexError.unauthorized(userMessage: nil)
        XCTAssertTrue(YaxiService.isConnectionResetError(err))
    }

    func test_unexpectedError_withMessage_isNotConnectionReset() {
        // HBCI-Transient-Errors wie „FGW Gatewaywechsel" kommen als
        // UnexpectedError MIT Message — die brauchen NICHT clearAll,
        // nur clearSessionsOnly (Volksbank-Pfad). Branch in isHBCITransientError.
        let err = RoutexError.unexpectedError(userMessage: "FGW Gatewaywechsel")
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_unexpectedError_withDialogkontextMessage_isNotConnectionReset() {
        let err = RoutexError.unexpectedError(userMessage: "Fehlender Dialogkontext")
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_unexpectedError_nilMessage_isConnectionReset() {
        // Build-181-Logik (NetworkService.swift, bei Migration verloren):
        // UnexpectedError ohne userMessage = stale ConnectionData.
        // Muss retry-ohne-CD + Full-Reset triggern — sonst Sparkasse-Bug.
        let err = RoutexError.unexpectedError(userMessage: nil)
        XCTAssertTrue(YaxiService.isConnectionResetError(err))
    }

    func test_unexpectedError_emptyStringMessage_isNotConnectionReset() {
        // Empty-String userMessage ist nicht das gleiche wie nil — wenn die
        // Bank explizit "" sendet, ist das kein „leer = stale CD"-Signal.
        // Bleibt im HBCI-Transient-Pfad.
        let err = RoutexError.unexpectedError(userMessage: "")
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_invalidCredentials_isNotConnectionReset() {
        // Falsche Credentials = User-Fehler, kein Auth-Reset.
        let err = RoutexError.invalidCredentials(userMessage: nil)
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_serviceBlocked_isNotConnectionReset() {
        let err = RoutexError.serviceBlocked(code: nil, userMessage: nil)
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_requestError_isNotConnectionReset() {
        // Netzwerkfehler: eigener Retry-Pfad (isRequestError), nicht Auth.
        let err = HTTPError.transportFailure(underlying: URLError(.timedOut))
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }

    func test_canceled_isNotConnectionReset() {
        XCTAssertFalse(YaxiService.isConnectionResetError(RoutexError.canceled))
    }

    func test_nonRoutexError_isNotConnectionReset() {
        let err = NSError(domain: "Test", code: 42, userInfo: nil)
        XCTAssertFalse(YaxiService.isConnectionResetError(err))
    }
}

/// Sichert die Klassifikation ab, die entscheidet, ob eine Überweisung nach einem
/// Fehler als „fehlgeschlagen" oder als „Status unklar" gezeigt wird. Bis 2.0.3 war
/// das ein Textvergleich auf „unexpected"/„provider" — ein Verbindungsabbruch nach
/// dem Senden galt damit als sicher fehlgeschlagen und lud zur Doppelzahlung ein.
final class TransferMayHaveBeenExecutedTests: XCTestCase {

    // Die Bank hat abgelehnt oder nie angefangen → sicher nicht ausgeführt.
    func test_bankHatAbgelehnt_istSicherFehlgeschlagen() {
        XCTAssertFalse(YaxiService.transferMayHaveBeenExecuted(RoutexError.paymentFailed(code: nil, userMessage: nil)))
        XCTAssertFalse(YaxiService.transferMayHaveBeenExecuted(RoutexError.invalidCredentials(userMessage: nil)))
        XCTAssertFalse(YaxiService.transferMayHaveBeenExecuted(RoutexError.unsupportedProduct(reason: nil, userMessage: nil)))
        XCTAssertFalse(YaxiService.transferMayHaveBeenExecuted(RoutexError.canceled))
    }

    // „unexpectedValue" enthält das Wort „unexpected" — der alte Textvergleich hielt
    // eine reine Eingabevalidierung für „vielleicht ausgeführt".
    func test_unexpectedValue_istSicherFehlgeschlagen() {
        XCTAssertFalse(YaxiService.transferMayHaveBeenExecuted(RoutexError.unexpectedValue(error: "iban")))
    }

    // Laut YAXI-Doku kann der Auftrag hier trotzdem ausgeführt sein.
    func test_unexpectedUndProvider_bleibenUnklar() {
        XCTAssertTrue(YaxiService.transferMayHaveBeenExecuted(RoutexError.unexpectedError(userMessage: nil)))
        XCTAssertTrue(YaxiService.transferMayHaveBeenExecuted(RoutexError.providerError(code: nil, userMessage: nil)))
        XCTAssertTrue(YaxiService.transferMayHaveBeenExecuted(RoutexError.unrecognizedResponse(status: 504, text: "gateway")))
    }

    // Der eigentliche Anlass: Transportfehler nach dem Senden.
    func test_transportfehler_istUnklar() {
        let url = URLError(.networkConnectionLost)
        XCTAssertTrue(YaxiService.transferMayHaveBeenExecuted(HTTPError.transportFailure(underlying: url)))
        XCTAssertTrue(YaxiService.transferMayHaveBeenExecuted(HTTPError.noResponse))
        XCTAssertTrue(YaxiService.transferMayHaveBeenExecuted(CancellationError()))
    }

    // Vor dem Senden gescheitert → nichts ging raus. Antwort nicht lesbar → sie kam.
    func test_clientFehler_nachSealingUnterscheidung() {
        XCTAssertFalse(YaxiService.transferMayHaveBeenExecuted(RoutexClientError.sealingFailed(message: "x", underlying: nil)))
        XCTAssertTrue(YaxiService.transferMayHaveBeenExecuted(RoutexClientError.unsealingFailed(message: "x", underlying: nil)))
        XCTAssertTrue(YaxiService.transferMayHaveBeenExecuted(RoutexClientError.malformedResponse(message: "x", underlying: nil)))
    }

    func test_endToEndId_passtInSEPA() {
        let id = TransferRequest.neueEndToEndId()
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.hasPrefix("SB"))
        XCTAssertNotEqual(id, TransferRequest.neueEndToEndId())
    }
}
