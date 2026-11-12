import AppKit

// MARK: - Doppelklick auf die Titelleiste

/// Wo in der Umsatzliste ein Doppelklick wie ein Doppelklick auf eine Titelleiste wirkt.
///
/// **Warum es die Regel überhaupt braucht.** Das Fenster läuft mit
/// `.fullSizeContentView` und durchsichtiger Titelleiste, damit die Money-Heat bis
/// ganz nach oben reicht. Dadurch liegt die SwiftUI-Fläche **über** AppKits
/// Titelleiste, und der Doppelklick erreicht deren eigene Behandlung nie — gemeldet
/// am 11.11.2026: „Doppelklick oben neben der Ampel vergrößert die Liste nicht."
/// Die Ampel selbst liegt darüber und funktioniert, deshalb fällt es erst hier auf.
///
/// Der Streifen lässt links die Ampel und rechts das Fenster-Chrome (Aktualisieren,
/// Oben halten, Einstellungen) frei. Ein Doppelklick auf einen dieser Knöpfe soll
/// den Knopf auslösen und nicht das Fenster umschalten.
enum Titelleistenzone {

    /// Höhe des Streifens — so hoch wie eine Titelleiste ohne Toolbar.
    static let hoehe: CGFloat = 28

    /// Was das Fenster-Chrome rechts belegt: drei Symbolknöpfe (13 pt, Abstand 15)
    /// plus Rand. Steht hier und nicht im Kopf der Liste, weil es die einzige Stelle
    /// ist, die davon weiß — wächst das Chrome, wächst diese Zahl mit.
    static let chromeBreite: CGFloat = 110

    /// `punkt` in Fensterkoordinaten (Ursprung unten links, wie `locationInWindow`).
    static func istZoomklick(_ punkt: NSPoint, fenster groesse: NSSize,
                             ampelRechts: CGFloat) -> Bool {
        punkt.y > groesse.height - hoehe
            && punkt.x > ampelRechts
            && punkt.x < groesse.width - chromeBreite
    }

    /// Was der Doppelklick auslöst — das, was der Nutzer im System eingestellt hat.
    ///
    /// Ohne diese Abfrage bekäme auch der Zoom, wer „Bewegen in das Dock" gewählt
    /// hat. Der Schlüssel liegt in der globalen Domain, die in der Suchliste von
    /// `UserDefaults.standard` steht; ist er nicht gesetzt, gilt Zoom.
    static func ausfuehren(auf fenster: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": fenster.performMiniaturize(nil)
        case "None":     break
        default:         fenster.performZoom(nil)
        }
    }
}

/// Das Fenster der Umsatzliste. Einziger Zweck der Unterklasse: der Doppelklick oben.
final class Umsatzfenster: NSPanel {

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2,
           Titelleistenzone.istZoomklick(event.locationInWindow, fenster: frame.size,
                                         ampelRechts: ampelRechts) {
            Titelleistenzone.ausfuehren(auf: self)
            return
        }
        super.sendEvent(event)
    }

    /// Rechter Rand der Ampel in Fensterkoordinaten, plus etwas Luft. Gefragt statt
    /// geraten: Wie breit die drei Knöpfe sind, entscheidet AppKit.
    private var ampelRechts: CGFloat {
        guard let knopf = standardWindowButton(.zoomButton) else { return 78 }
        return knopf.convert(knopf.bounds, to: nil).maxX + 8
    }
}
