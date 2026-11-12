import Foundation

// MARK: - Drahtform

/// Die Form, in der `simplebanking-mmimport` eine MoneyMoney-Datenbank herausgibt.
///
/// Das Ziel ist geteilt zwischen Helfer und App, damit das Format an **einer** Stelle
/// steht. Es hängt bewusst an nichts: Der Helfer linkt SQLCipher, die App linkt GRDB
/// und das System-SQLite, und beide exportieren dieselben `sqlite3_*`-Symbole. Ein
/// gemeinsames Ziel, das eine der beiden Seiten mitzieht, holt den Symbolkonflikt
/// zurück, den der eigene Prozess gerade auflöst — und zwar auch ins Testbinary.
public struct MoneyMoneyAuszug: Codable, Sendable, Hashable {
    /// Fassung der gelesenen Datenbank, soweit `config` sie nennt. Nur für Diagnose.
    public var erzeuger: String?
    public var konten: [MoneyMoneyKonto]
    public var kategorien: [MoneyMoneyKategorie]
    public var umsaetze: [MoneyMoneyUmsatz]

    public init(erzeuger: String? = nil,
                konten: [MoneyMoneyKonto] = [],
                kategorien: [MoneyMoneyKategorie] = [],
                umsaetze: [MoneyMoneyUmsatz] = []) {
        self.erzeuger = erzeuger
        self.konten = konten
        self.kategorien = kategorien
        self.umsaetze = umsaetze
    }
}

/// Ein Konto aus `accounts`. `inhaber` dient allein der Eigenerkennung
/// (`OwnPartyRegistry` in der App), nicht der Anzeige.
public struct MoneyMoneyKonto: Codable, Sendable, Hashable {
    public var schluessel: Int64        // accounts.rowid
    public var iban: String
    public var bic: String?
    public var waehrung: String?
    public var name: String?
    public var inhaber: String?
    /// `accounts.portfolio` — Depots und Versicherungsverträge. Werden übergangen.
    public var istDepot: Bool

    public init(schluessel: Int64, iban: String, bic: String? = nil,
                waehrung: String? = nil, name: String? = nil,
                inhaber: String? = nil, istDepot: Bool = false) {
        self.schluessel = schluessel
        self.iban = iban
        self.bic = bic
        self.waehrung = waehrung
        self.name = name
        self.inhaber = inhaber
        self.istDepot = istDepot
    }
}

/// Eine Kategorie aus `categories`, Pfad bereits aufgelöst.
///
/// MoneyMoney hängt die Verschachtelung an `categories.group_key` →
/// `category_groups.rowid`; der Helfer läuft den Baum hoch und gibt
/// `"Mobilität\\Bahn"` heraus, weil nur er die Datenbank hat.
public struct MoneyMoneyKategorie: Codable, Sendable, Hashable {
    public var schluessel: Int64        // categories.rowid
    /// Leer bei MoneyMoneys Standardkategorie: Sie trägt in der Datenbank keinen
    /// Namen, „Unkategorisiert" setzt MoneyMoney erst zur Laufzeit.
    public var pfad: String

    public init(schluessel: Int64, pfad: String) {
        self.schluessel = schluessel
        self.pfad = pfad
    }
}

/// Eine Kategoriegruppe aus `category_groups` — die Eltern einer Kategorie.
/// Nicht Teil des Auszugs: Der Helfer löst den Pfad vor dem Hinausschreiben auf.
public struct MoneyMoneyGruppe: Codable, Sendable, Hashable {
    public var name: String
    public var elternSchluessel: Int64

    public init(name: String, elternSchluessel: Int64) {
        self.name = name
        self.elternSchluessel = elternSchluessel
    }
}

/// Ein Umsatz aus `transactions`.
///
/// `gegenseite…` heißt so, weil MoneyMoneys Spalten `account`/`bankcode` auf der
/// Buchung **die andere Seite** tragen, nicht das eigene Konto — das steckt in
/// `local_account_key`. Der Spaltenname legt das Gegenteil nahe.
public struct MoneyMoneyUmsatz: Codable, Sendable, Hashable {
    public var kontoSchluessel: Int64   // transactions.local_account_key
    public var betrag: Double           // REAL, keine Cent-Ganzzahl
    public var waehrung: String?
    /// `transactions.timestamp` — Epoch-Sekunden in **UTC**, auf 12:00 gesetzt.
    public var gebuchtAm: Int64
    public var wertgestelltAm: Int64?
    public var gegenseiteName: String?
    public var gegenseiteIban: String?
    public var gegenseiteBic: String?
    /// `unformatted_purpose`. Eine Spalte `purpose` gibt es nicht; der aufbereitete
    /// Text wird von MoneyMoney zur Anzeigezeit erzeugt.
    public var zweck: String?
    /// `unformatted_type`, z. B. „Folgelastschrift".
    public var buchungstext: String?
    public var endeZuEnde: String?      // eref
    public var mandat: String?          // mref
    public var glaeubiger: String?       // cred
    public var rueckgabegrund: String?  // rtrn
    public var kategorieSchluessel: Int64?
    public var istGebucht: Bool
    /// `transactions.splitted` — eine Bankbuchung auf mehrere Kategorien verteilt.
    /// **Nicht** `split_key`: der ist bei allen Zeilen belegt und sortiert nur.
    public var istGeteilt: Bool

