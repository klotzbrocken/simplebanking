import XCTest
@testable import simplebanking

// MARK: - Katalog-Rückfall bei der Marken-Auflösung
//
// `BankLogoAssets.brands` ist eine handgepflegte Liste von 29 Marken, der YAXI-Catalog
// führt 192 Logos. Vor dem Rückfall bekam jede Bank außerhalb der 29 gar kein Icon,
// obwohl ihr Logo längst im Bundle lag — aufgefallen an bunq.
//
// Die Tests halten beides fest: dass der Rückfall greift, und dass er die kuratierten
// Marken nicht verdrängt.

final class BankLogoCatalogFallbackTests: XCTestCase {

    // MARK: Der Rückfall greift

    func test_bunq_wirdUeberDieLogoIdAufgeloest() {
        let brand = BankLogoAssets.resolve(displayName: "bunq", logoID: "bunq", iban: nil)
        XCTAssertEqual(brand?.id, "bunq")
    }

    /// Frisch eingerichtete Slots tragen noch keine logoId — dann muss der Anzeigename
    /// reichen.
    func test_ohneLogoId_greiftDerAnzeigename() {
        let brand = BankLogoAssets.resolve(displayName: "bunq", logoID: nil, iban: nil)
        XCTAssertEqual(brand?.id, "bunq")
    }

    func test_anzeigenameBleibtErhalten() {
        let brand = BankLogoAssets.resolve(displayName: "bunq Giro", logoID: "bunq", iban: nil)
        XCTAssertEqual(brand?.displayName, "bunq Giro")
    }

    /// Der Rückfall ist nur so viel wert wie das Logo dahinter: die URL muss auf eine
    /// real existierende Datei zeigen, sonst bleibt der Slot trotz Treffer leer.
    func test_dieAufgeloesteMarke_zeigtAufEinVorhandenesSVG() throws {
        let brand = try XCTUnwrap(BankLogoAssets.resolve(displayName: nil, logoID: "bunq", iban: nil))
        XCTAssertEqual(brand.logoURL.scheme, "file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: brand.logoURL.path),
                      "kein SVG unter \(brand.logoURL.path)")
    }

    func test_markenfarbeKommtAusDemKatalog() throws {
        let brand = try XCTUnwrap(BankLogoAssets.resolve(displayName: nil, logoID: "bunq", iban: nil))
        XCTAssertEqual(brand.accentColor.lowercased(),
                       BankLogoCatalog.primaryColor(forLogoId: "bunq")?
                           .replacingOccurrences(of: "#", with: "").lowercased())
    }

    /// Der Rückfall ist keine Einzelfalllösung für bunq — er muss den ganzen Katalog
    /// erschließen. Geprüft an Marken, die nachweislich nicht in `brands` stehen.
    func test_rueckfallGiltFuerDenGanzenKatalog() {
        let kuratiert = Set(BankLogoAssets.brands.map(\.id))
        let uebrige = BankLogoCatalog.availableLogoIds.subtracting(kuratiert)
        XCTAssertGreaterThan(uebrige.count, 100, "Katalog unerwartet klein")
        for id in uebrige {
            XCTAssertNotNil(BankLogoAssets.find(inCatalog: id, displayName: nil),
                            "\(id) bleibt ohne Logo")
        }
    }

    // MARK: Der Rückfall verdrängt nichts

    /// Die kuratierten Marken tragen Keywords und BLZ-Regeln, die der Katalog nicht
    /// kennt. Sie müssen weiterhin zuerst greifen — sonst hätte allein das Einführen
    /// des Rückfalls die Zuordnung bestehender Konten verändert.
    func test_kuratierteMarkenBehaltenVorrang() {
        // "sparkasse" steht in beiden Welten; die Hand-Liste gruppiert alle Sparkassen
        // unter einer Marke, deshalb muss ihr Anzeigename gewinnen.
        let brand = BankLogoAssets.resolve(displayName: "Stadtsparkasse München",
                                           logoID: nil, iban: nil)
        XCTAssertEqual(brand?.id, "sparkasse")
        XCTAssertEqual(brand?.displayName, "Sparkasse")
    }

    func test_unbekannteBankBleibtOhneMarke() {
        XCTAssertNil(BankLogoAssets.resolve(displayName: "Bank von Nirgendwo",
                                            logoID: "gibtesnicht", iban: nil))
    }

    func test_leereEingabenLiefernNichts() {
        XCTAssertNil(BankLogoAssets.find(inCatalog: "", displayName: ""))
        XCTAssertNil(BankLogoAssets.find(inCatalog: nil, displayName: nil))
    }

    /// `_default` ist der generische Platzhalter des Katalogs und keine Marke — er darf
    /// nicht über den Rückfall als echtes Bank-Logo durchrutschen.
    func test_defaultPlatzhalterIstKeineMarke() {
        XCTAssertNil(BankLogoAssets.find(inCatalog: "_default", displayName: nil))
    }

    // MARK: Dunkelmodus

    /// bunq führt `primaryColor = #000000` und hat eine Maske — nach den alten Kriterien
    /// wäre es „dunkel" und würde invertiert. Das gerenderte SVG ist aber eine bunte
    /// Kachel mit weißer Schrift; ein `.colorInvert()` darauf färbt die Balken um.
    /// Katalog-Marken bleiben deshalb uninvertiert.
    func test_katalogMarkenWerdenNichtInvertiert() {
        XCTAssertFalse(BankLogoAssets.isDark(brandId: "bunq"))
    }
}
