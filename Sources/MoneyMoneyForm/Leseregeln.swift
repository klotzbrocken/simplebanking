import Foundation

/// Die Regeln des Lesepfads — alle rein, alle mit eingespeisten Werten prüfbar.
///
/// Sie liegen hier und nicht im Helfer, weil der Helfer sich aus dem Testziel nicht
/// importieren lässt (Executable mit `main.swift`) und weil ein Testbinary, das
/// SQLCipher **und** System-SQLite lädt, zwei Implementierungen derselben Symbole
/// hätte. Der Helfer liest Zeilen und gibt sie weiter; entschieden wird hier.
public enum MoneyMoneyLeseregeln {

    // MARK: - Datum

    /// Epoch-Sekunden → `yyyy-MM-dd`, **in UTC**.
    ///
    /// MoneyMoney legt `transactions.timestamp` auf 12:00 **UTC** (gemessen:
    /// `1794398400` = 2026-11-11 12:00 UTC, in Berlin 13:00). In Ortszeit
    /// formatiert stimmt das in Europa zufällig und bricht östlich von UTC+12:
    /// Neuseeland bekäme 01:00 des Folgetages. Das Datum geht in den Fingerprint
    /// ein — es wäre kein Anzeigefehler, sondern ein falscher Schlüssel für jede
    /// importierte Buchung.
    ///
    /// Ganzzahlrechnung statt `DateFormatter`: kein Gebietsschema, keine Zeitzone,
    /// und vor allem kein geteilter Formatierer — der Import läuft im Hintergrund
    /// über Zehntausende Zeilen, und `DateFormatter` ist nicht threadsicher.
    /// Verfahren: `civil_from_days` (Howard Hinnant).
    public static func tag(ausEpoche sekunden: Int64) -> String {
        var tage = sekunden / 86_400
        if sekunden % 86_400 != 0 && sekunden < 0 { tage -= 1 }   // vor 1970 abrunden
        let z = tage + 719_468
        let aera = (z >= 0 ? z : z - 146_096) / 146_097
        let tagImAera = z - aera * 146_097                                             // [0, 146096]
        let jahrImAera = (tagImAera - tagImAera/1_460 + tagImAera/36_524 - tagImAera/146_096) / 365
        let jahrRoh = jahrImAera + aera * 400
        let tagImJahr = tagImAera - (365*jahrImAera + jahrImAera/4 - jahrImAera/100)   // [0, 365]
        let monatRoh = (5*tagImJahr + 2)/153                                           // [0, 11]
        let tagImMonat = tagImJahr - (153*monatRoh + 2)/5 + 1                          // [1, 31]
        let monat = monatRoh < 10 ? monatRoh + 3 : monatRoh - 9                        // [1, 12]
        let jahr = monat <= 2 ? jahrRoh + 1 : jahrRoh
        return String(format: "%04d-%02d-%02d", jahr, monat, tagImMonat)
    }

    // MARK: - Betrag

    /// `REAL` → Zeichenkette, wie der OFX-Importer sie erzeugt (`-20.00`).
    ///
    /// MoneyMoney speichert Beträge als `REAL`, nicht als Cent-Ganzzahl. Welche
    /// Zeichenkette hier herauskommt, entscheidet den Fingerprint der Buchung —
    /// `description` wäre `-20.0` und damit ein anderer Schlüssel. `locale: nil`
    /// ist der nicht-lokalisierte Punkt, unabhängig von der Systemeinstellung.
    public static func betrag(_ wert: Double) -> String {
        String(format: "%.2f", locale: nil, wert)
    }

    // MARK: - Was übernommen wird

