import XCTest
import MoneyMoneyForm
@testable import simplebanking

/// Der Umstieg bei einem **schon eingerichteten** simplebanking (2.2.1).
///
/// Bis 2.2.0 gab es den MoneyMoney-Import nur in der Ersteinrichtung. Hier wird
/// zugeordnet, was es wirklich entscheidet: die vorhandenen Slots. Kein YAXI, kein
/// Netz — und damit auch kein „nicht geprüft", das es im Assistenten nur gibt, weil
/// dort eine Abfrage scheitern kann.
final class MoneyMoneyBestandTests: XCTestCase {

    private func auszug() -> MoneyMoneyAuszug {
        MoneyMoneyAuszug(konten: [
            MoneyMoneyKonto(schluessel: 1, iban: "DE83460500010001808336", name: "Giro"),
            MoneyMoneyKonto(schluessel: 2, iban: "DE25100500000630017999", name: "Zweitkonto"),
            MoneyMoneyKonto(schluessel: 3, iban: "", name: "Versicherung", istDepot: true),
            MoneyMoneyKonto(schluessel: 4, iban: "1808336", name: "Kreditkarte"),
            MoneyMoneyKonto(schluessel: 5, iban: "NO1393572455724", name: "Nie verbunden"),
        ])
    }

    private func slot(_ iban: String,
                      id: String = UUID().uuidString,
                      name: String = "Sparkasse Siegen",
                      kurzname: String? = nil,
                      quelle: SlotSource? = nil) -> BankSlot {
        BankSlot(id: id, iban: iban, displayName: name, logoId: nil,
                 nickname: kurzname, source: quelle)
    }

    // MARK: - Der Normalfall

    func testKontoMitSlotWirdAngeboten() {
        let slots = [slot("DE83460500010001808336", id: "slot-giro")]
        let (treffer, _) = MoneyMoneyBestand.aufteilen(auszug(), slots: slots)
        XCTAssertEqual(treffer.map(\.konto.schluessel), [1])
        XCTAssertEqual(treffer.first?.slotId, "slot-giro")
    }

    func testJedesKontoBekommtEinUrteil() {
        let slots = [slot("DE83460500010001808336")]
        let (treffer, absagen) = MoneyMoneyBestand.aufteilen(auszug(), slots: slots)
        XCTAssertEqual(treffer.count + absagen.count, auszug().konten.count,
                       "Kein Konto darf unter den Tisch fallen")
    }

    func testJedeAbsageNenntIhrenGrund() {
        let slots = [slot("DE83460500010001808336")]
        let (_, absagen) = MoneyMoneyBestand.aufteilen(auszug(), slots: slots)
        let gruende = Dictionary(uniqueKeysWithValues: absagen.map { ($0.konto.schluessel, $0.grund) })
        XCTAssertEqual(gruende[3], .depot)
        XCTAssertEqual(gruende[4], .keineIban, "Eine nackte Kontonummer ist keine IBAN")
        XCTAssertEqual(gruende[2], .nichtVerbunden)
        XCTAssertEqual(gruende[5], .nichtVerbunden)
    }

    func testNichtGeprueftKommtHierNieVor() {
        // Der Bestandsweg fragt nichts ab, also kann auch nichts ungeprüft bleiben.
        // Stünde das hier, wäre es eine Ausrede für eine Antwort, die wir haben.
        let (_, absagen) = MoneyMoneyBestand.aufteilen(auszug(), slots: [])
        XCTAssertFalse(absagen.contains { $0.grund == .nichtGeprueft })
        XCTAssertFalse(absagen.contains { $0.grund == .nichtErreichbar })
    }

    // MARK: - Schreibweisen derselben IBAN

    func testIbanMitLeerzeichenUndKleinschreibungTrifftDenselbenSlot() {
        // MoneyMoney und die Bank schreiben die IBAN unterschiedlich; ein Vergleich,
        // der daran scheitert, sagt dem Nutzer „nicht verbunden" über ein Konto, das
        // er vor sich sieht.
        let auszug = MoneyMoneyAuszug(konten: [
            MoneyMoneyKonto(schluessel: 1, iban: "de83 4605 0001 0001 8083 36", name: "Giro")
        ])
        let slots = [slot("DE83460500010001808336", id: "slot-giro")]
        let (treffer, absagen) = MoneyMoneyBestand.aufteilen(auszug, slots: slots)
        XCTAssertEqual(treffer.first?.slotId, "slot-giro")
        XCTAssertTrue(absagen.isEmpty)
    }

    // MARK: - Slots, die nicht mitsuchen dürfen

