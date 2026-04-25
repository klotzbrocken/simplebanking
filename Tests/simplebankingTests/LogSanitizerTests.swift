import XCTest
@testable import simplebanking

// MARK: - LogSanitizer tests
//
// Schützt vor Regression der PII-Redaction. Alle 100+ AppLogger.log-Calls
// laufen durch diese Patterns — wenn die Regex hier brechen, leakt die App
// Bank-Credentials in Production-Logs.

final class LogSanitizerTests: XCTestCase {

    // MARK: - IBAN redaction

    func test_redacts_germanIBAN() {
        let input = "Account IBAN DE89370400440532013000 not found"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.contains("DE89370400440532013000"),
            "DE-IBAN muss redacted werden")
        XCTAssertTrue(output.contains("<redacted-iban>"))
    }

    func test_redacts_austrianIBAN() {
        let input = "AT611904300234573201 saldo: 1234"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.contains("AT611904300234573201"))
        XCTAssertTrue(output.contains("<redacted-iban>"))
    }

    func test_redacts_iban_caseInsensitive() {
        let input = "iban: de89370400440532013000"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.lowercased().contains("de89370400440532013000"))
    }

    // MARK: - Credential key=value

    func test_redacts_userIdKeyValue() {
        let input = "fetchAccounts userid=hans-mueller-1234 ok"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.contains("hans-mueller-1234"))
        XCTAssertTrue(output.contains("<redacted-secret>"))
    }

    func test_redacts_passwordKeyValue() {
        let input = "auth password=geheim123 status=ok"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.contains("geheim123"))
    }

    func test_redacts_sessionKeyValue() {
        let input = "session=abc-def-ghi resp=200"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.contains("abc-def-ghi"))
    }

    func test_redacts_apiKey() {
        let input = "anthropic api_key=sk-ant-XYZ123 model=opus"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.contains("sk-ant-XYZ123"))
    }

    // MARK: - long opaque tokens

    func test_redacts_longBase64Token() {
        let input = "ticket: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.foobar.signature"
        let output = LogSanitizer.redact(input)
        XCTAssertTrue(output.contains("<redacted-token>"),
            "Lange JWT-artige Tokens müssen redacted werden")
    }

    func test_redacts_sha256Hash() {
        // 64-char hex (SHA256-Output, z.B. unsere TXIDs)
        let input = "tx_id=a3f2e8b9c1d4e7f8a3f2e8b9c1d4e7f8a3f2e8b9c1d4e7f8a3f2e8b9c1d4e7f8"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.contains("a3f2e8b9c1d4e7f8a3f2e8b9c1d4e7f8"))
    }

    // MARK: - non-PII passes through

    func test_doesNotRedact_shortStatus() {
        let input = "refresh ok in 250ms"
        XCTAssertEqual(LogSanitizer.redact(input), input)
    }

    func test_doesNotRedact_amountInEur() {
        let input = "Saldo aktualisiert: 1234.56 EUR"
        let output = LogSanitizer.redact(input)
        XCTAssertEqual(output, input,
            "Beträge sind keine PII (Konto-Identifikation per Saldo allein nicht möglich)")
    }

    func test_doesNotRedact_categoryNames() {
        let input = "Category set: Lebensmittel & Getränke (count=42)"
        let output = LogSanitizer.redact(input)
        XCTAssertEqual(output, input)
    }

    func test_doesNotRedact_shortIDs() {
        // Kurze IDs (<24 chars) bleiben — sonst würden alle Random-Slugs redacted
        let input = "slot id=abc123 active"
        let output = LogSanitizer.redact(input)
        XCTAssertTrue(output.contains("abc123"),
            "Kurze IDs unter 24 chars dürfen durchkommen")
    }

    // MARK: - real-world AppLogger samples

    func test_realWorldSample_bankErrorWithIBAN() {
        let input = "Balance refresh failed: Customer IBAN DE89370400440532013000 not found at provider"
        let output = LogSanitizer.redact(input)
        XCTAssertFalse(output.contains("DE89370400440532013000"))
        XCTAssertTrue(output.contains("Balance refresh failed"))
    }

    func test_realWorldSample_keychainAccount() {
        let input = "kcWrite failed: status=-25299 account=hans.mueller@example.com"
        let output = LogSanitizer.redact(input)
        // account=...@example.com matched das key=value pattern
        XCTAssertFalse(output.contains("hans.mueller@example.com"),
            "account=value muss als secret redacted werden")
    }
}
