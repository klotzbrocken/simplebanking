import XCTest
@testable import simplebanking

// MARK: - ErrorReportStore Pure-Function-Tests
//
// Throttle-Decision, Mail-Body-Builder, Context-Block, JWT-Ticket-Decoder
// und filesToDelete sind alle pure und ohne Side-Effects testbar. Die
// @MainActor-NSAlert-Logik ist UI-only und nicht im Test-Scope.

final class ErrorReportStoreTests: XCTestCase {

    // MARK: - Throttle-Decision

    func test_shouldRegister_neverBefore_returnsTrue() {
        let result = ErrorReportStore.shouldRegister(
            lastReportedAt: nil, now: Date(), window: 30 * 60
        )
        XCTAssertTrue(result, "Erster Report einer Key-Kombi muss durchkommen")
    }

    func test_shouldRegister_within30min_blocked() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let now  = last.addingTimeInterval(29 * 60)
        let result = ErrorReportStore.shouldRegister(
            lastReportedAt: last, now: now, window: 30 * 60
        )
        XCTAssertFalse(result, "Innerhalb des 30-min-Throttle-Fensters muss geblockt werden")
    }

    func test_shouldRegister_exactlyAtWindow_allowed() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let now  = last.addingTimeInterval(30 * 60)
        let result = ErrorReportStore.shouldRegister(
            lastReportedAt: last, now: now, window: 30 * 60
        )
        XCTAssertTrue(result, "An der Grenze des Throttle-Fensters wieder erlauben (>=)")
    }

    func test_shouldRegister_afterWindow_allowed() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let now  = last.addingTimeInterval(31 * 60)
        let result = ErrorReportStore.shouldRegister(
            lastReportedAt: last, now: now, window: 30 * 60
        )
        XCTAssertTrue(result, "Nach Throttle-Fenster wieder erlauben")
    }

    // MARK: - CallSource Routing

    func test_callSource_capturesReports() {
        XCTAssertTrue(ErrorReportStore.CallSource.normal.capturesReports)
        XCTAssertTrue(ErrorReportStore.CallSource.setupWarmup.capturesReports)
        XCTAssertFalse(ErrorReportStore.CallSource.diagnostic.capturesReports)
        XCTAssertFalse(ErrorReportStore.CallSource.silent.capturesReports)
    }

    func test_callSource_autoPrompts() {
        XCTAssertTrue(ErrorReportStore.CallSource.normal.autoPrompts,
                      ".normal soll automatisch prompten")
        XCTAssertFalse(ErrorReportStore.CallSource.setupWarmup.autoPrompts,
                       ".setupWarmup darf NICHT prompten — Setup-UI nutzt presentManually")
        XCTAssertFalse(ErrorReportStore.CallSource.diagnostic.autoPrompts)
        XCTAssertFalse(ErrorReportStore.CallSource.silent.autoPrompts)
    }

    // MARK: - Context-Block (deterministisch)

    func test_composeContextBlock_includesAllFields() {
        let report = ErrorReportStore.PendingErrorReport(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: Date(timeIntervalSince1970: 1_716_134_400),  // 2024-05-19 16:00:00 UTC
            callName: "fetchTransactions",
            slotId: "374CFB84-AAAA",
            bankDisplayName: "Deutsche Kreditbank Berlin",
            connectionId: "connection-abc-123",
            traceId: "deadbeef",
            ticketId: "ticket-xyz-456",
            userMessageFromBank: "Bank says: try again later",
            attachmentURL: nil,
            alertTitle: "Unerwarteter Fehler"
        )
        let block = ErrorReportStore.composeContextBlock(report: report)

        XCTAssertTrue(block.contains("fetchTransactions"))
        XCTAssertTrue(block.contains("374CFB84-AAAA"))
        XCTAssertTrue(block.contains("Deutsche Kreditbank Berlin"))
        XCTAssertTrue(block.contains("connection-abc-123"))
        XCTAssertTrue(block.contains("deadbeef"))
        XCTAssertTrue(block.contains("ticket-xyz-456"))
        XCTAssertTrue(block.contains("=== simplebanking Diagnose-Kontext ==="))
        XCTAssertTrue(block.contains("=== Ende Kontext ==="))
    }

    func test_composeContextBlock_handlesNilFields() {
        let report = ErrorReportStore.PendingErrorReport(
            id: UUID(), createdAt: Date(),
            callName: "fetchBalances", slotId: "legacy",
            bankDisplayName: nil, connectionId: nil,
            traceId: nil, ticketId: nil,
            userMessageFromBank: nil,
            attachmentURL: nil,
            alertTitle: "Title"
        )
        let block = ErrorReportStore.composeContextBlock(report: report)

        XCTAssertTrue(block.contains("Bank:            -"), "Nil bank-name als '-' renden")
        XCTAssertTrue(block.contains("connectionId:    -"))
        XCTAssertTrue(block.contains("ticketId:        -"))
        XCTAssertTrue(block.contains("traceId:         -"))
        XCTAssertTrue(block.contains("Bank-Meldung:    -"))
    }

    func test_composeContextBlock_redactsBankMessage() {
        // LogSanitizer.redact sollte IBAN-Patterns entfernen
        let report = ErrorReportStore.PendingErrorReport(
            id: UUID(), createdAt: Date(),
            callName: "fetchBalances", slotId: "legacy",
            bankDisplayName: "X", connectionId: nil,
            traceId: nil, ticketId: nil,
            userMessageFromBank: "Error for DE89370400440532013000",
            attachmentURL: nil,
            alertTitle: "Title"
        )
        let block = ErrorReportStore.composeContextBlock(report: report)
        XCTAssertFalse(block.contains("DE89370400440532013000"),
                       "Bank-Meldung mit IBAN muss durch LogSanitizer.redact gefiltert sein")
    }

    // MARK: - Mail-Subject + Body

    func test_composeMailSubject_containsBankAndDate() {
        let report = ErrorReportStore.PendingErrorReport(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_716_134_400),
            callName: "fetchBalances", slotId: "legacy",
            bankDisplayName: "Sparkasse Siegen",
            connectionId: nil, traceId: nil, ticketId: nil,
            userMessageFromBank: nil, attachmentURL: nil,
            alertTitle: "Fehler"
        )
        let subject = ErrorReportStore.composeMailSubject(report: report)
        XCTAssertTrue(subject.contains("Sparkasse Siegen"))
        XCTAssertTrue(subject.contains("Unerwarteter Fehler") || subject.contains("Unexpected error"))
    }

    func test_composeMailBody_hasIntroAndContextBlock() {
        let report = ErrorReportStore.PendingErrorReport(
            id: UUID(), createdAt: Date(),
            callName: "fetchBalances", slotId: "legacy",
            bankDisplayName: "Test Bank",
            connectionId: "c-1", traceId: "t-1", ticketId: "tk-1",
            userMessageFromBank: nil, attachmentURL: nil,
            alertTitle: "X"
        )
        let body = ErrorReportStore.composeMailBody(report: report, locale: Locale(identifier: "de_DE"))
        // Intro
        XCTAssertTrue(body.contains("Bank-Abruf") || body.contains("bank call"))
        // Context-Block
        XCTAssertTrue(body.contains("fetchBalances"))
        XCTAssertTrue(body.contains("Test Bank"))
        XCTAssertTrue(body.contains("c-1"))
    }

    // MARK: - Privacy-Notice

    func test_privacyNotice_mentionsEncryptedAndExcludesCredentials() {
        let notice = ErrorReportStore.privacyNotice()
        // Korrekte Aussagen über die Datei
        XCTAssertTrue(notice.contains("verschlüsselt") || notice.contains("encrypted"))
        XCTAssertTrue(notice.contains("Zugangsdaten") || notice.contains("credentials"))
    }

    func test_composeAlertBody_includesBankMsgFirstThenPrivacy() {
        let report = ErrorReportStore.PendingErrorReport(
            id: UUID(), createdAt: Date(),
            callName: "fetchBalances", slotId: "legacy",
            bankDisplayName: "X", connectionId: nil,
            traceId: nil, ticketId: nil,
            userMessageFromBank: "Bank says: try again later",
            attachmentURL: nil,
            alertTitle: "T"
        )
        let body = ErrorReportStore.composeAlertBody(report: report)
        XCTAssertTrue(body.contains("Bank says: try again later"))
        XCTAssertTrue(body.contains("verschlüsselt") || body.contains("encrypted"))
        // Bank-Message vor Privacy-Notice
        let bankRange = body.range(of: "Bank says")!
        let privacyKey = body.range(of: "verschlüsselt") ?? body.range(of: "encrypted")!
        XCTAssertLessThan(bankRange.lowerBound, privacyKey.lowerBound)
    }

    func test_composeAlertBody_nilBankMsg_onlyPrivacy() {
        let report = ErrorReportStore.PendingErrorReport(
            id: UUID(), createdAt: Date(),
            callName: "fetchBalances", slotId: "legacy",
            bankDisplayName: "X", connectionId: nil,
            traceId: nil, ticketId: nil,
            userMessageFromBank: nil,
            attachmentURL: nil,
            alertTitle: "T"
        )
        let body = ErrorReportStore.composeAlertBody(report: report)
        XCTAssertTrue(body.contains("verschlüsselt") || body.contains("encrypted"))
    }

    // MARK: - filesToDelete

    func test_filesToDelete_underKeepCount_returnsEmpty() {
        let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/f\($0).txt") }
        let toDelete = ErrorReportStore.filesToDelete(from: urls, keepCount: 10)
        XCTAssertEqual(toDelete, [])
    }

    func test_filesToDelete_atExactlyKeepCount_returnsEmpty() {
        let urls = (0..<10).map { URL(fileURLWithPath: "/tmp/f\($0).txt") }
        let toDelete = ErrorReportStore.filesToDelete(from: urls, keepCount: 10)
        XCTAssertEqual(toDelete, [])
    }

    func test_filesToDelete_overKeepCount_returnsOldest() {
        // 12 files, keep 10 → 2 to delete (oldest 2 = die mit kleinstem mtime)
        // Da die URLs für Test nur Pfade sind und keine echten Files, würde der
        // resourceValues-Lookup .distantPast zurückgeben → alle gleichwertig.
        // Wir testen hier nur, dass die richtige ANZAHL gelöscht wird.
        let urls = (0..<12).map { URL(fileURLWithPath: "/tmp/f\($0).txt") }
        let toDelete = ErrorReportStore.filesToDelete(from: urls, keepCount: 10)
        XCTAssertEqual(toDelete.count, 2)
    }
}

