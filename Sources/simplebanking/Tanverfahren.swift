import Foundation

// MARK: - Welches TAN-Verfahren die Bank nehmen soll
//
// Fragt die Bank in der Freigabe nach dem Verfahren (`.selection`), antwortete die App
// bis 2.1.0 immer selbst: der erste Eintrag, in dem „push", „app" oder „decoupled"
// vorkommt, sonst der erste überhaupt. Der Nutzer hatte keine Wahl — wer pushTAN
// registriert hat, aber am Schreibtisch sitzt und chipTAN benutzen will, bekam trotzdem
// pushTAN, und zwar jedes Mal. Greift kein Stichwort, entscheidet die Reihenfolge der
// Bank, also nichts.
//
// Jetzt gilt: Was unter Einstellungen → Konten hinterlegt ist, hat Vorrang; nur ohne
// Hinterlegung rät die App weiter wie bisher. Die Vorgabe bleibt also unverändert, und
// niemand muss etwas einstellen, damit es weiter funktioniert.
//
// **Der Schlüssel allein trägt nicht.** Welchen `key` eine Bank einem Verfahren gibt,
// ist nirgends zugesichert — nach einem Umbau auf Bankseite kann derselbe „M2" ein
// anderes Verfahren sein oder fehlen. Darum wird beides gemerkt, Schlüssel und
// Beschriftung, und bei fehlendem Schlüssel über die Beschriftung wiedererkannt. Passt
// keines von beidem, fällt die Wahl still auf die Heuristik zurück: Eine Einrichtung,
// die nach einem Bank-Update klemmt, wäre schlimmer als eine, die wieder rät.

enum Tanverfahren {

    /// Ein Verfahren, wie die Bank es anbietet.
    struct Angebot: Equatable {
        let schluessel: String
        let beschriftung: String
        let erklaerung: String?

        init(schluessel: String, beschriftung: String, erklaerung: String? = nil) {
            self.schluessel = schluessel
            self.beschriftung = beschriftung
            self.erklaerung = erklaerung
        }
    }

    /// - Returns: Das zu beantwortende Verfahren, oder `nil`, wenn die Bank keines
    ///   geschickt hat (dann ist die Freigabe nicht fortsetzbar).
    static func wahl(aus angebote: [Angebot],
                     gespeicherterSchluessel: String?,
                     gespeicherterName: String?) -> Angebot? {
        guard !angebote.isEmpty else { return nil }

        if let schluessel = vergleichbar(gespeicherterSchluessel),
           let treffer = angebote.first(where: { vergleichbar($0.schluessel) == schluessel }) {
            return treffer
        }
        if let name = vergleichbar(gespeicherterName),
           let treffer = angebote.first(where: { vergleichbar($0.beschriftung) == name }) {
            return treffer
        }
        return geraten(aus: angebote)
    }

    /// Die Wahl der App, solange der Nutzer keine getroffen hat — unverändert seit 1.x.
    /// Push-/App-Freigabe zuerst, weil sie ohne Lesegerät und ohne Abtippen auskommt.
    static func geraten(aus angebote: [Angebot]) -> Angebot? {
        angebote.first { angebot in
            let text = "\(angebot.schluessel) \(angebot.beschriftung) \(angebot.erklaerung ?? "")".lowercased()
            return text.contains("push") || text.contains("app") || text.contains("decoupled")
        } ?? angebote.first
    }

    /// Reihenfolge für die Einstellungen: nach Beschriftung, weil ein Wörterbuch keine
    /// hat und eine wechselnde Liste in einem Menü unbenutzbar ist.
    static func sortiert(_ angebote: [String: String]) -> [Angebot] {
        angebote.map { Angebot(schluessel: $0.key, beschriftung: $0.value) }
            .sorted { $0.beschriftung.localizedCaseInsensitiveCompare($1.beschriftung) == .orderedAscending }
    }

    private static func vergleichbar(_ roh: String?) -> String? {
        guard let text = roh?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !text.isEmpty else { return nil }
        return text
    }
}
