import AppKit
import Foundation
import MoneyMoneyForm

// MARK: - Zuordnung

/// MoneyMoney-Zeilen → `TransactionsResponse.Transaction`.
///
/// Rein und ohne Datenbank, damit die Regeln mit eingespeisten Werten prüfbar sind.
/// Ziel ist dieselbe Strecke, die der OFX-Importer nimmt:
/// `[Transaction]` → `TransactionsDatabase.upsert`.
enum MoneyMoneyZuordnung {

    /// Die Konten, die überhaupt in Frage kommen.
    ///
    /// Ob die Bank über Open Banking erreichbar ist, beantwortet YAXI selbst
    /// (`search(filters: [.term(iban)], ibanDetection: true)`). Hier fällt nur weg,
    /// was gar keine IBAN zum Nachfragen hat.
    static func uebernehmbareKonten(_ auszug: MoneyMoneyAuszug) -> [MoneyMoneyKonto] {
        auszug.konten.filter(MoneyMoneyLeseregeln.istUebernehmbar)
    }

    /// Erste Kategorieebene je Kategorieschlüssel. Die Standardkategorie fehlt darin
    /// absichtlich — sie trägt in MoneyMoneys Datenbank keinen Namen.
    static func kategorienamen(_ auszug: MoneyMoneyAuszug) -> [Int64: String] {
        var namen: [Int64: String] = [:]
        for kategorie in auszug.kategorien {
            if let name = MoneyMoneyLeseregeln.erstEbene(kategorie.pfad) {
                namen[kategorie.schluessel] = name
            }
        }
        return namen
    }

    /// Die Buchungen eines MoneyMoney-Kontos, bereits gefiltert und zugeordnet.
    ///
    /// `aelterAls` ist die **Naht**: Übernommen wird nur, was älter ist als die
    /// älteste Buchung, die der Slot schon hat. Der Fingerprint ist ein SHA256 über
    /// Datum, Betrag, Namen, Zweck und Buchungstext — dieselbe Buchung aus MoneyMoney
    /// und aus dem Bankabruf trifft denselben Schlüssel nur bei zeichengenau gleichem
    /// Text, und ein Leerzeichen im Zweck genügt, damit sie es nicht tut. Ein Datum
    /// kann nicht halb daneben liegen. `nil` heißt „kein Bezugspunkt, alles nehmen"
    /// und ist nur für den Fall gedacht, dass der Slot leer ist.
    static func buchungen(_ auszug: MoneyMoneyAuszug,
                          fuerKonto kontoSchluessel: Int64,
                          aelterAls naht: String? = nil) -> [TransactionsResponse.Transaction] {
        let namen = kategorienamen(auszug)
        return auszug.umsaetze.compactMap { umsatz in
            guard umsatz.kontoSchluessel == kontoSchluessel,
                  MoneyMoneyLeseregeln.istUebernehmbar(umsatz) else { return nil }
            let buchung = buchung(umsatz,
                                  kategorie: umsatz.kategorieSchluessel.flatMap { namen[$0] })
            if let naht, let tag = buchung.bookingDate, tag >= naht { return nil }
            return buchung
        }
    }

    /// Die Kategorien, die MoneyMoney für den **Überschneidungszeitraum** führt.
    ///
    /// Alles ab der Naht liefert die Bank selbst — diese Buchungen werden nicht
    /// importiert, sonst stünde jede zweimal da. Ihre Kategorie fehlt damit aber auch,
    /// und das sind ausgerechnet die jüngsten Buchungen, die der Nutzer zuerst sieht.
    /// Hier kommen deshalb Tag, Betrag und Kategoriename heraus, sonst nichts.
    static func kategoriezeilen(_ auszug: MoneyMoneyAuszug,
                                fuerKonto kontoSchluessel: Int64,
                                abNaht naht: String)
        -> [(tag: String, betrag: String, kategorie: String)] {
        let namen = kategorienamen(auszug)
        return auszug.umsaetze.compactMap { umsatz in
            guard umsatz.kontoSchluessel == kontoSchluessel,
                  MoneyMoneyLeseregeln.istUebernehmbar(umsatz),
                  let kategorie = umsatz.kategorieSchluessel.flatMap({ namen[$0] })
            else { return nil }
            let tag = MoneyMoneyLeseregeln.tag(ausEpoche: umsatz.gebuchtAm)
            guard tag >= naht else { return nil }
            return (tag: tag, betrag: MoneyMoneyLeseregeln.betrag(umsatz.betrag),
                    kategorie: kategorie)
        }
    }

