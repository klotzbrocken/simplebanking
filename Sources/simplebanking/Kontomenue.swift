import Foundation

// MARK: - Kontowechsel im Statusmenü
//
// Bis 2.1.0 gab es **keinen** Weg, das Konto zu wechseln, außer die Kacheln im Flyout
// anzuklicken. Wer mehr Konten hat, als dort nebeneinander passen, kam an die übrigen
// nicht heran: Die Reihe wurde abgeschnitten (siehe `Kachelreihe`), und die ←/→-Tasten
// sind nur im Modus „Zentriert anzeigen (Halten)" belegt. Gemeldet am 04.11.2026 von
// einem Nutzer mit zehn Konten und einer Magic Mouse, mit der sich nicht quer scrollen
// ließ.
//
// Das Menü ist deshalb kein Beiwerk zur scrollbaren Reihe, sondern der Weg, der ohne
// Geste und ohne Tastenkürzel auskommt — und der einzige, der auch dann noch trägt,
// wenn jemand fünfzig Konten anlegt.
//
// Die Liste entsteht als reine Funktion: `NSMenu` lässt sich im Test nicht sinnvoll
// aufbauen, die Auswahlregeln schon.

enum Kontomenue {

    /// Ein Eintrag im Untermenü „Konto".
    struct Eintrag: Equatable {
        /// Was dort steht — Spitzname, sonst der Name der Bank.
        let titel: String
        /// Gesetzt bei einem Konto, `nil` bei „Alle Konten".
        let index: Int?
        /// Haken davor.
        let aktiv: Bool

        var istAlle: Bool { index == nil }
    }

    /// Baut die Einträge für das Untermenü.
    ///
    /// - Parameter unified: „Alle Konten" ist gewählt. Dann trägt **kein** einzelnes
    ///   Konto den Haken, auch wenn `activeIndex` weiter auf eines zeigt — der Index
    ///   bleibt beim Umschalten stehen, damit der Rückweg dort landet, wo man herkam.
    static func eintraege(slots: [BankSlot], activeIndex: Int, unified: Bool) -> [Eintrag] {
        var eintraege = slots.enumerated().map { idx, slot in
            Eintrag(titel: beschriftung(slot),
                    index: idx,
                    aktiv: !unified && idx == activeIndex)
        }
        // „Alle Konten" ist eine Übersicht über echte Bankkonten; mit einem davon gibt
        // es nichts zu aggregieren. Dieselbe Schranke wie im Flyout (`canAggregate`).
        let echte = slots.filter { !$0.isReceiptSlot }.count
        if echte > 1 {
            eintraege.append(Eintrag(titel: L10n.t("Alle Konten", "All accounts"),
                                     index: nil,
                                     aktiv: unified))
        }
        return eintraege
    }

    /// Wie die Kachel im Flyout: Spitzname schlägt Banknamen, leer zählt als nicht
    /// gesetzt. Ein Konto ganz ohne Namen bekommt einen Platzhalter statt einer leeren
    /// Zeile — ein unbeschrifteter Menüeintrag ist nicht anklickbar im Wortsinn.
    static func beschriftung(_ slot: BankSlot) -> String {
        if let spitzname = slot.nickname, !spitzname.isEmpty { return spitzname }
        if !slot.displayName.isEmpty { return slot.displayName }
        return L10n.t("Unbenanntes Konto", "Unnamed account")
    }
}
