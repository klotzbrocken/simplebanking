import XCTest
@testable import simplebanking

// MARK: - TransferDraftStore Tests
//
// Read/Write-Roundtrip, Expiry-Cleanup, Consume-One-Shot, Validierung via
// TransferRequest. Drafts werden ins echte Application-Support-Verzeichnis
// geschrieben — setUp/tearDown isoliert über UUID-Prefix, damit parallele
// Test-Runs sich nicht kreuzen.

final class TransferDraftStoreTests: XCTestCase {

    private var writtenIds: [String] = []

    override func tearDown() {
        for id in writtenIds {
            if let url = try? TransferDraftStore.draftURL(id: id) {
                TransferDraftStore.consume(url: url)
            }
        }
        writtenIds.removeAll()
        super.tearDown()
    }

    private func validRequest() throws -> TransferRequest {
        // DE-IBAN-Beispiel mit gültiger mod-97-Checksumme (DE89 3704 0044 0532 0130 00).
        try TransferRequest(
            creditorName: "Max Mustermann",
            creditorIban: "DE89370400440532013000",
            amountEUR: Decimal(string: "42.50")!,
            remittance: "Rechnung 2026-001",
            endToEndId: "E2E-TEST-001"
        )
    }

    func test_writeAndLoad_roundtrips() throws {
        let req = try validRequest()
        let draft = TransferDraftStore.makeDraft(from: req, source: "app")
        writtenIds.append(draft.id)

        try TransferDraftStore.write(draft)

        let loaded = TransferDraftStore.loadAll()
        XCTAssertTrue(loaded.contains { $0.id == draft.id })
        let mine = loaded.first { $0.id == draft.id }!
        XCTAssertEqual(mine.creditorName, "Max Mustermann")
        XCTAssertEqual(mine.creditorIban, "DE89370400440532013000")
        XCTAssertEqual(mine.amountEUR, "42.5")
        XCTAssertEqual(mine.remittance, "Rechnung 2026-001")
        XCTAssertEqual(mine.endToEndId, "E2E-TEST-001")
        XCTAssertEqual(mine.source, "app")
    }

    func test_consume_deletesDraft() throws {
        let req = try validRequest()
        let draft = TransferDraftStore.makeDraft(from: req, source: "app")
        writtenIds.append(draft.id)
        try TransferDraftStore.write(draft)

        let url = try TransferDraftStore.draftURL(id: draft.id)
        TransferDraftStore.consume(url: url)
        let loaded = TransferDraftStore.loadAll()
        XCTAssertFalse(loaded.contains { $0.id == draft.id })
    }

    func test_expiredDraft_isIgnoredAndRemoved() throws {
        let req = try validRequest()
        // 10 Minuten in der Vergangenheit → längst expired (TTL = 5 min).
        let pastDate = Date().addingTimeInterval(-10 * 60)
        let draft = TransferDraftStore.makeDraft(from: req, source: "app", now: pastDate)
        writtenIds.append(draft.id)
        try TransferDraftStore.write(draft)

        let loaded = TransferDraftStore.loadAll()
        XCTAssertFalse(loaded.contains { $0.id == draft.id },
                       "Expired draft must not appear in loadAll()")

        // Side-effect: Datei wurde mitgelöscht.
        let url = try TransferDraftStore.draftURL(id: draft.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_makeRequest_validDraft_succeeds() throws {
        let req = try validRequest()
        let draft = TransferDraftStore.makeDraft(from: req, source: "test")
        let reconstructed = try TransferDraftStore.makeRequest(from: draft)
        XCTAssertEqual(reconstructed, req)
    }

    func test_makeRequest_invalidIban_throws() throws {
        let bogusDraft = TransferDraft(
            id: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)),
            source: "test",
            creditorName: "Test",
            creditorIban: "DE00INVALID",
            amountEUR: "10.00",
            remittance: nil,
            endToEndId: nil
        )
        XCTAssertThrowsError(try TransferDraftStore.makeRequest(from: bogusDraft))
    }

