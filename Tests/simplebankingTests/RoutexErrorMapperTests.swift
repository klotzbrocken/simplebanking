import XCTest
import Foundation
import RoutexClient
@testable import simplebanking

// MARK: - RoutexErrorMapper tests
//
// Sichert ab, dass jeder RoutexClientError-Case auf einen verständlichen
// Title + Aktions-Vorschlag mappt — und dass die bank-supplied userMessage
// als detail durchgereicht wird (oft präziser als unser Text).
//
// Lokalisation: L10n.t() wählt deutsch wenn die System-Sprache de ist. Tests
// sind tolerant gegen beide Sprachen, prüfen nur dass title nicht leer ist und
// kritische Felder gesetzt sind.

final class RoutexErrorMapperTests: XCTestCase {

    // MARK: - bank userMessage pass-through

    func test_unauthorized_passesUserMessageAsDetail() {
        let bankMsg = "Session expired at 14:32 — please reconnect"
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexError.unauthorized(userMessage: bankMsg))
        XCTAssertEqual(msg.detail, bankMsg,
            "Bank-supplied userMessage muss als detail durchgereicht werden — UI zeigt sie primär an.")
        XCTAssertTrue(msg.isRetryable, "Unauthorized → reconnect → retryable")
    }

    func test_invalidCredentials_passesUserMessageAsDetail() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexError.invalidCredentials(userMessage: "Bad password"))
        XCTAssertEqual(msg.detail, "Bad password")
        XCTAssertFalse(msg.isRetryable,
            "InvalidCredentials darf KEIN automatischer Retry triggern — User muss aktiv Setup neu machen")
    }

    func test_serviceBlocked_isNotRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexError.serviceBlocked(code: nil, userMessage: "Account locked"))
        XCTAssertFalse(msg.isRetryable, "ServiceBlocked → User muss Bank kontaktieren, kein Retry")
    }

    // MARK: - Retryable contract

    func test_canceled_isRetryable() {
        let msg = RoutexErrorMapper.userMessage(for: RoutexError.canceled)
        XCTAssertTrue(msg.isRetryable, "Canceled = User-Cancel, retry ist sinnvoll")
        XCTAssertNil(msg.detail, "Canceled hat kein detail (kein Bank-Text)")
    }

    /// Transportfehler sind seit SDK 0.5 ein eigener Typ (`HTTPError` aus
    /// `RoutexTransport`) und keine Spielart des Dienstfehlers mehr.
    func test_transportfehler_istWiederholbar() {
        let msg = RoutexErrorMapper.userMessage(
            for: HTTPError.transportFailure(underlying: URLError(.timedOut)))
        XCTAssertTrue(msg.isRetryable, "Netzwerkaussetzer — ein zweiter Versuch lohnt")
        XCTAssertTrue(msg.title.localizedCaseInsensitiveContains("Verbindung"), msg.title)
    }

    func test_accessExceeded_isNotRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexError.accessExceeded(userMessage: "Daily limit"))
        XCTAssertFalse(msg.isRetryable, "AccessExceeded = daily quota, sofortiger retry hilft nicht")
    }

    func test_unsupportedProduct_isNotRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexError.unsupportedProduct(reason: nil, userMessage: "Sparkonto"))
        XCTAssertFalse(msg.isRetryable, "UnsupportedProduct = struktureller Fehler, kein retry")
    }

    func test_consentExpired_isRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexError.unauthorized(userMessage: nil))
        XCTAssertTrue(msg.isRetryable, "ConsentExpired = OAuth-Re-Auth möglich, retry sinnvoll")
    }

    // MARK: - title is always non-empty (defensive)

    /// Jeder Fehler braucht einen Titel — ein leerer erzeugt einen leeren Hinweis, in dem
    /// nichts steht, woran der Nutzer sich festhalten kann.
    ///
    /// Die Liste folgt `RoutexError` aus SDK 0.5. `InvalidRedirectUri`, `RequestError`
    /// und `ResponseError` gibt es nicht mehr; Transportfehler stehen unten als
    /// eigene Familie.
    func test_alleFaelle_habenEinenTitel() {
        let faelle: [any Error] = [
            RoutexError.unexpectedError(userMessage: nil),
            RoutexError.canceled,
            RoutexError.invalidCredentials(userMessage: nil),
            RoutexError.serviceBlocked(code: nil, userMessage: nil),
            RoutexError.unauthorized(userMessage: nil),
            RoutexError.accessExceeded(userMessage: nil),
            RoutexError.periodOutOfBounds(userMessage: nil),
            RoutexError.unsupportedProduct(reason: nil, userMessage: nil),
            RoutexError.paymentFailed(code: nil, userMessage: nil),
            RoutexError.unexpectedValue(error: "x"),
            RoutexError.providerError(code: nil, userMessage: nil),
            RoutexError.unrecognizedResponse(status: 500, text: "x"),
            RoutexError.notFound,
            RoutexError.interruptError,
            HTTPError.noResponse,
            HTTPError.transportFailure(underlying: URLError(.notConnectedToInternet)),
        ]
        for c in faelle {
            let msg = RoutexErrorMapper.userMessage(for: c)
            XCTAssertFalse(msg.title.isEmpty,
                "Titel leer für \(c) — die UI zeigte einen leeren Hinweis")
        }
    }

    /// Der Pflicht-`default` im Mapper: Legt das SDK einen Fall nach, darf daraus kein
    /// leerer Hinweis werden. Geprüft am Fall, den der Mapper nicht einzeln behandelt.
    func test_unbehandelterFall_bekommtTrotzdemEinenTitel() {
        let msg = RoutexErrorMapper.userMessage(for: RoutexError.ticketError(error: "x", code: .invalid))
        XCTAssertFalse(msg.title.isEmpty)
    }

    // MARK: - non-Routex error fallback

    func test_genericError_returnsFallback() {
        struct DummyError: Error, LocalizedError {
            var errorDescription: String? { "something broke" }
        }
        let msg = RoutexErrorMapper.userMessage(for: DummyError())
        XCTAssertFalse(msg.title.isEmpty)
        XCTAssertEqual(msg.detail, "something broke",
            "Non-Routex error: errorDescription wird durchgereicht als detail")
        XCTAssertTrue(msg.isRetryable, "Default für unbekannte Errors: retry erlaubt")
    }
}
