import XCTest
@testable import simplebanking

/// Das Lesefenster — und die Zusage, dass jeder Schreibweg es mitzieht.
///
/// Der Fehler, um den es hier geht, meldet sich nicht: Der Import schreibt, zählt
/// und meldet richtig, nur sieht niemand das Ergebnis. Zwei von vier Importwegen
/// hatten ihn (MoneyMoney, OFX, CAMT.053), und keiner der 1739 Tests konnte das
/// finden — sie prüften alle, was in der Datenbank steht.
@MainActor
final class AnzeigetiefeTests: XCTestCase {

    private let bank = "anzeigetiefe-test"

    override func setUp() async throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
        try TransactionsDatabase.migrate(bankId: bank)
    }

    override func tearDown() async throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
    }

    private func tag(_ abstand: Int) -> String {
        let former = DateFormatter()
        former.dateFormat = "yyyy-MM-dd"
        former.locale = Locale(identifier: "en_US_POSIX")
        return former.string(from: Date().addingTimeInterval(Double(-abstand) * 86_400))
    }

    private func buchung(_ tag: String) -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: tag, valueDate: tag, status: "booked", endToEndId: nil,
            amount: TransactionsResponse.Amount(currency: "EUR", amount: "-5.00"),
            creditor: TransactionsResponse.Party(name: "Laden", iban: nil, bic: nil),
            debtor: nil, remittanceInformation: ["Zweck \(tag)"],
            additionalInformation: nil, purposeCode: nil)
    }

    // MARK: - Die Rechnung

    func testDieTiefeZaehltDenStichtagMit() {
        // Vor 100 Tagen gebucht: `loadTransactions(days:)` nimmt heute − (Tage − 1)
        // als Stichtag, also braucht es 101 Tage, damit die Buchung hereinfällt.
        XCTAssertEqual(Anzeigetiefe.tiefeInTagen(tag(100)), 101)
    }

    func testHeuteGebuchtErgibtEinenTag() {
        XCTAssertEqual(Anzeigetiefe.tiefeInTagen(tag(0)), 1)
    }

    func testOhneLesbaresDatumGibtEsKeineTiefe() {
        XCTAssertNil(Anzeigetiefe.tiefeInTagen("Mittwoch"))
        XCTAssertNil(Anzeigetiefe.tiefeInTagen(""))
    }

    // MARK: - Die Marke

    func testDieMarkeKommtAusDerAeltestenBuchung() throws {
        let slot = "slot-marke"
        defer { BankSlotSettingsStore.delete(slotId: slot) }
        _ = try TransactionsDatabase.upsert(transactions: [buchung(tag(0)), buchung(tag(730))],
                                            slotId: slot, bankId: bank, purgeStalePending: false)
        Anzeigetiefe.merken(slotId: slot, bankId: bank)
        XCTAssertEqual(BankSlotSettingsStore.load(slotId: slot).lastImportedDays, 731)
    }

    /// Ein zweiter Lauf bringt nichts Neues herein, muss die Marke aber setzen
    /// können — sonst wäre ein schon vollzogener Import nicht mehr zu heilen.
    func testEinZweiterLaufOhneNeueBuchungenSetztDieMarkeTrotzdem() throws {
        let slot = "slot-zweiter-lauf"
        defer { BankSlotSettingsStore.delete(slotId: slot) }
        _ = try TransactionsDatabase.upsert(transactions: [buchung(tag(200))],
                                            slotId: slot, bankId: bank, purgeStalePending: false)
        XCTAssertNil(BankSlotSettingsStore.load(slotId: slot).lastImportedDays)
        Anzeigetiefe.merken(slotId: slot, bankId: bank)
        XCTAssertEqual(BankSlotSettingsStore.load(slotId: slot).lastImportedDays, 201)
    }

    func testDieMarkeSchrumpftNicht() throws {
        let slot = "slot-nur-nach-oben"
        defer { BankSlotSettingsStore.delete(slotId: slot) }
        var einstellungen = BankSlotSettingsStore.load(slotId: slot)
        einstellungen.lastImportedDays = 900
        BankSlotSettingsStore.save(einstellungen, slotId: slot)
        _ = try TransactionsDatabase.upsert(transactions: [buchung(tag(10))],
                                            slotId: slot, bankId: bank, purgeStalePending: false)
        Anzeigetiefe.merken(slotId: slot, bankId: bank)
        XCTAssertEqual(BankSlotSettingsStore.load(slotId: slot).lastImportedDays, 900)
    }

    func testEinLeererSlotBekommtKeineMarke() {
        let slot = "slot-leer"
        defer { BankSlotSettingsStore.delete(slotId: slot) }
        Anzeigetiefe.merken(slotId: slot, bankId: bank)
        XCTAssertNil(BankSlotSettingsStore.load(slotId: slot).lastImportedDays)
    }

    // MARK: - Die Zusage am Quelltext

    /// Prüft den **Quelltext**, weil kein Typ es erzwingt: Ein Importweg, der die
    /// Marke vergisst, schreibt trotzdem fehlerfrei — das Ergebnis ist nur
    /// unsichtbar. Genau so sind OFX und CAMT.053 bis 2.2.1 durchgerutscht.
    func testJederImportwegZiehtDasLesefensterMit() throws {
        for (datei, anzahl) in [("ImportSheet.swift", 3), ("MoneyMoneyUebernahme.swift", 1)] {
            let quelle = Quelltext.ohneKommentare(try Quelltext.datei(datei))
            let treffer = quelle.components(separatedBy: "Anzeigetiefe.merken").count - 1
            XCTAssertEqual(treffer, anzahl,
                           "\(datei) muss nach jedem Schreiben von Historie "
                           + "Anzeigetiefe.merken aufrufen")
        }
    }
}