    public init(kontoSchluessel: Int64, betrag: Double, waehrung: String? = nil,
                gebuchtAm: Int64, wertgestelltAm: Int64? = nil,
                gegenseiteName: String? = nil, gegenseiteIban: String? = nil,
                gegenseiteBic: String? = nil, zweck: String? = nil,
                buchungstext: String? = nil, endeZuEnde: String? = nil,
                mandat: String? = nil, glaeubiger: String? = nil,
                rueckgabegrund: String? = nil, kategorieSchluessel: Int64? = nil,
                istGebucht: Bool = true, istGeteilt: Bool = false) {
        self.kontoSchluessel = kontoSchluessel
        self.betrag = betrag
        self.waehrung = waehrung
        self.gebuchtAm = gebuchtAm
        self.wertgestelltAm = wertgestelltAm
        self.gegenseiteName = gegenseiteName
        self.gegenseiteIban = gegenseiteIban
        self.gegenseiteBic = gegenseiteBic
        self.zweck = zweck
        self.buchungstext = buchungstext
        self.endeZuEnde = endeZuEnde
        self.mandat = mandat
        self.glaeubiger = glaeubiger
        self.rueckgabegrund = rueckgabegrund
        self.kategorieSchluessel = kategorieSchluessel
        self.istGebucht = istGebucht
        self.istGeteilt = istGeteilt
    }
}

// MARK: - Rückmeldung des Helfers

/// Warum der Helfer aufgehört hat. Beide Seiten brauchen dieselbe Liste: der Helfer
/// zum Beenden, die App zum Anzeigen eines Satzes, mit dem der Nutzer etwas anfangen
/// kann. `0` ist Erfolg und steht deshalb nicht hier.
public enum MoneyMoneyLesefehler: Int32, Sendable, CaseIterable {
    /// Aufruf ohne Pfad, oder die Datei ist nicht lesbar.
    case keineDatei = 2
    /// `PRAGMA key` gesetzt, aber der erste Lesezugriff scheitert — falsches
    /// Kennwort oder kein gewöhnliches SQLCipher 4.
    case kennwortFalsch = 3
    /// Datei geöffnet, aber eine Spalte fehlt, auf die der Lesepfad baut.
    /// MoneyMoney baut sein Schema ohne Ankündigung um; dann wird nicht geraten.
    case schemaUnbekannt = 4
    /// Lesefehler mitten im Durchlauf.
    case lesefehler = 5
    /// Die Datei ist da und der Schlüssel stimmt — sie lässt sich gerade nur nicht
    /// lesen, weil MoneyMoney selbst darin schreibt.
    case inBenutzung = 6

    public var kennung: String {
        switch self {
        case .keineDatei:      return "keine-datei"
        case .kennwortFalsch:  return "kennwort-falsch"
        case .schemaUnbekannt: return "schema-unbekannt"
        case .lesefehler:      return "lesefehler"
        case .inBenutzung:     return "in-benutzung"
        }
    }

    /// Was ein gescheiterter erster Lesezugriff bedeutet.
    ///
    /// **Nur `SQLITE_NOTADB` heißt „falsches Kennwort".** Mit einem falschen Schlüssel
    /// ist der entschlüsselte Kopf kein SQLite-Kopf, und genau das meldet SQLite.
    /// Alles andere — belegt, gesperrt, nur lesend nicht zu öffnen — kommt daher, dass
    /// MoneyMoney gerade selbst schreibt: Neben der Datei liegt dann ein `-journal`,
    /// und eine Datenbank mit unaufgeräumtem Journal lässt sich nicht nur-lesend
    /// öffnen, weil das Zurückrollen Schreibrechte bräuchte.
    ///
    /// Bis zum 11.11.2026 fiel beides auf `kennwort-falsch` zusammen. Der Nutzer las
    /// „Das Kennwort passt nicht" und hatte das richtige getippt — eine Meldung, die
    /// in die falsche Richtung schickt, ist schlimmer als keine.
    public static func fuer(sqliteCode: Int32) -> MoneyMoneyLesefehler {
        sqliteCode == 26 ? .kennwortFalsch : .inBenutzung   // 26 = SQLITE_NOTADB
    }
}
