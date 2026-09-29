import XCTest
@testable import simplebanking

/// Aus einem Audit, 29.09.2026, Befunde 2 und 3 — die zusammen ein Fehler sind.
///
/// Die App führte zwei konkurrierende Identitäten für eine Buchung: den `fingerprint`
/// (Anreicherung) und `stableIdentifier` (Zeilen, OFX-Export, Sparmarken). Keine von
/// beiden trug den Schlüssel, unter dem die Datenbank die Zeile tatsächlich ablegt.
///
/// Zwei gleiche Buchungen aus einem Abruf liegen unter `fp` und `fp#2`
/// (`TransactionsDatabase.upsert`, seit der Abhilfe zum vorigen Audit). Beim Anzeigen
/// wurde die Identität neu berechnet — und traf für beide Zeilen dieselbe. Folge: Die
/// Anreicherungsspalten der zweiten Zeile waren unerreichbar, nicht schreibbar und nicht
/// lesbar, und beide Zeilen trugen dieselben Abzeichen.
final class BuchungsidentitaetTests: XCTestCase {

    private func buchung(endToEndId: String? = nil,
                         betrag: String = "-2.50",
                         empfaenger: String = "Kaffeeautomat",
                         dbTxId: String? = nil) -> TransactionsResponse.Transaction {
        var tx = TransactionsResponse.Transaction(
            bookingDate: "2026-09-29", valueDate: "2026-09-29", status: "booked",
            endToEndId: endToEndId,
            amount: TransactionsResponse.Amount(currency: "EUR", amount: betrag),
            creditor: TransactionsResponse.Party(name: empfaenger, iban: nil, bic: nil),
            debtor: nil, remittanceInformation: ["Kaffee"],
            additionalInformation: nil, purposeCode: nil)
        tx.dbTxId = dbTxId
        return tx
    }

    // MARK: - Der Kern: der Datenbankschlüssel gewinnt

    func test_anreicherungsSchluessel_nimmtDenDatenbankschluessel() {
        let erste = buchung(dbTxId: "abc")
        let zweite = buchung(dbTxId: "abc#2")

        XCTAssertEqual(erste.anreicherungsSchluessel, "abc")
        XCTAssertEqual(zweite.anreicherungsSchluessel, "abc#2")
        XCTAssertNotEqual(erste.anreicherungsSchluessel, zweite.anreicherungsSchluessel,
                          "Ohne Unterschied hängen Notiz und Beleg der zweiten Buchung an der ersten.")
    }

    /// Ohne Datenbankschlüssel — frischer Abruf, Vorschau, Test — bleibt es beim
    /// berechneten Fingerprint. Das ist der Rückfall, nicht der Normalfall.
    func test_ohneDatenbankschluessel_wirdGerechnet() {
        let tx = buchung()
        XCTAssertEqual(tx.anreicherungsSchluessel, TransactionRecord.fingerprint(for: tx))
    }

    // MARK: - Zeilenidentität und OFX-Kennung

    /// Genau der Fall, den das Audit als „NOTPROVIDED" beschrieb — er braucht das Sentinel
    /// gar nicht. Zwei gleiche Buchungen mit leerer End-to-End-ID reichen.
    func test_gleicheBuchungen_ohneEndToEndId_bekommenVerschiedeneKennungen() {
        let erste = buchung(endToEndId: "", dbTxId: "fp")
        let zweite = buchung(endToEndId: "", dbTxId: "fp#2")

        XCTAssertNotEqual(erste.stableIdentifier, zweite.stableIdentifier,
                          "Gleiche Kennungen kollidieren in der Zeilenidentität und als OFX-FITID.")
    }

    /// Und der Fall, den es beschrieb: Ein Sentinel als End-to-End-ID darf nicht mehr
    /// durchschlagen, sobald die Zeile aus der Datenbank kommt.
    func test_sentinelAlsEndToEndId_schlaegtNichtMehrDurch() {
        let erste = buchung(endToEndId: "NOTPROVIDED", betrag: "-2.50", dbTxId: "fp-a")
        let zweite = buchung(endToEndId: "NOTPROVIDED", betrag: "-99.00", dbTxId: "fp-b")

        XCTAssertNotEqual(erste.stableIdentifier, zweite.stableIdentifier)
        XCTAssertEqual(erste.stableIdentifier, "fp-a")
    }

    /// Gegenprobe: Ohne Datenbankschlüssel gilt weiter, was die Bank liefert — sonst
    /// änderte sich das Verhalten für frisch abgerufene Buchungen.
    func test_ohneDatenbankschluessel_giltDieBankkennung() {
        let tx = buchung(endToEndId: "E2E-4711")
        XCTAssertEqual(tx.stableIdentifier, "E2E-4711")
        XCTAssertEqual(tx.stableIdentifier, tx.stableIdentifierAusBankdaten)
    }

