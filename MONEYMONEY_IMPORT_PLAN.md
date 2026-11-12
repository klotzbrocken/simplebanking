# MoneyMoney-Import

Entwurf für 2.2. Ziel: Ein Umsteiger richtet simplebanking ein, und der Assistent
übernimmt dabei seine MoneyMoney-Konten, deren Verlauf und die erste Ebene seiner
Kategorien.

**Entschieden** (11.11.2026): Teil des Einrichtungsassistenten, nicht der Einstellungen.
Nur Konten, die über YAXI/Open Banking erreichbar sind — Offline-Konten, Bargeld,
Versicherungsverträge und Depots werden übergangen. Die Zwei-Faktor-Anmeldung läuft
unverändert, der Verlauf kommt danach. Quelle ist die MoneyMoney-Datenbank, nicht die
AppleScript-Schnittstelle.

---

## 1 Befund

Alles unten ist an einer echten MoneyMoney-2.5.3-Datenbank gemessen, nicht angenommen.

**Die Datei ist gewöhnliches SQLCipher 4.** `PRAGMA key` mit dem Kennwort des Nutzers,
dann `SELECT count(*) FROM sqlite_master` → `77`. SQLCipher 3 und 2 scheitern mit
`file is not a database`. Es gibt hier kein Format zurückzubauen; die Datei ist mit dem
Kennwort, das der Nutzer selbst gesetzt hat, mit Standardwerkzeug lesbar.

**Die Zahlen deckten sich mit der Schnittstelle**, was beide Wege bestätigt:
2058 Umsätze, 3 Konten plus 1 Kontengruppe, 1 Kategorie, 3 ungebuchte Posten.

**Das Datum ist Epoch-UTC auf 12:00.** `transactions.timestamp = 1794398400`
= 2026-11-11 12:00 UTC. Lokal formatiert liefert das östlich von UTC+12 den Folgetag.
Gelesen und formatiert wird **in UTC**, `yyyy-MM-dd`.

**Beträge sind `REAL`, keine Cent-Ganzzahlen.** Die Umwandlung in die Zeichenkette
entscheidet den Fingerprint; `%.2f` ist verbindlich, nicht `description`.

---

## 2 Was in derselben Datei liegt — und die drei Zusagen

```sql
CREATE TABLE pins  (bank_key INTEGER PRIMARY KEY, pin TEXT);
CREATE TABLE banks (… username, customer, credential, tanmethod,
                      tanmedium, systemid, pubkey BLOB, privkey BLOB …);
```

Wer diese Datei entschlüsselt, hat die Bank-PIN und den HBCI-Privatschlüssel des Nutzers
im Zugriff. Die AppleScript-Schnittstelle hatte das nicht. Daraus folgen drei Regeln,
die nicht verhandelbar sind:

1. **Kein `SELECT *`.** Jede Abfrage nennt ihre Spalten. `pins` und `banks` werden nie
   geöffnet.
2. **Keine entschlüsselte Kopie.** Kein `sqlcipher_export`, keine Zwischendatei, kein
   „einmal nach /tmp". Eine entschlüsselte Kopie wäre die Bank-PIN im Klartext auf der
   Platte — ein größerer Schaden als der Nutzen des gesamten Imports.
3. **Nur lesend, keine Diagnose.** Der Helfer öffnet `readonly`, schreibt kein Log, keine
   Absturzdatei und keine Diagnosemappe mit Datenbankinhalt.

Alle drei werden über `Tests/simplebankingTests/Quelltext.swift` geprüft — demselben
Helfer, der die anderen Zusagen dieses Projekts festhält, die kein Typ erzwingen kann.

---

## 3 Architektur: ein vierter Executable

