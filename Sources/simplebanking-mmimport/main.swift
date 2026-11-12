import Foundation
import MoneyMoneyForm
import SQLCipher

// simplebanking-mmimport — liest eine MoneyMoney-Datenbank und schreibt sie als
// Plist auf stdout.
//
// WARUM EIN EIGENER PROZESS: GRDB linkt das System-SQLite, SQLCipher ist ein
// SQLite-Fork mit denselben `sqlite3_*`-Symbolen. Beides in einem Binary heißt
// doppelte Symbole beim Linken oder — schlimmer — dyld bindet zur Laufzeit die
// falsche Seite. Zwei Prozesse lösen das, statt es zu umgehen.
//
// WARUM DAS AUCH SICHERHEIT IST: In derselben Datei liegen `pins` (die Bank-PIN) und
// `banks.privkey` (der HBCI-Privatschlüssel). Drei Zusagen, geprüft von
// `MoneyMoneyHelferTests` über den Quelltext:
//
//   1. Kein `SELECT *`. Jede Abfrage nennt ihre Spalten.
//      `pins` und `banks` werden nie geöffnet.
//   2. Keine entschlüsselte Kopie. Kein `sqlcipher_export`, keine Zwischendatei.
//      Eine entschlüsselte Kopie wäre die Bank-PIN im Klartext auf der Platte.
//   3. Nur lesend, keine Diagnose. `SQLITE_OPEN_READONLY`, kein Log, keine
//      Absturzdatei, kein Datenbankinhalt auf stderr.
//
// Das Kennwort kommt über **stdin**, nicht über die Befehlszeile: Argumente stehen
// für jeden Prozess der Sitzung in `ps`.

// MARK: - Abbruch

func abbrechen(_ fehler: MoneyMoneyLesefehler, _ hinweis: String) -> Never {
    // Bewusst ohne Datenbankinhalt — nur die Kennung und ein Satz über den Zustand.
    FileHandle.standardError.write(Data("\(fehler.kennung): \(hinweis)\n".utf8))
    exit(fehler.rawValue)
}

// MARK: - Spaltenzugriff

func text(_ satz: OpaquePointer?, _ spalte: Int32) -> String? {
    guard let rohe = sqlite3_column_text(satz, spalte) else { return nil }
    let wert = String(cString: rohe)
    return wert.isEmpty ? nil : wert
}

func ganzzahl(_ satz: OpaquePointer?, _ spalte: Int32) -> Int64? {
    sqlite3_column_type(satz, spalte) == SQLITE_NULL ? nil : sqlite3_column_int64(satz, spalte)
}

func abfrage(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
    var satz: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &satz, nil) == SQLITE_OK else { return nil }
    return satz
}

// MARK: - Öffnen

let argumente = CommandLine.arguments
guard argumente.count == 2 else {
    abbrechen(.keineDatei, "Aufruf: simplebanking-mmimport <pfad zur MoneyMoney.sqlite>")
}
let pfad = argumente[1]
guard FileManager.default.isReadableFile(atPath: pfad) else {
    abbrechen(.keineDatei, "Datei nicht lesbar")
}

// Kennwort von stdin. Genau ein abschließender Zeilenumbruch fällt weg, damit die
// Eingabe durch eine Pipe dasselbe ergibt wie eine ohne.
var kennwort = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
if kennwort.hasSuffix("\n") { kennwort.removeLast() }
guard !kennwort.isEmpty else { abbrechen(.kennwortFalsch, "Kein Kennwort über stdin erhalten") }

var db: OpaquePointer?
guard sqlite3_open_v2(pfad, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    abbrechen(.keineDatei, "Datei konnte nicht geöffnet werden")
}
defer { sqlite3_close(db) }

let kennwortBytes = Array(kennwort.utf8)
guard sqlite3_key(db, kennwortBytes, Int32(kennwortBytes.count)) == SQLITE_OK else {
    abbrechen(.kennwortFalsch, "Schlüssel wurde nicht angenommen")
}
kennwort.removeAll()

// `sqlite3_key` antwortet immer OK — es setzt den Schlüssel, es prüft ihn nicht.
// Geprüft wird erst beim ersten echten Lesezugriff.
guard let probe = abfrage(db, "SELECT count(*) FROM sqlite_master") else {
    // Auch hier entscheidet der SQLite-Code. Bei unaufgeräumtem Journal scheitert
    // schon das Vorbereiten — es liest das Schema —, der Lauf kommt also nie bis
    // zum `step` unten. Ein festverdrahtetes „kennwort-falsch" an dieser Stelle
    // schickte genau in die Richtung, die der 11.11.2026 abschaffen sollte.
    abbrechen(MoneyMoneyLesefehler.fuer(sqliteCode: sqlite3_errcode(db)),
              "Abfrage nicht vorzubereiten (SQLite \(sqlite3_errcode(db)))")
}
if sqlite3_step(probe) != SQLITE_ROW {
    // Der SQLite-Code entscheidet, nicht die Vermutung. Er geht als nackte Zahl
    // nach stderr — kein Inhalt der Datenbank, nur der Grund.
    let code = sqlite3_errcode(db)
    sqlite3_finalize(probe)
    abbrechen(MoneyMoneyLesefehler.fuer(sqliteCode: code),
              "Erster Lesezugriff gescheitert (SQLite \(code))")
}
sqlite3_finalize(probe)

// MARK: - Schemazusage

