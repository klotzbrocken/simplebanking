import XCTest
@testable import simplebanking

/// Die Palette der Kategorie-Kapseln.
///
/// Die harte Zusage ist **kein Grün, kein Orange, kein Rot**: Diese drei gehören der
/// Saldo-Stimmung und den Beträgen. Eine Kapsel in Saldo-Farbe läse sich als Warnung,
/// und sie liegt direkt auf der Stimmungsfläche. Deshalb wird der Farbton hier
/// gerechnet und nicht nachgesehen.
final class KategoriefarbeTests: XCTestCase {

    override func tearDown() {
        for kategorie in TransactionCategory.eingebaute {
            Eigenkategorien.farbeSetzen(kategorie, farbe: nil)
        }
        super.tearDown()
    }

    // MARK: - Zuordnung

    func testJedeEingebauteHatEinenTon() {
        for kategorie in TransactionCategory.eingebaute {
            let ton = Kategoriefarbe.vorgabe(fuer: kategorie)
            XCTAssertTrue(Kategoriefarbe.palette.contains(ton),
                          "\(kategorie.rawValue) trägt einen Ton außerhalb der Palette")
        }
    }

    func testWasKeineAusgabeIstBleibtNeutral() {
        for kategorie in [TransactionCategory.einkommen, .gehalt, .umbuchung, .sonstiges] {
            XCTAssertEqual(Kategoriefarbe.vorgabe(fuer: kategorie), Kategoriefarbe.neutral,
                           kategorie.rawValue)
        }
    }

    func testBenachbarteAusgabenartenTeilenKeinenTon() {
        let paare: [(TransactionCategory, TransactionCategory)] = [
            (.essenAlltag, .gastronomie), (.mobilitaet, .gastronomie),
            (.abosDigital, .versicherungen), (.shopping, .freizeit)
        ]
        for (a, b) in paare {
            XCTAssertNotEqual(Kategoriefarbe.vorgabe(fuer: a), Kategoriefarbe.vorgabe(fuer: b),
                              "\(a.rawValue) und \(b.rawValue) stehen oft nebeneinander")
        }
    }

    // MARK: - Die Regel

    /// Der Farbwinkel allein genügt nicht: Jedes Grau hat einen, und ein Taupe
    /// liegt rechnerisch im Orange, ohne je wie eine Warnung zu wirken. Entschieden
    /// wird deshalb über Winkel **und** Sättigung. Die Schwelle ist an den
    /// Stimmungsfarben gemessen, nicht geschätzt: `sbOrangeStrong` hat 70 %,
    /// `sbOrangeMid` 52 % (`ThemeSupport.swift`). Unter 35 % liest sich ein Ton als
    /// warmes oder kühles Grau; darüber gilt die Sperre.
    func testKeinGesaettigterTonLiegtImGruenOrangeOderRot() {
        for ton in Kategoriefarbe.palette {
            for hex in [ton.hell, ton.text, ton.textDunkel] {
                guard Self.saettigung(hex) >= 0.35 else { continue }
                let winkel = Self.farbwinkel(hex)
                XCTAssertFalse(winkel < 20 || winkel > 340,
                               "\(ton.id): \(hex) liegt im Rot (\(Int(winkel))°)")
                XCTAssertFalse(winkel >= 20 && winkel <= 50,
                               "\(ton.id): \(hex) liegt im Orange (\(Int(winkel))°)")
                XCTAssertFalse(winkel >= 80 && winkel <= 160,
                               "\(ton.id): \(hex) liegt im Grün (\(Int(winkel))°)")
            }
        }
    }

    /// Die Ausnahme oben darf kein Schlupfloch werden: Wer im Sperrbereich liegt und
    /// nur über die Sättigung durchkommt, muss deutlich darunter liegen und nicht
    /// knapp — sonst wandert irgendwann ein halbes Orange hinein.
    func testWerImSperrbereichLiegtIstDeutlichEntsaettigt() {
        for ton in Kategoriefarbe.palette {
            for hex in [ton.hell, ton.text, ton.textDunkel] where Self.imSperrbereich(hex) {
                XCTAssertLessThan(Self.saettigung(hex), 0.25,
                                  "\(ton.id): \(hex) liegt bei \(Int(Self.farbwinkel(hex)))° und ist zu satt für ein Grau")
            }
        }
    }

    /// Die Kapsel liegt auf der Stimmungsfläche, nicht auf Weiß — gerechnet wird
    /// deshalb gegen alle drei Stimmungen.
    func testDerTextBleibtAufJederStimmungsflaecheLesbar() {
        let flaechen = ["#E6EFE8", "#F3EADC", "#F3E3E1", "#FFFFFF"]   // grün, orange, rot, neutral
        for ton in Kategoriefarbe.palette {
            for flaeche in flaechen {
                let grund = Self.ueberlagert(Self.rgb(ton.hell), auf: Self.rgb(flaeche), deckung: 0.14)
                let verhaeltnis = Self.kontrast(Self.rgb(ton.text), grund)
                XCTAssertGreaterThanOrEqual(verhaeltnis, 4.5,
                    "\(ton.id) auf \(flaeche): nur \(String(format: "%.2f", verhaeltnis)):1")
            }
        }
    }

    // MARK: - Eigene Kategorien

