import AppKit

// MARK: - Das Desktop-Widget verschieben
//
// Gemeldet am 17.11.2026: Einmal abgelegt, ließ sich die Kontostand-Karte auf dem
// Schreibtisch nie wieder verschieben.
//
// Der Grund ist `isMovableByWindowBackground`: Es greift nur, wenn **kein** View den
// `mouseDown` verbraucht. Die Karte verbraucht ihn immer, sie hat einen Doppelklick auf
// die Umsatzliste, Hover für die Steuer-Icons und eine Drop-Zone für Rechnungen. Beim
// Ablegen fiel das nicht auf, weil dort ein eigenes Ziehen läuft
// (`startWidgetDragTracking`), solange die Maustaste noch gedrückt ist.
//
// Also wird dasselbe Ziehen auch später angestoßen, sobald ein Zug über die Schwelle
// geht. Ein einfacher Klick bleibt bei SwiftUI, und das Fenster verbraucht nichts: Es
// sieht die Ereignisse nur an.
enum Widgetzug {

    /// Ab dieser Strecke ist es ein Ziehen und kein Klick. Drei Punkte sind das, was
    /// AppKit selbst für „gewackelt" durchgehen lässt.
    static let schwelle: CGFloat = 3

    static func zieht(von start: NSPoint, nach jetzt: NSPoint) -> Bool {
        abs(jetzt.x - start.x) > schwelle || abs(jetzt.y - start.y) > schwelle
    }

    /// Fasst der Zeiger ein Bedienelement an?
    ///
    /// Dann gehört der Zug ihm: Auf dem Schließen-Knopf ein paar Punkte zu verwackeln
    /// darf den Klick nicht in eine Fensterbewegung verwandeln, und in einem Textfeld
    /// zieht man eine Auswahl auf. Gesucht wird die ganze Kette nach oben, weil SwiftUI
    /// seine Felder in eigene Hüllen packt.
    static func istBedienelement(_ view: NSView?) -> Bool {
        var aktuell = view
        while let v = aktuell {
            if v is NSButton || v is NSTextField || v is NSTextView { return true }
            aktuell = v.superview
        }
        return false
    }
}
