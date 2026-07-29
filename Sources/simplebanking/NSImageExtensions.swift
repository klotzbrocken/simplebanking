import AppKit

extension NSImage {
    func resized(to newSize: NSSize) -> NSImage {
        let img = NSImage(size: newSize)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy, fraction: 1.0)
        img.unlockFocus()
        return img
    }

    /// Beschneidet auf die Fläche mit sichtbarer Deckung und skaliert das Ergebnis
    /// seitenverhältnistreu in eine Box.
    ///
    /// Die Masken aus dem YAXI-Catalog liegen alle in einem quadratischen Feld, füllen
    /// es aber unterschiedlich stark aus: bunqs Schriftzug belegt davon nur ein flaches
    /// Band in der Mitte. Ein stures `resized(to: 16×16)` ließ davon in der Menüleiste
    /// einen rund drei Punkt hohen Streifen übrig. Nach dem Zuschnitt nutzt die Tinte
    /// die verfügbare Höhe aus, und breite Wortmarken wachsen in die Breite statt zu
    /// schrumpfen — gedeckelt durch `maxWidth`, damit die Menüleiste nicht überläuft.
    ///
    /// Bei vollflächigen Logos ohne Rand ist der Zuschnitt ein no-op.
    func trimmedToInk(fittingHeight height: CGFloat,
                      maxWidth: CGFloat,
                      alphaThreshold: UInt8 = 8) -> NSImage {
        let fallback = { self.resized(to: NSSize(width: height, height: height)) }
        guard size.width > 0, size.height > 0, height > 0, maxWidth > 0 else { return fallback() }

        // Auf einem festen Raster abtasten: Die Vorlage ist ein SVG ohne native
        // Pixelgröße, und für die Bounding-Box genügt grobe Auflösung.
        let probe = 128
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: probe, pixelsHigh: probe,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return fallback() }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(x: 0, y: 0, width: CGFloat(probe), height: CGFloat(probe)),
             from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let pixels = rep.bitmapData else { return fallback() }
        let bytesPerRow = rep.bytesPerRow
        let samples = rep.samplesPerPixel
        var minX = probe, minY = probe, maxX = -1, maxY = -1
        for y in 0..<probe {
            let row = pixels + y * bytesPerRow
            for x in 0..<probe where row[x * samples + 3] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        // Vollständig transparent — nichts zuzuschneiden.
        guard maxX >= minX, maxY >= minY else { return fallback() }

        // Bitmap-Zeile 0 liegt oben, der Zeichen-Ursprung unten: y spiegeln.
        let scaleX = size.width / CGFloat(probe)
        let scaleY = size.height / CGFloat(probe)
        let inkWidth = CGFloat(maxX - minX + 1)
        let inkHeight = CGFloat(maxY - minY + 1)
        let source = NSRect(x: CGFloat(minX) * scaleX,
                            y: CGFloat(probe - 1 - maxY) * scaleY,
                            width: inkWidth * scaleX,
                            height: inkHeight * scaleY)

        let ratio = inkWidth / inkHeight
        var targetHeight = height
        var targetWidth = height * ratio
        if targetWidth > maxWidth {
            targetWidth = maxWidth
            targetHeight = maxWidth / ratio
        }

        let out = NSImage(size: NSSize(width: targetWidth, height: targetHeight))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: out.size), from: source,
             operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
    }
}
