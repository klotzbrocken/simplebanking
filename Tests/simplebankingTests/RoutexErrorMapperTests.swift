import XCTest
import Routex
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
            for: RoutexClientError.Unauthorized(userMessage: bankMsg))
        XCTAssertEqual(msg.detail, bankMsg,
            "Bank-supplied userMessage muss als detail durchgereicht werden — UI zeigt sie primär an.")
        XCTAssertTrue(msg.isRetryable, "Unauthorized → reconnect → retryable")
    }

    func test_invalidCredentials_passesUserMessageAsDetail() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexClientError.InvalidCredentials(userMessage: "Bad password"))
        XCTAssertEqual(msg.detail, "Bad password")
        XCTAssertFalse(msg.isRetryable,
            "InvalidCredentials darf KEIN automatischer Retry triggern — User muss aktiv Setup neu machen")
    }

    func test_serviceBlocked_isNotRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexClientError.ServiceBlocked(userMessage: "Account locked", code: nil))
        XCTAssertFalse(msg.isRetryable, "ServiceBlocked → User muss Bank kontaktieren, kein Retry")
    }

    // MARK: - Retryable contract

    func test_canceled_isRetryable() {
        let msg = RoutexErrorMapper.userMessage(for: RoutexClientError.Canceled)
        XCTAssertTrue(msg.isRetryable, "Canceled = User-Cancel, retry ist sinnvoll")
        XCTAssertNil(msg.detail, "Canceled hat kein detail (kein Bank-Text)")
    }

    func test_requestError_isRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexClientError.RequestError(error: "timeout"))
        XCTAssertTrue(msg.isRetryable, "RequestError = network glitch, retry sinnvoll")
        XCTAssertEqual(msg.detail, "timeout")
    }

    func test_accessExceeded_isNotRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexClientError.AccessExceeded(userMessage: "Daily limit"))
        XCTAssertFalse(msg.isRetryable, "AccessExceeded = daily quota, sofortiger retry hilft nicht")
    }

    func test_unsupportedProduct_isNotRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexClientError.UnsupportedProduct(reason: nil, userMessage: "Sparkonto"))
        XCTAssertFalse(msg.isRetryable, "UnsupportedProduct = struktureller Fehler, kein retry")
    }

    func test_consentExpired_isRetryable() {
        let msg = RoutexErrorMapper.userMessage(
            for: RoutexClientError.ConsentExpired(userMessage: nil))
        XCTAssertTrue(msg.isRetryable, "ConsentExpired = OAuth-Re-Auth möglich, retry sinnvoll")
    }

    // MARK: - title is always non-empty (defensive)

    func test_allCases_haveNonEmptyTitle() {
        let cases: [RoutexClientError] = [
            .InvalidRedirectUri,
            .RequestError(error: "x"),
            .UnexpectedError(userMessage: nil),
            .Canceled,
            .InvalidCredentials(userMessage: nil),
            .ServiceBlocked(userMessage: nil, code: nil),
            .Unauthorized(userMessage: nil),
            .ConsentExpired(userMessage: nil),
            .AccessExceeded(userMessage: nil),
            .PeriodOutOfBounds(userMessage: nil),
            .UnsupportedProduct(reason: nil, userMessage: nil),
            .PaymentFailed(code: nil, userMessage: nil),
            .UnexpectedValue(error: "x"),
            .ProviderError(code: nil, userMessage: nil),
            .ResponseError(response: "x"),
            .NotFound,
            .InterruptError
        ]
        for c in cases {
            let msg = RoutexErrorMapper.userMessage(for: c)
            XCTAssertFalse(msg.title.isEmpty,
                "Title leer für \(c) — UI würde leeren Alert zeigen")
        }
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
