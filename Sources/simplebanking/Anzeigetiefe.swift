import Foundation

/// Wie weit zurück die Oberfläche ein Konto liest.
///
/// Gelesen wird überall nur ein Fenster: `BankSlotSettings.displayDays`, also
/// `max(fetchDays, lastImportedDays)` — standardmäßig 60 Tage. Wer Historie
/// **schreibt**, die älter ist als dieses Fenster, muss es mitziehen, sonst liegen
/// die Buchungen in der Datenbank und sind nirgends zu sehen: nicht in der Liste,
/// nicht im Export, nicht in der Kategorisierung. Nichts schlägt dabei fehl, und
/// genau deshalb fällt es erst dem Nutzer auf (gemeldet am 13.11.2026 nach einem
/// MoneyMoney-Umstieg mit knapp 3000 Buchungen).
///
/// Die Marke kommt aus der **ältesten Buchung des Kontos**, nicht aus der gerade
/// geschriebenen Liste: Ein zweiter Lauf desselben Imports bringt nichts Neues
/// herein, muss die Marke aber trotzdem setzen können — sonst wäre ein schon
/// vollzogener Import nicht mehr zu heilen. Aus demselben Grund steht sie hier und
/// nicht in den einzelnen Importern: Jeder von ihnen hatte sie sonst zu kennen, und
/// zwei von vier kannten sie nicht.
///
/// Der **Abrufzeitraum** der Bank bleibt davon unberührt (`fetchDays`, bei 90 Tagen
/// gedeckelt) — hier geht es nur ums Lesen aus der eigenen Datenbank.
enum Anzeigetiefe {

    /// Wie weit `tag` zurückliegt, in Tagen ab `heute` — einschließlich des
    /// Stichtags, weil `TransactionsDatabase.loadTransactions(days:)` ihn mitzählt
    /// (Stichtag = heute − (Tage − 1)). `nil`, wenn das Datum nicht lesbar ist.
    static func tiefeInTagen(_ tag: String, heute: Date = Date()) -> Int? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = .current
        format.dateFormat = "yyyy-MM-dd"
        let kalender = Calendar(identifier: .gregorian)
        guard let datum = format.date(from: tag),
              let abstand = kalender.dateComponents([.day],
                                                    from: kalender.startOfDay(for: datum),
                                                    to: kalender.startOfDay(for: heute)).day
        else { return nil }
        return max(1, abstand + 1)
    }

    /// Nach jedem Schreiben von Historie aufzurufen. Nur nach oben: Ein tieferer
    /// Import von früher darf nicht verloren gehen.
    static func merken(slotId: String, bankId: String = "primary") {
        guard let aelteste = (try? TransactionsDatabase.aeltesteBuchung(slotId: slotId,
                                                                        bankId: bankId)) ?? nil,
              let tiefe = tiefeInTagen(aelteste) else { return }
        var einstellungen = BankSlotSettingsStore.load(slotId: slotId)
        guard tiefe > (einstellungen.lastImportedDays ?? 0) else { return }
        einstellungen.lastImportedDays = tiefe
        BankSlotSettingsStore.save(einstellungen, slotId: slotId)
        AppLogger.log("Anzeigezeitraum slot=\(slotId) auf \(tiefe) Tage erweitert",
                      category: "Import")
    }
}
