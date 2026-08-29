import Foundation

// MARK: - Eine Bankfreigabe zur Zeit, und niemand schneidet sie ab
//
// Bei Banken mit Freigabe im Browser (bunq, N26, Revolut) dauert eine Zustimmung so lange,
// wie ein Mensch braucht: Seite öffnet, App der Bank, Bestätigung, zurück. Zwanzig bis
// sechzig Sekunden. In dieser Zeit passierten zwei Dinge, die einander verstärkten:
//
//   1. Jeder weitere Abruf öffnete **eine weitere Freigabe-Seite**. Im Protokoll vom
//      29.08.2026 stehen 44 davon.
//   2. Ein Kontowechsel brach den laufenden Vorgang ab (`switchToSlot` beendet den
//      vorherigen, damit „nur der letzte Klick gewinnt") — die Freigabe kam nie zu Ende,
//      und der nächste Blick auf das Konto fing von vorn an.
//
// Für einen Datenabruf ist Abbrechen richtig. Für eine Bankfreigabe ist es fatal: Sie
// kostet den Nutzer eine echte Handlung, und abgebrochen ist sie verloren.
//
// Diese Wache hält deshalb fest, für welche Konten gerade eine Freigabe aussteht. Sie
// entscheidet nichts über die Freigabe selbst — sie sagt nur, ob schon eine läuft.
actor Freigabewache {

    static let shared = Freigabewache()

    /// Nach dieser Zeit gilt eine Freigabe als verfallen, auch wenn niemand sie beendet
    /// hat. Ohne diese Grenze bliebe ein abgestürzter oder vergessener Vorgang für immer
    /// stehen und das Konto damit dauerhaft blockiert.
    static let hoechstdauer: TimeInterval = 300

    private var offen: [String: Date] = [:]

    /// Beginnt einen Vorgang. `false`, wenn für dieses Konto schon einer läuft — dann darf
    /// **keine zweite Freigabe-Seite** geöffnet werden.
    func beginnen(_ slotId: String, jetzt: Date = Date()) -> Bool {
        aufraeumen(jetzt: jetzt)
        guard offen[slotId] == nil else { return false }
        offen[slotId] = jetzt
        return true
    }

    func beenden(_ slotId: String) {
        offen.removeValue(forKey: slotId)
    }

    func laeuft(_ slotId: String, jetzt: Date = Date()) -> Bool {
        aufraeumen(jetzt: jetzt)
        return offen[slotId] != nil
    }

    /// Läuft irgendwo eine Freigabe? Danach richtet sich, ob ein Kontowechsel den
    /// laufenden Vorgang abbrechen darf.
    func laeuftIrgendwo(jetzt: Date = Date()) -> Bool {
        aufraeumen(jetzt: jetzt)
        return !offen.isEmpty
    }

    private func aufraeumen(jetzt: Date) {
        offen = offen.filter { jetzt.timeIntervalSince($0.value) < Self.hoechstdauer }
    }
}
