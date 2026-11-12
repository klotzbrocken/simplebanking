import Foundation
import MoneyMoneyForm

// MARK: - Ablage

/// Der Auszug zwischen Assistent und Übernahme.
///
/// Das Vorhaben ist dauerhaft, damit ein Abbruch bei Bank drei von fünf kein
/// Sonderfall ist. Der Auszug muss es deshalb auch sein: Die Freigabe kann Minuten
/// dauern, läuft über mehrere Banken und überdauert einen Programmneustart. Läge er
/// nur im Speicher, hätte der Nutzer beim Fortsetzen die Warteschlange und keine
/// Daten — und wir müssten ein zweites Mal nach seinem MoneyMoney-Kennwort fragen.
///
/// Er liegt neben `transactions.db`, mit Rechten 0600, und wird weggeworfen, sobald
/// das Vorhaben keine offene Bank mehr hat. Das gibt nichts preis, was dort nicht
/// ohnehin liegt: **dieselben** Umsätze stehen Sekunden später unverschlüsselt in
/// derselben Datenbank im selben Ordner. Das MoneyMoney-Kennwort steht **nicht**
/// darin — der Auszug ist das Ergebnis, nicht der Schlüssel.
enum MoneyMoneyAblage {

    static var ort: URL? {
        try? TransactionsDatabase.databaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("moneymoney-auszug.plist")
    }

    /// Rechte werden beim **Anlegen** gesetzt, nicht danach: Schreiben und
    /// anschließendes `setAttributes` lässt die Datei einen Moment lang für jeden
    /// lesbar liegen, und genau in diesem Moment steht der Umsatzverlauf darin.
    static func legen(_ auszug: MoneyMoneyAuszug) {
        guard let ort else { return }
        let kodierer = PropertyListEncoder()
        kodierer.outputFormat = .binary
        guard let daten = try? kodierer.encode(auszug) else { return }
        try? FileManager.default.removeItem(at: ort)
        if !FileManager.default.createFile(atPath: ort.path, contents: daten,
                                           attributes: [.posixPermissions: 0o600]) {
            AppLogger.log("MoneyMoney-Auszug konnte nicht abgelegt werden",
                          category: "MoneyMoney", level: "ERROR")
        }
    }

    static func holen() -> MoneyMoneyAuszug? {
        guard let ort, let daten = try? Data(contentsOf: ort) else { return nil }
        return try? PropertyListDecoder().decode(MoneyMoneyAuszug.self, from: daten)
    }

    static func wegwerfen() {
        guard let ort else { return }
        try? FileManager.default.removeItem(at: ort)
    }

    /// Weg damit, sobald keine Bank mehr offen ist. Separat von `wegwerfen`, weil nur
    /// diese Stelle die Bedingung kennt und sie sonst an jedem Aufrufer hängt.
    /// Wegwerfen, wenn nichts mehr daran hängt.
    ///
    /// Über `eintraege` und nicht über `offene`: Abgehakt heißt „die Bank steht",
    /// nicht „der Verlauf ist drin". Zwischen beidem liegt das Schließen des
    /// Assistenten — und genau dort wurde die Ablage bis zum 11.11.2026 weggeworfen,
    /// bevor irgendjemand sie gelesen hatte. `MoneyMoneyNachtrag` räumt seine
    /// Einträge selbst weg; erst wenn keiner mehr übrig ist, geht die Ablage.
    static func wegwerfenWennFertig() {
        guard MoneyMoneyVorhaben.eintraege.isEmpty else { return }
        wegwerfen()
        MoneyMoneyVorhaben.wegwerfen()
    }
}

// MARK: - Der Nachtrag, sobald es einen Slot gibt

