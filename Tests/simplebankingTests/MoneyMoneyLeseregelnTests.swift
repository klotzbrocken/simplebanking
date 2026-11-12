import XCTest
import MoneyMoneyForm
@testable import simplebanking

/// Die Regeln des MoneyMoney-Lesepfads, mit eingespeisten Werten.
final class MoneyMoneyLeseregelnTests: XCTestCase {

    // MARK: - Datum

    func testEpocheWirdInUTCZumTag() {
        // Gemessen an einer echten MoneyMoney-2.5.3-Datenbank: `transactions.timestamp`
        // der PayPal-Lastschrift vom 11.11.2026.
        XCTAssertEqual(MoneyMoneyLeseregeln.tag(ausEpoche: 1_794_398_400), "2026-11-11")
        XCTAssertEqual(MoneyMoneyLeseregeln.tag(ausEpoche: 0), "1970-01-01")
        XCTAssertEqual(MoneyMoneyLeseregeln.tag(ausEpoche: 86_399), "1970-01-01")
        XCTAssertEqual(MoneyMoneyLeseregeln.tag(ausEpoche: 951_782_400), "2000-02-29")
        XCTAssertEqual(MoneyMoneyLeseregeln.tag(ausEpoche: 1_583_020_800), "2020-03-01")
    }

    func testEpocheVorNeunzehnhundertsiebzigRundetAb() {
        // Ganzzahldivision schneidet gegen null ab; ohne die Korrektur läge der
        // 31.12.1969 einen Tag zu spät.
        XCTAssertEqual(MoneyMoneyLeseregeln.tag(ausEpoche: -1), "1969-12-31")
        XCTAssertEqual(MoneyMoneyLeseregeln.tag(ausEpoche: -86_400), "1969-12-31")
        XCTAssertEqual(MoneyMoneyLeseregeln.tag(ausEpoche: -86_401), "1969-12-30")
    }

    /// Der eigentliche Grund für die UTC-Regel, ausführbar festgehalten.
    ///
    /// MoneyMoney legt den Zeitstempel auf 12:00 UTC. In Ortszeit formatiert stimmt
    /// das in Europa zufällig — und bricht östlich von UTC+12. Das Datum geht in den
    /// Fingerprint ein, es wäre also kein Anzeigefehler, sondern ein falscher
    /// Schlüssel für jede importierte Buchung.
    func testOrtszeitWuerdeOestlichVonUTCZwoelfDenFolgetagLiefern() {
        let formatierer = DateFormatter()
        formatierer.dateFormat = "yyyy-MM-dd"
        formatierer.locale = Locale(identifier: "en_US_POSIX")
        guard let auckland = TimeZone(identifier: "Pacific/Auckland") else {
            return XCTFail("Zeitzone Pacific/Auckland fehlt im System")
        }
        formatierer.timeZone = auckland
        let ortszeit = formatierer.string(from: Date(timeIntervalSince1970: 1_794_398_400))
        XCTAssertEqual(ortszeit, "2026-11-12", "Annahme des Tests: Auckland ist UTC+13")
        XCTAssertNotEqual(MoneyMoneyLeseregeln.tag(ausEpoche: 1_794_398_400), ortszeit)
    }

    // MARK: - Betrag

    func testBetragKommtMitZweiStellen() {
        // `description` wäre "-20.0" und damit ein anderer Fingerprint.
        XCTAssertEqual(MoneyMoneyLeseregeln.betrag(-20.0), "-20.00")
        XCTAssertEqual(MoneyMoneyLeseregeln.betrag(0), "0.00")
        XCTAssertEqual(MoneyMoneyLeseregeln.betrag(1234.5), "1234.50")
        XCTAssertEqual(MoneyMoneyLeseregeln.betrag(1234.567), "1234.57")
    }

    func testBetragIgnoriertDieSystemsprache() {
        // Mit deutschem Gebietsschema wäre das Komma die Trennung — und jeder
        // Fingerprint anders, je nach Rechner des Nutzers.
        XCTAssertFalse(MoneyMoneyLeseregeln.betrag(1234.5).contains(","))
    }

    // MARK: - Was übernommen wird

