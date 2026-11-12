import SwiftUI

// MARK: - Farben der Kategorien

/// Der Farbton einer Kategorie — für die Kapsel in der Umsatzzeile und überall,
/// wo eine Kategorie als Farbe auftritt.
///
/// **Kein Grün, kein Orange, kein Rot.** Die drei gehören der Saldo-Stimmung
/// (MoneyMood) und den Beträgen: Ausgabe rot, Eingang grün. Eine Kapsel in einer
/// dieser Farben läse sich als Warnung, und sie stünde ausgerechnet dort, wo
/// nebenan schon eine Stimmungsfläche liegt. Die Palette hält deshalb gedämpfte
/// kühle und erdige Töne in ähnlicher Sättigung — damit keine Kapsel heraussticht.
///
/// `BTXMosaic.style(for:).hex` ist dafür **nicht** zu gebrauchen: Die Palette
/// enthält Rot und Grün und gehört der BTX-Semigrafik.
enum Kategoriefarbe {

    /// Ein Ton in drei Lesarten: Grundfarbe für die Fläche, dazu je eine Textfarbe
    /// für hellen und dunklen Grund. Beide Textfarben stehen hier und werden nicht
    /// gerechnet — Kontrast ist eine Zusage, keine Formel.
    struct Ton: Equatable, Identifiable, Sendable {
        /// Gespeicherte Kennung. Die Einstellung hält **diesen** Namen und keinen
        /// Hex-Wert: So bleibt die Regel „kein Grün/Orange/Rot" auch dann wahr, wenn
        /// jemand sich eine Farbe aussucht, und ein späterer Feinschliff an der
        /// Palette erreicht alle, die sie gewählt haben.
        let id: String
        let bezeichnung: String
        let hell: String        // Grundfarbe
        let text: String        // Textfarbe auf hellem Grund
        let textDunkel: String  // Textfarbe auf dunklem Grund
    }

    static let petrol   = Ton(id: "petrol",   bezeichnung: "Petrol",   hell: "#2B8A99", text: "#19606B", textDunkel: "#7CC6D1")
    static let indigo   = Ton(id: "indigo",   bezeichnung: "Indigo",   hell: "#5865B8", text: "#434E99", textDunkel: "#A3ACE6")
    static let beere    = Ton(id: "beere",    bezeichnung: "Beere",    hell: "#A9558A", text: "#8A3B6C", textDunkel: "#DDA0C6")
    static let taupe    = Ton(id: "taupe",    bezeichnung: "Taupe",    hell: "#8A7C70", text: "#595048", textDunkel: "#CBBFB4")
    static let violett  = Ton(id: "violett",  bezeichnung: "Violett",  hell: "#7E62B5", text: "#634A96", textDunkel: "#C2AEE6")
    static let ozean    = Ton(id: "ozean",    bezeichnung: "Ozean",    hell: "#3C7BB0", text: "#2C5F8A", textDunkel: "#93BFE3")
    static let pflaume  = Ton(id: "pflaume",  bezeichnung: "Pflaume",  hell: "#8A5A7A", text: "#6E4461", textDunkel: "#CFA6C2")
    static let schiefer = Ton(id: "schiefer", bezeichnung: "Schiefer", hell: "#5E6E7E", text: "#495663", textDunkel: "#B4C0CC")
    static let neutral  = Ton(id: "neutral",  bezeichnung: "Neutral",  hell: "#7A807C", text: "#545955", textDunkel: "#B8BDB9")

    /// Was in der Auswahl steht, in dieser Reihenfolge.
    static let palette: [Ton] = [petrol, ozean, indigo, violett, beere, pflaume,
                                 taupe, schiefer, neutral]

    /// Töne, unter denen eine eigene Kategorie automatisch einen bekommt. Ohne
    /// `neutral`: Das ist die Farbe für „keine Aussage", nicht eine unter neun.
    static let rotation: [Ton] = [petrol, indigo, beere, taupe, violett, ozean,
                                  pflaume, schiefer]

    static func ton(mitKennung kennung: String?) -> Ton? {
        guard let kennung else { return nil }
        return palette.first { $0.id == kennung }
    }

    // MARK: - Welche Kategorie welchen Ton trägt

