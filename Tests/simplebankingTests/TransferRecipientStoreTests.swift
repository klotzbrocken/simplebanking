import XCTest
import GRDB
@testable import simplebanking

// MARK: - TransferRecipientStore Tests
//
// Verifiziert SQL-Aggregation aus der lokalen Buchungs-Historie für die
// Geld-senden-Vorschläge. Nutzt isolierte test-bankId, räumt nach jedem
// Test auf.

final class TransferRecipientStoreTests: XCTestCase {

    private var testBankId: String = ""

    override func setUpWithError() throws {
        testBankId = "test-recip-\(UUID().uuidString.lowercased().prefix(12))"
        TransactionsDatabase.activeSlotId = "slot-a"
    }

    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: testBankId)
    }

    // MARK: - Helpers

    /// Macht eine Test-Transaktion. Negative `amount` = ausgehend (creditor),
    /// positive = eingehend (debtor).
    private func makeTx(
        endToEndId: String,
        merchant: String,
        iban: String?,
        amount: Double,
        bookingDate: String = "2026-04-01"
    ) -> TransactionsResponse.Transaction {
        let amt = TransactionsResponse.Amount(
            currency: "EUR",
            amount: String(format: "%.2f", amount)
        )
        let party = TransactionsResponse.Party(name: merchant, iban: iban, bic: nil)
        return TransactionsResponse.Transaction(
            bookingDate: bookingDate,
            valueDate: bookingDate,
            status: "booked",
            endToEndId: endToEndId,
            amount: amt,
            creditor: amount < 0 ? party : nil,
            debtor:  amount > 0 ? party : nil,
            remittanceInformation: ["Verwendungszweck \(merchant)"],
            additionalInformation: nil,
            purposeCode: nil
        )
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Empty DB

    func test_loadCandidates_emptyDb_returnsEmpty() throws {
        let candidates = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: date(2026, 5, 1), bankId: testBankId
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Filtering rules

    func test_loadCandidates_excludesIncomingTransactions() throws {
        // Nur Eingangs-Tx (positiv) → keine Empfänger-Vorschläge
        let txIn = makeTx(endToEndId: "in-1", merchant: "Arbeitgeber",
                          iban: "DE89370400440532013000", amount: 3000)
        try TransactionsDatabase.upsert(transactions: [txIn], bankId: testBankId)

        let candidates = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: date(2026, 5, 1), bankId: testBankId
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    /// Manuelle SEPA-Aufträge kommen oft ohne IBAN aus der Bank zurück.
    /// Solche Empfänger müssen trotzdem als Kandidat erscheinen — die UI
    /// fragt dann den User nach der IBAN. Vorher wurden sie hart aus-
    /// gefiltert.
    func test_loadCandidates_includesTxWithoutIban_forManualEntry() throws {
        let txNoIban = makeTx(endToEndId: "out-1", merchant: "Anna Klein",
                              iban: nil, amount: -25)
        try TransactionsDatabase.upsert(transactions: [txNoIban], bankId: testBankId)

        let candidates = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: date(2026, 5, 1), bankId: testBankId
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.creditorName, "Anna Klein")
        XCTAssertEqual(candidates.first?.creditorIban, "",
                       "Empty IBAN signals that UI must prompt the user before sending")
    }

    /// Zwei verschiedene Empfänger ohne IBAN müssen als getrennte
    /// Kandidaten erscheinen, nicht zu einem Eintrag zusammengelegt.
    func test_loadCandidates_ibanLessRecipients_separatedByName() throws {
        let a = makeTx(endToEndId: "a", merchant: "Anna",
                       iban: nil, amount: -10, bookingDate: "2026-04-01")
        let b = makeTx(endToEndId: "b", merchant: "Bert",
                       iban: nil, amount: -20, bookingDate: "2026-04-02")
        try TransactionsDatabase.upsert(transactions: [a, b], bankId: testBankId)

        let candidates = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: date(2026, 5, 1), bankId: testBankId
        )
        let names = Set(candidates.map(\.creditorName))
        XCTAssertEqual(names, ["Anna", "Bert"])
    }

    // MARK: - Slot isolation

    func test_loadCandidates_onlyReturnsActiveSlot() throws {
        // Slot A
        TransactionsDatabase.activeSlotId = "slot-a"
        let txA = makeTx(endToEndId: "a1", merchant: "Vermieter A",
                         iban: "DE89370400440532013000", amount: -1200)
        try TransactionsDatabase.upsert(transactions: [txA], bankId: testBankId)

        // Slot B
        TransactionsDatabase.activeSlotId = "slot-b"
        let txB = makeTx(endToEndId: "b1", merchant: "Vermieter B",
                         iban: "AT611904300234573201", amount: -800)
        try TransactionsDatabase.upsert(transactions: [txB], bankId: testBankId)

        let candidatesA = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: date(2026, 5, 1), bankId: testBankId
        )
        let candidatesB = try TransferRecipientStore.loadCandidates(
            slotId: "slot-b", today: date(2026, 5, 1), bankId: testBankId
        )
        XCTAssertEqual(candidatesA.count, 1)
        XCTAssertEqual(candidatesA.first?.creditorName, "Vermieter A")
        XCTAssertEqual(candidatesB.count, 1)
        XCTAssertEqual(candidatesB.first?.creditorName, "Vermieter B")
    }

    // MARK: - Aggregation

    func test_loadCandidates_aggregatesByNameAndIban_returnsFrequency() throws {
        // 3× Miete an gleichen Empfänger
        for i in 1...3 {
            let tx = makeTx(endToEndId: "miete-\(i)", merchant: "Vermieter",
                            iban: "DE89370400440532013000", amount: -1200,
                            bookingDate: "2026-0\(i)-01")
            try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)
        }
        // 1× anderer Empfänger
        let tx = makeTx(endToEndId: "spotify", merchant: "Spotify",
                        iban: "IE29AIBK93115212345678", amount: -10,
                        bookingDate: "2026-04-15")
        try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)

        let candidates = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: date(2026, 5, 1), bankId: testBankId
        )
        XCTAssertEqual(candidates.count, 2)
        let vermieter = candidates.first { $0.creditorName == "Vermieter" }
        XCTAssertEqual(vermieter?.frequency, 3)
        XCTAssertEqual(vermieter?.creditorIban, "DE89370400440532013000")
        XCTAssertEqual(vermieter?.mostFrequentAmount, Decimal(1200))
    }

    // MARK: - Most-frequent amount (mode, not mean)

    func test_loadCandidates_mostFrequentAmount_isModeNotMean() throws {
        // 3× 1200 €, 1× 1500 € (Sonderzahlung)
        for i in 1...3 {
            let tx = makeTx(endToEndId: "rent-\(i)", merchant: "Vermieter",
                            iban: "DE89370400440532013000", amount: -1200,
                            bookingDate: "2026-0\(i)-01")
            try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)
        }
        let bonus = makeTx(endToEndId: "rent-bonus", merchant: "Vermieter",
                           iban: "DE89370400440532013000", amount: -1500,
                           bookingDate: "2026-04-01")
        try TransactionsDatabase.upsert(transactions: [bonus], bankId: testBankId)

        let candidates = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: date(2026, 5, 1), bankId: testBankId
        )
        XCTAssertEqual(candidates.first?.mostFrequentAmount, Decimal(1200),
                       "Mode soll dominieren, nicht Mittelwert (1275)")
    }

    // MARK: - Recency-Boost re-sort

    func test_loadCandidates_recencyBoost_movesActiveAhead() throws {
        // Empfänger A: 5 Buchungen vor langer Zeit (vor 200 Tagen)
        for i in 1...5 {
            let tx = makeTx(endToEndId: "old-\(i)", merchant: "Alter Empfänger",
                            iban: "DE89370400440532013000", amount: -100,
                            bookingDate: "2025-10-0\(i)")
            try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)
        }
        // Empfänger B: 3 Buchungen ganz aktuell
        for i in 1...3 {
            let tx = makeTx(endToEndId: "new-\(i)", merchant: "Neuer Empfänger",
                            iban: "AT611904300234573201", amount: -100,
                            bookingDate: "2026-04-2\(i)")
            try TransactionsDatabase.upsert(transactions: [tx], bankId: testBankId)
        }

        let today = date(2026, 5, 1)
        let candidates = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: today, bankId: testBankId
        )
        // Mit Recency-Boost sollte Neuer Empfänger trotz geringerer Frequenz
        // vor Alter Empfänger liegen (3 × 1.0 ≈ 3 vs 5 × 0.45 ≈ 2.25).
        XCTAssertEqual(candidates.first?.creditorName, "Neuer Empfänger")
    }

    // MARK: - Filter

    func test_filter_emptyQuery_returnsAll() {
        let cs = [
            TransferRecipientCandidate(creditorName: "Spotify", creditorIban: "IE29AIBK93115212345678",
                                       mostFrequentAmount: 10, lastRemittance: nil,
                                       frequency: 12, lastBookingDate: "2026-04-01"),
            TransferRecipientCandidate(creditorName: "Vermieter", creditorIban: "DE89370400440532013000",
                                       mostFrequentAmount: 1200, lastRemittance: nil,
                                       frequency: 12, lastBookingDate: "2026-04-01"),
        ]
        XCTAssertEqual(TransferRecipientStore.filter(cs, query: "").count, 2)
    }

    func test_filter_byNameSubstring_caseInsensitive() {
        let cs = [
            TransferRecipientCandidate(creditorName: "Spotify", creditorIban: "IE29AIBK93115212345678",
                                       mostFrequentAmount: 10, lastRemittance: nil,
                                       frequency: 12, lastBookingDate: "2026-04-01"),
            TransferRecipientCandidate(creditorName: "Vermieter Müller", creditorIban: "DE89370400440532013000",
                                       mostFrequentAmount: 1200, lastRemittance: nil,
                                       frequency: 12, lastBookingDate: "2026-04-01"),
        ]
        let filtered = TransferRecipientStore.filter(cs, query: "müller")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.creditorName, "Vermieter Müller")
    }

    func test_filter_byIbanFragment_ignoresSpaces() {
        let cs = [
            TransferRecipientCandidate(creditorName: "Spotify", creditorIban: "IE29AIBK93115212345678",
                                       mostFrequentAmount: 10, lastRemittance: nil,
                                       frequency: 12, lastBookingDate: "2026-04-01"),
            TransferRecipientCandidate(creditorName: "Vermieter", creditorIban: "DE89370400440532013000",
                                       mostFrequentAmount: 1200, lastRemittance: nil,
                                       frequency: 12, lastBookingDate: "2026-04-01"),
        ]
        // User tippt mit Spaces — Filter soll trotzdem matchen
        let filtered = TransferRecipientStore.filter(cs, query: "DE89 3704")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.creditorName, "Vermieter")
    }

    // MARK: - Debtor-only counterparty (FinTS-Mapping-Quirk)

    /// Manche Bank-Backends (insb. historische FinTS-SEPA-Aufträge) liefern
    /// den Counterparty einer ausgehenden Buchung im `debtor`-Feld statt
    /// `creditor`. Das landet im DB-Feld `absender` und früher hat der
    /// `empfaenger != ''`-Filter solche Buchungen ausgeschlossen — der User
    /// sah keine Vorschläge zu Personen, an die er manuell Geld gesendet hat.
    func test_loadCandidates_debtorOnlyCounterparty_isFound() throws {
        let amt = TransactionsResponse.Amount(currency: "EUR", amount: "-50.00")
        let party = TransactionsResponse.Party(
            name: "Max Hoffmann", iban: "DE12700100800123456789", bic: nil
        )
        // Outgoing (amount < 0), aber Counterparty steckt im `debtor` —
        // `creditor` ist leer.
        let txDebtorOnly = TransactionsResponse.Transaction(
            bookingDate: "2026-04-15", valueDate: "2026-04-15", status: "booked",
            endToEndId: "manual-1", amount: amt,
            creditor: nil, debtor: party,
            remittanceInformation: ["Geschenk"], additionalInformation: nil,
            purposeCode: nil
        )
        try TransactionsDatabase.upsert(transactions: [txDebtorOnly], bankId: testBankId)

        let candidates = try TransferRecipientStore.loadCandidates(
            slotId: "slot-a", today: date(2026, 5, 1), bankId: testBankId
        )
        XCTAssertEqual(candidates.count, 1, "debtor-only Buchung muss als Kandidat erscheinen")
        XCTAssertEqual(candidates.first?.creditorName, "Max Hoffmann")
        XCTAssertEqual(candidates.first?.creditorIban, "DE12700100800123456789")
        XCTAssertEqual(candidates.first?.lastRemittance, "Geschenk")
    }

    // MARK: - Score function

    func test_score_freshTransaction_fullFrequencyValue() {
        let c = TransferRecipientCandidate(creditorName: "X", creditorIban: "DE00",
                                           mostFrequentAmount: nil, lastRemittance: nil,
                                           frequency: 5, lastBookingDate: "2026-05-01")
        let s = TransferRecipientStore.score(c, today: date(2026, 5, 1))
        XCTAssertEqual(s, 5.0, accuracy: 0.01)
    }

    func test_score_oldTransaction_appliesFloor() {
        let c = TransferRecipientCandidate(creditorName: "X", creditorIban: "DE00",
                                           mostFrequentAmount: nil, lastRemittance: nil,
                                           frequency: 5, lastBookingDate: "2020-01-01")
        let s = TransferRecipientStore.score(c, today: date(2026, 5, 1))
        // Mit Floor 0.1: 5 × 0.1 = 0.5 (statt fast 0).
        XCTAssertEqual(s, 0.5, accuracy: 0.01)
    }
}
