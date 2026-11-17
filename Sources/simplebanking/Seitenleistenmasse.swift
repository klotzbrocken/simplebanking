import CoreGraphics
import Foundation

// MARK: - Seitenleiste: Maße und Regeln
//
// Die Rechenarbeit der Seitenleiste steht hier und nicht im Fenster: Sie lässt sich so
// ohne Oberfläche prüfen (`SeitenleisteTests`).
//
// **Jeder Knopf tut eine Sache.** Das Umsatzfenster hat zwei feste Breiten, 348 und 840,
// und der grüne Ampelknopf schaltet zwischen ihnen; Ziehen am Rand ist gesperrt
// (`windowWillResize`). Die Leiste liegt quer dazu: Sie legt 230 pt vor den Inhalt, ohne
// dessen Breite anzufassen. Vier Breiten also, 348, 578, 840, 1070. Die Leiste an den
// breiten Zustand zu koppeln wäre ein Fall weniger gewesen, hätte aber einen Knopf
// gebraucht, der 348 auf 1070 springen lässt, und einen zweiten, der die Leiste
// ungefragt wieder schließt.
enum Seitenleiste {

    /// Breite der Leiste. Richtwert aus dem Konzept, nicht durch Ziehen änderbar.
    static let breite: CGFloat = 230

    /// Klickfläche des Knopfs in der Titelleiste und sein Abstand zur Ampel.
    static let knopfBreite: CGFloat = 30
    static let knopfHoehe: CGFloat = 24
    static let knopfAbstand: CGFloat = 14
    /// Luft links im Klickfeld, zwischen Feldkante und Zeichen. Der Abstand zur Ampel
    /// soll für das **Zeichen** gelten, nicht für die unsichtbare Fläche darum.
    static let knopfInnenrand: CGFloat = 7

    /// Was die drei Ampelknöpfe links belegen, bis der eigene Knopf anfängt. AppKit
    /// entscheidet ihre Breite; 78 ist der gemessene Wert, den auch `Umsatzfenster`
    /// als Rückfall nimmt.
    static let ampelBreite: CGFloat = 78

    /// Wo die Ampel sitzt, von AppKit erfragt statt geraten.
    ///
    /// Der Knopf soll auf einer Linie mit den drei Punkten liegen. Deren Lage hängt an
    /// der Fensterart und an macOS, also kommt sie aus dem Fenster und nicht aus einer
    /// Zahl in einer Ansicht. `mitteVonOben` ist der Abstand von der Fensteroberkante
    /// zur Mitte der Punkte.
    struct Ampelmasse: Equatable {
        var rechterRand: CGFloat = Seitenleiste.ampelBreite
        var mitteVonOben: CGFloat = 20
    }

    /// Gibt es die Leiste in diesem Zustand?
    ///
    /// Nur im breiten Fenster. Schmal ist der Schnellblick, den ein Doppelklick auf das
    /// Menüleistensymbol öffnet; 230 pt Navigation davor ließen von der Liste zu wenig
    /// übrig. Der Knopf erscheint dort deshalb gar nicht erst.
    static func moeglich(breit: Bool) -> Bool { breit }

    /// Breiteste Fassung des Fensters: breit plus Leiste.
    static var maxFensterbreite: CGFloat { TransactionsPanel.wideWidth + breite }

    /// Die Fensterbreite, die zu diesem Zustand gehört.
    static func fensterbreite(offen: Bool, breit: Bool) -> CGFloat {
        let inhalt = breit ? TransactionsPanel.wideWidth : TransactionsPanel.narrowWidth
        return offen ? inhalt + breite : inhalt
    }

    /// Ist der Inhalt breit? Rechnet die Leiste heraus, bevor sie vergleicht.
    ///
    /// Ohne das Herausrechnen hielte ein schmales Fenster mit Leiste (578) sich für breit,
    /// und der grüne Knopf schaltete in die falsche Richtung.
    static func istBreit(fensterbreite: CGFloat, offen: Bool) -> Bool {
        let inhalt = fensterbreite - (offen ? breite : 0)
        return inhalt > (TransactionsPanel.narrowWidth + TransactionsPanel.wideWidth) / 2
    }

    /// Der neue Fensterrahmen für eine geänderte Breite.
    ///
    /// Das Fenster wächst **nach links**, damit der Inhalt rechts an seiner Stelle bleibt:
    /// Saldo, Liste und Fußzeile springen beim Einblenden nicht unter dem Mauszeiger weg.
    /// Reicht der Platz links nicht, wächst es nach rechts; passt es gar nicht, klebt es
    /// am linken Rand. `sichtbar` ist `screen.visibleFrame`.
    static func rahmen(aktuell: CGRect, sichtbar: CGRect, zielbreite: CGFloat) -> CGRect {
        var neu = aktuell
        neu.size.width = zielbreite
        neu.origin.x = aktuell.maxX - zielbreite
        if neu.maxX > sichtbar.maxX { neu.origin.x = sichtbar.maxX - zielbreite }
        if neu.origin.x < sichtbar.minX { neu.origin.x = sichtbar.minX }
        return neu
    }
}

// MARK: - Wo eine Auswertung erscheint

/// Was im Inhaltsbereich des Umsatzfensters steht.
enum Hauptansicht: Equatable {
    case umsaetze
    case auswertung(DashboardTab)
    case senden(Sendeart)
}

/// Die drei Wege zum Geldsenden, wie sie in der Seitenleiste stehen.
///
/// Es sind keine drei Formulare: „Termin" ist dieselbe Überweisung mit offenem
/// Terminwähler, und eine Vorlage füllt sie aus. Drei Einträge, weil das die drei
/// Absichten sind, mit denen jemand hierherkommt.
enum Sendeart: String, CaseIterable, Identifiable, Equatable {
    case ueberweisung
    case termin
    case vorlagen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ueberweisung: return L10n.t("Überweisung", "Transfer")
        case .termin:       return L10n.t("Terminüberweisung", "Scheduled transfer")
        case .vorlagen:     return L10n.t("Vorlagen", "Templates")
        }
    }

    var icon: String {
        switch self {
        case .ueberweisung: return "paperplane"
        case .termin:       return "calendar.badge.clock"
        case .vorlagen:     return "star"
        }
    }
}

enum AuswertungsPlatz: Equatable {
    /// Umsätze sichtbar, keine Auswertung offen.
    case keiner
    case eigenesFenster(DashboardTab)
    case eingebettet(DashboardTab)
}

extension Seitenleiste {

    /// Die einzige Stelle, die entscheidet, **wo** eine Auswertung erscheint.
    ///
    /// Ohne Seitenleiste bleibt es beim Dashboard-Fenster, mit Seitenleiste erscheint die
    /// Auswertung rechts daneben. Zwei getrennte Abläufe dafür zu bauen hieße, jeden
    /// Übergang zweimal zu pflegen.
    ///
    /// Gefragt wird **beim Öffnen**. Eine laufende Ansicht wandert nicht von selbst: Das
    /// Ein- und Ausblenden der Leiste würde sonst ein Fenster schließen, das jemand
    /// bewusst dorthin gelegt hat. Für den Wechsel gibt es zwei sichtbare Knöpfe.
    static func auswertungsPlatz(seitenleisteOffen: Bool, ansicht: Hauptansicht) -> AuswertungsPlatz {
        guard case .auswertung(let art) = ansicht else { return .keiner }
        return seitenleisteOffen ? .eingebettet(art) : .eigenesFenster(art)
    }
}
