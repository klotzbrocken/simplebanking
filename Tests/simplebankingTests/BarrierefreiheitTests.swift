import XCTest
import SwiftUI
import AppKit
@testable import simplebanking

// MARK: - Dass die Beschriftungen bleiben, und dass sie nichts verschieben
//
// Thomas Brass hat am 07.11.2026 gemeldet, dass das Menüleisten-Symbol mit VoiceOver
// erreichbar, aber nicht bedienbar ist. Bei der Durchsicht danach: elf
// Accessibility-Aufrufe in 67.000 Zeilen, fast jedes Symbol-Bedienelement mit einem
// `.help(…)`, das genau den Satz trug, den eine Beschriftung braucht — nur kommt ein
// `.help` als AXHelp an und nicht als Name des Elements.
//
// Die Umstellung ist deshalb breit: 25 Aufrufstellen, vier Kontokacheln, zwei
// Wischreihen. Breite Umstellungen zerfallen am Rand — eine neue Zeile mit `.help(…)`
// statt `beschriftet(…)` fällt niemandem auf, weil die Kurzhilfe ja erscheint. Diese
// Tests halten deshalb die Form fest, nicht das Ergebnis: Was kein Typ erzwingt, muss
// gelesen werden.

@MainActor
final class BarrierefreiheitTests: XCTestCase {

    // MARK: - Zusagen am Quelltext

    /// `.help(…)` allein ist der Zustand von vorher. Beide Ansichten gehen über
    /// `beschriftet` / `hinweis`, die den Satz zusätzlich als Namen setzen.
    func testKeinNacktesHelpMehr() throws {
        for name in ["BalanceBar.swift", "TransactionsPanelView.swift"] {
            let quelle = try Quelltext.datei(name)
            XCTAssertFalse(quelle.contains(".help("),
                           "\(name): `.help(` erreicht VoiceOver nicht — `beschriftet` oder `hinweis` nehmen")
        }
    }

    /// Die beiden Wischreihen stehen mit `.opacity(…)` da, auch wenn sie unsichtbar sind —
    /// `.opacity(0)` nimmt ein Element **nicht** aus dem Accessibility-Baum. Ohne diese
    /// zwei Zeilen trifft VoiceOver auf jeder Zeile sechs unsichtbare Knöpfe.
    func testWischknoepfeSindVersteckt() throws {
        let quelle = try Quelltext.datei("TransactionsPanelView.swift")
        XCTAssertTrue(quelle.contains(".accessibilityHidden(offset <= 0)"))
        XCTAssertTrue(quelle.contains(".accessibilityHidden(offset >= 0)"))
        // Und die Wischgeste selbst hat keine Tastaturentsprechung, also stehen dieselben
        // Closures im Aktionsmenü.
        XCTAssertTrue(quelle.contains(".accessibilityAction(named:"))
    }

    /// `onTapGesture` ist für Tastatur und VoiceOver nichts — eine Ansicht mit Tippgeste
    /// ist kein Bedienelement. Die Kontokacheln waren genau das.
    ///
    /// Gezählt statt eingegrenzt: Die drei verbliebenen Stellen sind benannt, jede neue
    /// schlägt hier an. Kommt eine dazu, ist die Frage, ob sie ein `Button` sein muss.
    func testKeineNeuenTippgesten() throws {
        // BalanceBar: nur der Doppelklick auf die Saldo-Karte (`onDoubleTap`).
        let flyout = try Quelltext.datei("BalanceBar.swift")
        XCTAssertEqual(flyout.components(separatedBy: ".onTapGesture").count - 1, 1,
                       "neue Tippgeste in BalanceBar — gehört sie in einen Button?")
        // Umsatzliste: Einfach- und Doppeltippen auf der Zeile (beide zusätzlich als
        // `accessibilityAction`) und das Zurückschnappen einer offenen Wischreihe.
        let liste = try Quelltext.datei("TransactionsPanelView.swift")
        XCTAssertEqual(liste.components(separatedBy: ".onTapGesture").count - 1, 3,
                       "neue Tippgeste in der Umsatzliste — gehört sie in einen Button?")
    }

    /// Die aktive Kachel ist absichtlich ein Knopf mit leerer Handlung: Ein deaktiviertes
    /// Element überspringt VoiceOver, und dann erfährt niemand, welches Konto gewählt ist.
    func testAktiveKachelBleibtEinKnopf() throws {
        let quelle = try Quelltext.datei("BalanceBar.swift")
        XCTAssertTrue(quelle.contains("Button { } label: {"),
                      "die aktive Kachel ist kein Knopf mehr — dann ist die Auswahl wieder nur Farbe")
    }

    // MARK: - Dass das Layout gleich bleibt

    private func groesse<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// Die Kacheln sind nicht umgebaut, sondern umwickelt — `Button { } label: { Kachel }`
    /// mit `.buttonStyle(.plain)`. Dass das maßhaltig ist, ist die ganze Begründung
    /// dieses Vorgehens; ohne sie wäre die Reihe (348 pt breit, ab acht Konten knapp)
    /// neu zu vermessen.
    func test_knopfUmKachel_aendertDieMasseNicht() {
        let kachel = Circle()
            .frame(width: KontoKachel.aktivKante, height: KontoKachel.aktivKante)
            .background(Capsule(style: .continuous).fill(Color.clear))
        let nackt = groesse(kachel)
        let imKnopf = groesse(
            Button { } label: { kachel.contentShape(Capsule()) }.buttonStyle(.plain)
        )
        XCTAssertEqual(nackt.width, imKnopf.width, accuracy: 0.5, "Breite: \(nackt) ≠ \(imKnopf)")
        XCTAssertEqual(nackt.height, imKnopf.height, accuracy: 0.5, "Höhe: \(nackt) ≠ \(imKnopf)")
    }

    /// `beschriftet` hängt vier Modifikatoren an jedes Bedienelement. Keiner davon darf
    /// Platz kosten — sie sitzen an 25 Stellen in zwei Fenstern mit festen Breiten.
    func test_beschriftung_aendertDieMasseNicht() {
        let text = Text("Filter").font(.system(size: 12))
        let nackt = groesse(text)
        let beschriftet = groesse(
            text.beschriftet("Filter", wert: "3", hinweis: "Filter einblenden", aktiv: true)
        )
        XCTAssertEqual(nackt.width, beschriftet.width, accuracy: 0.5)
        XCTAssertEqual(nackt.height, beschriftet.height, accuracy: 0.5)
    }
}
