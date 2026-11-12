import XCTest
@testable import simplebanking

// MARK: - Eigene Kategorien
//
// `TransactionCategory` war bis 2.1.0 ein `enum` und ist jetzt eine Struktur. Diese
// Tests halten genau die Zusagen fest, die dabei zu brechen wären, ohne dass ein
// Compilerfehler es zeigt — die Speicherform voran.

final class KategorieSpeicherformTests: XCTestCase {

    /// **Die wichtigste Zusage der ganzen Umstellung.** Das `enum` kodierte eine nackte
    /// Zeichenkette. Eine synthetisierte `Codable`-Fassung der Struktur schriebe
    /// `{"rawValue":"…"}` — und damit wäre die Kategorie jeder gespeicherten
    /// Zuordnungsregel beim ersten Start still verloren.
    func testKategorieKodiertAlsNackteZeichenkette() throws {
        let daten = try JSONEncoder().encode(TransactionCategory.freizeit)
        XCTAssertEqual(String(data: daten, encoding: .utf8), "\"Freizeit\"")
    }

    func testAlteSpeicherformWirdGelesen() throws {
        let gelesen = try JSONDecoder().decode(TransactionCategory.self, from: Data("\"Freizeit\"".utf8))
        XCTAssertEqual(gelesen, .freizeit)
    }

