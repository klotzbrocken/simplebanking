import XCTest
import MoneyMoneyForm
@testable import simplebanking

/// Welche Konten der Assistent anbietet — und was er mit den anderen sagt.
final class MoneyMoneyAuswahlTests: XCTestCase {

    private func auszug() -> MoneyMoneyAuszug {
        MoneyMoneyAuszug(konten: [
            MoneyMoneyKonto(schluessel: 1, iban: "DE83460500010001808336", name: "Giro"),
            MoneyMoneyKonto(schluessel: 2, iban: "DE25100500000630017999", name: "Zweitkonto"),
            MoneyMoneyKonto(schluessel: 3, iban: "", name: "Versicherung", istDepot: true),
            MoneyMoneyKonto(schluessel: 4, iban: "1808336", name: "Kreditkarte"),
            MoneyMoneyKonto(schluessel: 5, iban: "NO1393572455724", name: "Ausland"),
            MoneyMoneyKonto(schluessel: 6, iban: "SE8797800000097817083608", name: "Ungeprüft"),
        ])
    }

    private var erreichbar: [String: (verbindungsId: String, bankname: String)?] {
        [
            "DE83460500010001808336": ("connection-sparkasse", "Sparkasse Siegen"),
            "DE25100500000630017999": ("connection-berlin", "Berliner Sparkasse"),
            "NO1393572455724": nil,            // YAXI kennt die Bank nicht
            // SE… fehlt absichtlich: nicht geprüft (kein Netz)
        ]
    }

    func testJedesKontoBekommtEinUrteil() {
        let (treffer, absagen) = MoneyMoneyAuswahl.aufteilen(auszug(), erreichbar: erreichbar)
        XCTAssertEqual(treffer.count + absagen.count, auszug().konten.count,
                       "Kein Konto darf unter den Tisch fallen")
    }

    func testTrefferTragenVerbindungUndBankname() {
        let (treffer, _) = MoneyMoneyAuswahl.aufteilen(auszug(), erreichbar: erreichbar)
        XCTAssertEqual(treffer.map(\.konto.schluessel), [1, 2])
        XCTAssertEqual(treffer.first?.verbindungsId, "connection-sparkasse")
        XCTAssertEqual(treffer.first?.bankname, "Sparkasse Siegen")
    }

    func testJedeAbsageNenntIhrenGrund() {
        let (_, absagen) = MoneyMoneyAuswahl.aufteilen(auszug(), erreichbar: erreichbar)
        let gruende = Dictionary(uniqueKeysWithValues: absagen.map { ($0.konto.schluessel, $0.grund) })
        XCTAssertEqual(gruende[3], .depot)
        XCTAssertEqual(gruende[4], .keineIban, "Eine nackte Kontonummer ist keine IBAN")
        XCTAssertEqual(gruende[5], .nichtErreichbar)
        XCTAssertEqual(gruende[6], .nichtGeprueft)
        for absage in absagen {
            XCTAssertFalse(absage.satz.isEmpty, "Ohne Begründung sucht der Nutzer den Fehler bei sich")
        }
    }

    /// Der Unterschied, der ohne Netz über den ganzen Import entscheidet.
    func testNichtGeprueftIstNichtDasselbeWieNichtErreichbar() {
        // Keine einzige Abfrage ging durch — dann darf niemandem gesagt werden,
        // seine Banken seien unerreichbar.
        let (treffer, absagen) = MoneyMoneyAuswahl.aufteilen(auszug(), erreichbar: [:])
        XCTAssertTrue(treffer.isEmpty)
        let geprueft = absagen.filter { $0.grund == .nichtErreichbar }
        XCTAssertTrue(geprueft.isEmpty)
        XCTAssertEqual(absagen.filter { $0.grund == .nichtGeprueft }.count, 4)
    }

