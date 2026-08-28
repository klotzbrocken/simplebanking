import CoreGraphics

// MARK: - Maße der Konto-Umschalter
//
// Die Kontoauswahl gibt es zweimal: im Flyout (`FlyoutSlotSegmentedControl`) und über der
// Umsatzliste (`accountDotsBar`). Die beiden teilen sich keinen Code — sie sitzen in
// verschiedenen Dateien und haben verschiedene Datenquellen —, sollen aber gleich
// aussehen. Bisher wurden die Maße an beiden Stellen einzeln gepflegt, und sie liefen
// auseinander (16 pt gegen 15 pt bei denselben Kacheln).
//
// **Der Bankname steht in beiden Flächen nicht mehr an der Kachel.** Er erscheint ohnehin
// darüber neben der Uhrzeit („Sparkasse · 17 Uhr") und ist dort die verlässlichere Quelle;
// an der Kachel kostete er nur Platz, der bei mehreren Konten fehlt. Erkennbar bleibt das
// aktive Konto an Größe, voller Sättigung und Ring.
enum KontoKachel {
    /// Aktives Konto — größer und voll gesättigt.
    ///
    /// **Kein Rahmen.** Ein Ring um die Kachel trennt die Marke von der Fläche und wirkt
    /// wie ein Bedienelement; Größe und Sättigung genügen zur Unterscheidung.
    static let aktivKante: CGFloat = 30
    static let aktivLogo: CGFloat = 20

    /// Weitere Konten — kleiner und gedämpft.
    static let inaktivKante: CGFloat = 26
    static let inaktivLogo: CGFloat = 16
    static let inaktivDeckkraft: Double = 0.42

    /// Abstand zwischen den Kacheln.
    static let abstand: CGFloat = 10
}