    /// Eine Regel ist ein Objekt mit der Kategorie als Feld — der Fall, der in den
    /// UserDefaults wirklich liegt.
    func testKategorieInEinemObjektBleibtLesbar() throws {
        struct Regelrumpf: Codable { var setCategory: TransactionCategory? }
        let gelesen = try JSONDecoder().decode(Regelrumpf.self, from: Data(#"{"setCategory":"Gastronomie"}"#.utf8))
        XCTAssertEqual(gelesen.setCategory, .gastronomie)

        let geschrieben = try JSONEncoder().encode(Regelrumpf(setCategory: .gastronomie))
        XCTAssertEqual(String(data: geschrieben, encoding: .utf8), #"{"setCategory":"Gastronomie"}"#)
    }

    /// Eine eigene Kategorie wird genauso gespeichert — sie braucht keinen eigenen Typ.
    func testEigeneKategorieUeberlebtDieSpeicherform() throws {
        let hund = TransactionCategory(rawValue: "Hund")
        let daten = try JSONEncoder().encode(hund)
        XCTAssertEqual(try JSONDecoder().decode(TransactionCategory.self, from: daten), hund)
    }
}

final class KategorienamenTests: XCTestCase {

    func testLeerUndNurLeerzeichenSindKeinName() {
        XCTAssertNil(Kategorienamen.bereinigt(""))
        XCTAssertNil(Kategorienamen.bereinigt("   \n "))
    }

    /// „Haus Garten" und „Haus  Garten" wären zwei Kategorien, die niemand
    /// unterscheiden kann.
    func testMehrfacheLeerzeichenWerdenEingezogen() {
        XCTAssertEqual(Kategorienamen.bereinigt("  Haus   Garten "), "Haus Garten")
    }

    func testZuLangWirdAbgelehnt() {
        let lang = String(repeating: "a", count: Eigenkategorien.maximaleLaenge + 1)
        XCTAssertEqual(Kategorienamen.pruefe(lang, belegt: []), .zuLang)
    }

    /// Groß-/Kleinschreibung und Akzente machen keinen neuen Namen.
    func testBelegtIstUnabhaengigVonSchreibweise() {
        XCTAssertEqual(Kategorienamen.pruefe("shopping", belegt: ["Shopping"]), .belegt)
        XCTAssertEqual(Kategorienamen.pruefe("Cafe", belegt: ["Café"]), .belegt)
    }

    func testFreierNameGehtDurch() {
        XCTAssertNil(Kategorienamen.pruefe("Hund", belegt: ["Shopping", "Sparen"]))
    }
}

final class EigenkategorienTests: XCTestCase {

    override func setUp() {
        super.setUp()
        aufraeumen()
    }

    override func tearDown() {
        aufraeumen()
        super.tearDown()
    }

    private func aufraeumen() {
        for kategorie in Eigenkategorien.alle { Eigenkategorien.loeschen(name: kategorie.name) }
        for eingebaut in TransactionCategory.eingebaute {
            Eigenkategorien.umbenennen(eingebaut: eingebaut.rawValue, auf: nil)
        }
        Eigenkategorien.pufferWegwerfen()
    }

    // MARK: - Anlegen

    func testAngelegteKategorieStehtInDerAuswahl() {
        XCTAssertNil(Eigenkategorien.anlegen(name: " Hund ", symbol: "pawprint"))
        let hund = TransactionCategory(rawValue: "Hund")
        XCTAssertTrue(TransactionCategory.allCases.contains(hund))
        XCTAssertTrue(hund.istEigene)
        XCTAssertEqual(hund.icon, "pawprint")
        XCTAssertEqual(hund.displayName, "Hund")
    }

    /// Zwei Kategorien mit demselben Namen wären nicht auseinanderzuhalten, und
    /// `from(displayName:)` müsste raten.
    func testNameEinerEingebautenIstBelegt() {
        XCTAssertEqual(Eigenkategorien.anlegen(name: "shopping", symbol: "tag"), .belegt)
        XCTAssertEqual(Eigenkategorien.anlegen(name: "Mobilität", symbol: "tag"), .belegt)
    }

    func testEigenerNameNurEinmal() {
        XCTAssertNil(Eigenkategorien.anlegen(name: "Kita", symbol: "tag"))
        XCTAssertEqual(Eigenkategorien.anlegen(name: "KITA", symbol: "tag"), .belegt)
    }

    func testGeloeschteKategorieVerschwindetAusDerAuswahl() {
        XCTAssertNil(Eigenkategorien.anlegen(name: "Hund", symbol: "pawprint"))
        Eigenkategorien.loeschen(name: "Hund")
        XCTAssertFalse(TransactionCategory.allCases.contains(TransactionCategory(rawValue: "Hund")))
    }

    // MARK: - Umbenennen einer eingebauten

    func testUmbenannteEingebauteZeigtDenNeuenNamen() {
        XCTAssertNil(Eigenkategorien.umbenennen(eingebaut: TransactionCategory.mobilitaet.rawValue, auf: "Auto"))
        XCTAssertEqual(TransactionCategory.mobilitaet.displayName, "Auto")
        XCTAssertTrue(TransactionCategory.mobilitaet.istUmbenannt)
    }

    /// **Die Falle.** In der Datenbank steht „Mobilität" — der werkseitige Anzeigename.
    /// Nach einer Umbenennung dürfen diese Zeilen nicht ins Leere laufen, und über den
    /// `rawValue` sind sie nicht zu finden: Die Vergleichsform faltet „ä" zu „a", nicht
    /// zu „ae", also passt „Mobilitaet" nicht auf „Mobilität".
    func testGespeicherteBezeichnungUeberlebtEineUmbenennung() {
        XCTAssertNil(Eigenkategorien.umbenennen(eingebaut: TransactionCategory.mobilitaet.rawValue, auf: "Auto"))
        XCTAssertEqual(TransactionCategory.from(displayName: "Mobilität"), .mobilitaet)
        XCTAssertEqual(TransactionCategory.from(displayName: "Mobilitaet"), .mobilitaet)
        XCTAssertEqual(TransactionCategory.from(displayName: "Auto"), .mobilitaet)
    }

    func testZuruecksetzenStelltDenWerksnamenWiederHer() {
        XCTAssertNil(Eigenkategorien.umbenennen(eingebaut: TransactionCategory.mobilitaet.rawValue, auf: "Auto"))
        Eigenkategorien.umbenennen(eingebaut: TransactionCategory.mobilitaet.rawValue, auf: nil)
        XCTAssertEqual(TransactionCategory.mobilitaet.displayName, "Mobilität")
        XCTAssertFalse(TransactionCategory.mobilitaet.istUmbenannt)
    }

    /// Eine eingebaute auf den Namen einer anderen umzubenennen, wäre dieselbe
    /// Verwechslung wie zwei gleich benannte eigene.
    func testEingebauteDarfNichtWieEineAndereHeissen() {
        XCTAssertEqual(
            Eigenkategorien.umbenennen(eingebaut: TransactionCategory.mobilitaet.rawValue, auf: "Shopping"),
            .belegt)
    }

    /// Denselben Namen nochmal setzen ist kein Einwand — sonst bekäme der Nutzer eine
    /// Fehlermeldung dafür, dass er nichts geändert hat.
    func testDerselbeNameIstKeinEinwand() {
        XCTAssertNil(Eigenkategorien.umbenennen(eingebaut: TransactionCategory.mobilitaet.rawValue, auf: "Mobilität"))
    }

    // MARK: - Umbenennen einer eigenen

    func testEigeneUmbenennenAendertDieAuswahl() {
        XCTAssertNil(Eigenkategorien.anlegen(name: "Hund", symbol: "pawprint"))
        XCTAssertNil(Eigenkategorien.umbenennen(eigene: "Hund", auf: "Haustier"))
        XCTAssertTrue(TransactionCategory.allCases.contains(TransactionCategory(rawValue: "Haustier")))
        XCTAssertFalse(TransactionCategory.allCases.contains(TransactionCategory(rawValue: "Hund")))
        XCTAssertEqual(TransactionCategory(rawValue: "Haustier").icon, "pawprint")
    }

    func testEigeneDarfNichtWieEineEingebauteHeissen() {
        XCTAssertNil(Eigenkategorien.anlegen(name: "Hund", symbol: "pawprint"))
        XCTAssertEqual(Eigenkategorien.umbenennen(eigene: "Hund", auf: "Sparen"), .belegt)
        XCTAssertTrue(TransactionCategory.allCases.contains(TransactionCategory(rawValue: "Hund")))
    }
}

/// Die Overrides sind die stärkste Zuordnung — sie schlagen Regel und gespeicherte
/// Bezeichnung. Beim Umbenennen einer eigenen Kategorie müssen sie mit umziehen, sonst
/// verliert der Nutzer genau die Zuordnungen, die er von Hand getroffen hat.
///
/// Eigene Fingerprints je Lauf und Aufräumen danach — wie in `OverrideSlotScopeTests`,
/// weil die Overrides in der echten Domain liegen.
final class KategorieUmzugTests: XCTestCase {

    private let txID = "umzug-\(UUID().uuidString.prefix(8))"
    private let slot = "slot-\(UUID().uuidString.prefix(6))"

    override func tearDown() {
        _ = TransactionCategorizer.removeOverride(txID: txID, slotId: slot)
        super.tearDown()
    }

    /// Der ganze Weg: Kategorie anlegen, Buchung von Hand zuordnen, Kategorie
    /// umbenennen — die Zuordnung muss stehen.
    func testOverrideZiehtBeimUmbenennenMitUm() {
        XCTAssertNil(Eigenkategorien.anlegen(name: "Hund", symbol: "pawprint"))
        defer { Eigenkategorien.loeschen(name: "Haustier"); Eigenkategorien.loeschen(name: "Hund") }

        TransactionCategorizer.saveOverride(txID: txID, slotId: slot,
                                            category: TransactionCategory(rawValue: "Hund"))
        XCTAssertNil(Eigenkategorien.umbenennen(eigene: "Hund", auf: "Haustier"))

        XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: txID, slotId: slot)?.rawValue,
                       "Haustier")
    }

    /// Nach dem **Löschen** bleibt der Override liegen, löst aber nicht mehr auf: Die
    /// Buchung fällt auf die automatische Zuordnung zurück. Genau das sagt der
    /// Bestätigungsdialog zu — und wer dieselbe Kategorie neu anlegt, hat sie zurück.
    func testGeloeschteKategorieLaesstDenUmsatzZurueckfallen() {
        XCTAssertNil(Eigenkategorien.anlegen(name: "Hund", symbol: "pawprint"))
        TransactionCategorizer.saveOverride(txID: txID, slotId: slot,
                                            category: TransactionCategory(rawValue: "Hund"))
        Eigenkategorien.loeschen(name: "Hund")

        XCTAssertNil(TransactionCategorizer.overrideCategory(txID: txID, slotId: slot))

        XCTAssertNil(Eigenkategorien.anlegen(name: "Hund", symbol: "pawprint"))
        XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: txID, slotId: slot)?.rawValue, "Hund")
        Eigenkategorien.loeschen(name: "Hund")
    }

    func testFremdeOverridesBleibenUnberuehrt() {
        TransactionCategorizer.saveOverride(txID: txID, slotId: slot, category: .freizeit)
        TransactionCategorizer.overridesUmbenennen(von: "Hund", nach: "Haustier")

        XCTAssertEqual(TransactionCategorizer.overrideCategory(txID: txID, slotId: slot), .freizeit)
    }
}