    /// Welche Buchung der Bank welche MoneyMoney-Kategorie bekommt.
    ///
    /// Über Tag und Betrag, nicht über den Fingerabdruck: Der trifft nur bei
    /// zeichengleichem Text, und Bank und MoneyMoney schreiben denselben Zweck
    /// verschieden — gemessen am 11.11.2026 fiel **keine einzige** von 233
    /// Bankbuchungen mit einer MoneyMoney-Zeile zusammen.
    ///
    /// **Nur eindeutige Paare.** Zwei Buchungen über denselben Betrag am selben Tag
    /// sind so nicht auseinanderzuhalten; dann bleibt beides ohne Kategorie. Eine
    /// geratene Zuordnung wäre schlimmer als keine — sie sieht aus wie eine
    /// Entscheidung des Nutzers und wird nie wieder hinterfragt.
    static func kategoriezuordnung(bank: [(txID: String, tag: String, betrag: Double)],
                                   moneymoney: [(tag: String, betrag: String, kategorie: String)])
        -> [(txID: String, kategorie: String)] {
        var bankSeite: [String: [String]] = [:]
        for zeile in bank {
            bankSeite[zeile.tag + "|" + MoneyMoneyLeseregeln.betrag(zeile.betrag), default: []]
                .append(zeile.txID)
        }
        var mmSeite: [String: [String]] = [:]
        for zeile in moneymoney {
            mmSeite[zeile.tag + "|" + zeile.betrag, default: []].append(zeile.kategorie)
        }
        return mmSeite.compactMap { schluessel, kategorien in
            guard kategorien.count == 1, let txIDs = bankSeite[schluessel], txIDs.count == 1
            else { return nil }
            return (txID: txIDs[0], kategorie: kategorien[0])
        }
    }

    /// Eine Zeile.
    ///
    /// Vorzeichenkonvention wie im OFX- und CAMT-Importer: Bei negativem Betrag ist
    /// die Gegenseite der Gläubiger, bei positivem der Schuldner. `name` wird auf zwei
    /// Wörter gekürzt, weil daran Fixkosten, Abo-Erkennung und Zuordnungsregeln
    /// hängen; der ungekürzte Name geht nach `fullName`.
    static func buchung(_ umsatz: MoneyMoneyUmsatz,
                        kategorie: String?) -> TransactionsResponse.Transaction {
        let gegenseite = TransactionsResponse.Party(
            name: YaxiService.truncateName(umsatz.gegenseiteName),
            fullName: umsatz.gegenseiteName,
            iban: umsatz.gegenseiteIban,
            bic: umsatz.gegenseiteBic
        )
        let hinaus = umsatz.betrag < 0
        var buchung = TransactionsResponse.Transaction(
            bookingDate: MoneyMoneyLeseregeln.tag(ausEpoche: umsatz.gebuchtAm),
            valueDate: umsatz.wertgestelltAm.map(MoneyMoneyLeseregeln.tag(ausEpoche:)),
            status: "Booked",
            endToEndId: umsatz.endeZuEnde,
            amount: TransactionsResponse.Amount(
                currency: umsatz.waehrung ?? "EUR",
                amount: MoneyMoneyLeseregeln.betrag(umsatz.betrag)
            ),
            creditor: hinaus ? gegenseite : nil,
            debtor: hinaus ? nil : gegenseite,
            remittanceInformation: umsatz.zweck.map { [$0] },
            additionalInformation: umsatz.buchungstext,
            purposeCode: nil
        )
        // Nur zum Weitergeben an den Kategorie-Override: `TransactionRecord.init`
        // verwirft dieses Feld und kategorisiert neu, die Kategorie wird deshalb
        // NACH dem Upsert über `TransactionCategorizer.saveOverride` gesetzt.
        buchung.category = kategorie
        return buchung
    }
}

// MARK: - Lesepfad

enum MoneyMoneyFehler: Error, LocalizedError {
    case helferFehlt
    case keineDatei
    case kennwortFalsch
    case schemaUnbekannt
    case lesefehler
    case inBenutzung
    case auszugUnlesbar

    init(abbruchcode: Int32) {
        switch MoneyMoneyLesefehler(rawValue: abbruchcode) {
        case .keineDatei:      self = .keineDatei
        case .kennwortFalsch:  self = .kennwortFalsch
        case .schemaUnbekannt: self = .schemaUnbekannt
        case .inBenutzung:     self = .inBenutzung
        case .lesefehler, nil: self = .lesefehler
        }
    }

    var errorDescription: String? {
        switch self {
        case .helferFehlt:
            return L10n.t("Der Importhelfer fehlt in dieser Installation.",
                          "The import helper is missing from this installation.")
        case .keineDatei:
            // Nennt beide Möglichkeiten, weil der Helfer sie nicht unterscheiden kann:
            // Ein verweigerter Zugriff und eine fehlende Datei sehen für ihn gleich aus.
            // Der häufigere Fall steht vorn — MoneyMoneys Ordner ist der Container einer
            // anderen App, und den gibt macOS erst auf Nachfrage frei.
            return L10n.t("Die MoneyMoney-Datenbank ließ sich nicht öffnen. Meist fehlt simplebanking der Zugriff auf den Ordner von MoneyMoney: Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff, dort simplebanking mit „+“ hinzufügen.",
                          "The MoneyMoney database could not be opened. Usually simplebanking lacks access to MoneyMoney's folder: System Settings → Privacy & Security → Full Disk Access, add simplebanking there with “+”.")
        case .kennwortFalsch:
            return L10n.t("Das Kennwort passt nicht zu dieser MoneyMoney-Datenbank.",
                          "That password does not open this MoneyMoney database.")
        case .schemaUnbekannt:
            return L10n.t("Diese MoneyMoney-Fassung speichert anders, als der Import erwartet.",
                          "This version of MoneyMoney stores its data differently than the import expects.")
        case .lesefehler:
            return L10n.t("Die MoneyMoney-Datenbank konnte nicht gelesen werden.",
                          "The MoneyMoney database could not be read.")
        case .inBenutzung:
            return L10n.t("MoneyMoney arbeitet gerade in der Datenbank. "
                          + "Bitte MoneyMoney beenden und es noch einmal versuchen.",
                          "MoneyMoney is currently writing to its database. "
                          + "Please quit MoneyMoney and try again.")
        case .auszugUnlesbar:
            return L10n.t("Der Importhelfer hat eine unerwartete Antwort gegeben.",
                          "The import helper returned an unexpected answer.")
        }
    }
}