    func testNurGebuchteUngeteilteUmsaetze() {
        func umsatz(gebucht: Bool, geteilt: Bool) -> MoneyMoneyUmsatz {
            MoneyMoneyUmsatz(kontoSchluessel: 1, betrag: -1, gebuchtAm: 0,
                             istGebucht: gebucht, istGeteilt: geteilt)
        }
        XCTAssertTrue(MoneyMoneyLeseregeln.istUebernehmbar(umsatz(gebucht: true, geteilt: false)))
        XCTAssertFalse(MoneyMoneyLeseregeln.istUebernehmbar(umsatz(gebucht: false, geteilt: false)))
        XCTAssertFalse(MoneyMoneyLeseregeln.istUebernehmbar(umsatz(gebucht: true, geteilt: true)))
    }

    func testNurKontenMitIBANUndOhneDepot() {
        func konto(iban: String, depot: Bool) -> MoneyMoneyKonto {
            MoneyMoneyKonto(schluessel: 1, iban: iban, istDepot: depot)
        }
        XCTAssertTrue(MoneyMoneyLeseregeln.istUebernehmbar(konto(iban: "DE02120300000000202051", depot: false)))
        XCTAssertFalse(MoneyMoneyLeseregeln.istUebernehmbar(konto(iban: "", depot: false)))
        XCTAssertFalse(MoneyMoneyLeseregeln.istUebernehmbar(konto(iban: "   ", depot: false)))
        // Gemessen: Versicherungsverträge tragen `portfolio = 1` und keine IBAN.
        XCTAssertFalse(MoneyMoneyLeseregeln.istUebernehmbar(konto(iban: "DE02120300000000202051", depot: true)))
        // Gemessen: ein Konto trägt `"1808336"` — eine nackte Kontonummer. „Nicht
        // leer" hätte sie durchgelassen.
        XCTAssertFalse(MoneyMoneyLeseregeln.istUebernehmbar(konto(iban: "1808336", depot: false)))
    }

    func testIbanErkennungPrueftDieForm() {
        XCTAssertTrue(MoneyMoneyLeseregeln.istIban("DE83460500010001808336"))
        XCTAssertTrue(MoneyMoneyLeseregeln.istIban("de83 4605 0001 0001 8083 36"))
        XCTAssertTrue(MoneyMoneyLeseregeln.istIban("NO1393572455724"))      // 15 Zeichen
        XCTAssertTrue(MoneyMoneyLeseregeln.istIban("LU89751000135104200E"))  // Buchstabe am Ende
        XCTAssertFalse(MoneyMoneyLeseregeln.istIban("1808336"))              // nackte Kontonummer
        XCTAssertFalse(MoneyMoneyLeseregeln.istIban(""))
        XCTAssertFalse(MoneyMoneyLeseregeln.istIban("DEDE460500010001808336"))  // keine Prüfzahl
        XCTAssertFalse(MoneyMoneyLeseregeln.istIban("DE8346050001000180833!"))  // Sonderzeichen
        XCTAssertFalse(MoneyMoneyLeseregeln.istIban("NO139357245"))             // zu kurz
    }

    // MARK: - Kategorien

    func testErstEbeneNimmtDasErstePfadglied() {
        XCTAssertEqual(MoneyMoneyLeseregeln.erstEbene("Mobilität\\Bahn"), "Mobilität")
        XCTAssertEqual(MoneyMoneyLeseregeln.erstEbene("Mobilität"), "Mobilität")
        XCTAssertEqual(MoneyMoneyLeseregeln.erstEbene("  Essen  \\Kantine"), "Essen")
    }

    func testStandardkategorieFaelltWeg() {
        // Gemessen: `categories.rowid = 1` hat `name = ''`. „Unkategorisiert" setzt
        // MoneyMoney erst zur Laufzeit — importiert wäre es eine Kategorie, die
        // nichts aussagt.
        XCTAssertNil(MoneyMoneyLeseregeln.erstEbene(""))
        XCTAssertNil(MoneyMoneyLeseregeln.erstEbene("   "))
    }

