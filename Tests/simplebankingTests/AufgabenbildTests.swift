import XCTest
@testable import simplebanking

// MARK: - chipTAN: die optische Aufgabe
//
// Gemeldet am 02.09.2026 für die Sparkasse Bodensee: Das Eingabefenster kam, aber
// ohne QR-Code — und ohne den erzeugt der Generator keine TAN. Das Bild lag im SDK
// längst bei (`Dialog.image`), wurde beim Übersetzen in `SCACommon` aber verworfen.
//
// Bei Flicker-Grafiken ist die Anzeigebreite Teil des Verfahrens: 62,5 mm physisch,
// sonst treffen die hellen Balken die Sensoren nicht.

final class AufgabenbildTests: XCTestCase {

    private func bild(hhdUC: Data?) -> SCAFieldInput.Aufgabenbild {
        .init(mimeType: "image/gif", daten: Data([0x47, 0x49, 0x46]), hhdUC: hhdUC)
    }

    func test_hhdUCKennzeichnetFlicker() {
        XCTAssertTrue(bild(hhdUC: Data([0x01])).istFlicker)
        XCTAssertFalse(bild(hhdUC: nil).istFlicker, "QR und photoTAN sind kein Flicker")
    }

    /// MacBook Pro 14": 1512 Punkte auf 302 mm. 62,5 mm entsprechen dort rund 313 Punkten.
    func test_breiteEntsprichtDenVorgeschriebenenMillimetern() {
        let breite = SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 1512,
                                                 bildschirmBreiteMm: 302)
        XCTAssertEqual(breite, 62.5 * 1512 / 302, accuracy: 0.001)
        // Gegenprobe von der anderen Seite: zurückgerechnet müssen 62,5 mm herauskommen.
        XCTAssertEqual(breite * 302 / 1512, SCAFieldInput.flickerBreiteMm, accuracy: 0.001)
    }

    /// Ein größerer Bildschirm mit gleicher Punktzahl heißt gröbere Punkte — die
    /// Grafik braucht dort *weniger* Punkte für dieselben Millimeter.
    func test_groebereBildschirmpunkteBrauchenWenigerPunkte() {
        let eng = SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 1512, bildschirmBreiteMm: 302)
        let weit = SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 1512, bildschirmBreiteMm: 604)
        XCTAssertLessThan(weit, eng)
    }

    func test_feinjustierungWirktProportional() {
        let normal = SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 1512,
                                                 bildschirmBreiteMm: 302)
        let groesser = SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 1512,
                                                   bildschirmBreiteMm: 302, anpassung: 1.1)
        XCTAssertEqual(groesser, normal * 1.1, accuracy: 0.001)
    }

    /// Meldet der Bildschirm seine Größe nicht (externe Monitore tun das oft nicht),
    /// darf kein Bild der Breite null herauskommen — der Nutzer sähe gar nichts.
    func test_unbekannteBildschirmgroesseLiefertBrauchbarenWert() {
        XCTAssertEqual(SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 1512,
                                                   bildschirmBreiteMm: 0), 240)
        XCTAssertEqual(SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 0,
                                                   bildschirmBreiteMm: 302), 240)
    }

    /// Absurde Werte dürfen das Fenster nicht sprengen.
    func test_breiteBleibtInVernuenftigenGrenzen() {
        XCTAssertEqual(SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 1512,
                                                   bildschirmBreiteMm: 5000), 80)
        XCTAssertEqual(SCAFieldInput.flickerBreite(bildschirmBreitePunkte: 8000,
                                                   bildschirmBreiteMm: 10), 700)
    }

    /// Die Aufgabe gehört in die Spec — genau das fehlte und machte den Dialog
    /// unbeantwortbar.
    func test_specTraegtDieAufgabe() {
        let spec = SCAFieldInput.Spec(type: .number, secrecyLevel: .otp,
                                      minLength: 6, maxLength: 6,
                                      bankDisplayName: "Sparkasse Bodensee",
                                      msg: "Bitte bestätigen",
                                      slotEpochAtRequest: 0,
                                      bild: bild(hhdUC: nil))
        XCTAssertNotNil(spec.bild)
        XCTAssertEqual(spec.bild?.mimeType, "image/gif")
    }
}