    func testEineBankEinmal() {
        // Drei Konten bei derselben Bank sind eine Verbindung und eine Anmeldung.
        let treffer = [
            MoneyMoneyTreffer(konto: MoneyMoneyKonto(schluessel: 1, iban: "DE1"),
                              verbindungsId: "a", bankname: "Bank A"),
            MoneyMoneyTreffer(konto: MoneyMoneyKonto(schluessel: 2, iban: "DE2"),
                              verbindungsId: "b", bankname: "Bank B"),
            MoneyMoneyTreffer(konto: MoneyMoneyKonto(schluessel: 3, iban: "DE3"),
                              verbindungsId: "a", bankname: "Bank A"),
        ]
        let gebuendelt = MoneyMoneyAuswahl.nachBank(treffer)
        XCTAssertEqual(gebuendelt.map(\.verbindungsId), ["a", "b"],
                       "Reihenfolge des Auszugs, damit zwei Läufe gleich beginnen")
        XCTAssertEqual(gebuendelt.first?.konten.map(\.schluessel), [1, 3])
    }

    func testBankleitzahlBuendeltDieAbfragen() {
        // Eine Abfrage je Bankleitzahl, nicht je Konto.
        XCTAssertEqual(MoneyMoneyEinrichtung.bankleitzahl("DE83460500010001808336"),
                       MoneyMoneyEinrichtung.bankleitzahl("DE63460500010048640684"))
        XCTAssertNotEqual(MoneyMoneyEinrichtung.bankleitzahl("DE83460500010001808336"),
                          MoneyMoneyEinrichtung.bankleitzahl("DE25100500000630017999"))
        XCTAssertEqual(MoneyMoneyEinrichtung.bankleitzahl("de83 4605 0001 0001 808336"),
                       MoneyMoneyEinrichtung.bankleitzahl("DE83460500010001808336"))
    }
}

/// Die Warteschlange über Assistentenläufe hinweg.
final class MoneyMoneyVorhabenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MoneyMoneyVorhaben.wegwerfen()
    }

    private func vorhaben() {
        MoneyMoneyVorhaben.anlegen([
            MoneyMoneyVorhabenEintrag(iban: "DE1", verbindungsId: "a", bankname: "Bank A", kontoSchluessel: 1),
            MoneyMoneyVorhabenEintrag(iban: "DE2", verbindungsId: "a", bankname: "Bank A", kontoSchluessel: 2),
            MoneyMoneyVorhabenEintrag(iban: "DE3", verbindungsId: "b", bankname: "Bank B", kontoSchluessel: 3),
        ])
    }

    func testDieNaechsteBankBringtIhreKontenMit() {
        vorhaben()
        let naechste = MoneyMoneyVorhaben.naechsteBank
        XCTAssertEqual(naechste?.verbindungsId, "a")
        XCTAssertEqual(naechste?.ibans, ["DE1", "DE2"])
    }

    func testAbgehakteKommenNichtZurueck() {
        vorhaben()
        MoneyMoneyVorhaben.abhaken(ibans: ["DE1", "DE2"])
        XCTAssertEqual(MoneyMoneyVorhaben.offene.map(\.iban), ["DE3"])
        XCTAssertEqual(MoneyMoneyVorhaben.naechsteBank?.verbindungsId, "b")
    }

    func testIBANVergleichIgnoriertLeerzeichenUndSchreibweise() {
        // Banken und MoneyMoney schreiben IBANs unterschiedlich. Ein Vergleich, der
        // daran scheitert, lässt den Eintrag offen — und der Assistent fragt ewig weiter.
        MoneyMoneyVorhaben.anlegen([
            MoneyMoneyVorhabenEintrag(iban: "DE83 4605 0001 0001 8083 36", verbindungsId: "a",
                                      bankname: "Bank A", kontoSchluessel: 1),
        ])
        MoneyMoneyVorhaben.abhaken(ibans: ["de83460500010001808336"])
        XCTAssertTrue(MoneyMoneyVorhaben.offene.isEmpty)
    }

    func testEineBankOhneGewaehltesKontoBlockiertNicht() {
        // Sonst bliebe sie als nächste stehen und der Assistent liefe im Kreis.
        vorhaben()
        MoneyMoneyVorhaben.abhaken(ibans: [])
        MoneyMoneyVorhaben.bankAbhaken(verbindungsId: "a")
        XCTAssertEqual(MoneyMoneyVorhaben.naechsteBank?.verbindungsId, "b")
    }

    func testOhneVorhabenGibtEsKeineNaechsteBank() {
        XCTAssertNil(MoneyMoneyVorhaben.naechsteBank)
        XCTAssertTrue(MoneyMoneyVorhaben.offene.isEmpty)
    }

    func testDasVorhabenTraegtKeinKennwort() throws {
        // Das Kennwort gilt für eine Datenbank, in der die Bank-PIN des Nutzers
        // liegt. Gespeichert wäre es ein zweiter Schlüssel zu fremdem Geld.
        let eintrag = MoneyMoneyVorhabenEintrag(iban: "DE1", verbindungsId: "a",
                                                bankname: "Bank A", kontoSchluessel: 1)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(eintrag), encoding: .utf8))
        for verboten in ["kennwort", "password", "passwort", "pin", "secret"] {
            XCTAssertFalse(json.lowercased().contains(verboten), "\(verboten) im Vorhaben")
        }
    }

    func testDerAssistentSpeichertDasKennwortNicht() throws {
        let quelle = Quelltext.ohneKommentare(try Quelltext.datei("SetupFlowPanel.swift"))
        // Weder in UserDefaults noch in den Keychain noch ins Vorhaben.
        XCTAssertFalse(quelle.contains("set(mmKennwortField"))
        XCTAssertFalse(quelle.contains("mmKennwort = "))
        // Und nach dem Lesen wird das Feld geleert.
        XCTAssertTrue(quelle.contains("mmKennwortField.stringValue = \"\""))
    }
}

