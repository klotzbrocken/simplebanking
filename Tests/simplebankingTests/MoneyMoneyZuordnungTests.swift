import XCTest
import MoneyMoneyForm
@testable import simplebanking

/// MoneyMoney-Zeile → `TransactionsResponse.Transaction`.
@MainActor
final class MoneyMoneyZuordnungTests: XCTestCase {

    /// Die PayPal-Lastschrift vom 11.11.2026 aus der Messdatenbank, Felder gekürzt.
    private func lastschrift(betrag: Double = -20.0) -> MoneyMoneyUmsatz {
        MoneyMoneyUmsatz(
            kontoSchluessel: 1,
            betrag: betrag,
            waehrung: "EUR",
            gebuchtAm: 1_794_398_400,
            wertgestelltAm: 1_794_398_400,
            gegenseiteName: "PayPal Europe S.a.r.l. et Cie S.C.A",
            gegenseiteIban: "LU89751000135104200E",
            gegenseiteBic: "PPLXLUL2",
            zweck: "1054362496256/PP.6847.PP/. Ihr Einkauf",
            buchungstext: "Folgelastschrift",
            endeZuEnde: "1054362496256",
            mandat: "4QB2224MX8KAU",
            kategorieSchluessel: 5
        )
    }

    func testAusgabeLegtDieGegenseiteAlsGlaeubigerAb() {
        let buchung = MoneyMoneyZuordnung.buchung(lastschrift(), kategorie: nil)
        XCTAssertEqual(buchung.bookingDate, "2026-11-11")
        XCTAssertEqual(buchung.valueDate, "2026-11-11")
        XCTAssertEqual(buchung.amount?.amount, "-20.00")
        XCTAssertEqual(buchung.amount?.currency, "EUR")
        XCTAssertEqual(buchung.endToEndId, "1054362496256")
        XCTAssertEqual(buchung.remittanceInformation, ["1054362496256/PP.6847.PP/. Ihr Einkauf"])
        XCTAssertEqual(buchung.additionalInformation, "Folgelastschrift")
        XCTAssertEqual(buchung.status, "Booked")
        XCTAssertNotNil(buchung.creditor)
        XCTAssertNil(buchung.debtor, "Bei Ausgang steht die Gegenseite im Gläubiger")
    }

    func testEingangLegtDieGegenseiteAlsSchuldnerAb() {
        let buchung = MoneyMoneyZuordnung.buchung(lastschrift(betrag: 42.5), kategorie: nil)
        XCTAssertEqual(buchung.amount?.amount, "42.50")
        XCTAssertNotNil(buchung.debtor)
        XCTAssertNil(buchung.creditor)
    }

    func testNameWirdGekuerztUndDerVolleBleibt() {
        // `Party.name` ist der Gruppierungsschlüssel (Fixkosten, Abo-Erkennung,
        // Zuordnungsregeln) und darum auf zwei Wörter gekürzt; der ungekürzte
        // gehört nach `fullName`. Wer hier den vollen Namen einträgt, zerlegt
        // bestehende Gruppen.
        let buchung = MoneyMoneyZuordnung.buchung(lastschrift(), kategorie: nil)
        XCTAssertEqual(buchung.creditor?.name, "PayPal Europe")
        XCTAssertEqual(buchung.creditor?.fullName, "PayPal Europe S.a.r.l. et Cie S.C.A")
        XCTAssertEqual(buchung.creditor?.iban, "LU89751000135104200E")
        XCTAssertEqual(buchung.creditor?.bic, "PPLXLUL2")
    }

    func testKategorieWirdNurMitgegeben() {
        // `TransactionRecord.init` verwirft `category` und kategorisiert neu. Das
        // Feld trägt den Wert nur bis zum Override-Schreiben nach dem Upsert.
        XCTAssertEqual(MoneyMoneyZuordnung.buchung(lastschrift(), kategorie: "Haustier").category,
                       "Haustier")
        XCTAssertNil(MoneyMoneyZuordnung.buchung(lastschrift(), kategorie: nil).category)
    }

