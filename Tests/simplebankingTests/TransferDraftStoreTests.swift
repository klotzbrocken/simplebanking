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
            TransferDraftStore.consume(id: id)
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
        let draft = TransferDraftStore.makeDraft(from: req, source: "test")
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
        XCTAssertEqual(mine.source, "test")
    }

    func test_consume_deletesDraft() throws {
        let req = try validRequest()
        let draft = TransferDraftStore.makeDraft(from: req, source: "test")
        writtenIds.append(draft.id)
        try TransferDraftStore.write(draft)

        TransferDraftStore.consume(id: draft.id)
        let loaded = TransferDraftStore.loadAll()
        XCTAssertFalse(loaded.contains { $0.id == draft.id })
    }

    func test_expiredDraft_isIgnoredAndRemoved() throws {
        let req = try validRequest()
        // 10 Minuten in der Vergangenheit → längst expired (TTL = 5 min).
        let pastDate = Date().addingTimeInterval(-10 * 60)
        let draft = TransferDraftStore.makeDraft(from: req, source: "test", now: pastDate)
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
        let older = TransferDraftStore.makeDraft(from: req, source: "test",
                                                  now: Date().addingTimeInterval(-30))
        let newer = TransferDraftStore.makeDraft(from: req, source: "test",
                                                  now: Date())
        writtenIds.append(contentsOf: [older.id, newer.id])
        try TransferDraftStore.write(older)
        try TransferDraftStore.write(newer)

        let loaded = TransferDraftStore.loadAll()
        let testDrafts = loaded.filter { writtenIds.contains($0.id) }
        XCTAssertEqual(testDrafts.first?.id, newer.id, "Newest draft must come first")
    }
}