    func test_makeRequest_unparseableAmount_throws() throws {
        let bogusDraft = TransferDraft(
            id: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)),
            source: "test",
            creditorName: "Test",
            creditorIban: "DE89370400440532013000",
            amountEUR: "not-a-number",
            remittance: nil,
            endToEndId: nil
        )
        XCTAssertThrowsError(try TransferDraftStore.makeRequest(from: bogusDraft))
    }

    func test_makeRequest_amountWithComma_isAccepted() throws {
        let germanAmountDraft = TransferDraft(
            id: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60)),
            source: "test",
            creditorName: "Test",
            creditorIban: "DE89370400440532013000",
            amountEUR: "42,50",
            remittance: nil,
            endToEndId: nil
        )
        let req = try TransferDraftStore.makeRequest(from: germanAmountDraft)
        XCTAssertEqual(req.amountEUR, Decimal(string: "42.5")!)
    }

    func test_loadAll_sortsNewestFirst() throws {
        let req = try validRequest()
        let older = TransferDraftStore.makeDraft(from: req, source: "app",
                                                  now: Date().addingTimeInterval(-30))
        let newer = TransferDraftStore.makeDraft(from: req, source: "app",
                                                  now: Date())
        writtenIds.append(contentsOf: [older.id, newer.id])
        try TransferDraftStore.write(older)
        try TransferDraftStore.write(newer)

        let loaded = TransferDraftStore.loadAll()
        let testDrafts = loaded.filter { writtenIds.contains($0.id) }
        XCTAssertEqual(testDrafts.first?.id, newer.id, "Newest draft must come first")
    }

    // MARK: - isValid: Pfadmanipulation + Zeit/Quelle-Härtung (rein, kein Filesystem)

    private func makeDraftWith(
        id: String,
        source: String = "mcp",
        createdOffset: TimeInterval = 0,
        expiresOffset: TimeInterval = 60,
        now: Date = Date()
    ) -> TransferDraft {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return TransferDraft(
            id: id,
            createdAt: iso.string(from: now.addingTimeInterval(createdOffset)),
            expiresAt: iso.string(from: now.addingTimeInterval(expiresOffset)),
            source: source,
            creditorName: "Test",
            creditorIban: "DE89370400440532013000",
            amountEUR: "10.00",
            remittance: nil,
            endToEndId: nil
        )
    }

    func test_isValid_acceptsWellFormedUUIDDraft() {
        let id = UUID().uuidString
        let d = makeDraftWith(id: id)
        XCTAssertTrue(TransferDraftStore.isValid(d, filenameStem: id))
    }

    func test_isValid_rejectsPathTraversalId() {
        // ID mit ../ — darf nie akzeptiert werden (kein UUID + != Dateiname).
        let d = makeDraftWith(id: "../../evil")
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: "../../evil"))
    }

    func test_isValid_rejectsAbsolutePathId() {
        let d = makeDraftWith(id: "/etc/passwd")
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: "/etc/passwd"))
    }

    func test_isValid_rejectsNonUUIDId() {
        let d = makeDraftWith(id: "not-a-uuid")
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: "not-a-uuid"))
    }

    func test_isValid_rejectsIdFilenameMismatch() {
        // Gültiger UUID im JSON, aber Datei heißt anders → Draft gehört nicht zur Datei.
        let d = makeDraftWith(id: UUID().uuidString)
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: UUID().uuidString))
    }

    func test_isValid_rejectsUnparseableExpiry() {
        let id = UUID().uuidString
        var d = makeDraftWith(id: id)
        d = TransferDraft(id: d.id, createdAt: d.createdAt, expiresAt: "kaputt",
                          source: d.source, creditorName: d.creditorName,
                          creditorIban: d.creditorIban, amountEUR: d.amountEUR,
                          remittance: d.remittance, endToEndId: d.endToEndId)
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: id))
    }

    func test_isValid_rejectsExpiredDraft() {
        let id = UUID().uuidString
        let d = makeDraftWith(id: id, createdOffset: -600, expiresOffset: -300)
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: id))
    }

    func test_isValid_rejectsExpiryBeyondTTL() {
        // expiresAt weit in der Zukunft (> TTL + Skew) → verworfen.
        let id = UUID().uuidString
        let d = makeDraftWith(id: id, createdOffset: 0, expiresOffset: 24 * 3600)
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: id))
    }

    func test_isValid_rejectsFutureCreatedAt() {
        let id = UUID().uuidString
        // createdAt deutlich in der Zukunft (jenseits Skew).
        let d = makeDraftWith(id: id, createdOffset: 3600, expiresOffset: 3660)
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: id))
    }

    func test_isValid_rejectsUnknownSource() {
        let id = UUID().uuidString
        let d = makeDraftWith(id: id, source: "evil")
        XCTAssertFalse(TransferDraftStore.isValid(d, filenameStem: id))
    }
}
