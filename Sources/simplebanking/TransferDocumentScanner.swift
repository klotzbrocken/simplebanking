import AppKit
import Foundation
import PDFKit
import Vision

// MARK: - TransferDocumentScanner
//
// Zieht Klartext aus einem gedroppten Dokument (PDF oder Bild), damit
// `TransferClipboardParser` daraus Name/IBAN/Betrag/Verwendungszweck erkennen kann.
//
// Bewusst OHNE externe Abhängigkeit und OHNE Cloud:
//   • PDFKit liefert bei digital erzeugten Rechnungen die **Textebene** direkt —
//     schneller und exakter als OCR. Das ist der bevorzugte Weg.
//   • Nur wenn kein/kaum Text drinsteckt (Scan/Foto), rendern wir die Seite und
//     lassen **Vision** (`VNRecognizeTextRequest`) on-device OCR laufen.
// Beides sind System-Frameworks — kein Netzwerk, keine Entitlement-Änderung; die
// Dokumentinhalte verlassen den Mac nicht.
//
// Kein Logging der Inhalte (Rechnungen sind sensibel).

enum TransferDocumentScanner {

    /// Unterstützte Drop-Typen (Dateiendungen, lowercased).
    static let supportedExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Klartext aus PDF oder Bild. `nil`, wenn nichts Verwertbares gefunden wurde.
    /// Läuft off-main (Rendern + OCR sind teuer).
    static func extractText(from url: URL, maxPages: Int = 3) async -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return await extractFromPDF(url, maxPages: maxPages)
        }
        guard let image = NSImage(contentsOf: url), let cg = cgImage(from: image) else { return nil }
        return await recognizeText(in: cg)
    }

    // MARK: - PDF

    private static func extractFromPDF(_ url: URL, maxPages: Int) async -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let pageCount = min(doc.pageCount, maxPages)
        guard pageCount > 0 else { return nil }

        // 1) Textebene — bei digital erzeugten Rechnungen der beste Treffer.
        var embedded = ""
        for i in 0..<pageCount {
            if let s = doc.page(at: i)?.string { embedded += s + "\n" }
        }
        if hasUsableText(embedded) { return embedded }

        // 2) Fallback: Seiten rendern + Vision-OCR (gescannte/fotografierte Belege).
        var ocr = ""
        for i in 0..<pageCount {
            guard let page = doc.page(at: i), let cg = render(page) else { continue }
            if let text = await recognizeText(in: cg) { ocr += text + "\n" }
        }
        return hasUsableText(ocr) ? ocr : (hasUsableText(embedded) ? embedded : nil)
    }

    /// Genug Substanz, um einen Parse zu versuchen? (Leere Textebenen liefern oft
    /// nur Whitespace/ein paar Steuerzeichen.)
    private static func hasUsableText(_ s: String) -> Bool {
        s.filter { $0.isLetter || $0.isNumber }.count >= 20
    }

    /// Rendert eine PDF-Seite in doppelter Auflösung — deutlich bessere OCR-Trefferquote
    /// als die 1:1-Darstellung.
    private static func render(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 1, size.height > 1 else { return nil }
        let image = page.thumbnail(of: size, for: .mediaBox)
        return cgImage(from: image)
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Vision OCR

    /// On-device Texterkennung (deutsch + englisch, `.accurate`).
    static func recognizeText(in cgImage: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["de-DE", "en-US"]

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
        }
    }
}