for (tabelle, spalten) in MoneyMoneyLeseregeln.benoetigteSpalten {
    guard let satz = abfrage(db, "PRAGMA table_info(\(tabelle))") else {
        abbrechen(.schemaUnbekannt, "Tabelle \(tabelle) nicht lesbar")
    }
    var vorhanden = Set<String>()
    while sqlite3_step(satz) == SQLITE_ROW {
        if let name = text(satz, 1) { vorhanden.insert(name) }
    }
    sqlite3_finalize(satz)
    guard !vorhanden.isEmpty else {
        abbrechen(.schemaUnbekannt, "Tabelle \(tabelle) fehlt")
    }
    let fehlend = spalten.filter { !vorhanden.contains($0) }
    guard fehlend.isEmpty else {
        abbrechen(.schemaUnbekannt,
                  "In \(tabelle) fehlen Spalten: \(fehlend.sorted().joined(separator: ", "))")
    }
}

// MARK: - Konten

var konten: [MoneyMoneyKonto] = []
guard let kontenSatz = abfrage(db, """
    SELECT rowid, iban, bic, currency, name, owner, portfolio FROM accounts
    """) else { abbrechen(.lesefehler, "accounts nicht lesbar") }
while sqlite3_step(kontenSatz) == SQLITE_ROW {
    konten.append(MoneyMoneyKonto(
        schluessel: sqlite3_column_int64(kontenSatz, 0),
        iban: text(kontenSatz, 1) ?? "",
        bic: text(kontenSatz, 2),
        waehrung: text(kontenSatz, 3),
        name: text(kontenSatz, 4),
        inhaber: text(kontenSatz, 5),
        istDepot: (ganzzahl(kontenSatz, 6) ?? 0) != 0
    ))
}
sqlite3_finalize(kontenSatz)

// MARK: - Kategorien

// Gruppen zuerst, damit der Pfad einer Kategorie hochgelaufen werden kann.
// MoneyMoney verschachtelt über `group_key` → `category_groups.rowid`; `0` heißt
// „keine Eltern".
var gruppen: [Int64: MoneyMoneyGruppe] = [:]
guard let gruppenSatz = abfrage(db, "SELECT rowid, name, group_key FROM category_groups") else {
    abbrechen(.lesefehler, "category_groups nicht lesbar")
}
while sqlite3_step(gruppenSatz) == SQLITE_ROW {
    gruppen[sqlite3_column_int64(gruppenSatz, 0)] = MoneyMoneyGruppe(
        name: text(gruppenSatz, 1) ?? "",
        elternSchluessel: ganzzahl(gruppenSatz, 2) ?? 0
    )
}
sqlite3_finalize(gruppenSatz)

var kategorien: [MoneyMoneyKategorie] = []
guard let katSatz = abfrage(db, "SELECT rowid, name, group_key FROM categories") else {
    abbrechen(.lesefehler, "categories nicht lesbar")
}
while sqlite3_step(katSatz) == SQLITE_ROW {
    kategorien.append(MoneyMoneyKategorie(
        schluessel: sqlite3_column_int64(katSatz, 0),
        pfad: MoneyMoneyLeseregeln.pfad(name: text(katSatz, 1) ?? "",
                                        elternSchluessel: ganzzahl(katSatz, 2) ?? 0,
                                        gruppen: gruppen)
    ))
}
sqlite3_finalize(katSatz)

// MARK: - Umsätze

// `account` und `bankcode` tragen auf der Buchung die **Gegenseite**, nicht das
// eigene Konto — das steckt in `local_account_key`. Der Spaltenname legt das
// Gegenteil nahe, und genau daran scheitert eine Zuordnung, die ihn wörtlich nimmt.
//
// `unformatted_purpose` und nicht `a1794240104`: Letztere ist nach einem
// Epoch-Zeitstempel benannt (2026-11-09 17:01:44) und damit ein Migrationsgrabstein.
var umsaetze: [MoneyMoneyUmsatz] = []
guard let umsatzSatz = abfrage(db, """
    SELECT local_account_key, amount, currency, timestamp, value_timestamp,
           name, account, bankcode, unformatted_purpose, unformatted_type,
           eref, mref, cred, rtrn, category_key, booked, splitted
      FROM transactions
     ORDER BY timestamp ASC, rowid ASC
    """) else { abbrechen(.lesefehler, "transactions nicht lesbar") }
while sqlite3_step(umsatzSatz) == SQLITE_ROW {
    umsaetze.append(MoneyMoneyUmsatz(
        kontoSchluessel: sqlite3_column_int64(umsatzSatz, 0),
        betrag: sqlite3_column_double(umsatzSatz, 1),
        waehrung: text(umsatzSatz, 2),
        gebuchtAm: sqlite3_column_int64(umsatzSatz, 3),
        wertgestelltAm: ganzzahl(umsatzSatz, 4),
        gegenseiteName: text(umsatzSatz, 5),
        gegenseiteIban: text(umsatzSatz, 6),
        gegenseiteBic: text(umsatzSatz, 7),
        zweck: text(umsatzSatz, 8),
        buchungstext: text(umsatzSatz, 9),
        endeZuEnde: text(umsatzSatz, 10),
        mandat: text(umsatzSatz, 11),
        glaeubiger: text(umsatzSatz, 12),
        rueckgabegrund: text(umsatzSatz, 13),
        kategorieSchluessel: ganzzahl(umsatzSatz, 14),
        istGebucht: (ganzzahl(umsatzSatz, 15) ?? 1) != 0,
        istGeteilt: (ganzzahl(umsatzSatz, 16) ?? 0) != 0
    ))
}
sqlite3_finalize(umsatzSatz)

// MARK: - Hinausschreiben

let auszug = MoneyMoneyAuszug(konten: konten, kategorien: kategorien, umsaetze: umsaetze)
let kodierer = PropertyListEncoder()
kodierer.outputFormat = .binary
do {
    FileHandle.standardOutput.write(try kodierer.encode(auszug))
} catch {
    abbrechen(.lesefehler, "Auszug konnte nicht geschrieben werden")
}
