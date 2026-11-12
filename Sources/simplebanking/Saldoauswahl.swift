import Foundation
import RoutexModels

/// Welcher der gelieferten Salden angezeigt wird.
///
/// **Warum es diese Datei gibt.** Bis zum 21.10.2026 nahm die App den ersten Eintrag mit
/// `balanceType == .booked`, sonst den ersten `.available` — ohne je auf ein Datum zu
/// schauen. Begründet war das damit, dass `Available` bei manchen Banken die Dispo-Linie
/// enthält und als „Kontostand" irreführend wäre.
///
/// Gemeldet am 20.10.2026: Bei der Postbank hing der Saldo hinter der Banking-App zurück,
/// obwohl dieselben Buchungen in der Umsatzliste standen und der Abruf erfolgreich war.
/// Die Erklärung kam von YAXI:
///
/// > richtig, neueres Available sollte älteres Booked schlagen. In diesem Fall ist Booked
/// > der Endsaldo des Vortags.
///
/// Die Bank liefert also **einen** `Booked` — den Tagesabschluss von gestern — und daneben
/// ein aktuelleres `Available`. Unsere Regel war für diesen Fall genau verkehrt herum.
///
/// Die Reihenfolge der Einträge ist laut YAXI **nicht zugesichert**; sie darf also nichts
/// entscheiden. Die Dispo-Sorge von früher fängt Stufe 2 ab, nicht die harte Rangfolge.
///
/// Zwei weitere Zusagen aus derselben Antwort: Mehrere `Booked` gibt es **nur** bei
/// unterschiedlichem `creditLimitIncluded` — ein Gleichstand zweier gebuchter Salden ist
/// also immer eine Dispo-Frage und von Stufe 2 erledigt. Und YAXI baut `primaryBalances`
/// in die Pipeline, das dieselbe Regel auf deren Seite abbildet; sobald es da ist, kann
/// diese Datei zur Weiche darauf werden.
enum Saldoauswahl {

    /// Die von YAXI empfohlene Regel, in dieser Reihenfolge:
    ///
    /// 1. nur `Booked` und `Available` betrachten (`Expected` nettet auch eingehende
    ///    Beträge und taugt nicht als Kontostand)
    /// 2. `creditLimitIncluded != true` bevorzugen — ein Betrag mit eingerechneter
    ///    Dispo-Linie ist kein Kontostand
    /// 3. einen Stand bevorzugen, der nicht in der Zukunft liegt
    /// 4. den jüngsten `dateTime` wählen
    /// 5. bei Gleichstand `Booked` bevorzugen
    ///
    /// **Ein zukunftsdatierter Stand wird nachgeordnet, nicht verworfen.** Bis zum
    /// 06.11.2026 flog er heraus, und das war an echten Daten falsch: Die ING stempelt
    /// ihren Saldo mit **Ortszeit und kennzeichnet ihn als UTC** — gemessen am selben Tag,
    /// Protokollzeile um 18:00:04 UTC, `dateTime` 19:00:04Z, also genau eine Stunde
    /// voraus. Es war ihr einziger Saldo. Verworfen hieß: kein Kontostand, nur noch eine
    /// Meldung — schlimmer als die Zahl, um die es ging.
    ///
    /// Dass es bis dahin niemandem auffiel, lag an einem `?? allBalances.first` beim
    /// Aufrufer, das jeden verworfenen Saldo doch noch durchließ, und zwar nach
    /// Feldreihenfolge. Diese Hintertür ist zu; dafür muss die Regel selbst tragen.
    static func waehle(aus salden: [Balance], jetzt: Date = Date()) -> Balance? {
        // Stufe 1. Mehr schließt hier nichts aus — was die Bank liefert, soll nicht an
        // einer Uhr scheitern, die um eine Zeitzone verstellt ist.
        let infrage = salden.filter {
            $0.balanceType == .booked || $0.balanceType == .available
        }
        guard !infrage.isEmpty else { return nil }

        // Die drei verbleibenden Stufen als eine Ordnung. `sorted` ist hier richtig und
        // nicht `max(by:)`: Die Regel ist eine Rangfolge mit Gleichständen, und die soll
        // man beim Lesen als solche erkennen.
        return infrage.min { links, rechts in
            // Stufe 2 — ohne eingerechnete Dispo-Linie zuerst.
            let linksOhneDispo = links.creditLimitIncluded != true
            let rechtsOhneDispo = rechts.creditLimitIncluded != true
            if linksOhneDispo != rechtsOhneDispo { return linksOhneDispo }

            // Stufe 3 — ein Stand aus der Gegenwart schlägt einen aus der Zukunft. Erst
            // hier, nicht als Ausschluss: Eine Vorausberechnung der Bank taugt nicht als
            // Kontostand, eine um eine Stunde verstellte Uhr macht den Betrag aber nicht
            // falsch. Steht nur Zukunft zur Wahl, ist sie besser als nichts.
            let linksZukunft = links.dateTime.map { $0 > jetzt } ?? false
            let rechtsZukunft = rechts.dateTime.map { $0 > jetzt } ?? false
            if linksZukunft != rechtsZukunft { return rechtsZukunft }

            // Stufe 4 — jüngerer Stand zuerst. Ein Eintrag ohne Datum lässt sich nicht
            // einordnen und landet hinter jedem datierten; ganz verwerfen wäre falsch,
            // denn manche Banken liefern gar kein Datum, und dann ist er alles, was da ist.
            switch (links.dateTime, rechts.dateTime) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?):                 return false
            case (_?, nil):                 return true
            default:                        break
            }

            // Stufe 5 — bei Gleichstand der gebuchte Saldo.
            if links.balanceType != rechts.balanceType {
                return links.balanceType == .booked
            }
            return false
        }
    }
}