/// Trägt den MoneyMoney-Verlauf nach, sobald das Konto wirklich existiert.
///
/// **Warum das nicht im Einrichtungsassistenten passiert.** Der Slot entsteht erst,
/// wenn der Assistent zu ist: `runModal` kehrt zurück, und erst der Aufrufer legt ihn
/// an (`replaceFirstSlot`). Ein Nachtrag im Assistenten suchte deshalb einen Slot, den
/// es noch nicht gab, und meldete „kein Slot zu den übernommenen IBANs gefunden" —
/// gemessen am 11.11.2026, als die Herkunft der IBANs schon repariert war.
///
/// Darum hier, und darum über die Ablage: Sie überlebt den Assistenten, einen Abbruch
/// und einen Neustart. Jeder Eintrag, dessen Konto jetzt da ist, wird nachgetragen und
/// danach aus dem Vorhaben entfernt. Deshalb darf dieser Aufruf auch beim Programmstart
/// stehen: Was schon drin ist, hat keinen Eintrag mehr.
@MainActor
enum MoneyMoneyNachtrag {

    /// Alle Einträge, deren Konto inzwischen existiert.
    @discardableResult
    static func alleFaelligen() async -> Int {
        let eintraege = MoneyMoneyVorhaben.eintraege
        guard !eintraege.isEmpty else {
            MoneyMoneyAblage.wegwerfenWennFertig()
            return 0
        }
        guard let auszug = MoneyMoneyAblage.holen() else {
            // Ohne Auszug ist nichts nachzutragen, und die Einträge würden ewig
            // stehen bleiben. Lieber einmal verloren als dauerhaft im Weg.
            AppLogger.log("MoneyMoney-Nachtrag: Ablage fehlt, \(eintraege.count) Einträge verworfen",
                          category: "MoneyMoney", level: "WARN")
            MoneyMoneyVorhaben.wegwerfen()
            return 0
        }

        var buchungen = 0
        for eintrag in eintraege {
            let gesucht = MoneyMoneyVorhaben.normiert(eintrag.iban)
            guard let slot = MultibankingStore.shared.slots.first(where: {
                MoneyMoneyVorhaben.normiert($0.iban) == gesucht
            }) else { continue }   // Konto noch nicht da — beim nächsten Mal.

            // **Erst wenn die Bank ihre Umsätze geschrieben hat.** Die Naht ist die
            // älteste Buchung des Slots; ohne sie käme der ganze MoneyMoney-Zeitraum
            // herein, auch die Wochen, die die Bank selbst liefert — und in der
            // Überschneidung stünde jede Buchung zweimal, weil der Fingerabdruck nur
            // zeichengleiche Texte zusammenführt und Bank und MoneyMoney denselben
            // Zweck verschieden schreiben.
            //
            // Gemessen am 11.11.2026: dreimal `naht=-`, 2055 statt 1822 Buchungen,
            // und von 233 Bankbuchungen fiel **keine einzige** mit einer
            // MoneyMoney-Zeile zusammen. Der Eintrag bleibt deshalb liegen, bis
            // Umsätze da sind — verloren geht nichts, der nächste Aufruf holt ihn.
            guard (try? TransactionsDatabase.aeltesteBuchung(slotId: slot.id)) ?? nil != nil else {
                AppLogger.log("MoneyMoney-Nachtrag: slot=\(slot.id) hat noch keine "
                              + "Bankbuchungen — Verlauf wartet auf die Naht",
                              category: "MoneyMoney")
                continue
            }

            // Den Namen, den der Nutzer in MoneyMoney selbst vergeben hat, als
            // Kurznamen übernehmen. Nur wo keiner steht: Ein vorhandener Kurzname
            // ist seine Entscheidung.
            if (slot.nickname ?? "").isEmpty,
               let mmName = auszug.konten.first(where: {
                   MoneyMoneyVorhaben.normiert($0.iban) == gesucht
               })?.name,
               !mmName.trimmingCharacters(in: .whitespaces).isEmpty {
                MultibankingStore.shared.updateNickname(mmName, forSlotId: slot.id)
            }

            do {
                let ergebnis = try await MoneyMoneyUebernahme.nachtragen(
                    slotId: slot.id, kontoSchluessel: eintrag.kontoSchluessel, auszug: auszug)
                buchungen += ergebnis.buchungen
                AppLogger.log("MoneyMoney-Nachtrag: slot=\(slot.id) → "
                              + "\(ergebnis.buchungen) Buchungen, \(ergebnis.kategorien) Kategorien"
                              + (ergebnis.uebergangeneKategorien.isEmpty ? ""
                                 : ", übergangen: \(ergebnis.uebergangeneKategorien.count)"),
                              category: "MoneyMoney")
            } catch {
                // Ein gescheiterter Verlauf darf nichts anhalten: Das Konto ist
                // verbunden und liefert Daten, es fehlt nur die Vergangenheit.
                AppLogger.log("MoneyMoney-Nachtrag gescheitert slot=\(slot.id): "
                              + "\(error.localizedDescription)",
                              category: "MoneyMoney", level: "ERROR")
            }
            // Erledigt ist erledigt — auch bei einem Fehler. Ein zweiter Versuch
            // beim nächsten Start würde denselben Fehler wiederholen und den
            // Nutzer nie davon erlösen.
            MoneyMoneyVorhaben.entfernen(iban: eintrag.iban)
        }

        MoneyMoneyAblage.wegwerfenWennFertig()
        return buchungen
    }
}