    func testEBonSlotsZaehlenNicht() {
        // REWE-, dm- und Amazon-Slots tragen keine IBAN und keinen Bankverlauf. Ohne
        // diesen Ausschluss bekäme ein Konto mit leerer IBAN einen Treffer auf einen
        // leeren Slot-Eintrag.
        let auszug = MoneyMoneyAuszug(konten: [
            MoneyMoneyKonto(schluessel: 1, iban: "", name: "Bargeld")
        ])
        let slots = [slot("", id: "slot-rewe", name: "REWE", quelle: .rewe)]
        let (treffer, absagen) = MoneyMoneyBestand.aufteilen(auszug, slots: slots)
        XCTAssertTrue(treffer.isEmpty)
        XCTAssertEqual(absagen.first?.grund, .keineIban)
    }

    func testZweiSlotsMitDerselbenIbanLiefernNurEinenTreffer() {
        // Ein Fehlzustand, aber einer, der vorkommt (zweimal dieselbe Bank verbunden).
        // Zweimal in denselben Verlauf zu schreiben wäre schlimmer als einmal.
        let slots = [slot("DE83460500010001808336", id: "slot-a"),
                     slot("DE83460500010001808336", id: "slot-b")]
        let (treffer, _) = MoneyMoneyBestand.aufteilen(auszug(), slots: slots)
        XCTAssertEqual(treffer.count, 1)
        XCTAssertEqual(treffer.first?.slotId, "slot-a", "Der erste gewinnt, nicht der zufällige")
    }

    // MARK: - Der Name in der Auswahlliste

    func testKurznameGewinntVorBanknameUndIban() {
        // Der Nutzer erkennt sein Konto an dem Namen, den die App ihm zeigt.
        XCTAssertEqual(MoneyMoneyBestand.anzeigename(
            slot("DE83460500010001808336", name: "Sparkasse Siegen", kurzname: "Privat")), "Privat")
        XCTAssertEqual(MoneyMoneyBestand.anzeigename(
            slot("DE83460500010001808336", name: "Sparkasse Siegen")), "Sparkasse Siegen")
        XCTAssertEqual(MoneyMoneyBestand.anzeigename(
            slot("DE83460500010001808336", name: "", kurzname: "   ")), "DE83460500010001808336",
                       "Ein Name aus Leerzeichen ist keiner")
    }
}

