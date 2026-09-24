import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Ein Logo in genau der Größe rechnen, in der es gezeichnet wird
//
// Die Umsatzzeile zeigt ein Händlerlogo 20 Punkte breit. Auf einem angeschlossenen
// 1080p-Monitor sind das **20 echte Pixel**; das Bild von logo.dev hat 256. Bis hierher
// hat diese Verkleinerung SwiftUI beim Zeichnen gemacht, mit dem Standardfilter von
// Core Graphics. Bei einem Verhältnis von 12:1 ist das sichtbar: Kanten treppen, und
// Wortmarken (DHL, Uber) zerfallen zu einem Fleck.
//
// Gemessen am 23.09.2026, 256 → 20 Pixel, dasselbe Quellbild:
//
//   Core Graphics (bisher)   Kanten ausgefranst, „DHL" unleserlich
//   Lanczos                  deutlich klarer, „DHL" wieder lesbar
//   Lanczos + leichte Schärfung   am besten, ohne sichtbare Ränder
//
// Deshalb rechnet die App das Anzeigebild jetzt selbst — einmal je Händler und
// Zielgröße, gecacht — und zwar mit Lanczos und einer milden Schärfung. SwiftUI
// zeichnet danach 1:1 und skaliert gar nicht mehr.
//
// Zwei Sonderfälle, die die Sache einfacher machen als sie klingt:
//
//   * **Mitgelieferte SVGs sind Vektoren.** Die werden nicht verkleinert, sondern in der
//     Zielgröße frisch gerastert — schärfer geht nicht.
//   * **Nicht-quadratische Logos** (dm ist 1,45:1) werden eingepasst und zentriert, nicht
//     beschnitten. Das Ergebnis ist immer quadratisch, die Ansicht muss nichts mehr tun.

enum Logoskalierung {

    /// Radius und Stärke der Nachschärfung. Klein gewählt: Sie soll die Kante retten,
    /// die beim Verkleinern weich wird, und keinen Rand um das Logo malen.
    static let schaerfeRadius: Double = 0.6
    static let schaerfeStaerke: Double = 0.55

    /// Ab dieser Verkleinerung lohnt die Nachschärfung. Wird ein Bild kaum kleiner
    /// gemacht (Retina, 256 → 144), ist es ohne sie besser dran.
    static let schaerfeAbFaktor: CGFloat = 2.0

    /// Einer für alle. Ein `CIContext` bringt eine eigene Metal-Queue und eigene Caches
    /// mit; ihn je Logo neu zu bauen hieß beim ersten Start mit leerem Cache, hundert
    /// davon hintereinander anzulegen und wieder wegzuwerfen. Der Kontext ist
    /// threadsicher (Apple dokumentiert das ausdrücklich), gemeinsame Nutzung ist der
    /// vorgesehene Weg.
    static let kontext = CIContext(options: [.useSoftwareRenderer: false])

    /// Zielkantenlänge in echten Pixeln. Eigene Funktion, weil genau hier die Fehler
    /// entstehen: abrunden statt runden ergibt bei 1,5-fachen Bildschirmen ein Pixel
    /// zu wenig und damit wieder eine Skalierung beim Zeichnen.
    static func zielPixel(kante: CGFloat, skala: CGFloat) -> Int {
        max(1, Int((kante * max(skala, 1)).rounded()))
    }

    /// Hat das Bild überhaupt Pixel — oder ist es ein Vektor (mitgeliefertes SVG)?
    static func istRaster(_ image: NSImage) -> Bool {
        image.representations.contains { $0 is NSBitmapImageRep }
    }

