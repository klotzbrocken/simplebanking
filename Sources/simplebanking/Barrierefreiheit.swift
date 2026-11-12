import Foundation
import SwiftUI

// MARK: - Was VoiceOver vorliest
//
// Der Titel in der Menüleiste ist für das Auge geschrieben: „— €", „…", „•.••• €", ein
// Emoji, eine nackte Zahl. Eine Beschriftung hat er nie bekommen — in 67.000 Zeilen
// Quelltext gab es bis 2.1.0 genau elf Accessibility-Aufrufe —, also las VoiceOver vor,
// was gerade im `attributedTitle` stand. Bei einem ausgeblendeten Kontostand sind das
// drei Punkte.
//
// Die Umwandlung steht als reine Funktion hier, nicht an den vierzehn Stellen, die den
// Titel schreiben. Der Grund ist derselbe wie bei `Saldoalter`: Zwei Stellen mit je
// eigener Schreibweise sind genau, wie Fehler dieser Art entstehen.

enum Vorlesetext {

    /// Die Beschriftung des Menüleisten-Symbols zum sichtbaren Titel.
    ///
    /// Beginnt immer mit dem Programmnamen: In der Menüleiste stehen ein Dutzend Symbole
    /// nebeneinander, und „1.234,56 Euro" allein sagt nicht, von wem.
    ///
    /// - Parameter zusatz: Ersetzt den abgeleiteten Teil. Nötig dort, wo der sichtbare
    ///   Titel seine Bedeutung nicht trägt — „TAN", das Schloss-Zeichen.
    static func leiste(_ titel: String, zusatz: String? = nil) -> String {
        let name = "simplebanking"
        guard let teil = zusatz ?? abgeleitet(titel) else { return name }
        return "\(name), \(teil)"
    }

    /// Ein Betrag, wie er in Flyout, Widget und Karte steht, in vorlesbarer Form.
    ///
    /// Dieselbe Umwandlung wie in der Leiste, nur ohne den Programmnamen davor — im
    /// Flyout weiß der Nutzer, in welchem Fenster er steht. Trägt der Text keine
    /// Sonderform (also einen echten Betrag), bleibt er, wie er ist: „1.234,56 €" liest
    /// VoiceOver von sich aus richtig vor.
    static func betrag(_ titel: String) -> String { abgeleitet(titel) ?? titel }

    /// Der Teil hinter dem Programmnamen, aus dem sichtbaren Titel geschlossen.
    ///
    /// `nil` heißt: Der Titel trägt keine Aussage, die vorzulesen wäre — im
    /// Flyout-Modus steht dort nur das Banklogo, ein Emoji oder ein einzelnes „€".
    ///
    /// **Der ausgeblendete Saldo wird nie vorgelesen.** Wer ihn ausblendet, tut das, weil
    /// jemand mitsehen könnte — Sprache ist genauso mithörbar. Die Maske als „Punkt Punkt
    /// Punkt" vorzulesen wäre nur die unbrauchbare Fassung derselben Preisgabe.
    private static func abgeleitet(_ titel: String) -> String? {
        // Emoji raus: Das Stimmungszeichen ist Beiwerk vor dem Betrag, und
        // „leicht lächelndes Gesicht 1.234,56 Euro" ist keine Auskunft. Die
        // Emoji-*Darstellung* prüfen, nicht `isEmoji` — Ziffern erfüllen letzteres.
        let text = String(String.UnicodeScalarView(
            titel.unicodeScalars.filter { !$0.properties.isEmojiPresentation }
        )).trimmingCharacters(in: .whitespacesAndNewlines)

        if text.contains("•") { return L10n.t("Kontostand ausgeblendet", "balance hidden") }
        if text.contains("—") || text.contains("--") {
            return L10n.t("kein Kontostand abgerufen", "no balance fetched")
        }
        // „…" und „Lädt…" meinen dasselbe; das eine ist die kurze Fassung für die
        // schmale Leiste.
        if text == "…" || text.hasPrefix("Lädt") || text.hasPrefix("Loading") {
            return L10n.t("lädt", "loading")
        }
        // Ein Betrag bekommt „Kontostand" davor, damit die Zahl einen Bezug hat.
        if text.contains(where: \.isNumber) { return L10n.t("Kontostand ", "balance ") + text }
        // Ein Wort trägt sich selbst — „Verbinden…", „Gesperrt".
        if text.contains(where: \.isLetter) { return text }
        return nil
    }
}

// MARK: - Beschriftung für Symbol-Bedienelemente
//
// Fast jedes Symbol-Bedienelement in dieser App trug schon ein `.help(…)` mit genau dem
// Satz, den eine Beschriftung braucht — er kam bei VoiceOver nur nicht an: Ein
// `.help` wird zu AXHelp, und AXHelp liest VoiceOver erst auf Nachfrage vor, nicht als
// Namen des Elements. Ein Knopf ohne Namen heißt „Taste".
//
// Darum ein Modifikator statt 25 Paare aus `.help` und `.accessibilityLabel`: Zwei
// Zeilen pro Bedienelement, die dasselbe sagen müssen, ist genau die Form, in der eine
// davon beim nächsten Mal fehlt.

extension View {

    /// Kurzhilfe und VoiceOver-Beschriftung aus einem Text.
    ///
    /// - Parameter text: Wie das Bedienelement **heißt** — „Filter", „Einstellungen".
    ///   Kein Satz darüber, was ein Tippen tut; das gehört in `hinweis`.
    /// - Parameter wert: Was es gerade *zeigt* und der Name nicht nennt — die Zahl im
    ///   Abzeichen, der laufende Zeitraum eines Umschalters.
    /// - Parameter hinweis: Die ausführliche Fassung für die Kurzhilfe am Mauszeiger,
    ///   wenn sie mehr sagt als der Name. VoiceOver liest sie auf Nachfrage.
    /// - Parameter aktiv: Eingeschaltet oder ausgewählt. VoiceOver sagt dann
    ///   „ausgewählt" — bisher trug das allein die Farbe.
    func beschriftet(_ text: String, wert: String? = nil,
                     hinweis: String? = nil, aktiv: Bool = false) -> some View {
        // Alle Zusätze unbedingt, damit der Rückgabetyp einer bleibt: Ein leerer Wert
        // wird nicht vorgelesen, ein leeres Merkmal ist keins.
        self.help(hinweis ?? text)
            .accessibilityLabel(Text(text))
            .accessibilityValue(Text(wert ?? ""))
            .accessibilityHint(Text(hinweis ?? ""))
            .accessibilityAddTraits(aktiv ? [.isSelected] : [])
    }

    /// Nur Kurzhilfe und Hinweis — für ein Bedienelement, das seinen Namen schon
    /// sichtbar trägt.
    ///
    /// Eine Beschriftung wäre hier schädlich: Sie **ersetzt** den Text des Elements, und
    /// aus „Oktober" würde „Filter aufheben".
    func hinweis(_ text: String) -> some View {
        self.help(text).accessibilityHint(Text(text))
    }
}