// MARK: - Übernahme

/// Trägt den MoneyMoney-Verlauf in einen Slot nach, der gerade entstanden ist.
///
/// **Die Reihenfolge ist nicht beliebig.** Das läuft erst *nach* dem ersten
/// YAXI-Abruf: Der Slot muss existieren (`slot_id` steckt im Primärschlüssel), und
/// die Naht braucht einen Bezugspunkt — übernommen wird nur, was älter ist als die
/// älteste Buchung, die der Slot schon hat. Liefe es davor, gäbe es keine älteste
/// Buchung, es zöge alles bis heute herein, und der erste Abruf legte die letzten
/// 90 Tage ein zweites Mal daneben.
///
/// Nicht `@MainActor`: Bei einem Umsteiger mit 50.000 Buchungen hält das Schreiben
/// in die Datenbank den Hauptfaden an, und dann steht auch der Fortschritt im
/// Assistenten still — ausgerechnet dort, wo er gebraucht wird. Nur der
/// Kategorieteil springt auf den Hauptakteur, weil `Eigenkategorien` beim Anlegen
/// eine Benachrichtigung verschickt, auf die Oberflächen hören.
enum MoneyMoneyUebernahme {

    struct Ergebnis {
        var buchungen = 0
        var kategorien = 0
        /// Namen, die simplebanking nicht führen kann (länger als
        /// `Eigenkategorien.maximaleLaenge`). Die Buchungen landen trotzdem, nur ohne
        /// Kategorie — ein von uns zurechtgeschnittener Name wäre keiner, den der
        /// Nutzer gewählt hat.
        var uebergangeneKategorien: [String] = []
    }

