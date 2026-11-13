import XCTest
import MoneyMoneyForm
@testable import simplebanking

/// Der Schreibweg: Naht, Vormerkungen, Schlüsselrückgabe, Ablage.
///
/// Diese Tests laufen gegen eine **echte** Datenbank unter eigenem `bankId` — die
/// reinen Regeln sind in `MoneyMoneyZuordnungTests` abgedeckt, hier geht es um das,
/// was erst beim Schreiben schiefgehen kann.
@MainActor
final class MoneyMoneyUebernahmeTests: XCTestCase {

    private let bank = "mm-uebernahme-test"
    private let slot = "slot-uebernahme"

    override func setUp() async throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
        try TransactionsDatabase.migrate(bankId: bank)
    }

    override func tearDown() async throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: bank)
    }

    // MARK: - Hilfen

    /// Epoche zu einem Tag, wie MoneyMoney sie stempelt: 12:00 UTC.
    private func epoche(_ tag: String) -> Int64 {
        let former = DateFormatter()
        former.dateFormat = "yyyy-MM-dd"
        former.timeZone = TimeZone(identifier: "UTC")
        former.locale = Locale(identifier: "en_US_POSIX")
        guard let datum = former.date(from: tag) else {
            XCTFail("Testdatum \(tag) nicht lesbar"); return 0
        }
        return Int64(datum.timeIntervalSince1970) + 43_200
    }

    private func umsatz(_ tag: String, betrag: Double = -10.0,
                        kategorie: Int64? = nil) -> MoneyMoneyUmsatz {
        MoneyMoneyUmsatz(
            kontoSchluessel: 1,
            betrag: betrag,
            waehrung: "EUR",
            gebuchtAm: epoche(tag),
            wertgestelltAm: epoche(tag),
            gegenseiteName: "Testladen GmbH",
            gegenseiteIban: "DE02120300000000202051",
            zweck: "Einkauf \(tag)",
            buchungstext: "Lastschrift",
            kategorieSchluessel: kategorie
        )
    }

    private func auszug(_ umsaetze: [MoneyMoneyUmsatz],
                        kategorien: [MoneyMoneyKategorie] = []) -> MoneyMoneyAuszug {
        MoneyMoneyAuszug(
            konten: [MoneyMoneyKonto(schluessel: 1, iban: "DE83460500010001808336")],
            kategorien: kategorien,
            umsaetze: umsaetze
        )
    }

    /// Eine Buchung, wie die Bank sie liefert — sie setzt die Naht.
    private func bankbuchung(_ tag: String, status: String = "Booked")
        -> TransactionsResponse.Transaction {
        TransactionsResponse.Transaction(
            bookingDate: tag,
            valueDate: tag,
            status: status,
            endToEndId: nil,
            amount: TransactionsResponse.Amount(currency: "EUR", amount: "-5.00"),
            creditor: TransactionsResponse.Party(name: "Bank Laden",
                                                 fullName: "Bank Laden GmbH",
                                                 iban: nil, bic: nil),
            debtor: nil,
            remittanceInformation: ["Vom Abruf \(tag)"],
            additionalInformation: nil,
            purposeCode: nil
        )
    }

    // MARK: - Die Naht

    func testUebernommenWirdNurWasAelterIstAlsDieAelteste() async throws {
        // Die Bank hat ab 2026-06-01 geliefert — das ist die Naht.
        try TransactionsDatabase.upsert(transactions: [bankbuchung("2026-06-01")],
                                        slotId: slot, bankId: bank)
        XCTAssertEqual(try TransactionsDatabase.allTxIds(slotId: slot, bankId: bank).count, 1)

        let ergebnis = try await MoneyMoneyUebernahme.nachtragen(
            slotId: slot, kontoSchluessel: 1,
            auszug: auszug([umsatz("2026-05-01"),   // älter → herein
                            umsatz("2026-06-01"),   // genau die Naht → draußen
                            umsatz("2026-07-01")]), // jünger → draußen
            bankId: bank)

        XCTAssertEqual(ergebnis.buchungen, 1, "Nur die ältere Buchung darf herein")
        XCTAssertEqual(try TransactionsDatabase.allTxIds(slotId: slot, bankId: bank).count, 2)
    }

    func testDerNahttagSelbstBleibtDraussen() async throws {
        // Der Tag der ältesten Buchung ist genau der, den die Bank schon geliefert
        // hat. Nimmt der Import ihn mit, liegt jede Buchung dieses Tages doppelt da —
        // mit anderem Fingerprint, weil MoneyMoney den Text anders schreibt.
        try TransactionsDatabase.upsert(transactions: [bankbuchung("2026-06-01")],
                                        slotId: slot, bankId: bank)
        let ergebnis = try await MoneyMoneyUebernahme.nachtragen(
            slotId: slot, kontoSchluessel: 1,
            auszug: auszug([umsatz("2026-06-01")]), bankId: bank)
        XCTAssertEqual(ergebnis.buchungen, 0)
        XCTAssertEqual(try TransactionsDatabase.allTxIds(slotId: slot, bankId: bank).count, 1)
    }

    func testOhneBuchungImSlotKommtAllesHerein() async throws {
        // Leerer Slot: Die Bank hat nichts geliefert, es gibt keinen Bezugspunkt.
        let ergebnis = try await MoneyMoneyUebernahme.nachtragen(
            slotId: slot, kontoSchluessel: 1,
            auszug: auszug([umsatz("2026-05-01"), umsatz("2026-07-01")]), bankId: bank)
        XCTAssertEqual(ergebnis.buchungen, 2)
    }

    func testBuchungenEinesAnderenKontosBleibenLiegen() async throws {
        var fremd = umsatz("2026-05-01")
        fremd.kontoSchluessel = 7
        let ergebnis = try await MoneyMoneyUebernahme.nachtragen(
            slotId: slot, kontoSchluessel: 1,
            auszug: auszug([umsatz("2026-05-02"), fremd]), bankId: bank)
        XCTAssertEqual(ergebnis.buchungen, 1)
    }

    // MARK: - Vormerkungen

    func testVorgemerkteBuchungenUeberlebenDenImport() async throws {
        // `purgeStalePending` löscht JEDE Vormerkung des Slots, die nicht in der
        // übergebenen Liste steht. Der Import übergibt absichtlich nur Vergangenheit —
        // mit dem Standardwert `true` risse er damit alles Vorgemerkte mit.
        try TransactionsDatabase.upsert(
            transactions: [bankbuchung("2026-06-01"),
                           bankbuchung("2026-06-10", status: "Pending")],
            slotId: slot, bankId: bank)
        let vorher = try TransactionsDatabase.allTxIds(slotId: slot, bankId: bank).count
        XCTAssertEqual(vorher, 2)

        _ = try await MoneyMoneyUebernahme.nachtragen(
            slotId: slot, kontoSchluessel: 1,
            auszug: auszug([umsatz("2026-05-01")]), bankId: bank)

        XCTAssertEqual(try TransactionsDatabase.allTxIds(slotId: slot, bankId: bank).count,
                       vorher + 1,
                       "Die Vormerkung muss stehen bleiben")
    }

    // MARK: - Die Schlüsselrückgabe

    func testUpsertGibtDieSchluesselInDerReihenfolgeZurueck() throws {
        let schluessel = try TransactionsDatabase.upsert(
            transactions: [bankbuchung("2026-06-01"), bankbuchung("2026-06-02")],
            slotId: slot, bankId: bank)
        XCTAssertEqual(schluessel.count, 2)
        XCTAssertNotEqual(schluessel[0], schluessel[1])
    }

    func testMehrfachGleicheBuchungenBekommenGezaehlteSchluessel() throws {
        // Zweimal derselbe Kaffee am selben Automaten: gleicher Fingerprint. Ab dem
        // zweiten hängt ein Zähler an der ID — und die Kategoriezuordnung braucht
        // genau diese gezählte Form, sonst landet der Override auf der ersten Zeile.
        let gleich = bankbuchung("2026-06-01")
        let schluessel = try TransactionsDatabase.upsert(transactions: [gleich, gleich],
                                                        slotId: slot, bankId: bank)
        XCTAssertEqual(schluessel.count, 2)
        XCTAssertTrue(schluessel[1].hasSuffix("#2"), "Erwartet gezählte ID, war \(schluessel[1])")
        XCTAssertFalse(schluessel[0].contains("#"))
    }

    func testLeereListeGibtKeineSchluessel() throws {
        XCTAssertEqual(try TransactionsDatabase.upsert(transactions: [], slotId: slot,
                                                       bankId: bank).count, 0)
    }

    // MARK: - Kategorien

    func testEineUnbekannteKategorieWirdAlsEigeneAngelegt() async throws {
        // MoneyMoneys Namen sind nicht unsere vierzehn. Ohne das Anlegen importierte
        // der Umstieg so gut wie keine Kategorie.
        let name = "Pferdepension"
        XCTAssertNil(TransactionCategory.from(displayName: name))

        let ergebnis = try await MoneyMoneyUebernahme.nachtragen(
            slotId: slot, kontoSchluessel: 1,
            auszug: auszug([umsatz("2026-05-01", kategorie: 9)],
                           kategorien: [MoneyMoneyKategorie(schluessel: 9, pfad: name)]),
            bankId: bank)

        XCTAssertEqual(ergebnis.buchungen, 1)
        XCTAssertEqual(ergebnis.kategorien, 1)
        XCTAssertNotNil(TransactionCategory.from(displayName: name),
                        "Die Kategorie muss danach existieren")
        Eigenkategorien.loeschen(name: name)
    }

    func testEineEingebauteKategorieWirdNichtDoppeltAngelegt() async throws {
        let vorher = Eigenkategorien.alle.count
        _ = try await MoneyMoneyUebernahme.nachtragen(
            slotId: slot, kontoSchluessel: 1,
            auszug: auszug([umsatz("2026-05-01", kategorie: 3)],
                           kategorien: [MoneyMoneyKategorie(schluessel: 3,
                                                            pfad: "Essen & Alltag")]),
            bankId: bank)
        XCTAssertEqual(Eigenkategorien.alle.count, vorher,
                       "Für eine eingebaute Kategorie darf keine eigene entstehen")
    }

    func testEinZuLangerNameWirdUebergangenStattZurechtgeschnitten() async throws {
        // Ein von uns gekürzter Name wäre keiner, den der Nutzer gewählt hat. Die
        // Buchung landet trotzdem — nur ohne Kategorie.
        let lang = String(repeating: "x", count: Eigenkategorien.maximaleLaenge + 1)
        let ergebnis = try await MoneyMoneyUebernahme.nachtragen(
            slotId: slot, kontoSchluessel: 1,
            auszug: auszug([umsatz("2026-05-01", kategorie: 4)],
                           kategorien: [MoneyMoneyKategorie(schluessel: 4, pfad: lang)]),
            bankId: bank)
        XCTAssertEqual(ergebnis.buchungen, 1)
        XCTAssertEqual(ergebnis.kategorien, 0)
        XCTAssertEqual(ergebnis.uebergangeneKategorien, [lang])
    }

    func testGebuendelteOverridesSchreibenAlleZuordnungen() {
        let paare = (1...50).map { (txID: "tx-\($0)", slotId: slot,
                                    category: TransactionCategory.essenAlltag) }
        TransactionCategorizer.saveOverrides(paare)
        for paar in paare {
            XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: paar.txID,
                                                                   slotId: slot),
                           .essenAlltag)
        }
        for paar in paare {
            TransactionCategorizer.removeOverride(txID: paar.txID, slotId: slot)
        }
    }

    func testDieZuordnungenLaufenNichtInDieEchtenEinstellungen() {
        // Bis zu diesem Sandkasten schrieb jeder Test, der einen Override setzt, in
        // die Zuordnungen des Nutzers.
        XCTAssertNotEqual(TransactionCategorizer.defaults, UserDefaults.standard)
    }

    // MARK: - Die Ablage

    func testDieAblageUeberlebtUndWirdWeggeworfen() throws {
        let original = auszug([umsatz("2026-05-01"), umsatz("2026-05-02")])
        MoneyMoneyAblage.legen(original)
        XCTAssertEqual(MoneyMoneyAblage.holen(), original)
        MoneyMoneyAblage.wegwerfen()
        XCTAssertNil(MoneyMoneyAblage.holen())
    }

    func testDieAblageIstNurFuerDenEigentuemerLesbar() throws {
        MoneyMoneyAblage.legen(auszug([umsatz("2026-05-01")]))
        defer { MoneyMoneyAblage.wegwerfen() }
        let ort = try XCTUnwrap(MoneyMoneyAblage.ort)
        let rechte = try FileManager.default.attributesOfItem(atPath: ort.path)[.posixPermissions]
        XCTAssertEqual(rechte as? Int, 0o600,
                       "Darin steht der Umsatzverlauf — niemand sonst darf ihn lesen")
    }

    func testDieAblageTraegtKeinKennwort() throws {
        MoneyMoneyAblage.legen(auszug([umsatz("2026-05-01")]))
        defer { MoneyMoneyAblage.wegwerfen() }
        let ort = try XCTUnwrap(MoneyMoneyAblage.ort)
        let roh = try Data(contentsOf: ort)
        // Der Auszug ist das Ergebnis, nicht der Schlüssel. Eine Form, die ein Feld
        // dafür hätte, wäre ein Kennwort auf der Platte.
        let form = Quelltext.ohneKommentare(
            try Quelltext.quelle("Sources/MoneyMoneyForm/Datenform.swift")).lowercased()
        // Auf Eigenschaften prüfen, nicht auf das Wort: `kennwortFalsch` ist ein
        // Fehlerfall der Rückmeldung und muss genau so heißen.
        for begriff in ["kennwort", "passwort", "password", "pin", "privkey"] {
            for form_ in ["var \(begriff)", "let \(begriff)"] {
                XCTAssertFalse(form.contains(form_),
                               "Die Drahtform darf kein Feld \(begriff) haben")
            }
        }
        XCTAssertFalse(roh.isEmpty)
    }

    // MARK: - Anzeigezeitraum

    private func tag(_ abstand: Int) -> String {
        let former = DateFormatter()
        former.dateFormat = "yyyy-MM-dd"
        former.locale = Locale(identifier: "en_US_POSIX")
        return former.string(from: Date().addingTimeInterval(Double(-abstand) * 86_400))
    }

    func testDieTiefeZaehltDenStichtagMit() {
        // Vor 100 Tagen gebucht: `loadTransactions(days:)` nimmt heute − (Tage − 1)
        // als Stichtag, also braucht es 101 Tage, damit die Buchung hereinfällt.
        XCTAssertEqual(MoneyMoneyUebernahme.tiefeInTagen(tag(100)), 101)
    }

    func testHeuteGebuchtErgibtEinenTag() {
        XCTAssertEqual(MoneyMoneyUebernahme.tiefeInTagen(tag(0)), 1)
    }

    func testOhneLesbaresDatumGibtEsKeineTiefe() {
        XCTAssertNil(MoneyMoneyUebernahme.tiefeInTagen("Mittwoch"))
        XCTAssertNil(MoneyMoneyUebernahme.tiefeInTagen(""))
    }

    /// Der eigentliche Fehler von 2.2.1: Buchungen in der Datenbank, aber
    /// `displayDays` bei 60 — und damit nichts zu sehen.
    func testDieUebernahmeWeitetDenAnzeigezeitraum() async throws {
        let merkslot = "slot-anzeigezeitraum"
        defer { BankSlotSettingsStore.delete(slotId: merkslot) }
        // Eine Bankbuchung von heute setzt die Naht, alles Ältere kommt herein.
        _ = try TransactionsDatabase.upsert(transactions: [bankbuchung(tag(0))],
                                            slotId: merkslot, bankId: bank)
        XCTAssertEqual(BankSlotSettingsStore.load(slotId: merkslot).displayDays, 60)

        _ = try await MoneyMoneyUebernahme.nachtragen(
            slotId: merkslot, kontoSchluessel: 1,
            auszug: auszug([umsatz(tag(400))]), bankId: bank)

        XCTAssertEqual(BankSlotSettingsStore.load(slotId: merkslot).lastImportedDays, 401)
        XCTAssertEqual(BankSlotSettingsStore.load(slotId: merkslot).displayDays, 401)
    }
}