    // MARK: - Auszug

    private func auszug() -> MoneyMoneyAuszug {
        MoneyMoneyAuszug(
            konten: [
                MoneyMoneyKonto(schluessel: 1, iban: "DE83460500010001808336", name: "Giro"),
                MoneyMoneyKonto(schluessel: 2, iban: "", name: "Versicherung", istDepot: true),
            ],
            kategorien: [
                MoneyMoneyKategorie(schluessel: 1, pfad: ""),                      // Standard
                MoneyMoneyKategorie(schluessel: 5, pfad: "Mobilität\\Bahn"),
            ],
            umsaetze: [
                MoneyMoneyUmsatz(kontoSchluessel: 1, betrag: -1, gebuchtAm: 1_700_000_000,
                                 kategorieSchluessel: 5),
                MoneyMoneyUmsatz(kontoSchluessel: 1, betrag: -2, gebuchtAm: 1_794_398_400,
                                 kategorieSchluessel: 1),
                MoneyMoneyUmsatz(kontoSchluessel: 1, betrag: -3, gebuchtAm: 1_700_000_000,
                                 istGebucht: false),
                MoneyMoneyUmsatz(kontoSchluessel: 1, betrag: -4, gebuchtAm: 1_700_000_000,
                                 istGeteilt: true),
                MoneyMoneyUmsatz(kontoSchluessel: 2, betrag: -5, gebuchtAm: 1_700_000_000),
            ]
        )
    }

    func testNurDasKontoMitIBANKommtInFrage() {
        let konten = MoneyMoneyZuordnung.uebernehmbareKonten(auszug())
        XCTAssertEqual(konten.map(\.schluessel), [1])
    }

    func testVorgemerkteUndGeteilteFallenWeg() {
        let buchungen = MoneyMoneyZuordnung.buchungen(auszug(), fuerKonto: 1)
        XCTAssertEqual(buchungen.compactMap { $0.amount?.amount }, ["-1.00", "-2.00"])
    }

    func testFremdesKontoKommtNichtMit() {
        XCTAssertTrue(MoneyMoneyZuordnung.buchungen(auszug(), fuerKonto: 3).isEmpty)
    }

    func testErsteKategorieebeneKommtAnDerBuchungAn() {
        let buchungen = MoneyMoneyZuordnung.buchungen(auszug(), fuerKonto: 1)
        XCTAssertEqual(buchungen.first?.category, "Mobilität")
        // Die Standardkategorie trägt keinen Namen und darf keine Kategorie setzen.
        XCTAssertNil(buchungen.last?.category)
    }

    func testDieNahtNimmtNurAeltereBuchungen() {
        // Die Naht ist ein Datum, kein Hash: Übernommen wird nur, was älter ist als
        // die älteste Buchung, die der Slot schon hat. 1_700_000_000 = 2023-11-14,
        // 1_794_398_400 = 2026-11-11.
        let buchungen = MoneyMoneyZuordnung.buchungen(auszug(), fuerKonto: 1,
                                                      aelterAls: "2026-01-01")
        XCTAssertEqual(buchungen.compactMap { $0.amount?.amount }, ["-1.00"])
    }

    func testOhneNahtKommtAllesGebuchteMit() {
        XCTAssertEqual(MoneyMoneyZuordnung.buchungen(auszug(), fuerKonto: 1, aelterAls: nil).count, 2)
    }

    func testNahtSchliesstDenTagSelbstAus() {
        // Gleiches Datum heißt: die Bank hat diesen Tag schon geliefert. Nähme der
        // Import ihn mit, läge der Tag doppelt da — der Fingerprint fängt das nicht,
        // weil ein Leerzeichen im Zweck genügt, damit er abweicht.
        let buchungen = MoneyMoneyZuordnung.buchungen(auszug(), fuerKonto: 1,
                                                      aelterAls: "2023-11-14")
        XCTAssertTrue(buchungen.isEmpty)
    }

    // MARK: - Drahtform