    @discardableResult
    static func nachtragen(slotId: String,
                           kontoSchluessel: Int64,
                           auszug: MoneyMoneyAuszug,
                           bankId: String = "primary") async throws -> Ergebnis {
        var ergebnis = Ergebnis()

        // `nil` heißt leerer Slot — dann gibt es keinen Bezugspunkt und alles darf
        // herein. Das ist der Fall, in dem die Bank selbst nichts geliefert hat.
        let naht = try TransactionsDatabase.aeltesteBuchung(slotId: slotId, bankId: bankId)
        let buchungen = MoneyMoneyZuordnung.buchungen(auszug,
                                                      fuerKonto: kontoSchluessel,
                                                      aelterAls: naht)
        var paare: [(txID: String, name: String)] = []

        if !buchungen.isEmpty {
            // `purgeStalePending: false` — der Aufräumer wirft vorgemerkte Posten weg,
            // die nicht in der übergebenen Liste stehen. Hier steht absichtlich nur
            // Vergangenheit darin; mit `true` würde der Import jede offene Vormerkung
            // des Slots mitreißen.
            let txIds = try TransactionsDatabase.upsert(transactions: buchungen,
                                                        slotId: slotId,
                                                        bankId: bankId,
                                                        purgeStalePending: false)
            ergebnis.buchungen = buchungen.count

            // Die Kategorie kommt NACH dem Schreiben: `TransactionRecord.init` verwirft
            // das Feld und kategorisiert selbst neu. Gebündelt, weil `saveOverride` je
            // Aufruf das ganze Wörterbuch neu schreibt.
            paare = zip(txIds, buchungen).compactMap { (txID, buchung) in
                buchung.category.map { (txID: txID, name: $0) }
            }
        }

        // **Der Überschneidungszeitraum.** Ab der Naht liefert die Bank die Buchungen
        // selbst; übernommen wird davon nichts, sonst stünde jede zweimal da. Die
        // Kategorie fehlt damit aber ausgerechnet den jüngsten Buchungen — und wer in
        // MoneyMoney gerade erst Kategorien angelegt hat, hat genau die dort hängen.
        // Gemessen am 11.11.2026: 1826 übernommene Buchungen, `kategorien=0`, während
        // in MoneyMoney zwei Kategorien auf Buchungen von heute saßen.
        if let naht {
            let mmZeilen = MoneyMoneyZuordnung.kategoriezeilen(auszug,
                                                               fuerKonto: kontoSchluessel,
                                                               abNaht: naht)
            if !mmZeilen.isEmpty {
                let bankZeilen = try TransactionsDatabase.buchungsschluessel(
                    slotId: slotId, ab: naht, bankId: bankId)
                paare += MoneyMoneyZuordnung
                    .kategoriezuordnung(bank: bankZeilen, moneymoney: mmZeilen)
                    .map { (txID: $0.txID, name: $0.kategorie) }
            }
        }

        guard !paare.isEmpty else {
            AppLogger.log("MoneyMoney übernommen slot=\(slotId) buchungen=\(ergebnis.buchungen) "
                          + "kategorien=0 naht=\(naht ?? "-")", category: "MoneyMoney")
            return ergebnis
        }
        // `Hauptthread.lauf` und nicht `MainActor.run`: Der Nachtrag läuft noch im
        // modalen Einrichtungsassistenten, und dort kehrt `MainActor.run` nie zurück
        // (siehe `Hauptthread`).
        let kategorieErgebnis = await Hauptthread.lauf { () -> (anzahl: Int, uebergangen: [String]) in
            var innen = Ergebnis()
            var aufgeloest: [String: TransactionCategory?] = [:]
            var zuordnungen: [(txID: String, slotId: String, category: TransactionCategory)] = []
            for paar in paare {
                let kategorie: TransactionCategory?
                if let bekannt = aufgeloest[paar.name] {
                    kategorie = bekannt
                } else {
                    kategorie = anlegenOderFinden(paar.name, ergebnis: &innen)
                    aufgeloest[paar.name] = kategorie
                }
                guard let kategorie else { continue }
                zuordnungen.append((txID: paar.txID, slotId: slotId, category: kategorie))
            }
            TransactionCategorizer.saveOverrides(zuordnungen)
            return (Set(zuordnungen.map(\.category)).count, innen.uebergangeneKategorien)
        }
        ergebnis.kategorien = kategorieErgebnis.anzahl
        ergebnis.uebergangeneKategorien = kategorieErgebnis.uebergangen

        AppLogger.log("MoneyMoney übernommen slot=\(slotId) buchungen=\(ergebnis.buchungen) "
                      + "kategorien=\(ergebnis.kategorien) naht=\(naht ?? "-")",
                      category: "MoneyMoney")
        return ergebnis
    }

    /// Gibt es die Kategorie schon, wird sie benutzt; sonst wird sie als eigene
    /// angelegt. Ohne das Anlegen importierte der Umstieg so gut wie keine Kategorie:
    /// MoneyMoneys Namen sind nicht unsere vierzehn.
    private static func anlegenOderFinden(_ name: String,
                                          ergebnis: inout Ergebnis) -> TransactionCategory? {
        if let vorhanden = TransactionCategory.from(displayName: name) { return vorhanden }
        switch Eigenkategorien.anlegen(name: name, symbol: "tag") {
        case nil, .belegt:
            // `.belegt` kann auftreten, wenn der Name sich nur in Diakritika von einem
            // bestehenden unterscheidet — dann ist der bestehende gemeint.
            return TransactionCategory.from(displayName: name)
        case .zuLang:
            ergebnis.uebergangeneKategorien.append(name)
            return nil
        case .leer:
            return nil
        }
    }
}