/// Woher die IBANs kommen, deren Verlauf nachgetragen wird.
///
/// Am 11.11.2026 war die Bank verbunden, 233 Buchungen kamen vom Abruf — und die
/// 1.800 aus MoneyMoney nicht. Der Grund: Die Kontoauswahl des Assistenten erscheint
/// nur, wenn die Bank mehrere Konten nennt. Bei einem Konto blieb die Menge leer und
/// der Nachtrag stieg aus, ohne Fehler und ohne Protokollzeile.
final class MoneyMoneyZuUebernehmenTests: XCTestCase {

    private func eintrag(_ iban: String, _ verbindung: String) -> MoneyMoneyVorhabenEintrag {
        MoneyMoneyVorhabenEintrag(iban: iban, verbindungsId: verbindung,
                                  bankname: "Testbank", kontoSchluessel: 1)
    }

    func testDieKontoauswahlGiltWennSieEtwasEnthaelt() {
        let gewaehlt: Set<String> = ["DE11"]
        let ergebnis = MoneyMoneyVorhaben.zuUebernehmen(
            gewaehlt: gewaehlt, bankKennung: "v1",
            offene: [eintrag("DE11", "v1"), eintrag("DE22", "v1")])
        XCTAssertEqual(ergebnis, ["DE11"],
                       "Was der Nutzer abgewählt hat, bleibt abgewählt")
    }

    func testOhneKontoauswahlZaehltDasVorhabenDieserBank() {
        let ergebnis = MoneyMoneyVorhaben.zuUebernehmen(
            gewaehlt: [], bankKennung: "v1",
            offene: [eintrag("DE11", "v1"), eintrag("DE22", "v2")])
        XCTAssertEqual(ergebnis, ["DE11"],
                       "Nur die Konten der gerade verbundenen Bank")
    }

    func testOhneKennungZaehlenAlleOffenen() {
        let ergebnis = MoneyMoneyVorhaben.zuUebernehmen(
            gewaehlt: [], bankKennung: nil,
            offene: [eintrag("DE11", "v1"), eintrag("DE22", "v2")])
        XCTAssertEqual(ergebnis, ["DE11", "DE22"])
    }

    func testOhneAllesBleibtEsLeer() {
        XCTAssertTrue(MoneyMoneyVorhaben.zuUebernehmen(
            gewaehlt: [], bankKennung: "v1", offene: []).isEmpty)
    }
}