    /// Ob der Wert in `accounts.iban` überhaupt eine IBAN ist.
    ///
    /// MoneyMoney trägt dort auch nackte Kontonummern ein — gemessen: ein Konto mit
    /// `"1808336"`. „Nicht leer" ist deshalb keine brauchbare Prüfung. Ohne diese
    /// Regel geht so ein Wert in die YAXI-Abfrage, kommt ohne Treffer zurück, und
    /// der Nutzer liest „diese Bank ist nicht erreichbar" statt „das ist keine
    /// IBAN" — eine Begründung, mit der er nichts anfangen kann.
    ///
    /// Geprüft wird die Form, nicht die Prüfsumme: Land (zwei Buchstaben),
    /// Prüfzahl (zwei Ziffern), dann alphanumerisch, 15 bis 34 Zeichen. Eine echte
    /// IBAN-Prüfsumme wäre strenger als nötig — ob es die Bank gibt, beantwortet
    /// YAXI, und eine Ziffernverdreher-Absage wollen wir nicht selbst erfinden.
    public static func istIban(_ wert: String) -> Bool {
        let blank = wert.replacingOccurrences(of: " ", with: "").uppercased()
        guard (15...34).contains(blank.count) else { return false }
        let zeichen = Array(blank)
        guard zeichen[0].isLetter, zeichen[1].isLetter,
              zeichen[2].isNumber, zeichen[3].isNumber else { return false }
        return zeichen.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Nur Konten mit IBAN und ohne Depot-Kennzeichen.
    ///
    /// Depots und Versicherungsverträge (`portfolio = 1`) haben in MoneyMoney keine
    /// IBAN und in simplebanking kein Gegenstück. Die eigentliche Prüfung, ob die
    /// Bank über Open Banking erreichbar ist, macht YAXI selbst — hier fällt nur
    /// weg, was gar keine IBAN zum Nachfragen hat.
    public static func istUebernehmbar(_ konto: MoneyMoneyKonto) -> Bool {
        !konto.istDepot && istIban(konto.iban)
    }

    /// Nur gebuchte, ungeteilte Umsätze.
    ///
    /// Vorgemerkte sind flüchtig: die Bank liefert sie beim nächsten Abruf selbst,
    /// und als importierte Zeile werden sie nie gebucht — sie blieben als Geister
    /// liegen, an denen `purgeStalePending` vorbeiläuft.
    ///
    /// Geteilte Buchungen verteilt MoneyMoney auf mehrere Kategorien; unser Modell
    /// hat eine Kategorie pro Buchung. Ungefiltert würde aus einer Bankbuchung ein
    /// Satz Dubletten, der dasselbe Geld mehrfach zählt.
    public static func istUebernehmbar(_ umsatz: MoneyMoneyUmsatz) -> Bool {
        umsatz.istGebucht && !umsatz.istGeteilt
    }

    // MARK: - Kategorien

    /// Erste Ebene eines MoneyMoney-Kategoriepfads, oder `nil`.
    ///
    /// `nil` bei leerem Pfad: MoneyMoneys Standardkategorie trägt in der Datenbank
    /// **keinen** Namen (gemessen: `categories.rowid = 1` mit `name = ''`), weil
    /// „Unkategorisiert" erst zur Laufzeit gesetzt wird. Importiert bekäme jeder
    /// Umsteiger als erstes eine Kategorie geschenkt, die nichts aussagt.
    public static func erstEbene(_ pfad: String) -> String? {
        let erste = pfad.split(separator: "\\", maxSplits: 1,
                               omittingEmptySubsequences: false).first ?? ""
        let sauber = erste.trimmingCharacters(in: .whitespacesAndNewlines)
        return sauber.isEmpty ? nil : sauber
    }

    /// Pfad einer Kategorie von der Wurzel abwärts, mit Backslash getrennt.
    ///
    /// MoneyMoney hängt die Verschachtelung an `categories.group_key` →
    /// `category_groups.rowid`; `0` heißt „keine Eltern". Namenlose Glieder fallen
    /// weg, damit die Standardkategorie am Ende einen leeren Pfad hat und nicht
    /// einen aus Backslashes.
    ///
    /// Die Tiefenschranke ist gegen einen Ringschluss in fremden Daten. Ohne sie
    /// stünde hier eine Endlosschleife, die der Nutzer als hängenden Import sieht —
    /// und ob MoneyMoney Ringschlüsse ausschließt, wissen wir nicht.
    public static func pfad(name: String,
                            elternSchluessel: Int64,
                            gruppen: [Int64: MoneyMoneyGruppe],
                            hoechsteTiefe: Int = 32) -> String {
        var teile: [String] = name.isEmpty ? [] : [name]
        var schluessel = elternSchluessel
        var tiefe = 0
        while schluessel != 0, tiefe < hoechsteTiefe, let gruppe = gruppen[schluessel] {
            if !gruppe.name.isEmpty { teile.insert(gruppe.name, at: 0) }
            schluessel = gruppe.elternSchluessel
            tiefe += 1
        }
        return teile.joined(separator: "\\")
    }

    // MARK: - Schemazusage

    /// Die Spalten, auf die der Lesepfad baut — Tabelle → Spalten.
    ///
    /// Der Helfer prüft sie beim Öffnen und bricht ab, wenn eine fehlt, statt zu
    /// raten. Dass das nötig ist, steht in MoneyMoneys eigener Datenbank: die Spalte
    /// `a1794240104` ist nach einem Epoch-Zeitstempel benannt — 2026-11-09 17:01:44,
    /// ein Migrationsgrabstein. Das Schema bewegt sich ohne Ankündigung.
    ///
    /// `rowid` steht bewusst nicht drin: SQLite führt sie bei jeder dieser Tabellen,
    /// auch wenn `PRAGMA table_info` sie nicht nennt.
    ///
    /// `pins` und `banks` stehen hier nicht und werden nie geöffnet — in ihnen liegen
    /// die Bank-PIN und der HBCI-Privatschlüssel des Nutzers.
    public static let benoetigteSpalten: [String: [String]] = [
        "accounts": ["iban", "bic", "currency", "name", "owner", "portfolio"],
        "categories": ["name", "group_key"],
        "category_groups": ["name", "group_key"],
        "transactions": [
            "local_account_key", "account", "bankcode", "amount", "currency",
            "timestamp", "value_timestamp", "name", "unformatted_purpose",
            "unformatted_type", "eref", "mref", "cred", "rtrn", "category_key",
            "booked", "splitted",
        ],
    ]
}
