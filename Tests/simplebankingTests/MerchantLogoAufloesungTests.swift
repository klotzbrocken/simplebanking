import XCTest
import AppKit
@testable import simplebanking

/// Der Fehler dahinter: Bis 2.0.2 kamen die Händlerlogos von DuckDuckGo und waren
/// Favicons (16–48 px). Nach dem Wechsel auf logo.dev blieben sie noch 30 Tage im
/// Cache und wurden weiter angezeigt — in der 20-Punkt-Zeile auf einem Retina-Schirm
/// als erkennbarer Pixelbrei. Diese Tests sichern die Messung, an der solche Bilder
/// jetzt aussortiert werden.
final class MerchantLogoAufloesungTests: XCTestCase {

    private func bild(kante: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: kante, pixelsHigh: kante,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        // Punktgröße bewusst abweichend von der Pixelgröße — genau so liefert es
        // NSImage bei Retina-Assets und bei .ico-Dateien mit mehreren Auflösungen.
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(rep)
        return image
    }

    func test_kanteWirdInPixelnGemessen_nichtInPunkten() {
        XCTAssertEqual(MerchantLogoService.kanteInPixeln(bild(kante: 128)), 128)
        XCTAssertEqual(MerchantLogoService.kanteInPixeln(bild(kante: 16)), 16)
    }

    func test_favicongroessenLiegenUnterDerGrenze() {
        // Die Größen, die DuckDuckGo tatsächlich lieferte.
        for kante in [16, 32, 48] {
            XCTAssertLessThan(MerchantLogoService.kanteInPixeln(bild(kante: kante)),
                              MerchantLogoService.mindestKante,
                              "\(kante)px müsste verworfen werden")
        }
    }

    func test_logoDevGroessenLiegenUeberDerGrenze() {
        // Was logo.dev auf `size=256` liefert — und die 128er aus der ersten Fassung.
        for kante in [64, 128, 256] {
            XCTAssertGreaterThanOrEqual(MerchantLogoService.kanteInPixeln(bild(kante: kante)),
                                        MerchantLogoService.mindestKante,
                                        "\(kante)px müsste benutzt werden")
        }
    }

    func test_groessteReprMitZaehlt_beiMehrerenAufloesungen() {
        // .ico-Dateien bringen mehrere Repräsentationen mit. Maßgeblich ist die beste,
        // sonst würde ein brauchbares Bild an seiner 16er-Variante scheitern.
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for kante in [16, 32, 128] {
            image.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                     pixelsWide: kante, pixelsHigh: kante,
                                                     bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0)!)
        }
        XCTAssertEqual(MerchantLogoService.kanteInPixeln(image), 128)
    }

    func test_urlFordertDieGroessereKante() throws {
        let url = try XCTUnwrap(MerchantLogoService.LogoDev.url(for: "rewe.de"))
        XCTAssertTrue(url.absoluteString.contains("size=256"), url.absoluteString)
        // Ohne `fallback=404` liefert logo.dev einen generischen Platzhalter, den wir
        // als echtes Logo einbauen würden.
        XCTAssertTrue(url.absoluteString.contains("fallback=404"), url.absoluteString)
    }

    func test_nachholkontingentGehtVorDemTagesbudget() {
        let d = UserDefaults.standard
        let keys = ["merchantLogoNachholBudget", "merchantLogoFetchDay", "merchantLogoFetchCount"]
        let gesichert = keys.map { ($0, d.object(forKey: $0)) }
        defer { for (k, v) in gesichert { d.set(v, forKey: k) } }
        keys.forEach { d.removeObject(forKey: $0) }

        // Tagesbudget aufbrauchen …
        for _ in 0..<MerchantLogoService.LogoDev.fetchesPerDay {
            XCTAssertTrue(MerchantLogoService.LogoDev.budgetVerbrauchen())
        }
        XCTAssertFalse(MerchantLogoService.LogoDev.budgetVerbrauchen())

        // … dann zwei verworfene Logos melden: genau zwei weitere Abrufe sind frei.
        MerchantLogoService.LogoDev.nachholenErlauben(2)
        XCTAssertTrue(MerchantLogoService.LogoDev.budgetVerbrauchen())
        XCTAssertTrue(MerchantLogoService.LogoDev.budgetVerbrauchen())
        XCTAssertFalse(MerchantLogoService.LogoDev.budgetVerbrauchen())
    }

    func test_nachholkontingentIstGedeckelt() {
        let d = UserDefaults.standard
        let gesichert = d.object(forKey: "merchantLogoNachholBudget")
        defer { d.set(gesichert, forKey: "merchantLogoNachholBudget") }
        d.removeObject(forKey: "merchantLogoNachholBudget")

        MerchantLogoService.LogoDev.nachholenErlauben(500)
        MerchantLogoService.LogoDev.nachholenErlauben(500)
        XCTAssertEqual(d.integer(forKey: "merchantLogoNachholBudget"),
                       MerchantLogoService.LogoDev.nachholHoechstzahl)
    }
}