    /// Erst die Wahl des Nutzers, sonst die Vorgabe.
    static func ton(fuer kategorie: TransactionCategory) -> Ton {
        ton(mitKennung: Eigenkategorien.farbe(fuer: kategorie)) ?? vorgabe(fuer: kategorie)
    }

    /// Die werkseitige Zuordnung.
    ///
    /// Benachbarte Kategorien unterscheiden sich auch in der Helligkeit, nicht nur im
    /// Farbton — zwei gleich helle Kapseln nebeneinander sind bei Farbfehlsichtigkeit
    /// nicht zu trennen. Einkommen, Gehalt, Umbuchungen und Sonstiges bleiben
    /// `neutral`: Das sind keine Ausgabenarten, und eine Farbe behauptete dort eine
    /// Einordnung, die es nicht gibt. Sparen gehört dazu — eine Umbuchung auf das
    /// eigene Konto ist kein Verbrauch.
    ///
    /// Neun Ausgabenarten auf acht Tönen: **ein Doppel ist unvermeidlich.** Es liegt
    /// auf Essen und Mobilität, weil die beiden sich in der Zeile ohnehin durch
    /// Symbol und Händler unterscheiden; auf den vier Paaren, die `KategoriefarbeTests`
    /// als „stehen oft nebeneinander" festhält, liegt keines.
    static func vorgabe(fuer kategorie: TransactionCategory) -> Ton {
        switch kategorie {
        case .essenAlltag:    return petrol
        case .gastronomie:    return taupe
        case .wohnenKredit:   return indigo
        case .abosDigital:    return schiefer
        case .versicherungen: return ozean
        case .freizeit:       return beere
        case .shopping:       return violett
        case .gesundheit:     return pflaume
        case .mobilitaet:     return petrol
        case .sparen:         return neutral
        case .einkommen, .gehalt, .umbuchung, .sonstiges:
            return neutral
        default:
            return rotation[stabilerIndex(kategorie.rawValue, anzahl: rotation.count)]
        }
    }

    /// Deterministisch über Programmstarts hinweg.
    ///
    /// **Nicht** `hashValue`: Swift salzt den Hash je Prozess, und die Farbe einer
    /// eigenen Kategorie wechselte bei jedem Start. FNV-1a, 32 Bit.
    static func stabilerIndex(_ text: String, anzahl: Int) -> Int {
        guard anzahl > 0 else { return 0 }
        var h: UInt32 = 2166136261
        for b in text.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % UInt32(anzahl))
    }
}

// MARK: - Als SwiftUI-Farben

extension Kategoriefarbe.Ton {
    var grundfarbe: Color { Color(nsColor: AppTheme.color(from: hell, fallback: .secondaryLabelColor)) }

    /// Ein Scheibchen als Bild — für Menüeinträge.
    ///
    /// Ein SF-Symbol scheidet dort aus: Menüs zeichnen Symbolbilder als Schablone,
    /// also einfarbig, und eine Farbwahl ohne Farbe ist keine. Ein eigenes Bild mit
    /// `isTemplate = false` kommt in seiner Farbe durch.
    ///
    /// Die laufende Wahl trägt einen **Ring** und keinen Haken: Der Haken gehört dem
    /// Umschalter, und ein Umschalter im Menü reicht sein Bild nicht durch —
    /// gemessen am 12.11.2026, die Plättchen fehlten.
    func plaettchen(gewaehlt: Bool = false) -> NSImage {
        let kante: CGFloat = 14
        let bild = NSImage(size: NSSize(width: kante, height: kante), flipped: false) { flaeche in
            let farbe = AppTheme.color(from: self.hell, fallback: .secondaryLabelColor)
            farbe.setFill()
            farbe.setStroke()
            if gewaehlt {
                let ring = NSBezierPath(ovalIn: flaeche.insetBy(dx: 1.25, dy: 1.25))
                ring.lineWidth = 1.5
                ring.stroke()
                NSBezierPath(ovalIn: flaeche.insetBy(dx: 4.5, dy: 4.5)).fill()
            } else {
                NSBezierPath(ovalIn: flaeche.insetBy(dx: 1.25, dy: 1.25)).fill()
            }
            return true
        }
        bild.isTemplate = false
        return bild
    }

    func schrift(dunkel: Bool) -> Color {
        Color(nsColor: AppTheme.color(from: dunkel ? textDunkel : text,
                                      fallback: .secondaryLabelColor))
    }
}