    // MARK: - Der Weg aus der Datenbank ins Modell

    func test_toTransaction_traegtDenSchluesselMit() throws {
        let tx = buchung(endToEndId: "")
        var record = try TransactionRecord(transaction: tx, updatedAt: "2026-09-29T00:00:00Z")
        record.txID += "#2"

        let zurueck = try XCTUnwrap(record.toTransaction())
        XCTAssertEqual(zurueck.dbTxId, record.txID)
        XCTAssertEqual(zurueck.anreicherungsSchluessel, record.txID)
    }

    /// Der Schlüssel gehört zur Zeile, nicht zur Buchung — er darf nicht in `raw_json`
    /// landen. Sonst stünde er in den gespeicherten Daten und wanderte beim nächsten
    /// Abruf als Teil der Buchung mit.
    func test_datenbankschluessel_stehtNichtImGespeichertenJSON() throws {
        var tx = buchung(endToEndId: "E2E-1")
        tx.dbTxId = "sollte-nicht-auftauchen"
        let json = try JSONEncoder().encode(tx)
        let text = String(data: json, encoding: .utf8) ?? ""

        XCTAssertFalse(text.contains("dbTxId"))
        XCTAssertFalse(text.contains("sollte-nicht-auftauchen"))
        XCTAssertTrue(text.contains("E2E-1"), "die übrigen Felder müssen erhalten bleiben")
    }

    /// Und die Gegenrichtung: Ein dekodierter Datensatz hat keinen Schlüssel, bis
    /// `toTransaction()` ihn setzt.
    func test_dekodiertOhneSchluessel() throws {
        let tx = buchung(endToEndId: "E2E-1")
        let zurueck = try JSONDecoder().decode(TransactionsResponse.Transaction.self,
                                               from: try JSONEncoder().encode(tx))
        XCTAssertNil(zurueck.dbTxId)
    }

    // MARK: - Sparmarken: der Rückweg für Bestehendes

    /// Sparmarken hingen bis 2.0.7 an `stableIdentifierAusBankdaten`. Mit dem Umstieg auf
    /// den Datenbankschlüssel wären sie unsichtbar geworden — kein Datenverlust im engeren
    /// Sinn, aber genau die Art stiller Verschlechterung, die niemand meldet.
    func test_alteSparmarke_bleibtLesbar() {
        let d = UserDefaults.standard
        let tx = buchung(endToEndId: "E2E-alt", dbTxId: "neuer-schluessel")
        let vorher = d.stringArray(forKey: "savingsBookmarkedTransactions")
        defer { d.set(vorher, forKey: "savingsBookmarkedTransactions") }

        // So lag sie vor dem Umstieg im Speicher.
        d.set([tx.stableIdentifierAusBankdaten], forKey: "savingsBookmarkedTransactions")
        XCTAssertTrue(SavingsBookmarks.isBookmarked(tx),
                      "eine vor dem Umstieg gesetzte Marke muss weiter erkannt werden")
    }

    /// Und sie muss sich auch wieder abwählen lassen — sonst bliebe sie für immer stehen.
    func test_alteSparmarke_laesstSichAbwaehlen() {
        let d = UserDefaults.standard
        let tx = buchung(endToEndId: "E2E-alt", dbTxId: "neuer-schluessel")
        let vorher = d.stringArray(forKey: "savingsBookmarkedTransactions")
        defer { d.set(vorher, forKey: "savingsBookmarkedTransactions") }

        d.set([tx.stableIdentifierAusBankdaten], forKey: "savingsBookmarkedTransactions")
        SavingsBookmarks.toggle(tx)
        XCTAssertFalse(SavingsBookmarks.isBookmarked(tx))
        XCTAssertFalse((d.stringArray(forKey: "savingsBookmarkedTransactions") ?? [])
                        .contains(tx.stableIdentifierAusBankdaten),
                       "der alte Eintrag muss verschwinden, nicht nur der neue")
    }

    /// Neue Marken entstehen unter dem neuen Schlüssel.
    func test_neueSparmarke_nutztDenDatenbankschluessel() {
        let d = UserDefaults.standard
        let tx = buchung(endToEndId: "E2E-neu", dbTxId: "zeile-7")
        let vorher = d.stringArray(forKey: "savingsBookmarkedTransactions")
        defer { d.set(vorher, forKey: "savingsBookmarkedTransactions") }

        d.set([], forKey: "savingsBookmarkedTransactions")
        SavingsBookmarks.toggle(tx)
        XCTAssertEqual(d.stringArray(forKey: "savingsBookmarkedTransactions"), ["zeile-7"])
    }
}