/// Was das Vorhaben nach dem Nachtrag noch festhält.
///
/// Abgehakt heißt „die Bank steht", nicht „der Verlauf ist drin". Zwischen beidem
/// liegt das Schließen des Assistenten — und dort wurde die Ablage bis zum
/// 11.11.2026 weggeworfen, bevor irgendjemand sie gelesen hatte. Seitdem räumt der
/// Nachtrag seine Einträge selbst weg, und erst dann geht die Ablage.
final class MoneyMoneyVorhabenAufraeumenTests: XCTestCase {

    override func tearDown() {
        MoneyMoneyVorhaben.wegwerfen()
        super.tearDown()
    }

    private func eintrag(_ iban: String) -> MoneyMoneyVorhabenEintrag {
        MoneyMoneyVorhabenEintrag(iban: iban, verbindungsId: "v1",
                                  bankname: "Testbank", kontoSchluessel: 7)
    }

    func testEntfernenNimmtGenauEinenEintrag() {
        MoneyMoneyVorhaben.anlegen([eintrag("DE11 2222"), eintrag("DE33")])
        MoneyMoneyVorhaben.entfernen(iban: "de112222")
        XCTAssertEqual(MoneyMoneyVorhaben.eintraege.map(\.iban), ["DE33"],
                       "Der Vergleich läuft ohne Leerzeichen und Schreibweise")
    }

    func testAbhakenLaesstDenEintragStehen() {
        MoneyMoneyVorhaben.anlegen([eintrag("DE11")])
        MoneyMoneyVorhaben.abhaken(ibans: ["DE11"])
        XCTAssertTrue(MoneyMoneyVorhaben.offene.isEmpty, "Die Bank steht")
        XCTAssertEqual(MoneyMoneyVorhaben.eintraege.count, 1,
                       "Der Verlauf ist aber noch nicht nachgetragen — der Eintrag "
                       + "muss bleiben, sonst findet ihn der Nachtrag nicht mehr")
    }

    func testDerAssistentTraegtDenVerlaufNichtSelbstNach() throws {
        let quelle = Quelltext.ohneKommentare(try Quelltext.datei("SetupFlowPanel.swift"))
        XCTAssertFalse(quelle.contains("MoneyMoneyUebernahme.nachtragen"),
                       "Im Assistenten gibt es den Slot noch nicht — der Nachtrag "
                       + "gehört hinter runModal, siehe MoneyMoneyNachtrag")
    }

    /// Der Nachtrag wartet auf die Naht.
    ///
    /// Die Naht ist die älteste Buchung des Slots. Ohne sie käme der ganze
    /// MoneyMoney-Zeitraum herein, auch die Wochen, die die Bank selbst liefert —
    /// und von 233 Bankbuchungen fiel am 11.11.2026 **keine einzige** mit einer
    /// MoneyMoney-Zeile zusammen, weil beide denselben Zweck verschieden schreiben.
    ///
    /// Bankumsätze schreibt genau eine Stelle: `openTransactionsPanel`. Dort muss
    /// der Nachtrag hängen, und er muss einen Slot ohne Buchungen überspringen,
    /// statt alles zu nehmen.
    func testDerNachtragHaengtAmSchreibenDerBankumsaetze() throws {
        let bar = Quelltext.ohneKommentare(try Quelltext.datei("BalanceBar.swift"))
        guard let schreiben = bar.range(of: "TransactionsDatabase.upsert(transactions: sortedNetwork)"),
              let nachtrag = bar.range(of: "MoneyMoneyNachtrag.alleFaelligen()", range: schreiben.upperBound..<bar.endIndex)
        else { return XCTFail("Der Nachtrag steht nicht hinter dem Schreiben der Bankumsätze") }
        XCTAssertLessThan(schreiben.upperBound, nachtrag.lowerBound)

        let nachtragQuelle = Quelltext.ohneKommentare(try Quelltext.datei("MoneyMoneyUebernahme.swift"))
        XCTAssertTrue(nachtragQuelle.contains("aeltesteBuchung(slotId: slot.id)"),
                      "Ohne Buchungen im Slot gibt es keine Naht — dann wird gewartet, "
                      + "nicht alles genommen")
    }
}

