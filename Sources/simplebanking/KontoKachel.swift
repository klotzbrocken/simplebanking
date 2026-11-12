import SwiftUI

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

// MARK: - Die Reihe, wenn sie nicht mehr passt
//
// Gemeldet am 04.11.2026 von einem Nutzer mit **zehn** Konten: „Die Reihe an Symbolen
// sprengt die Breite des Fensters und ich kann mit der Magic Mouse nicht links/rechts
// scrollen." Im Flyout bleiben nach Rand, Papierflieger und Abstand 290 pt für die
// Kacheln; gebraucht werden `30 + 36·(n−1) + 36` — **ab acht Konten reicht es nicht**.
//
// Schlimmer als das Fehlende ist, wo es fehlt: Ein überlaufendes `HStack` zentriert
// SwiftUI auf seinem Rahmen, es wird also an **beiden** Enden abgeschnitten, unter
// Umständen auch die aktive Kachel. Und es gab keinen zweiten Weg zu den verdeckten
// Konten — das Statusmenü kannte keinen Kontowechsel (das tut es seit 2.1.0, siehe
// `Kontomenue`), und die ←/→-Tasten sind nur im Modus „Zentriert anzeigen (Halten)"
// belegt.
//
// Der Randverlauf erscheint **nur, wenn wirklich etwas überläuft**. Fest eingebaut
// würde er bei zwei Konten die erste Kachel anknabbern, und das ist der Normalfall.

/// Wer in der Reihe gerade ausgewählt ist — ein Konto oder die Aggregat-Kachel.
enum Kachelkennung: Hashable {
    case konto(Int)
    case alle
}

/// Legt eine Kachelreihe in eine waagerechte Scrollview, blendet die Ränder aus, sobald
/// etwas überläuft, und holt die aktive Kachel in den Blick.
///
/// Gemessen statt gerechnet: Die beiden Aufrufer sitzen in unterschiedlich breiten
/// Fenstern (Flyout fest 348, Umsatzliste 348 **oder** 840), und die BTX-Variante zeigt
/// Text statt Kacheln, dessen Breite von der Schrift abhängt. Eine Formel müsste alle
/// drei Fälle treffen; zwei `GeometryReader` treffen sie von selbst.
struct Kachelreihe: ViewModifier {
    let aktiv: Kachelkennung

    @State private var inhalt: CGFloat = 0
    @State private var sichtbar: CGFloat = 0

    /// Ein halbes Punkt Toleranz: Beide Breiten kommen aus dem Layout und sind
    /// Fließkommazahlen, die bei exakt passendem Inhalt minimal auseinanderliegen können.
    private var laeuftUeber: Bool { sichtbar > 0 && inhalt > sichtbar + 0.5 }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .background(GeometryReader { g in
                        Color.clear.preference(key: Inhaltsbreite.self, value: g.size.width)
                    })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.preference(key: Sichtbreite.self, value: g.size.width)
            })
            .onPreferenceChange(Inhaltsbreite.self) { inhalt = $0 }
            .onPreferenceChange(Sichtbreite.self) { sichtbar = $0 }
            .mask(randverlauf)
            .onChange(of: aktiv) { neu in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(neu, anchor: .center) }
            }
            // Beim Öffnen des Flyouts steht die aktive Kachel sonst außerhalb des
            // Ausschnitts, wenn sie weit hinten liegt — der Nutzer sähe fremde Konten.
            .onAppear { proxy.scrollTo(aktiv, anchor: .center) }
        }
    }

    /// Ohne Überlauf durchgehend deckend — also kein Verlauf. Die Maske bleibt trotzdem
    /// an der Ansicht, statt den Baum zu verzweigen: Ein `if` an dieser Stelle baut die
    /// Scrollview neu auf und wirft dabei die Scrollposition weg.
    private var randverlauf: some View {
        let kante: Color = laeuftUeber ? .clear : .black
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: kante, location: 0.0),
                .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.96),
                .init(color: kante, location: 1.0)
            ]),
            startPoint: .leading,
            endPoint: .trailing)
    }

    private struct Inhaltsbreite: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private struct Sichtbreite: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
}

extension View {
    /// Siehe `Kachelreihe`. Die Kacheln darin brauchen je ein `.id(Kachelkennung…)`,
    /// sonst findet das Nachführen sie nicht.
    func kachelreihe(aktiv: Kachelkennung) -> some View {
        modifier(Kachelreihe(aktiv: aktiv))
    }
}