    func testDerIndexIstUeberProgrammstarteHinwegDerselbe() {
        let erst = Kategoriefarbe.stabilerIndex("Hundefutter", anzahl: 8)
        XCTAssertEqual(erst, Kategoriefarbe.stabilerIndex("Hundefutter", anzahl: 8))
        XCTAssertTrue((0..<8).contains(erst))
        XCTAssertNotEqual(Kategoriefarbe.stabilerIndex("Hundefutter", anzahl: 8),
                          Kategoriefarbe.stabilerIndex("Katzenfutter", anzahl: 8),
                          "Zwei Namen sollten sich in der Regel unterscheiden")
    }

    func testEineEigeneKategorieBekommtEinenTonAusDerRotation() {
        let eigene = TransactionCategory(rawValue: "Hundefutter")
        let ton = Kategoriefarbe.vorgabe(fuer: eigene)
        XCTAssertTrue(Kategoriefarbe.rotation.contains(ton))
        XCTAssertNotEqual(ton, Kategoriefarbe.neutral, "Neutral wird nicht verlost")
    }

    // MARK: - Die eigene Wahl

    func testDieWahlDesNutzersSchlaegtDieVorgabe() {
        XCTAssertEqual(Kategoriefarbe.ton(fuer: .essenAlltag), Kategoriefarbe.petrol)
        Eigenkategorien.farbeSetzen(.essenAlltag, farbe: Kategoriefarbe.beere.id)
        XCTAssertEqual(Kategoriefarbe.ton(fuer: .essenAlltag), Kategoriefarbe.beere)
        Eigenkategorien.farbeSetzen(.essenAlltag, farbe: nil)
        XCTAssertEqual(Kategoriefarbe.ton(fuer: .essenAlltag), Kategoriefarbe.petrol,
                       "„Automatisch\" stellt die Vorgabe wieder her")
    }

    /// Am 12.11.2026 gemeldet: Die neue Farbe erschien erst, wenn man danach noch
    /// das Symbol wechselte. Dass das **Modell** sofort antwortet, steht hier fest —
    /// alles Weitere ist Sache der Ansicht und nicht des Speichers.
    func testEineEigeneKategorieAntwortetSofortMitDerNeuenFarbe() {
        Eigenkategorien.anlegen(name: "Hundefutter", symbol: "pawprint")
        defer { Eigenkategorien.loeschen(name: "Hundefutter") }
        let eigene = TransactionCategory(rawValue: "Hundefutter")

        Eigenkategorien.farbeSetzen(eigene, farbe: Kategoriefarbe.ozean.id)
        XCTAssertEqual(Kategoriefarbe.ton(fuer: eigene), Kategoriefarbe.ozean,
                       "Die Farbe muss ohne Umweg über einen Neuaufbau zu lesen sein")

        Eigenkategorien.farbeSetzen(eigene, farbe: nil)
        XCTAssertEqual(Kategoriefarbe.ton(fuer: eigene), Kategoriefarbe.vorgabe(fuer: eigene))
    }

    func testEineUnbekannteKennungFaelltAufDieVorgabeZurueck() {
        Eigenkategorien.farbeSetzen(.shopping, farbe: "limettengruen")
        XCTAssertEqual(Kategoriefarbe.ton(fuer: .shopping), Kategoriefarbe.violett)
    }

    // MARK: - Farbrechnung

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        var wert: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&wert)
        return (Double((wert >> 16) & 0xFF) / 255,
                Double((wert >> 8) & 0xFF) / 255,
                Double(wert & 0xFF) / 255)
    }

    private static func imSperrbereich(_ hex: String) -> Bool {
        let winkel = farbwinkel(hex)
        return winkel < 20 || winkel > 340 || (winkel >= 20 && winkel <= 50)
            || (winkel >= 80 && winkel <= 160)
    }

    /// Sättigung nach HSV (0 = grau, 1 = volle Farbe).
    private static func saettigung(_ hex: String) -> Double {
        let (r, g, b) = rgb(hex)
        let hoch = max(r, g, b)
        guard hoch > 0 else { return 0 }
        return (hoch - min(r, g, b)) / hoch
    }

    /// Farbwinkel in Grad (0 = Rot, 120 = Grün, 240 = Blau).
    private static func farbwinkel(_ hex: String) -> Double {
        let (r, g, b) = rgb(hex)
        let hoch = max(r, g, b), tief = min(r, g, b)
        let spanne = hoch - tief
        guard spanne > 0.0001 else { return 210 }   // grau: außerhalb aller Sperrbereiche
        let winkel: Double
        if hoch == r      { winkel = 60 * ((g - b) / spanne) }
        else if hoch == g { winkel = 60 * (2 + (b - r) / spanne) }
        else              { winkel = 60 * (4 + (r - g) / spanne) }
        return winkel < 0 ? winkel + 360 : winkel
    }

    private static func ueberlagert(_ vorne: (Double, Double, Double),
                                    auf hinten: (Double, Double, Double),
                                    deckung: Double) -> (Double, Double, Double) {
        (vorne.0 * deckung + hinten.0 * (1 - deckung),
         vorne.1 * deckung + hinten.1 * (1 - deckung),
         vorne.2 * deckung + hinten.2 * (1 - deckung))
    }

    private static func leuchtdichte(_ farbe: (Double, Double, Double)) -> Double {
        func gerade(_ k: Double) -> Double {
            k <= 0.03928 ? k / 12.92 : pow((k + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * gerade(farbe.0) + 0.7152 * gerade(farbe.1) + 0.0722 * gerade(farbe.2)
    }

    private static func kontrast(_ a: (Double, Double, Double),
                                 _ b: (Double, Double, Double)) -> Double {
        let la = leuchtdichte(a), lb = leuchtdichte(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