**SQLCipher darf nicht in die App.** GRDBs SPM-Paket bietet genau ein SQLite: `CSQLite`
als `systemLibrary`, also `/usr/lib/libsqlite3.dylib`. SQLCipher ist ein SQLite-Fork mit
**denselben** `sqlite3_*`-Symbolen. Beides in einem Binary heißt doppelte Symbole beim
Linken oder — schlimmer — dyld bindet zur Laufzeit die falsche Seite. Zetetic verlangt
deshalb, `libsqlite3` aus der Linkliste zu nehmen; das ist hier unmöglich, weil die
eigene Datenbank der App daran hängt.

Also ein eigener Prozess, passend zu den drei Zielen, die `Package.swift` schon hat:

| Ziel | Rolle |
|---|---|
| `simplebanking` | App. Linkt SQLCipher **nicht**, startet den Helfer. |
| `simplebanking-mmimport` *(neu)* | Linkt SQLCipher, liest die MoneyMoney-Datenbank, schreibt ein Plist auf stdout, beendet sich. |

Zwei Prozesse, zwei SQLite-Welten, kein gemeinsamer Symbolnamensraum — das Problem ist
weg, nicht umgangen. Nebengewinne: das Kennwort lebt in einem kurzlebigen Prozess statt
im Adressraum der Banking-App, und ein Absturz im Fremdformat reißt die App nicht mit.
`sign-and-notarize.sh` signiert verschachtelte Binaries bereits.

Die Parse- und Zuordnungsschicht liegt in der App und ist quellenneutral. Der
AppleScript-Weg (geprüft: 2058 Umsätze, 2,0 MB, 0,17 s) ließe sich später ohne neue
Zuordnungsarbeit als zweite Quelle anhängen, falls der Kennwortdialog störend wirkt.

---

## 4 Zuordnung

| MoneyMoney | simplebanking |
|---|---|
| `accounts.iban`, `.bic`, `.currency`, `.name`, `.owner` | Slot-Zuordnung und YAXI-Prüfung |
| `transactions.local_account_key` → `accounts.rowid` | welcher Slot |
| `transactions.account`, `.bankcode` | `Party.iban`, `.bic` — **die Gegenseite** |
| `.amount` (REAL), `.currency` | `Amount`, `%.2f` |
| `.timestamp`, `.value_timestamp` | `bookingDate`, `valueDate` — UTC, `yyyy-MM-dd` |
| `.name` | `creditor.name` bei negativem, `debtor.name` bei positivem Betrag |
| `.unformatted_purpose` | `remittanceInformation` |
| `.eref` | `endToEndId` |
| `.mref`, `.cred`, `.rtrn`, `.ocmt`, `.exch` | `raw_json` |
| `.booked` | `status` — nur `1` wird importiert |
| `.category_key` → `categories.rowid` | Kategorie-Override |

Ziel ist `TransactionsResponse.Transaction` → `TransactionsDatabase.upsert`, also genau
die Strecke, die `Importers/OFXImporter.swift` benutzt. Vorzeichenkonvention von dort
übernehmen, nicht neu erfinden.

**Die Kategorie kann nicht mitgeschickt werden.** `TransactionRecord.init` verwirft
`transaction.category` und kategorisiert immer neu. Sie kommt nach dem Upsert über
`TransactionCategorizer.saveOverride(txID:slotId:category:)` — dieselbe Ablage wie eine
Zuordnung von Hand, stärker als Regel und Heuristik, übersteht jeden Abruf.

**Und sie muss gebündelt geschrieben werden.** `saveOverride` liest das vollständige
Wörterbuch, ändert einen Eintrag und schreibt es zurück. Bei 2058 fällt das nicht auf;
ein Umsteiger mit zehn Jahren hat 50.000, und das wären 50.000 vollständige
Plist-Schreibvorgänge. Es braucht **eine** Bündelfunktion, keinen neuen Speicher.

---

## 5 Ablauf im Assistenten

`SetupFlowPanel` ist AppKit und führt heute eine Bank:
`welcome → masterPassword → bankSearch → credentials → connecting → accountPicker → onboarding`.

Neu:

