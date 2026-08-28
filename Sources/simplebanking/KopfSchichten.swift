// MARK: - Suche und Filter im Kopf der Umsatzliste
//
// Beide Schichten sitzen an derselben Stelle: unter der Kontoauswahl, über der Liste.
// Beide gleichzeitig einzublenden schöbe die Buchungen zu weit nach unten — sie schließen
// einander deshalb aus. Die Kategorien-Ansicht ist davon unberührt; sie wirkt in jedem
// Zustand, auch über Suchtreffern und gefilterten Listen.
//
// Als eigener Typ und nicht als drei Zeilen im View: Eine Umschaltregel mit zwei Zuständen
// hat vier Fälle, und die sind ohne Oberfläche prüfbar.
struct KopfSchichten: Equatable {
    var suche: Bool = false
    var filter: Bool = false

    /// Druck auf die Lupe.
    func nachLupe() -> KopfSchichten {
        suche ? KopfSchichten(suche: false, filter: filter)
              : KopfSchichten(suche: true, filter: false)
    }

    /// Druck auf das Filtersymbol.
    func nachFilter() -> KopfSchichten {
        filter ? KopfSchichten(suche: suche, filter: false)
               : KopfSchichten(suche: false, filter: true)
    }

    /// Wird beim Übergang die Suche geschlossen? Dann muss die Eingabe geleert werden —
    /// sonst filterte eine unsichtbare Suche die Liste weiter, und niemand sähe mehr,
    /// warum Buchungen fehlen.
    func schliesstDieSuche(gegenueber vorher: KopfSchichten) -> Bool {
        vorher.suche && !suche
    }
}
