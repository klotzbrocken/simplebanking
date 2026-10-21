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
enum Saldoauswahl {

    /// Die von YAXI empfohlene Regel, in dieser Reihenfolge:
    ///
    /// 1. nur `Booked` und `Available` betrachten (`Expected` nettet auch eingehende
    ///    Beträge und taugt nicht als Kontostand)
    /// 2. `creditLimitIncluded != true` bevorzugen — ein Betrag mit eingerechneter
    ///    Dispo-Linie ist kein Kontostand
    /// 3. den jüngsten `dateTime` wählen, der nicht in der Zukunft liegt
    /// 4. bei Gleichstand `Booked` bevorzugen
    static func waehle(aus salden: [Balance], jetzt: Date = Date()) -> Balance? {
        // Stufe 1 und der Zukunfts-Ausschluss aus Stufe 3. Ein Stichdatum in der Zukunft
        // ist entweder eine Vorausberechnung der Bank oder eine verstellte Uhr — als
        // „aktueller Kontostand" taugt es in beiden Fällen nicht.
        let infrage = salden.filter { s in
            guard s.balanceType == .booked || s.balanceType == .available else { return false }
            if let d = s.dateTime, d > jetzt { return false }
            return true
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

            // Stufe 3 — jüngerer Stand zuerst. Ein Eintrag ohne Datum lässt sich nicht
            // einordnen und landet hinter jedem datierten; ganz verwerfen wäre falsch,
            // denn manche Banken liefern gar kein Datum, und dann ist er alles, was da ist.
            switch (links.dateTime, rechts.dateTime) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?):                 return false
            case (_?, nil):                 return true
            default:                        break
            }

            // Stufe 4 — bei Gleichstand der gebuchte Saldo.
            if links.balanceType != rechts.balanceType {
                return links.balanceType == .booked
            }
            return false
        }
    }
}