```
welcome → masterPassword
  → [neu] MoneyMoney gefunden: Kennwort, dann Konten auswählen
  → je Bank:  credentials → connecting → accountPicker → erster Abruf
                 → [neu] Verlauf + Kategorien übernehmen
  → onboarding
```

`bankSearch` entfällt, weil die Antwort schon vorliegt: **YAXI beantwortet die
Erreichbarkeitsfrage selbst.** `search(filters: [.term(iban)], ibanDetection: true)`
liefert zu einer IBAN die Verbindungen des passenden Bankleitzahlbereichs. Treffer heißt
erreichbar, kein Treffer heißt übergehen — belastbarer als der Kontotyp, den MoneyMoney
draufschreibt, und der Nutzer muss seine Bank nicht suchen.

**Die Reihenfolge ist nicht beliebig.** Der Verlauf läuft erst **nach** dem ersten
YAXI-Abruf. Der Slot muss existieren (`slot_id` steckt im Primärschlüssel), und die Naht
braucht einen Bezugspunkt: importiert wird nur, was **älter** ist als die älteste
Buchung, die der Slot schon hat. Läuft der Import davor, gibt es keine älteste Buchung,
er zieht alles bis heute herein, und der erste Abruf legt die letzten 90 Tage doppelt
daneben.

**Die Naht ist ein Datum, kein Hash.** Der Fingerprint ist ein SHA256 über Datum,
Betrag, Namen, Zweck und Buchungstext. Derselbe Umsatz aus MoneyMoney und aus dem
Bankabruf trifft denselben Schlüssel nur bei zeichengenau gleichem Text — ein
Leerzeichen im Zweck genügt, und er trifft ihn nicht. Ein Datum kann nicht halb daneben
liegen.

**Abbruch muss ein Zustand sein.** Bricht die Anmeldung bei Bank drei von fünf ab, sind
zwei Slots samt Verlauf da und drei nicht. Der Assistent macht beim nächsten Start dort
weiter, vergisst die Auswahl nicht und importiert nicht doppelt.

---

## 6 Was nicht importiert wird

- **Ungebuchte Posten** (`booked = 0`, 3 von 2058). Sie sind flüchtig, die Bank liefert
  sie sowieso, und als importierte Zeile werden sie nie gebucht — sie bleiben als Geister
  liegen, an denen `purgeStalePending` vorbeiläuft.
- **Geteilte Buchungen** (`splitted = 1`). MoneyMoney teilt eine Bankbuchung auf mehrere
  Kategorien; unser Modell hat eine Kategorie pro Buchung. Ungefiltert wird daraus ein
  Satz Dubletten, der dieselbe Bankbuchung mehrfach zählt. **Nicht** auf `split_key`
  filtern: der ist bei allen 2058 Zeilen belegt und dient der Sortierung.
- **Die Standardkategorie.** `categories.rowid = 1` hat `name = ''` — leer. MoneyMoney
  setzt „Unkategorisiert" erst zur Laufzeit. Importiert man sie, bekommt jeder Umsteiger
  als erstes eine Kategorie geschenkt, die nichts aussagt.
- **Depots und Versicherungsverträge** (`accounts.portfolio = 1`, `type = 9`, ohne IBAN).
- **Kontostände** (`accounts.balances` ist ein 21-Byte-BLOB unbekannter Form). Der Stand
  kommt von der Bank.
- **Kontoauszüge** (`statements` zeigt auf PDFs außerhalb der Datenbank).
- **Daueraufträge und Vorlagen** (`payments`) — eigene Runde, siehe `Dauerauftrag.swift`.
- **Nichts wird zurückgeschrieben.** Die AppleScript-Schnittstelle bietet
  `add transaction` und `set transaction`; wir benutzen sie nie. Dieser Satz steht im
  Quelltext, bevor jemand auf die Idee mit dem Abgleich kommt.

---

## 7 Offene Punkte

