import Foundation

// MARK: - Der Name, den die Bank einem Konto gibt
//
// Die Bank liefert bei der Kontenauswahl einen Namen mit (`displayName`, sonst
// `productName`) — „Girokonto", „S-Vita Basic", „Extra-Konto". Bis 2.1.0 wurde er beim
// Anlegen eines Slots weggeworfen: Das erste Konto hieß nach der Bank, jedes weitere
// trug den Namen im Feld `displayName`, wo eigentlich die Bank stehen muss (die
// Logo-/Markenerkennung geht über diesen Namen). Wer zwei Konten derselben Bank
// verband, sah zwei gleich aussehende Kacheln.
//
// Der Name gehört deshalb in `nickname`: Die ganze App zeigt ohnehin überall
// `nickname ?? displayName` (Kacheln, Kopfzeile, Kontomenü, Regeln, Dashboard), und der
// Nutzer kann ihn in den Einstellungen überschreiben — was bei einem Vorschlag der Bank
// auch der richtige Weg ist.
//
// Reine Funktionen, mit Zeichenketten statt `RoutexModels.Account`: Die Regel ist
// prüfbar, ohne ein SDK-Modell zu bauen.

enum Kontoname {

    /// Der Name für einen **weiteren** Slot derselben Einrichtung.
    ///
    /// Reihenfolge: Anzeigename der Bank, dann Produktname, dann Kontoinhaber. Bleibt
    /// alles leer, entscheiden die letzten vier Stellen der IBAN — zwei Kacheln mit
    /// demselben Banknamen sind nicht auseinanderzuhalten, „…2600" schon.
    static func fuerSlot(anzeigename: String?,
                         produktname: String?,
                         inhaber: String?,
                         iban: String) -> String? {
        for kandidat in [anzeigename, produktname, inhaber] {
            if let name = sauber(kandidat) { return name }
        }
        let kompakt = iban.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return kompakt.count >= 4 ? "…" + kompakt.suffix(4) : nil
    }

    /// Der Name für das **erste** Konto einer Einrichtung.
    ///
    /// - Parameter eingetippt: Was der Nutzer im Assistenten als Kurznamen eingegeben
    ///   hat. Der schlägt alles.
    /// - Parameter weitereKonten: Wie viele Konten sonst noch angelegt werden.
    ///
    /// Bei einem einzigen Konto bleibt es beim Banknamen (`nil`): In der Kopfzeile und
    /// in der Menüleiste sagt „Sparkasse Siegen" mehr als „Girokonto" — der Nutzer weiß,
    /// welches seiner Konten er verbunden hat, aber nicht unbedingt, welche Bank die App
    /// gerade zeigt. Erst sobald mehrere Konten nebeneinander stehen, braucht jedes
    /// seinen eigenen Namen.
    static func fuerErstenSlot(eingetippt: String?,
                               weitereKonten: Int,
                               anzeigename: String?,
                               produktname: String?,
                               inhaber: String?,
                               iban: String) -> String? {
        if let eigener = sauber(eingetippt) { return eigener }
        guard weitereKonten > 0 else { return nil }
        return fuerSlot(anzeigename: anzeigename, produktname: produktname,
                        inhaber: inhaber, iban: iban)
    }

    /// Wie das Konto im Fortschritt der Einrichtung genannt wird.
    ///
    /// Anders als `fuerErstenSlot`: Hier zählt nur, ob ein Name vorliegt. Der Satz
    /// „Kontostand wird abgerufen — Girokonto" trägt auch bei einem einzigen Konto,
    /// weil er sagt, worauf gewartet wird. Die IBAN-Notlösung gehört nicht hierher,
    /// „…2600" erklärt in einem Wartetext nichts.
    static func fuerFortschritt(anzeigename: String?, produktname: String?) -> String? {
        sauber(anzeigename) ?? sauber(produktname)
    }

    private static func sauber(_ roh: String?) -> String? {
        guard let text = roh?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
