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
//
// MARK: - Und wie man aus dem Warten wieder herauskommt
//
// Gemeldet am 06.11.2026: Wer das Freigabe-Fenster versehentlich schließt, kommt bis zum
// Programmneustart nicht mehr an sein Konto. Das Schließen ist absichtlich **kein**
// Abbruch (siehe `Freigabefenster`) — die Freigabe kann in der Banking-App längst erteilt
// sein. Danach wartet `pollRedirect` aber seine vollen zehn Minuten, und solange hält der
// umgebende Aufruf `hbciSlotsInFlight`. An dieser Sperre scheitert dann **jede**
// Nutzerhandlung: „Aktualisieren", das ↻, das Herunterziehen und der Klick auf das
// Menüleisten-Symbol sind alle korrekt als Nutzerhandlung markiert und kommen trotzdem
// nicht durch, weil sie eine Ebene höher abbrechen.
//
// Es gab nichts zum Abbrechen, weil niemand einen Griff auf die laufende Aufgabe hält —
// bei Überweisungen gibt es „Warten beenden", beim Abruf nicht. Statt diesen Griff durch
// ein halbes Dutzend Aufrufstellen zu fädeln, liegt die Abbruchmarke hier: Die beiden
// Warteschleifen fragen sie ohnehin jede Runde ab, und `Task.isCancelled` prüfen sie
// längst — es kam nur niemand hin.
actor Freigabewache {

    static let shared = Freigabewache()

    /// Nach dieser Zeit gilt eine Freigabe als verfallen, auch wenn niemand sie beendet
    /// hat. Ohne diese Grenze bliebe ein abgestürzter oder vergessener Vorgang für immer
    /// stehen und das Konto damit dauerhaft blockiert.
    static let hoechstdauer: TimeInterval = 300

    private var offen: [String: Date] = [:]
    private var abbrueche: [String: Date] = [:]

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
        // Eine beendete Freigabe lässt keinen Abbruch zurück, der den nächsten Anlauf
        // sofort wieder abräumt.
        abbrueche.removeValue(forKey: slotId)
    }

    /// Der Nutzer will nicht länger warten. Die laufende Warteschleife sieht das in ihrer
    /// nächsten Runde — also binnen fünf Sekunden — und kehrt zurück; erst damit geben die
    /// `defer` der Aufrufer `hbciSlotsInFlight` und die Warteschlange frei.
    ///
    /// Gilt **auch für Konten ohne Eintrag** in `offen`: Der entkoppelte Weg („bitte in
    /// der Banking-App bestätigen") meldet sich hier nie an, braucht den Ausgang aber
    /// genauso.
    func abbrechen(_ slotId: String, jetzt: Date = Date()) {
        abbrueche[slotId] = jetzt
    }

    /// Fragt **und verbraucht** die Abbruchmarke — ein Abbruch wirkt einmal.
    ///
    /// Verbrauchend, damit die Reihenfolge nicht zählt: Stünde die Marke noch, wenn der
    /// neue Anlauf beginnt, würde der sich selbst abräumen. Dass Prüfen und Entfernen
    /// zusammen geschehen, erledigt der Aktor.
    func nimmAbbruch(_ slotId: String, jetzt: Date = Date()) -> Bool {
        aufraeumen(jetzt: jetzt)
        return abbrueche.removeValue(forKey: slotId) != nil
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
        // Dieselbe Grenze: Ein Abbruch, den nie eine Schleife abgeholt hat, war an keine
        // gerichtet — nach fünf Minuten ist er gegenstandslos.
        abbrueche = abbrueche.filter { jetzt.timeIntervalSince($0.value) < Self.hoechstdauer }
    }
}