/// Die Weißliste der KI-Zuordnung muss halten: Ohne sie schriebe jedes Wort, das das
/// Modell erfindet, als Kategorie in die Datenbank.
final class KIKategorieschluesselTests: XCTestCase {

    func testEingebauterSchluesselWirdUebersetzt() {
        XCTAssertEqual(AICategorizationService.kategorie(fuerSchluessel: "gastronomie", eigene: []),
                       .gastronomie)
    }

    func testEigeneKategorieWirdAnDerListeGeprueft() {
        XCTAssertEqual(AICategorizationService.kategorie(fuerSchluessel: "hund", eigene: ["Hund"])?.rawValue,
                       "Hund")
    }

    func testErfundeneKategorieWirdVerworfen() {
        XCTAssertNil(AICategorizationService.kategorie(fuerSchluessel: "Trinkgeld", eigene: ["Hund"]))
    }

    /// Ohne eigene Kategorien bleibt der Prompt wortgleich — die KI-Zuordnung soll sich
    /// für niemanden ändern, der nichts angelegt hat.
    func testPromptBleibtUnveraendertOhneEigeneKategorien() {
        XCTAssertEqual(AIProviderService.categorizationSystemPrompt(eigeneKategorien: []),
                       AIProviderService.CATEGORIZATION_SYSTEM_PROMPT)
    }

    func testEigeneKategorienStehenImPrompt() {
        let prompt = AIProviderService.categorizationSystemPrompt(eigeneKategorien: ["Hund", "Kita"])
        XCTAssertTrue(prompt.contains("\"Hund\""))
        XCTAssertTrue(prompt.contains("\"Kita\""))
    }
}