**Der Verwendungszweck.** Es gibt `unformatted_purpose` (2051 von 2058 belegt) und
`a1794240104` (ebenfalls 2051, gleiche Länge in der Stichprobe). Eine Spalte `purpose`
existiert nicht. `a1794240104` ist nach einem Epoch-Zeitstempel benannt —
**2026-11-09 17:01:44**, zwei Tage vor diesem Entwurf: ein Migrationsgrabstein. Der
Entwurf liest `unformatted_purpose`, weil nur dieser Name eine Bedeutung hat und
überlebt. Offen bleibt, ob der Grabstein den aufbereiteten Text hält und wir damit
rauere Texte importieren als MoneyMoney anzeigt. Klärt eine Zeile:

```sql
SELECT count(*), sum(a1794240104 = unformatted_purpose) FROM transactions;
```

MoneyMoney bereitet Texte nachweislich auf: `name` weicht in 485 von 2058 Zeilen von
`unformatted_name` ab, bei `nopretty = 0` überall.

**Der Kategorienbaum.** `categories.group_key` zeigt auf `category_groups.rowid`; die
Schnittstelle glättete das zu `Mobilität\Bahn` plus `indentation`. Für „erste Ebene" muss
der Helfer den Baum selbst hochlaufen — **und das ist an der Messdatenbank nicht
prüfbar**: eine Kategorie, null Gruppen. Das bleibt die Stelle, die erst mit einer echten
Umsteiger-Datenbank belastbar wird.

**Die Schemastabilität.** Der Grabstein vom 09.11.2026 ist der Beleg, dass MoneyMoney
seine Tabellen ohne Ankündigung umbaut. Der Helfer prüft deshalb beim Start die Spalten,
die er braucht, und bricht mit einem klaren Satz ab, wenn eine fehlt — er rät nicht und
liest nichts halb.

---

## 8 Verifikation

1. `swift build`, `swift test` — derzeit 1592 grün, harte Schranke.
2. **Reine Funktionen, mit eingespeisten Werten:** Epoch → `yyyy-MM-dd` in UTC
   (Grenzfälle UTC−12 und UTC+13, dort bricht die lokale Formatierung);
   `REAL` → Betragszeichenkette (`-20.0` → `"-20.00"`); Vorzeichen →
   `creditor`/`debtor`; Fingerprint einer zugeordneten Buchung gegen einen festen
   Erwartungswert, damit die Formel nicht unbemerkt wandert.
3. **Filterzusagen:** `booked = 0`, `splitted = 1`, `portfolio = 1`, Standardkategorie —
   je ein Test mit einer Zeile, die hineinfällt, und einer, die nicht.
4. **Die Naht:** ein Slot mit Buchungen ab Datum X, Import mit Buchungen vor und nach X →
   nur die vor X landen in der Datenbank, die Zahl der Zeilen ist vorher wie nachher
   bekannt.
5. **Quelltext-Zusagen** über `Quelltext.swift`: kein `SELECT *` im Helfer, kein
   Vorkommen von `pins` oder `banks`, kein `sqlcipher_export`, kein Schreibpfad.
6. **Was kein Test leisten kann, und das bleibt so gesagt:** dass MoneyMoneys Schema in
   der nächsten Fassung noch so heißt; dass der Kategorienbaum bei echten Umsteigern so
   hochläuft wie entworfen; dass der Nutzer bereit ist, sein MoneyMoney-Kennwort in
   simplebanking einzugeben.

---

## 9 Reihenfolge

Nicht in 2.1.0 — die ist inhaltlich zu und wartet auf den VoiceOver-Testbau. Ein neuer
Schritt im Einrichtungsassistenten ist das Gegenteil davon.

1. Helfer samt vierter Zielzeile in `Package.swift`, Lesepfad, die drei Zusagen.
2. Zuordnung und Naht als reine Funktionen, mit Tests.
3. Assistentenschritt und Warteschlange über die Banken.
4. Bündelfunktion für die Kategorie-Overrides.
5. `CHANGELOG.md`, `WhatsNewContent.highlights(for:)` — ohne den `case` erscheint beim
   Update kein „Was ist neu".