/// `ergaenzen` statt `anlegen`: Der Weg über die Einstellungen darf ein offenes
/// Vorhaben aus der Ersteinrichtung nicht wegwerfen.
final class MoneyMoneyVorhabenErgaenzenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MoneyMoneyVorhaben.wegwerfen()
        // Auch die Umstiegsmarke: `wegwerfen` räumt nur das Vorhaben, die Marke ist
        // absichtlich dauerhaft. Ohne das hing `testErgaenzenSetztDieUmstiegsmarke`
        // davon ab, ob ein anderer Test sie vorher gesetzt hatte — in Isolation grün,
        // im vollen Lauf rot.
        MoneyMoneyVorhaben.defaults.removeObject(forKey: MoneyMoneyVorhaben.umstiegSchluessel)
    }

    private func eintrag(_ iban: String, erledigt: Bool = false) -> MoneyMoneyVorhabenEintrag {
        MoneyMoneyVorhabenEintrag(iban: iban, verbindungsId: "conn", bankname: "Bank",
                                  kontoSchluessel: 1, erledigt: erledigt)
    }

    func testVorhandeneEintraegeBleibenStehen() {
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        MoneyMoneyVorhaben.ergaenzen([eintrag("DE25100500000630017999")])
        XCTAssertEqual(Set(MoneyMoneyVorhaben.eintraege.map(\.iban)),
                       ["DE83460500010001808336", "DE25100500000630017999"])
    }

    func testOffeneIbanKommtNichtZweimalHerein() {
        // Zwei Einträge auf denselben Slot schrieben denselben Verlauf zweimal — die
        // zweite Runde liegt hinter einer verschobenen Naht, der Fingerabdruck fängt
        // das also nicht.
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        MoneyMoneyVorhaben.ergaenzen([eintrag("de83 4605 0001 0001 8083 36")])
        XCTAssertEqual(MoneyMoneyVorhaben.eintraege.count, 1)
    }

    func testErledigterEintragStehtEinerNeuenUebernahmeNichtImWeg() {
        // Abgehakt heißt „die Bank steht", nicht „der Verlauf ist drin".
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336", erledigt: true)])
        MoneyMoneyVorhaben.ergaenzen([eintrag("DE83460500010001808336")])
        XCTAssertEqual(MoneyMoneyVorhaben.eintraege.count, 2)
        XCTAssertEqual(MoneyMoneyVorhaben.offene.count, 1)
    }

    func testLeereListeAendertNichts() {
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        MoneyMoneyVorhaben.ergaenzen([])
        XCTAssertEqual(MoneyMoneyVorhaben.eintraege.count, 1)
    }

    func testErgaenzenSetztDieUmstiegsmarke() {
        XCTAssertFalse(MoneyMoneyVorhaben.umstiegErfolgt)
        MoneyMoneyVorhaben.ergaenzen([eintrag("DE83460500010001808336")])
        XCTAssertTrue(MoneyMoneyVorhaben.umstiegErfolgt)
    }

    // MARK: - Verfall (2.2.1)

    /// Der Auszug trägt den Umsatzverlauf **aller** Konten der MoneyMoney-Datei. Ein
    /// Eintrag, der nie fertig wird — Bank nie verbunden, Konto nie abgerufen —, ließ
    /// ihn vorher für immer neben der Datenbank liegen.
    func testFrischesVorhabenVerfaelltNicht() {
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        XCTAssertFalse(MoneyMoneyVorhaben.istVerfallen())
    }

    func testVorhabenVerfaelltNachDreissigTagen() {
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        let spaeter = Date().addingTimeInterval(MoneyMoneyVorhaben.hoechstalter + 60)
        XCTAssertTrue(MoneyMoneyVorhaben.istVerfallen(jetzt: spaeter))
    }

    func testEinWeitererEintragVerlaengertDieFristNicht() {
        // Sonst hält ein Umsteiger, der alle paar Wochen ein Konto nachträgt, den
        // Auszug unbegrenzt am Leben.
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        MoneyMoneyVorhaben.ergaenzen([eintrag("DE25100500000630017999")])
        let spaeter = Date().addingTimeInterval(MoneyMoneyVorhaben.hoechstalter + 60)
        XCTAssertTrue(MoneyMoneyVorhaben.istVerfallen(jetzt: spaeter))
    }

    func testEinNeuesVorhabenBekommtEineNeueFrist() {
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        MoneyMoneyVorhaben.anlegen([eintrag("DE25100500000630017999")])
        XCTAssertFalse(MoneyMoneyVorhaben.istVerfallen())
    }

    func testOhneEintraegeGibtEsNichtsZuVerfallen() {
        XCTAssertFalse(MoneyMoneyVorhaben.istVerfallen(
            jetzt: Date().addingTimeInterval(MoneyMoneyVorhaben.hoechstalter * 10)))
    }

    func testVorhabenOhneAnlegedatumVerfaelltNicht() {
        // Ein Vorhaben aus einer Fassung vor 2.2.1 trägt kein Datum. Unbekanntes Alter
        // ist kein Verfall — sonst wirft das erste Update einen gültigen Verlauf weg.
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        MoneyMoneyVorhaben.defaults.removeObject(forKey: "moneymoneyVorhabenAngelegtAm")
        XCTAssertFalse(MoneyMoneyVorhaben.istVerfallen(
            jetzt: Date().addingTimeInterval(MoneyMoneyVorhaben.hoechstalter * 10)))
    }

    func testWegwerfenNimmtAuchDasAnlegedatumMit() {
        MoneyMoneyVorhaben.anlegen([eintrag("DE83460500010001808336")])
        MoneyMoneyVorhaben.wegwerfen()
        MoneyMoneyVorhaben.anlegen([eintrag("DE25100500000630017999")])
        XCTAssertFalse(MoneyMoneyVorhaben.istVerfallen(),
                       "Ein stehengebliebenes Datum ließe das nächste Vorhaben sofort verfallen")
    }
}

/// Der Betrag im Überweisungsformular (2.2.1).
///
/// Dort stand ein zweiter Parser, der **jeden Punkt löschte**. Getippt stimmte das,
/// weil `sanitizeDecimal` bei jedem Tastendruck Punkte zu Kommas macht. `amountInput`
/// wird aber auch von außen gesetzt — GiroCode, gelesene Rechnung, Vorlage.
final class UeberweisungBetragTests: XCTestCase {

    /// Die Kette, die `TransferSheet.amountValue` jetzt benutzt.
    private func betrag(_ eingabe: String) -> Decimal {
        QuickSendFormatting.amountDecimal(
            QuickSendFormatting.sanitizeAmountInput(eingabe)) ?? 0
    }

    func testPunktAlsDezimaltrenner() {
        // Der Fall, der vorher 1050 ergeben hätte.
        XCTAssertEqual(betrag("10.50"), Decimal(string: "10.50"))
        XCTAssertEqual(betrag("1.5"), Decimal(string: "1.5"))
    }

    func testKommaAlsDezimaltrenner() {
        XCTAssertEqual(betrag("1234,56"), Decimal(string: "1234.56"))
    }

    func testPunktAlsTausendertrenner() {
        XCTAssertEqual(betrag("1.000"), 1000)
        XCTAssertEqual(betrag("1.234.567"), 1234567)
    }

    func testBeideTrennerDeutscheSchreibweise() {
        XCTAssertEqual(betrag("1.234,56"), Decimal(string: "1234.56"))
    }

    func testLeerUndUnsinnErgebenNull() {
        XCTAssertEqual(betrag(""), 0)
        XCTAssertEqual(betrag(","), 0)
        XCTAssertEqual(betrag("abc"), 0)
    }
}
