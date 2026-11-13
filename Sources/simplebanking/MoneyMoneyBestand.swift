import Foundation
import MoneyMoneyForm

// MARK: - Umstieg bei schon eingerichteten Konten
//
// Bis 2.2.0 war der MoneyMoney-Umstieg ausschließlich Teil der Ersteinrichtung
// (`erststart && MoneyMoneyLesepfad.istVorhanden` auf der Willkommensseite). Wer
// simplebanking schon benutzte und erst danach seinen MoneyMoney-Verlauf mitnehmen
// wollte, hatte keinen Weg dorthin — außer alles zu löschen und neu einzurichten.
//
// Die Übernahme selbst kann das längst: `MoneyMoneyNachtrag.alleFaelligen()` sucht den
// Slot über die IBAN und fragt nie, wie er entstanden ist. Gefehlt hat nur der Einstieg.
//
// **Warum eine eigene Aufteilung und nicht `MoneyMoneyAuswahl`.** Die dort fragt für
// jede IBAN bei YAXI nach, ob es überhaupt eine Bankverbindung gibt — nötig im
// Assistenten, weil dort noch kein Konto existiert und die Antwort entscheidet, was
// eingerichtet werden kann. Bei einem Bestandssetup ist diese Frage schon beantwortet:
// Der Slot ist da, die Zustimmung steht, Umsätze liegen in der Datenbank. Die Zuordnung
// läuft deshalb gegen die vorhandenen Slots — das ist die verlässlichere Auskunft und
// braucht **kein Netz**, also auch kein „nicht geprüft".
//
// Konten ohne Slot werden hier abgesagt, nicht in eine Warteschlange gelegt. Der
// Nachtrag könnte einen Eintrag zwar liegen lassen, bis die Bank irgendwann verbunden
// wird — dann läge aber der Auszug (der ganze Umsatzverlauf, 0600) unbefristet neben der
// Datenbank. Der Weg für diese Konten heißt: Bank verbinden, Übernahme erneut starten.

/// Ein MoneyMoney-Konto, zu dem es in simplebanking schon einen Slot gibt.
struct MoneyMoneyBestandstreffer: Hashable {
    let konto: MoneyMoneyKonto
    let slotId: String
    /// Wie das Konto in simplebanking heißt — für die Auswahlliste. Der Nutzer
    /// erkennt sein Konto an dem Namen, den er dort sieht, nicht an der IBAN.
    let slotName: String
}

enum MoneyMoneyBestand {

    /// Teilt einen Auszug in „kann jetzt übernommen werden" und „geht nicht, und zwar
    /// deshalb".
    ///
    /// Rein und ohne Datenbank: Welche Konten das Blatt anbietet, entscheidet darüber,
    /// was ein Umsteiger am Ende bekommt — und die Begründung für die übergangenen
    /// gehört zur Antwort, nicht ins Logbuch.
    ///
    /// Die Reihenfolge der Treffer ist die des Auszugs, damit zwei Läufe dieselbe
    /// Abfolge zeigen.
    static func aufteilen(_ auszug: MoneyMoneyAuszug,
                          slots: [BankSlot]) -> (treffer: [MoneyMoneyBestandstreffer],
                                                 absagen: [MoneyMoneyAbsage]) {
        // eBon-Slots (REWE, dm, Amazon) tragen keine IBAN und keinen Bankverlauf; sie
        // dürfen hier nicht mitsuchen, sonst bekäme ein Konto mit leerer IBAN einen
        // Treffer auf einen leeren Slot-Eintrag.
        var jeIban: [String: BankSlot] = [:]
        for slot in slots where !slot.isReceiptSlot {
            let schluessel = MoneyMoneyVorhaben.normiert(slot.iban)
            guard !schluessel.isEmpty else { continue }
            // Beim ersten bleiben: Zwei Slots mit derselben IBAN sind ein Fehlzustand,
            // und in den Verlauf zweimal zu schreiben wäre schlimmer als einmal.
            if jeIban[schluessel] == nil { jeIban[schluessel] = slot }
        }

        var treffer: [MoneyMoneyBestandstreffer] = []
        var absagen: [MoneyMoneyAbsage] = []

        for konto in auszug.konten {
            guard !konto.istDepot else {
                absagen.append(MoneyMoneyAbsage(konto: konto, grund: .depot))
                continue
            }
            let iban = konto.iban.trimmingCharacters(in: .whitespaces)
            guard MoneyMoneyLeseregeln.istIban(iban) else {
                absagen.append(MoneyMoneyAbsage(konto: konto, grund: .keineIban))
                continue
            }
            guard let slot = jeIban[MoneyMoneyVorhaben.normiert(iban)] else {
                absagen.append(MoneyMoneyAbsage(konto: konto, grund: .nichtVerbunden))
                continue
            }
            treffer.append(MoneyMoneyBestandstreffer(konto: konto,
                                                     slotId: slot.id,
                                                     slotName: anzeigename(slot)))
        }
        return (treffer, absagen)
    }

    /// Derselbe Name, den die Kacheln und die Kopfzeile zeigen: Kurzname zuerst, dann
    /// der Bankname, und erst wenn beides fehlt die IBAN.
    static func anzeigename(_ slot: BankSlot) -> String {
        for kandidat in [slot.nickname, slot.displayName] {
            let sauber = (kandidat ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !sauber.isEmpty { return sauber }
        }
        return slot.iban
    }
}