    func testPfadLaeuftDenBaumHoch() {
        let gruppen: [Int64: MoneyMoneyGruppe] = [
            7: MoneyMoneyGruppe(name: "Bahn", elternSchluessel: 3),
            3: MoneyMoneyGruppe(name: "Mobilität", elternSchluessel: 0),
        ]
        XCTAssertEqual(
            MoneyMoneyLeseregeln.pfad(name: "Fernverkehr", elternSchluessel: 7, gruppen: gruppen),
            "Mobilität\\Bahn\\Fernverkehr")
        XCTAssertEqual(MoneyMoneyLeseregeln.erstEbene(
            MoneyMoneyLeseregeln.pfad(name: "Fernverkehr", elternSchluessel: 7, gruppen: gruppen)),
            "Mobilität")
    }

    func testPfadOhneElternIstDerNameSelbst() {
        XCTAssertEqual(MoneyMoneyLeseregeln.pfad(name: "Essen", elternSchluessel: 0, gruppen: [:]), "Essen")
        // Unbekannter Elternschlüssel bricht ab, statt zu erfinden.
        XCTAssertEqual(MoneyMoneyLeseregeln.pfad(name: "Essen", elternSchluessel: 99, gruppen: [:]), "Essen")
    }

    func testNamenloseGliederFallenAusDemPfad() {
        // Sonst stünde am Ende ein Pfad aus Backslashes, und `erstEbene` gäbe einen
        // leeren Namen als gültige Kategorie heraus.
        let gruppen: [Int64: MoneyMoneyGruppe] = [1: MoneyMoneyGruppe(name: "", elternSchluessel: 0)]
        XCTAssertEqual(MoneyMoneyLeseregeln.pfad(name: "", elternSchluessel: 1, gruppen: gruppen), "")
        XCTAssertNil(MoneyMoneyLeseregeln.erstEbene(
            MoneyMoneyLeseregeln.pfad(name: "", elternSchluessel: 1, gruppen: gruppen)))
    }

    func testRingschlussHaengtNicht() {
        // Ob MoneyMoney Ringschlüsse ausschließt, wissen wir nicht. Ohne Schranke
        // wäre das eine Endlosschleife, die der Nutzer als hängenden Import sieht.
        let gruppen: [Int64: MoneyMoneyGruppe] = [
            1: MoneyMoneyGruppe(name: "A", elternSchluessel: 2),
            2: MoneyMoneyGruppe(name: "B", elternSchluessel: 1),
        ]
        let pfad = MoneyMoneyLeseregeln.pfad(name: "X", elternSchluessel: 1,
                                             gruppen: gruppen, hoechsteTiefe: 4)
        XCTAssertEqual(pfad.split(separator: "\\").count, 5)
    }

    // MARK: - Schemazusage

    func testSchemazusageNenntWederPinsNochBanks() {
        // In `pins` liegt die Bank-PIN, in `banks` der HBCI-Privatschlüssel. Sie
        // stehen nicht in der Zusage, also öffnet der Helfer sie nicht.
        let tabellen = Set(MoneyMoneyLeseregeln.benoetigteSpalten.keys)
        XCTAssertFalse(tabellen.contains("pins"))
        XCTAssertFalse(tabellen.contains("banks"))
        XCTAssertEqual(tabellen, ["accounts", "categories", "category_groups", "transactions"])
    }

    func testSchemazusageNenntDieGelesenenSpalten() {
        // Gegenprobe zum SQL im Helfer: Fällt dort eine Spalte dazu, ohne hier
        // genannt zu werden, prüft der Helfer sie beim Öffnen nicht — und liest ins
        // Leere, wenn MoneyMoney sie umbenennt.
        let umsatz = MoneyMoneyLeseregeln.benoetigteSpalten["transactions"] ?? []
        for spalte in ["local_account_key", "amount", "timestamp", "value_timestamp",
                       "unformatted_purpose", "unformatted_type", "eref", "booked", "splitted"] {
            XCTAssertTrue(umsatz.contains(spalte), "\(spalte) fehlt in der Schemazusage")
        }
        // `a1794240104` ist ein Migrationsgrabstein (Epoch 2026-11-09 17:01:44) und
        // darf nie zur Zusage werden.
        XCTAssertFalse(umsatz.contains("a1794240104"))
        XCTAssertFalse(umsatz.contains("purpose"))
    }
}