// MARK: - JWT Ticket-Decoder Tests

final class JWTTicketDecoderTests: XCTestCase {

    func test_extractTicketId_invalidJWT_returnsNil() {
        XCTAssertNil(JWTTicketDecoder.extractTicketId(from: ""))
        XCTAssertNil(JWTTicketDecoder.extractTicketId(from: "not-a-jwt"))
        XCTAssertNil(JWTTicketDecoder.extractTicketId(from: "only.two"))
        XCTAssertNil(JWTTicketDecoder.extractTicketId(from: "a.b.c.d"))
    }

    func test_extractTicketId_validJWT_returnsId() {
        // Payload: {"data":{"service":"Balances","id":"my-ticket-id","data":null},"exp":1,"iat":0}
        // Base64URL encoded
        let header  = base64URLEncode(#"{"alg":"HS256"}"#)
        let payload = base64URLEncode(#"{"data":{"service":"Balances","id":"my-ticket-id","data":null},"exp":1,"iat":0}"#)
        let sig     = "signature"
        let jwt = "\(header).\(payload).\(sig)"
        XCTAssertEqual(JWTTicketDecoder.extractTicketId(from: jwt), "my-ticket-id")
    }

    func test_extractTicketId_payloadWithoutId_returnsNil() {
        let header  = base64URLEncode(#"{"alg":"HS256"}"#)
        let payload = base64URLEncode(#"{"data":{"service":"Balances"},"exp":1,"iat":0}"#)
        let jwt = "\(header).\(payload).sig"
        XCTAssertNil(JWTTicketDecoder.extractTicketId(from: jwt))
    }

    func test_extractTicketId_malformedJSON_returnsNil() {
        let header  = base64URLEncode(#"{"alg":"HS256"}"#)
        let payload = base64URLEncode(#"{"not": "valid json structure"}"#)
        let jwt = "\(header).\(payload).sig"
        XCTAssertNil(JWTTicketDecoder.extractTicketId(from: jwt))
    }

    func test_extractTicketId_realYaxiTicket_extractsId() {
        // Simuliere ein echtes YAXI-Ticket aus YaxiTicketMaker.issueTicket
        let actualTicket = YaxiTicketMaker.issueTicket(service: "Accounts", data: nil)
        let id = JWTTicketDecoder.extractTicketId(from: actualTicket)
        XCTAssertNotNil(id)
        // ID ist ein UUID-String (lowercase)
        XCTAssertEqual(id?.count, 36)
        XCTAssertTrue(id?.contains("-") ?? false)
    }

    func test_base64URLDecode_handlesPaddingVariants() {
        // "hello" base64-encoded = "aGVsbG8=" (8 chars mit padding) / "aGVsbG8" (ohne)
        XCTAssertEqual(JWTTicketDecoder.base64URLDecode("aGVsbG8"), Data("hello".utf8))
        XCTAssertEqual(JWTTicketDecoder.base64URLDecode("aGVsbG8="), Data("hello".utf8))
        // URL-safe chars: "+/" werden zu "-_" — wir testen mit einem 8-char-Input,
        // der nach Konversion gültiges base64 ist.
        XCTAssertNotNil(JWTTicketDecoder.base64URLDecode("PD8-Pj4_"))   // == "<?>>?" (valid 6-byte payload)
    }

    // Hilfsfunktion analog YaxiTicketMaker.base64URLEncode
    private func base64URLEncode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