/// Ansehen ist keine Entscheidung.
///
/// `onAppear` setzt `selectedCategory` vom Vorgabewert `.sonstiges` auf die
/// wirkliche Kategorie; `onChange` feuert danach und die Sperre
/// `categorySelectionReady` steht dann längst auf `true`. Das bloße Öffnen einer
/// Buchung schrieb deshalb einen Kategorie-Override — und die Umsatzliste zeichnete
/// darauf komplett neu, womit sich das Detailfenster sofort wieder schloss.
/// Gemeldet am 11.11.2026.
final class KategorieBeimOeffnenTests: XCTestCase {

    func testDasOeffnenSchreibtKeineKategorie() throws {
        let quelle = Quelltext.ohneKommentare(try Quelltext.datei("TransactionDetailView.swift"))
        let anwenden = Quelltext.abschnitt(quelle,
                                           von: "private func applyCategorySelection(",
                                           bis: "autoCategory")
        XCTAssertTrue(anwenden.contains("guard newCategory != TransactionCategorizer.category(for: transaction)"),
                      "Ohne diese Sperre schreibt jedes Öffnen einer Buchung einen "
                      + "Override und zeichnet die Liste neu")
    }
}

/// Der Umsteigerrabatt im letzten Schritt der Einrichtung hängt an einer Marke, die
/// das Vorhaben überdauert — das räumt sich weg, sobald der Verlauf drin ist.
final class MoneyMoneyUmstiegsmarkeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MoneyMoneyVorhaben.defaults.removeObject(forKey: MoneyMoneyVorhaben.umstiegSchluessel)
        MoneyMoneyVorhaben.wegwerfen()
    }

    override func tearDown() {
        MoneyMoneyVorhaben.defaults.removeObject(forKey: MoneyMoneyVorhaben.umstiegSchluessel)
        MoneyMoneyVorhaben.wegwerfen()
        super.tearDown()
    }

    func testOhneUebernahmeKeinRabatt() {
        XCTAssertFalse(MoneyMoneyVorhaben.umstiegErfolgt)
    }

    func testEinLeeresVorhabenIstKeineUebernahme() {
        MoneyMoneyVorhaben.anlegen([])
        XCTAssertFalse(MoneyMoneyVorhaben.umstiegErfolgt,
                       "Wer alle Konten abwählt, ist kein Umsteiger")
    }

    func testDieMarkeUeberdauertDasWeggeraeumteVorhaben() {
        MoneyMoneyVorhaben.anlegen([
            MoneyMoneyVorhabenEintrag(iban: "DE1", verbindungsId: "a",
                                      bankname: "Bank A", kontoSchluessel: 1)
        ])
        XCTAssertTrue(MoneyMoneyVorhaben.umstiegErfolgt)
        MoneyMoneyVorhaben.wegwerfen()
        XCTAssertTrue(MoneyMoneyVorhaben.umstiegErfolgt,
                      "Der Rabatt wird auch nach dem Nachtrag noch gezeigt")
    }
}

/// Der Rabattcode greift auch ohne Abtippen — er hängt als `discount_code` an der
/// Checkout-URL.
final class RabattURLTests: XCTestCase {

    func testOhneCodeBleibtDieURLUnberuehrt() {
        XCTAssertEqual(LicenseConfig.purchaseURL(mitRabattcode: nil), LicenseConfig.purchaseURL)
        XCTAssertEqual(LicenseConfig.purchaseURL(mitRabattcode: ""), LicenseConfig.purchaseURL)
    }

    func testMitCodeHaengtErAlsAbfrageAn() {
        let url = LicenseConfig.purchaseURL(mitRabattcode: LicenseConfig.umstiegDiscountCode)
        let teile = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(teile?.queryItems?.first(where: { $0.name == "discount_code" })?.value,
                       LicenseConfig.umstiegDiscountCode)
        XCTAssertEqual(teile?.path, URLComponents(url: LicenseConfig.purchaseURL,
                                                  resolvingAgainstBaseURL: false)?.path,
                       "Nur die Abfrage kommt dazu, der Rest bleibt")
    }
}