    func testDrahtformUeberlebtDenWegDurchDasPlist() throws {
        // Der Helfer schreibt ein Binär-Plist auf stdout, die App liest es. Fällt ein
        // Feld beim Kodieren durch, merkt das sonst niemand — der Import wäre
        // stillschweigend unvollständig.
        let kodierer = PropertyListEncoder()
        kodierer.outputFormat = .binary
        let daten = try kodierer.encode(auszug())
        let zurueck = try PropertyListDecoder().decode(MoneyMoneyAuszug.self, from: daten)
        XCTAssertEqual(zurueck, auszug())
    }
}

/// Der Überschneidungszeitraum: Die Buchung kommt von der Bank, die Kategorie aus
/// MoneyMoney. Gemeldet am 11.11.2026 — „HUHN" und „HUND" hingen dort auf Buchungen
/// von heute, und der Import übersprang genau die, weil die Bank sie selbst liefert.
@MainActor
final class MoneyMoneyKategorienahtTests: XCTestCase {

    func testEindeutigesPaarBekommtDieKategorie() {
        let zuordnung = MoneyMoneyZuordnung.kategoriezuordnung(
            bank: [(txID: "a", tag: "2026-11-11", betrag: -20.0),
                   (txID: "b", tag: "2026-11-11", betrag: -35.5)],
            moneymoney: [(tag: "2026-11-11", betrag: "-35.50", kategorie: "HUND")])
        XCTAssertEqual(zuordnung.map(\.txID), ["b"])
        XCTAssertEqual(zuordnung.map(\.kategorie), ["HUND"])
    }

    func testZweiGleicheBetraegeAmSelbenTagBleibenOhneKategorie() {
        let zuordnung = MoneyMoneyZuordnung.kategoriezuordnung(
            bank: [(txID: "a", tag: "2026-11-11", betrag: -20.0),
                   (txID: "b", tag: "2026-11-11", betrag: -20.0)],
            moneymoney: [(tag: "2026-11-11", betrag: "-20.00", kategorie: "HUHN")])
        XCTAssertTrue(zuordnung.isEmpty, "Geraten ist schlechter als gar nicht")
    }

    func testOhneGegenstueckInDerBankFaelltDieZeileWeg() {
        let zuordnung = MoneyMoneyZuordnung.kategoriezuordnung(
            bank: [(txID: "a", tag: "2026-11-10", betrag: -20.0)],
            moneymoney: [(tag: "2026-11-11", betrag: "-20.00", kategorie: "HUHN")])
        XCTAssertTrue(zuordnung.isEmpty)
    }

    func testKategoriezeilenNehmenNurWasAbDerNahtLiegtUndEinenNamenHat() {
        let auszug = MoneyMoneyAuszug(
            konten: [],
            kategorien: [MoneyMoneyKategorie(schluessel: 5, pfad: "HUND"),
                         MoneyMoneyKategorie(schluessel: 9, pfad: "")],
            umsaetze: [umsatz(epoche: 1_794_398_400, kategorie: 5),    // 2026-11-11
                       umsatz(epoche: 1_755_475_200, kategorie: 5),    // 2025-08-18
                       umsatz(epoche: 1_794_398_400, kategorie: 9),    // namenlos
                       umsatz(epoche: 1_794_398_400, kategorie: nil)])
        let zeilen = MoneyMoneyZuordnung.kategoriezeilen(auszug, fuerKonto: 1,
                                                         abNaht: "2026-09-14")
        XCTAssertEqual(zeilen.map(\.kategorie), ["HUND"])
        XCTAssertEqual(zeilen.map(\.tag), ["2026-11-11"])
        XCTAssertEqual(zeilen.map(\.betrag), ["-20.00"])
    }

    private func umsatz(epoche: Int64, kategorie: Int64?) -> MoneyMoneyUmsatz {
        MoneyMoneyUmsatz(kontoSchluessel: 1, betrag: -20.0, waehrung: "EUR",
                         gebuchtAm: epoche, gegenseiteName: "PayPal",
                         zweck: "Einkauf", kategorieSchluessel: kategorie)
    }
}
