import Foundation

// MARK: - Wann war dieser Kontostand aktuell?
//
// Gemeldet am 06.11.2026: „ING zeigt in der Banking-App einen anderen Kontostand als
// simplebanking." Bei der Untersuchung stellte sich heraus, dass die Frage mit der
// damaligen Anzeige gar nicht zu beantworten war — nicht weil die Zahl falsch sein muss,
// sondern weil **ihr Alter nicht ablesbar war**:
//
//   - Die Kopfzeile nannte nur die Stunde („ING · 14 Uhr"). Gestern 14 Uhr war von vor
//     einer Minute nicht zu unterscheiden, und der Abruf läuft ab Werk nur alle vier
//     Stunden.
//   - Beim Kontowechsel übernahm die App den gespeicherten Saldo, ohne den dazugehörigen
//     Zeitpunkt mitzunehmen — danach stand an der neuen Zahl die Zeit des **vorherigen**
//     Kontos. Eine falsche Zeit ist schlimmer als keine.
//   - Der Diagnosebericht las `simplebanking.lastBalanceFetch.<slotId>` als `Date`,
//     geschrieben wurde aber `simplebanking.cachedBalanceAt.<slotId>` als Sekundenwert.
//     Anderer Schlüssel, anderer Typ — „Last-Sync: nie", in jedem Bericht, immer.
//
// Genau so entsteht ein Fehler wie der letzte: Zwei Stellen schreiben den Schlüssel von
// Hand, eine dritte liest ihn anders. Deshalb gibt es für den Zeitpunkt nur noch diesen
// einen Zugang. Der Saldo selbst wird weiter an vielen Stellen gelesen — sein Schlüssel
// ist nie auseinandergelaufen, und ihn nachzuziehen wäre Umbau ohne Befund.
enum Saldoalter {

    private static func schluessel(_ slotId: String) -> String {
        "simplebanking.cachedBalanceAt.\(slotId)"
    }

    /// Wann der gespeicherte Saldo dieses Kontos geholt wurde. `nil`, wenn nie.
    static func zeitpunkt(slotId: String, defaults: UserDefaults = .standard) -> Date? {
        guard let sekunden = defaults.object(forKey: schluessel(slotId)) as? Double else { return nil }
        return Date(timeIntervalSince1970: sekunden)
    }

    /// Hält fest, dass der Saldo dieses Kontos jetzt geholt wurde.
    static func merken(slotId: String, jetzt: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(jetzt.timeIntervalSince1970, forKey: schluessel(slotId))
    }

    /// Wie die Zeit an einem Kontostand dasteht.
    ///
    /// Von heute genügt die Uhrzeit — alles andere wäre Lärm im Flyout, das 348 pt breit
    /// ist. Alles Ältere trägt sein Datum, denn genau dort fängt die Verwechslung an.
    /// Minuten statt nur Stunden, weil „14 Uhr" eine Zahl nach einem frischen Abruf
    /// älter aussehen lässt, als sie ist.
    static func beschriftung(_ zeitpunkt: Date,
                             jetzt: Date = Date(),
                             kalender: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        if kalender.isDate(zeitpunkt, inSameDayAs: jetzt) {
            f.dateFormat = "HH:mm"
            return f.string(from: zeitpunkt)
        }
        if let gestern = kalender.date(byAdding: .day, value: -1, to: jetzt),
           kalender.isDate(zeitpunkt, inSameDayAs: gestern) {
            f.dateFormat = "HH:mm"
            return L10n.t("gestern \(f.string(from: zeitpunkt))",
                          "yesterday \(f.string(from: zeitpunkt))")
        }
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: zeitpunkt)
    }
}