    /// Rechnet `quelle` auf ein quadratisches Anzeigebild der Kantenlänge `kante`
    /// (in Punkten) für einen Bildschirm mit `skala` (1, 2 oder 3).
    ///
    /// Das Ergebnis hat `size == kante × kante` und genau `kante × skala` Pixel je
    /// Seite. Damit zeichnet SwiftUI es ohne weitere Skalierung.
    static func anzeigebild(aus quelle: NSImage, kante: CGFloat, skala: CGFloat) -> NSImage? {
        let px = zielPixel(kante: kante, skala: skala)
        guard px > 0, kante > 0 else { return nil }

        // Seitenverhältnis der Quelle — `size` ist bei Vektoren die einzige Angabe.
        let qGroesse = quelle.size
        guard qGroesse.width > 0, qGroesse.height > 0 else { return nil }
        let faktor = min(CGFloat(px) / qGroesse.width, CGFloat(px) / qGroesse.height)
        let zielBreite = max(1, Int((qGroesse.width * faktor).rounded()))
        let zielHoehe = max(1, Int((qGroesse.height * faktor).rounded()))
        let x = (px - zielBreite) / 2
        let y = (px - zielHoehe) / 2

        guard let ziel = leereFlaeche(px: px) else { return nil }

        let inhalt = NSRect(x: CGFloat(x), y: CGFloat(y),
                            width: CGFloat(zielBreite), height: CGFloat(zielHoehe))

        if let cg = gerechnetesRaster(quelle, breite: zielBreite, hoehe: zielHoehe) {
            zeichnen(cg, in: inhalt, auf: ziel)
        } else {
            // Vektor (oder ein Bild, das Core Image nicht annimmt): direkt in der
            // Zielgröße rastern. Hier wird nichts verkleinert, sondern neu gezeichnet.
            zeichnenVektor(quelle, in: inhalt, auf: ziel)
        }

        ziel.size = NSSize(width: kante, height: kante)
        let bild = NSImage(size: NSSize(width: kante, height: kante))
        bild.addRepresentation(ziel)
        return bild
    }

    // MARK: - Innereien

    private static func leereFlaeche(px: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil,
                         pixelsWide: px, pixelsHigh: px,
                         bitsPerSample: 8, samplesPerPixel: 4,
                         hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB,
                         bytesPerRow: 0, bitsPerPixel: 0)
    }

    /// Lanczos-Verkleinerung plus milde Schärfung. `nil`, wenn die Quelle kein Raster
    /// ist — dann übernimmt der Vektorweg.
    private static func gerechnetesRaster(_ quelle: NSImage, breite: Int, hoehe: Int) -> CGImage? {
        guard istRaster(quelle),
              let cg = quelle.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let eingang = CIImage(cgImage: cg)
        let faktor = CGFloat(breite) / CGFloat(cg.width)

        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = eingang
        lanczos.scale = Float(faktor)
        lanczos.aspectRatio = Float((CGFloat(hoehe) / CGFloat(cg.height)) / max(faktor, 0.0001))
        guard var bild = lanczos.outputImage else { return nil }

        if faktor <= 1 / schaerfeAbFaktor {
            let schaerfen = CIFilter.unsharpMask()
            schaerfen.inputImage = bild
            schaerfen.radius = Float(schaerfeRadius)
            schaerfen.intensity = Float(schaerfeStaerke)
            if let geschaerft = schaerfen.outputImage { bild = geschaerft }
        }

        // Auf den tatsächlichen Bildausschnitt beschneiden: Lanczos und Unsharp
        // liefern ein Bild mit unendlicher Ausdehnung bzw. weichem Rand.
        let rahmen = CGRect(x: 0, y: 0, width: breite, height: hoehe)
        return kontext.createCGImage(bild.cropped(to: rahmen), from: rahmen)
    }

    private static func zeichnen(_ cg: CGImage, in rahmen: NSRect, auf ziel: NSBitmapImageRep) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: ziel) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.interpolationQuality = .none   // ist bereits in Zielgröße
        ctx.cgContext.draw(cg, in: rahmen)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func zeichnenVektor(_ quelle: NSImage, in rahmen: NSRect, auf ziel: NSBitmapImageRep) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: ziel) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        ctx.shouldAntialias = true
        quelle.draw(in: rahmen,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
}
