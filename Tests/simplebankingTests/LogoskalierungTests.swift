import XCTest
import AppKit
@testable import simplebanking

/// Gemeldet am 23.09.2026: Händlerlogos sahen „zerzaust, krisselig" aus. Auf einem
/// angeschlossenen 1080p-Monitor sind die 20 Punkte der Umsatzzeile 20 echte Pixel,
/// das Bild von logo.dev hat 256 — diese Verkleinerung machte bis dahin SwiftUI beim
/// Zeichnen. Jetzt rechnet die App sie selbst, in exakter Zielgröße.
final class LogoskalierungTests: XCTestCase {

    private func rasterbild(breite: Int, hoehe: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: breite, pixelsHigh: hoehe,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        // Vollflächig füllen, damit sich die Einpassung messen lässt.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: breite, height: hoehe).fill()
        NSGraphicsContext.restoreGraphicsState()

        let bild = NSImage(size: NSSize(width: breite, height: hoehe))
        bild.addRepresentation(rep)
        return bild
    }

    private func pixelKante(_ bild: NSImage) -> (breit: Int, hoch: Int)? {
        guard let rep = bild.representations.first as? NSBitmapImageRep else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    // MARK: - Zielgröße

    func test_zielPixel_rundetStattAbzuschneiden() {
        XCTAssertEqual(Logoskalierung.zielPixel(kante: 20, skala: 1), 20)
        XCTAssertEqual(Logoskalierung.zielPixel(kante: 20, skala: 2), 40)
        XCTAssertEqual(Logoskalierung.zielPixel(kante: 20, skala: 3), 60)
        // 1,5-fache Bildschirme gibt es wirklich; Abschneiden ergäbe hier 29 und damit
        // wieder eine Skalierung beim Zeichnen.
        XCTAssertEqual(Logoskalierung.zielPixel(kante: 19.9, skala: 1.5), 30)
    }

    func test_zielPixel_behandeltSkalaKleinerEinsWieEins() {
        // Eine Skala unter 1 liefert kein sinnvolles Ziel — sie darf das Bild nicht
        // kleiner machen als die Punktgröße.
        XCTAssertEqual(Logoskalierung.zielPixel(kante: 20, skala: 0), 20)
    }

    // MARK: - Ergebnisform

    func test_ergebnisHatGenauDieGefragtenPixel() throws {
        let quelle = rasterbild(breite: 256, hoehe: 256)
        for (kante, skala, erwartet) in [(20.0, 1.0, 20), (20.0, 2.0, 40), (48.0, 3.0, 144)] {
            let bild = try XCTUnwrap(Logoskalierung.anzeigebild(aus: quelle,
                                                               kante: CGFloat(kante),
                                                               skala: CGFloat(skala)))
            let px = try XCTUnwrap(pixelKante(bild))
            XCTAssertEqual(px.breit, erwartet, "kante=\(kante) skala=\(skala)")
            XCTAssertEqual(px.hoch, erwartet)
            // Punktgröße muss der Anzeigegröße entsprechen, sonst skaliert SwiftUI doch.
            XCTAssertEqual(bild.size.width, CGFloat(kante), accuracy: 0.01)
            XCTAssertEqual(bild.size.height, CGFloat(kante), accuracy: 0.01)
        }
    }

    func test_ergebnisIstImmerQuadratisch_auchBeiBreiterQuelle() throws {
        // dm ist 1,45:1. Vorher schnitt `scaledToFill` die Seiten ab.
        let quelle = rasterbild(breite: 1024, hoehe: 706)
        let bild = try XCTUnwrap(Logoskalierung.anzeigebild(aus: quelle, kante: 20, skala: 1))
        let px = try XCTUnwrap(pixelKante(bild))
        XCTAssertEqual(px.breit, 20)
        XCTAssertEqual(px.hoch, 20)
    }

    func test_breiteQuelle_wirdEingepasstUndNichtBeschnitten() throws {
        let quelle = rasterbild(breite: 1024, hoehe: 512)   // 2:1
        let bild = try XCTUnwrap(Logoskalierung.anzeigebild(aus: quelle, kante: 40, skala: 1))
        let rep = try XCTUnwrap(bild.representations.first as? NSBitmapImageRep)

        // Volle Breite belegt (Einpassung), oben und unten durchsichtig (kein Beschnitt).
        let mitte = rep.colorAt(x: 20, y: 20)
        XCTAssertEqual(mitte?.alphaComponent ?? 0, 1.0, accuracy: 0.05, "Mitte muss gefüllt sein")
        XCTAssertEqual(rep.colorAt(x: 1, y: 20)?.alphaComponent ?? 0, 1.0, accuracy: 0.1,
                       "linker Rand muss belegt sein — die Quelle ist breiter als hoch")
        XCTAssertEqual(rep.colorAt(x: 20, y: 1)?.alphaComponent ?? 1, 0.0, accuracy: 0.05,
                       "oben muss frei bleiben statt beschnitten zu werden")
    }

    func test_vektorUndRasterWerdenAuseinandergehalten() {
        XCTAssertTrue(Logoskalierung.istRaster(rasterbild(breite: 64, hoehe: 64)))
        let leer = NSImage(size: NSSize(width: 10, height: 10))
        XCTAssertFalse(Logoskalierung.istRaster(leer), "ohne Bitmap-Repräsentation kein Raster")
    }

    func test_mitgeliefertesSVG_wirdInZielgroesseGerastert() throws {
        // Ein Vektor wird nicht verkleinert, sondern neu gezeichnet — und muss trotzdem
        // die exakte Pixelzahl liefern.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "dm", withExtension: "svg",
                                                subdirectory: "merchant-logos")
                                ?? Bundle.module.url(forResource: "dm", withExtension: "svg",
                                                     subdirectory: "merchant-logos"))
        let svg = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertFalse(Logoskalierung.istRaster(svg), "SVG darf nicht als Raster gelten")

        let bild = try XCTUnwrap(Logoskalierung.anzeigebild(aus: svg, kante: 20, skala: 2))
        let px = try XCTUnwrap(pixelKante(bild))
        XCTAssertEqual(px.breit, 40)
        XCTAssertEqual(px.hoch, 40)
    }

    func test_ungueltigeEingabenLiefernNichts() {
        let quelle = rasterbild(breite: 64, hoehe: 64)
        XCTAssertNil(Logoskalierung.anzeigebild(aus: quelle, kante: 0, skala: 1))
        XCTAssertNil(Logoskalierung.anzeigebild(aus: NSImage(), kante: 20, skala: 1),
                     "ein Bild ohne Ausdehnung hat keine Zielform")
    }
}