/// Startet `simplebanking-mmimport` und liest dessen Auszug.
///
/// Der Helfer ist ein eigener Prozess, weil er SQLCipher linkt und die App das
/// System-SQLite — dieselben `sqlite3_*`-Symbole. Und weil in der MoneyMoney-Datei
/// neben den Umsätzen `pins` (die Bank-PIN) und `banks.privkey` liegen: so lebt der
/// entschlüsselte Zugriff in einem kurzlebigen Prozess statt im Adressraum einer
/// Banking-App.
enum MoneyMoneyLesepfad {

    /// Der Standardort der MoneyMoney-Datenbank.
    static let ueblicherOrt = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.moneymoney-app.retail/Data/"
                                + "Library/Application Support/MoneyMoney/Database/MoneyMoney.sqlite")

    /// Benutzt dieser Mensch MoneyMoney? Gefragt wird LaunchServices, nicht das
    /// Dateisystem.
    ///
    /// Hier stand `isReadableFile` auf der Datenbank. Das benutzt `access(2)`, und für
    /// den Container einer anderen App verweigert macOS das seit Sonoma ohne
    /// Rückfrage — die Antwort war also auf jedem Rechner ohne Festplattenvollzugriff
    /// `false`, und der Assistent bot den Umstieg nie an (13.11.2026). Ob die App
    /// installiert ist, beantwortet ohnehin die bessere Frage: Die Datei lesen wir
    /// erst, wenn der Nutzer es verlangt, und dann fragt macOS selbst.
    static var istVorhanden: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.moneymoney-app.retail") != nil
    }

    /// Neben dem laufenden Programm — im Bundle `Contents/MacOS/`, bei einem
    /// SwiftPM-Lauf im Bauordner. Beides ist derselbe Ort relativ zur eigenen Datei.
    static var helfer: URL? {
        guard let eigenes = Bundle.main.executableURL else { return nil }
        let kandidat = eigenes.deletingLastPathComponent()
            .appendingPathComponent("simplebanking-mmimport")
        return FileManager.default.isExecutableFile(atPath: kandidat.path) ? kandidat : nil
    }

    /// `helferPfad` ist nur für den Echtlauf-Test gedacht: Dort ist
    /// `Bundle.main.executableURL` die XCTest-Hülle, und der Helfer liegt nicht
    /// daneben, sondern im Bauordner. In der App bleibt der Standard.
    static func auszug(datenbank: URL = ueblicherOrt, kennwort: String,
                       helferPfad: URL? = nil) throws -> MoneyMoneyAuszug {
        guard let gewaehlt = helferPfad ?? helfer else { throw MoneyMoneyFehler.helferFehlt }
        let prozess = Process()
        prozess.executableURL = gewaehlt
        prozess.arguments = [datenbank.path]
        let eingabe = Pipe(), ausgabe = Pipe(), meldungen = Pipe()
        prozess.standardInput = eingabe
        prozess.standardOutput = ausgabe
        prozess.standardError = meldungen
        do { try prozess.run() } catch { throw MoneyMoneyFehler.helferFehlt }

        // Kennwort über stdin, nie als Argument — Argumente stehen für jeden Prozess
        // der Sitzung in `ps`.
        eingabe.fileHandleForWriting.write(Data(kennwort.utf8))
        try? eingabe.fileHandleForWriting.close()

        // VOR `waitUntilExit` lesen: Der Auszug ist größer als der Rohrpuffer
        // (2 MB bei 2058 Umsätzen, Puffer 64 KB). Erst warten, dann lesen hieße,
        // dass der Helfer beim Schreiben blockiert und wir beim Warten.
        let daten = ausgabe.fileHandleForReading.readDataToEndOfFile()
        _ = meldungen.fileHandleForReading.readDataToEndOfFile()
        prozess.waitUntilExit()

        guard prozess.terminationStatus == 0 else {
            throw MoneyMoneyFehler(abbruchcode: prozess.terminationStatus)
        }
        do {
            return try PropertyListDecoder().decode(MoneyMoneyAuszug.self, from: daten)
        } catch {
            throw MoneyMoneyFehler.auszugUnlesbar
        }
    }
}