/// Der Cache muss die zu kleinen Bilder auch wirklich loswerden — bliebe die Zeile
/// stehen, käme das Favicon beim nächsten Start zurück und der Händler bekäme nie
/// ein neues Logo, weil `INSERT OR REPLACE` nur bei einem erfolgreichen Abruf greift.
final class LogoCacheBereinigungTests: XCTestCase {

    private var testBankId: String = ""

    override func setUpWithError() throws {
        testBankId = "test-\(UUID().uuidString.lowercased().prefix(12))"
    }

    override func tearDownWithError() throws {
        try? TransactionsDatabase.deleteDatabaseFileIfExists(bankId: testBankId)
    }

    func test_deleteLogos_entferntNurDieGenanntenSchluessel() throws {
        TransactionsDatabase.saveLogo(key: "rossmann", data: Data([1, 2, 3]), bankId: testBankId)
        TransactionsDatabase.saveLogo(key: "rewe", data: Data([4, 5, 6]), bankId: testBankId)
        TransactionsDatabase.saveLogo(key: "lidl", data: Data([7, 8, 9]), bankId: testBankId)

        TransactionsDatabase.deleteLogos(keys: ["rossmann", "lidl"], bankId: testBankId)

        let rest = try TransactionsDatabase.loadCachedLogoData(bankId: testBankId)
        XCTAssertEqual(Set(rest.keys), ["rewe"])
    }

    func test_deleteLogos_ohneSchluesselIstEinNichtstun() throws {
        TransactionsDatabase.saveLogo(key: "rewe", data: Data([4, 5, 6]), bankId: testBankId)
        TransactionsDatabase.deleteLogos(keys: [], bankId: testBankId)
        let rest = try TransactionsDatabase.loadCachedLogoData(bankId: testBankId)
        XCTAssertEqual(Set(rest.keys), ["rewe"])
    }
}

/// Rückfall auf Googles Favicon-Dienst, wenn logo.dev einen Händler nicht kennt.
/// Siehe `MerchantLogoService.GoogleFavicon` — dort steht auch, warum er derzeit
/// keinen einzigen Händler rettet und trotzdem drin bleibt.
final class GoogleFaviconRueckfallTests: XCTestCase {

    func test_urlEnthaeltDomainUndGroesse() throws {
        let url = try XCTUnwrap(MerchantLogoService.GoogleFavicon.url(for: "storytel.de"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertTrue(url.absoluteString.contains("domain=storytel.de"), url.absoluteString)
        // Ohne `sz` liefert Google 16 Pixel — das fiele an der Mindestgröße durch.
        XCTAssertTrue(url.absoluteString.contains("sz=256"), url.absoluteString)
    }

    func test_urlTraegtKeinenSchluessel() throws {
        // Der Dienst braucht keinen; ein versehentlich mitgeschickter Token wäre ein Leck.
        let url = try XCTUnwrap(MerchantLogoService.GoogleFavicon.url(for: "rewe.de"))
        XCTAssertFalse(url.absoluteString.contains("token"), url.absoluteString)
        XCTAssertFalse(url.absoluteString.contains("pk_"), url.absoluteString)
    }

    func test_nurDieDomainVerlaesstDasGeraet() throws {
        // Es darf nichts aus der Buchung in die Anfrage geraten — kein Verwendungszweck,
        // kein Betrag, keine IBAN. Der Schlüssel der App ist ein Händlername, die
        // Anfrage kennt nur die zugeordnete Domain.
        let url = try XCTUnwrap(MerchantLogoService.GoogleFavicon.url(for: "edeka.de"))
        let query = url.query ?? ""
        let felder = Set(query.split(separator: "&").map { $0.split(separator: "=")[0] })
        XCTAssertEqual(felder, ["domain", "sz"])
    }

    func test_ungewoehnlicheDomainWirdKodiert() throws {
        let url = try XCTUnwrap(MerchantLogoService.GoogleFavicon.url(for: "bäcker.de"))
        XCTAssertFalse(url.absoluteString.contains(" "), url.absoluteString)
        XCTAssertNotNil(URL(string: url.absoluteString))
    }

    func test_grenzeGiltAuchFuerGoogle() {
        // Für unbekannte Domains liefert Google eine 16×16-Weltkugel statt eines 404.
        // Dass die aussortiert wird, hängt allein an dieser Grenze.
        XCTAssertLessThan(16, MerchantLogoService.mindestKante)
    }
}
