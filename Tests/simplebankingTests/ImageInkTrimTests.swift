import XCTest
import AppKit
@testable import simplebanking

// MARK: - Zuschnitt auf die Tinte
//
// Die Menüleiste skalierte Masken stur auf 16×16. Katalog-Masken liegen aber in einem
// quadratischen Feld, das sie unterschiedlich stark ausfüllen — bunqs Wortmarke belegt
// nur ein flaches Band, von dem knapp drei Punkt Höhe übrig blieben.
//
// Geprüft wird an synthetischen Bildern mit bekannter Tintenfläche, damit die Aussage
// nicht von einem konkreten Katalog-SVG abhängt.

final class ImageInkTrimTests: XCTestCase {

    /// Bild der Größe `size` mit einem deckenden Rechteck `ink` (Ursprung unten links).
    private func image(size: NSSize, ink: NSRect) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setFill()
        ink.fill()
        img.unlockFocus()
        return img
    }

    /// Der Fall bunq: breite Wortmarke in quadratischem Feld. Vorher 16×16 (die Tinte
    /// darin gut 3 Punkt hoch), jetzt füllt sie die Höhe aus und wächst in die Breite.
    func test_flacheWortmarke_nutztDieHoeheAus() {
        let img = image(size: NSSize(width: 250, height: 250),
                        ink: NSRect(x: 25, y: 105, width: 200, height: 40))
        let out = img.trimmedToInk(fittingHeight: 16, maxWidth: 32)
        // Seitenverhältnis 200:40 = 5 → 16 × 80, gedeckelt auf 32 Breite → Höhe 6,4.
        XCTAssertEqual(out.size.width, 32, accuracy: 1.5)
        XCTAssertEqual(out.size.width / out.size.height, 5, accuracy: 0.5)
    }

    /// Ohne Deckel wäre die Menüleiste die Grenze — deshalb muss `maxWidth` wirklich
    /// binden und nicht nur ein Richtwert sein.
    func test_maxWidthWirdEingehalten() {
        let img = image(size: NSSize(width: 250, height: 250),
                        ink: NSRect(x: 5, y: 120, width: 240, height: 10))
        let out = img.trimmedToInk(fittingHeight: 16, maxWidth: 32)
        XCTAssertLessThanOrEqual(out.size.width, 32)
    }

    /// Ein quadratisches Logo mit Rand soll den Rand verlieren, aber quadratisch bleiben
    /// und die volle Höhe bekommen — sonst hätte der Zuschnitt die bestehenden Logos
    /// verzerrt statt vergrößert.
    func test_quadratischeTinte_bleibtQuadratisch() {
        let img = image(size: NSSize(width: 250, height: 250),
                        ink: NSRect(x: 50, y: 50, width: 150, height: 150))
        let out = img.trimmedToInk(fittingHeight: 16, maxWidth: 32)
        XCTAssertEqual(out.size.width, 16, accuracy: 1.5)
        XCTAssertEqual(out.size.height, 16, accuracy: 1.5)
    }

    /// Randlose Logos dürfen sich nicht verändern — der Zuschnitt ist für sie ein no-op.
    func test_randlosesLogo_bleibtWieEsIst() {
        let img = image(size: NSSize(width: 250, height: 250),
                        ink: NSRect(x: 0, y: 0, width: 250, height: 250))
        let out = img.trimmedToInk(fittingHeight: 16, maxWidth: 32)
        XCTAssertEqual(out.size.width, 16, accuracy: 1.0)
        XCTAssertEqual(out.size.height, 16, accuracy: 1.0)
    }

    /// Ein leeres Bild hat keine Tinte, an der sich der Zuschnitt orientieren könnte.
    /// Es muss trotzdem ein brauchbares Bild herauskommen, sonst wird das Status-Item
    /// null-breit.
    func test_leeresBild_faelltAufDieQuadratischeGroesseZurueck() {
        let img = NSImage(size: NSSize(width: 250, height: 250))
        let out = img.trimmedToInk(fittingHeight: 16, maxWidth: 32)
        XCTAssertEqual(out.size, NSSize(width: 16, height: 16))
    }

    func test_entarteteGroessenLiefernEinBild() {
        let out = NSImage(size: .zero).trimmedToInk(fittingHeight: 16, maxWidth: 32)
        XCTAssertEqual(out.size, NSSize(width: 16, height: 16))
    }

    // MARK: Am echten Katalog

    /// Die eigentliche Wirkung: bunqs Maske war in der Menüleiste ein Streifen.
    func test_bunqMaske_wirdDeutlichBreiterAlsHoch() throws {
        let url = try XCTUnwrap(BankLogoCache.url(forLogoId: "bunq", mask: true))
        let mask = try XCTUnwrap(NSImage(contentsOf: url))
        let out = mask.trimmedToInk(fittingHeight: 16, maxWidth: 32)
        XCTAssertGreaterThan(out.size.width, out.size.height,
                             "Wortmarke sollte breiter als hoch sein")
        XCTAssertGreaterThan(out.size.height, 5,
                             "vor dem Zuschnitt blieben rund 3 Punkt Tintenhöhe übrig")
        XCTAssertLessThanOrEqual(out.size.width, 32)
    }
}
