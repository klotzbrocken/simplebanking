# simplebanking im Mac App Store

## Detaillierter Umbau-, Prüf- und Einreichungsplan

**Stand:** 26. Juli 2026  
**Ziel:** simplebanking so vorbereiten, dass die Anwendung technisch, architektonisch, rechtlich und in der Benutzerführung für eine erneute Einreichung in den Mac App Store geeignet ist.  
**Wichtig:** Dieses Dokument ist ein Plan. Es beschreibt notwendige und empfohlene Änderungen, nimmt selbst aber keine Änderungen am Programmcode vor.

---

## 1. Kurzfassung

simplebanking besitzt genügend Funktionsumfang und eigenständigen Nutzen für eine Veröffentlichung im Mac App Store. Der derzeitige Entwicklungsstand sollte jedoch nicht unverändert eingereicht werden.

Die größten Risiken sind:

1. Apples besondere Anforderungen an Banking- und Money-Management-Apps.
2. Die rechtliche Rolle von simplebanking, YAXI/Routex und den Banken.
3. Ein im Client enthaltenes YAXI-Signiergeheimnis.
4. Ein nicht mehr konsequent vom Direktvertrieb getrennter App-Store-Build.
5. Sparkle-, MCP-, CLI-, Symlink- und Prozessfunktionen, die im App-Store-Build nicht enthalten sein sollten.
6. Die bereits beanstandete Menü-/Kontextmenü-Konstruktion.
7. Nicht oder nur schwer sandboxfähige Funktionen.
8. Händler-Integrationen über Web-Sitzungen und nicht eindeutig öffentliche Schnittstellen.
9. Externe Lizenzierung von innerhalb der App freigeschalteten Funktionen.
10. Datenschutzanforderungen für Bank-, Einkaufs-, Diagnose- und KI-Daten.

**Der Originaltext der damaligen Ablehnung liegt inzwischen vor** und ist wörtlich in
[8.1](#81-hintergrund-der-früheren-ablehnung) und [12.5](#125-die-zweite-ablehnung-api-schlüssel-statt-in-app-purchase)
zitiert. Er bestätigt Punkt 6 der Liste oben — und ergänzt einen Punkt, der in diesem
Plan bisher **falsch eingeordnet** war: Apple beanstandete nicht nur die Menüführung,
sondern auch, dass **vom Nutzer eingetragene API-Schlüssel Funktionen freischalten**.
Das betrifft die KI-Anbieter-Schlüssel und wurde bisher ausschließlich als
Datenschutzfrage behandelt (13.5). Es ist zusätzlich eine Frage des Geschäftsmodells,
und die Konsequenz ist schärfer: Ein Opt-in genügt nicht, der Mechanismus muss aus dem
Store-Build heraus.

Die empfohlene Strategie ist eine bewusst reduzierte erste App-Store-Version:

- Bankkonten über YAXI/Routex verbinden
- Kontostände und Umsätze
- Multibanking
- lokale Kategorien und Auswertungen
- Fixkosten und Abonnements
- vollständig nutzbarer Demo-Modus
- **simplesend als nicht verbrauchbarer In-App-Kauf** (entschieden, siehe 12.2)

Nicht Bestandteil der ersten App-Store-Version (entschieden):

- Sparkle
- MCP
- CLI
- Shell-Integration
- Symlink-Installation
- externe Lizenzschlüssel — ersetzt durch StoreKit
- **REWE, dm, Amazon und PayPal** (siehe 11.4)
- **Cloud-KI und jedes Eingabefeld für eigene KI-API-Schlüssel** (siehe 12.5)

---

## 2. Bedeutung der Prioritäten

| Priorität | Bedeutung |
|---|---|
| **P0** | Blockiert eine seriöse Einreichung. Muss vor dem eigentlichen Store-Umbau oder spätestens vor einem Test-Upload gelöst sein. |
| **P1** | Hohes Ablehnungs-, Sicherheits- oder Funktionsrisiko. Muss vor der Einreichung gelöst sein. |
| **P2** | Wichtig für Reviewbarkeit, Apple-konforme UX und ein belastbares Produkt. Sollte vor Version 1.0 abgeschlossen sein. |
| **P3** | Qualitäts-, Wartbarkeits- und Prozessverbesserung. Kann teilweise nach dem ersten Release folgen, sofern kein Review-Risiko besteht. |
| **PX** | Beobachtungspunkt oder bewusst zurückgestellte Erweiterung. Vor späterer Aktivierung erneut prüfen. |

---

## 3. Verbindliche Apple-Grundlagen

Vor und während des Umbaus sollten mindestens folgende Apple-Dokumente als verbindliche Referenz verwendet werden:

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App Review – typische Ablehnungsgründe](https://developer.apple.com/app-store/review/)
- [Human Interface Guidelines: Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Human Interface Guidelines: Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)
- [MenuBarExtra](https://developer.apple.com/documentation/SwiftUI/MenuBarExtra)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Manage App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Adding a Privacy Manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Offering Account Deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

### Besonders relevante Richtlinien

| Richtlinie | Bedeutung für simplebanking |
|---|---|
| **2.1 App Completeness** | Apple muss die App vollständig prüfen können. Demo-Modus, Testablauf und funktionierende Backends sind erforderlich. |
| **2.4.5 Mac App Store** | Sandbox, selbstenthaltenes Bundle, keine fremden Updateverfahren, kein ungefragter Autostart und keine nachinstallierten Werkzeuge. |
| **2.5.1 Public APIs** | Nur öffentliche und bestimmungsgemäß eingesetzte APIs verwenden. |
| **3.1.1 In-App Purchase** | Digitale App-Funktionen müssen grundsätzlich über In-App Purchase freigeschaltet werden. |
| **3.2.1(viii)** | Apps für Finanzhandel, Investitionen oder Money Management unterliegen besonderen Anforderungen an Anbieter, Lizenzen und Berechtigungen. |
| **4.2 Minimum Functionality** | Die App muss eigenständig nützlich und ausreichend „app-like“ sein. |
| **5.1 Privacy** | Sensible Daten, Einwilligung, Aufbewahrung, Löschung und Drittanbieter müssen transparent beschrieben werden. |
| **5.2.2 Third-Party Services** | Für verwendete Drittanbieterdienste und Inhalte müssen entsprechende Rechte beziehungsweise Berechtigungen bestehen. |

Apple kann Richtlinien verändern oder im konkreten Review anders auslegen. Vor dem finalen Upload ist deshalb ein erneuter Abgleich mit der dann aktuellen Fassung notwendig.

---

## 4. P0 – Rechtliche und organisatorische Zulässigkeit

### 4.1 Einreichende rechtliche Einheit klären

Apple nennt Banking und Finanzdienstleistungen ausdrücklich als regulierte Bereiche. Eine Einreichung durch eine Privatperson oder eine nicht zum angebotenen Dienst passende Einheit kann abgelehnt werden.

**Wortlaut der Regel (5.1.1(ix)):**

> Apps providing services in highly regulated fields (such as **banking and financial
> services**, healthcare, gambling, legal cannabis use, air travel and crypto exchanges)
> or that require sensitive user information **should be submitted by a legal entity that
> provides the services, and not by an individual developer.**

**Wie streng das ausgelegt wird — ein belegter Fall:** Im Apple-Entwicklerforum
beschreibt ein Entwickler einen Aggregator, der eine **offizielle, vom Anbieter
ausdrücklich unterstützte** API nutzt, **nichts speichert** und **nur liest**. Die App
war über ein Jahr im Store und flog bei einem Routine-Update unter genau dieser Regel
raus; Apple begründete inhaltlich nichts und verwies nur aufs Appeal-Verfahren
([Forum](https://developer.apple.com/forums/thread/740042)). Weder Datensparsamkeit noch
eine Freigabe des API-Anbieters haben dort geholfen.

**Ist-Zustand:** Das aktuelle Signaturzertifikat lautet auf „Maik Klotz (FTJLR8JRNS)",
also auf eine natürliche Person. Die Regel ist als „should" formuliert, es gibt also
Ermessensspielraum — aber keinen Anspruch. **Der gesamte übrige Umbau kann technisch
einwandfrei sein und trotzdem hieran scheitern.** Deshalb steht dieser Punkt vor allen
anderen: Er sollte über eine
[App-Review-Anfrage](https://developer.apple.com/contact/request/app-review/) oder eine
Probe-Einreichung einer minimalen Fassung geklärt werden, bevor Wochen in den Umbau
fließen.

#### Zu klären

- Wird die App über einen persönlichen oder einen organisatorischen Apple-Developer-Account eingereicht?
- Welche juristische Person ist Hersteller und Anbieter von simplebanking?
- Ist diese Einheit zur Vermarktung einer Money-Management- beziehungsweise Banking-Anwendung berechtigt?
- In welchen Ländern darf simplebanking angeboten werden?
- Welche Rolle übernimmt YAXI/Routex rechtlich und technisch?
- Wer ist für Kontoinformations- und Zahlungsauslösedienste verantwortlich?
- Darf simplesend öffentlich an Endkunden angeboten werden?

#### Empfohlene Unterlagen

- Handelsregister- beziehungsweise Unternehmensnachweis
- Anbieterkennzeichnung und ladungsfähige Anschrift
- Vertrag oder schriftliche Freigabe von YAXI/Routex
- Beschreibung der technischen und rechtlichen Rollen
- gegebenenfalls PSD2-/Kontoinformations-/Zahlungsauslösungsnachweise des Partners
- Liste freigegebener Länder
- Nachweis, dass Bank- und Händlernamen beziehungsweise Logos verwendet werden dürfen
- Datenschutzerklärung
- Nutzungsbedingungen
- Support- und Eskalationsprozess

#### Empfohlene Rollenbeschreibung

Eine mögliche sachliche Beschreibung für Apple:

> simplebanking ist eine lokale macOS-Anwendung zur Darstellung und Auswertung der eigenen Bankdaten. Die App eröffnet keine Konten, verwahrt keine Gelder und führt selbst keine Bankgeschäfte aus. Der technische Bankzugriff beziehungsweise die Zahlungsauslösung erfolgt über den angebundenen Banking-Dienst YAXI/Routex und die jeweilige Bank. Zugangsdaten werden lokal geschützt gespeichert; TAN- und SCA-Freigaben erfolgen im von der Bank vorgesehenen Ablauf.

Diese Beschreibung muss mit den tatsächlichen Verträgen, Datenflüssen und Funktionen übereinstimmen.

#### Abnahmekriterien

- [ ] Einreichende rechtliche Einheit ist festgelegt.
- [ ] YAXI-/Routex-Freigabe für öffentlichen App-Store-Vertrieb liegt schriftlich vor.
- [ ] simplesend ist rechtlich und vertraglich geklärt.
- [ ] Vertriebsregionen sind festgelegt.
- [ ] Dokumentationspaket für App Review ist vorbereitet.
- [ ] Marken- und Logorechte sind dokumentiert.

---

## 5. P0 – YAXI-Ticket-Sicherheit

### 5.1 Ist-Zustand

Der Client erzeugt lokal signierte YAXI-Tickets. Die Auswahl der Schlüssel findet in `Sources/simplebanking/YaxiTicketMaker.swift` statt. Der Mac-App-Store-Build verlangt dafür eine generierte `Sources/simplebanking/Secrets.swift`.

Ein symmetrisches HS256-Geheimnis in einer öffentlich ausgelieferten App kann aus dem App-Binary extrahiert werden. Verschleierung oder Aufteilung in mehrere Konstanten verhindert das nicht zuverlässig.

### 5.2 Zielarchitektur

```text
┌──────────────────────┐
│ simplebanking MAS App│
└──────────┬───────────┘
           │ authentisierte Anfrage
           │ ohne Bank-PIN und ohne TAN
           ▼
┌──────────────────────────┐
│ simplebanking Ticket API │
│ - prüft Installation     │
│ - begrenzt Zweck und Rate│
│ - signiert Kurzticket    │
└──────────┬───────────────┘
           │ kurzlebiges, zweckgebundenes Ticket
           ▼
┌──────────────────────┐
│ YAXI / Routex        │
└──────────────────────┘
```

### 5.3 Anforderungen an den Ticket-Broker

- Kein dauerhaftes YAXI-Signiergeheimnis im Client.
- Keine Übermittlung oder Speicherung von Onlinebanking-PIN und TAN auf dem Broker.
- Tickets mit sehr kurzer Gültigkeit.
- Bindung an:
  - Dienst
  - Installation oder Nutzer
  - erlaubten Vorgang
  - Region
  - gegebenenfalls Betrag und Empfängerkonto
- getrennte Berechtigungen für:
  - Accounts
  - Balances
  - Transactions
  - Transfer
- Rate Limits und Missbrauchserkennung.
- Widerrufsmöglichkeit für kompromittierte Installationen.
- Datenschutzfreundliche Protokollierung ohne Bankdaten und Umsatzinhalte.
- Schlüsselrotation ohne App-Update.
- Monitoring und Ausfallkonzept.

### 5.4 Speziell für Überweisungen

Transfer-Tickets sollten zusätzlich an die bestätigten Überweisungsdaten gebunden werden:

- Quellkonto
- Empfängername
- Empfänger-IBAN, vorzugsweise gehasht oder anderweitig datensparsam gebunden
- Betrag
- Währung
- Verwendungszweck
- kurze Ablaufzeit
- eindeutige Request-ID gegen Wiederholung

Die App darf nach Ausstellung des Tickets keine für die Autorisierung relevanten Werte unbemerkt verändern.

#### Abnahmekriterien

- [ ] Im finalen MAS-Binary befindet sich kein YAXI-Signiergeheimnis.
- [ ] Schlüssel können serverseitig rotiert werden.
- [ ] Transfer-Tickets sind enger begrenzt als reine Lesetickets.
- [ ] Broker protokolliert keine unnötigen Finanzdaten.
- [ ] Datenschutz und Auftragsverarbeitung sind dokumentiert.
- [ ] Ausfall und Widerruf wurden getestet.

---

## 6. P0 – Saubere Trennung der Vertriebskanäle

### 6.1 Problem

Der aktuelle Buildpfad `build-mas.sh` baut denselben Haupt-Target wie die Direktversion. Der Haupt-Target bindet in `Package.swift` weiterhin Sparkle ein. Das Store-Skript kopiert Sparkle dagegen absichtlich nicht in das App-Bundle.

**Nachgesehen am 26.07.2026, mit einem schärferen Ergebnis als „nicht garantiert":**
`build-mas.sh:84` legt `Contents/Frameworks` an, füllt es aber nie — im ganzen Skript
kommt `Sparkle.framework` nicht vor, während `build-app.sh:251-254` es ausdrücklich
einbettet. Das Binary linkt Sparkle jedoch (`import Sparkle` in `UpdateChecker.swift`
plus die Abhängigkeit in `Package.swift`). **Dieser Store-Build wäre beim Start nicht
lauffähig**, weil dyld das Framework nicht findet. Erschlossen, nicht ausgeführt — das
Skript bricht vorher am fehlenden Provisioning-Profil ab. Vor jeder weiteren Planung
sollte das einmal praktisch bestätigt werden.

Damit ist nicht garantiert, dass:

- das Store-Bundle vollständig startfähig ist,
- kein Sparkle-Code beziehungsweise keine Sparkle-Referenz enthalten ist,
- keine Direktvertriebsfunktion versehentlich im Store-Build landet,
- spätere Änderungen automatisch beide Vertriebswege korrekt berücksichtigen.

### 6.2 Empfohlene Zielstruktur

```text
simplebanking Workspace
├── SimpleBankingCore
│   ├── Banking
│   ├── Transactions
│   ├── Categories
│   ├── Recurring Payments
│   ├── Security
│   └── Shared UI
│
├── simplebanking-direct
│   ├── SparkleUpdateProvider
│   ├── MCP Integration
│   ├── CLI Integration
│   ├── Direct Licensing
│   └── Developer-ID Entitlements
│
└── simplebanking-mas
    ├── AppStoreUpdateProvider
    ├── StoreKit Purchase Provider
    ├── No External Tools
    ├── App Sandbox
    └── MAS Entitlements
```

### 6.3 Technische Schnittstellen

Gemeinsame Funktionen sollten nicht über verstreute `if appStore`-Abfragen gesteuert werden, sondern über kleine Schnittstellen:

```swift
protocol UpdateProviding {
    var canCheckManually: Bool { get }
    func checkForUpdates()
}

protocol PurchaseProviding {
    func products() async throws -> [ProductInfo]
    func purchase(_ product: ProductInfo) async throws
    func restorePurchases() async throws
}

protocol ExternalToolProviding {
    var supportsCLI: Bool { get }
    var supportsMCP: Bool { get }
}

enum DistributionChannel {
    case direct
    case macAppStore
}
```

Der MAS-Target sollte unerlaubte Komponenten nicht linken und nicht mitliefern. Ein lediglich ausgeblendeter Button reicht nicht.

### 6.4 Xcode-Archivierung

Die dauerhafte App-Store-Pipeline sollte über einen eigenen Xcode-Target und ein Xcode-Archive laufen:

1. Xcode-Projekt oder Workspace anlegen.
2. Bundle Identifier und Team korrekt zuordnen.
3. App Sandbox aktivieren.
4. nur benötigte Capabilities aktivieren.
5. Release Scheme `simplebanking-mas` erstellen.
6. StoreKit-Konfiguration für lokale Tests anlegen.
7. `Product > Archive`.
8. Archiv validieren.
9. über Organizer oder unterstützte App-Store-Werkzeuge hochladen.

Das vorhandene Skript kann als Referenz oder für lokale Prüfungen erhalten bleiben, sollte aber nicht die einzige Quelle für Bundle-Inhalt und Signierung sein.

### 6.5 Universalität und Betriebssysteme

Der aktuelle Store-Build baut nur `arm64`. Das ist grundsätzlich eine Produktentscheidung, schließt aber Intel-Macs aus.

Zu entscheiden:

- nur Apple Silicon unterstützen und dies korrekt deklarieren,
- oder Universal Binary für `arm64` und `x86_64` erzeugen.

Zusätzlich muss der jeweils aktuelle, von Apple erwartete macOS-Stand getestet werden.

### 6.6 Arbeitsweise: eine Hauptlinie, kein Store-Branch

**Kein eigener Dauerbranch für die Store-Fassung.** Der Versuch existiert bereits und ist
das beste Argument gegen eine Wiederholung:

```
1.3.4-appstore   ae63501   2026-04-07
  „App Store branch: Sparkle entfernt, Ko-Fi entfernt, MCP-Tab entfernt,
   Sandbox-Entitlements + Version-Label"

  exklusive Commits:  1
  hinterher:        181
```

Ein einziger Commit, der Dinge entfernt, dann Stillstand. Er ist an genau dem gestorben,
was ihn attraktiv machte.

**Warum das hier strukturell und nicht aus Nachlässigkeit passiert:** Die Store-Fassung
ist nicht durch Hinzufügen definiert, sondern durch **Entfernen** — Sparkle, Lizenz,
MCP/CLI, Händler, KI-Schlüssel. Jeder Merge von der Hauptlinie trifft dadurch
systematisch genau die Dateien, die der Branch ausgeweidet hat. Dazu der UX-Umbau in
`BalanceBar.swift` (rund 8000 Zeilen, in ständiger Bewegung). Und es gibt keinen
Rückführungspunkt: Ein Branch ohne Merge-Back-Datum ist kein Branch, sondern ein Fork.

#### Stattdessen

**Compile-Zeit, nicht Laufzeit.** 2.3.1(a) verbietet schlafende Funktionen — der Code
muss abwesend sein, nicht ausgeblendet. Ein Laufzeit-Schalter erfüllt das nicht.

```bash
swift build                          # Direktvertrieb
swift build -Xswiftc -DMAS_BUILD     # Store-Fassung
```

Das Muster gibt es im Repo bereits zweimal: drei Executables aus einem Package, und der
additive Theme-Schalter-Vertrag in `ThemeSupport.swift`.

**Der Compile-Schalter allein genügt aber nicht** — er entfernt Quelltext, nicht ein
gelinktes Framework. Genau daran krankt `build-mas.sh` heute (siehe 6.1). Dafür ist die
Target-Trennung aus 6.2 zuständig: Sparkle gehört ausschließlich in den Direkt-Target,
StoreKit ausschließlich in den MAS-Target, alles Gemeinsame nach `SimpleBankingCore`.
Beide Mechanismen ergänzen sich — die Target-Trennung für Abhängigkeiten, der
Compile-Schalter für die feinere Ausdünnung innerhalb des geteilten Codes.
`Package.swift` ist Swift-Code und kann eine Umgebungsvariable auswerten, um die
Sparkle-Abhängigkeit gar nicht erst aufzunehmen.

#### Ablauf

1. **Vorher aufräumen.** Entwickelt wird derzeit auf `feat/flyout-refresh-4b`, während
   `main` weit hinterherhinkt — daran hing der Fehlpush beim 2.0-Release. Bevor eine
   dritte Linie dazukommt, muss das geradegezogen sein.
2. **Kurzlebige Feature-Branches je Arbeitspaket**, täglich zurück auf die Hauptlinie.
   Nie länger als wenige Tage offen.
3. **Reihenfolge nach Konfliktrisiko:** erst die Entfernungen (Abschnitt 7, 11, 12 —
   kleiner, klar abgegrenzter Diff), dann die Sandbox (Abschnitt 10), zuletzt der
   UX-Umbau (Abschnitt 8 und 9), der `BalanceBar.swift` am tiefsten anfasst.
4. **Testgate in beiden Konfigurationen.** `swift test` **und**
   `swift test -Xswiftc -DMAS_BUILD` müssen grün sein. Ohne das verrottet die
   Store-Variante still — exakt wie der Branch von April.
5. **Getrennte Release-Spuren:** eigene Bundle-ID, eigener Build-Zähler
   (`.build-number-mas` existiert bereits), eigenes Tag-Schema. Die Direktfassung läuft
   ungestört weiter und behält Sparkle.

#### Abnahmekriterien

- [ ] Eigener MAS-Target vorhanden.
- [ ] MAS-Target linkt Sparkle nicht.
- [ ] MAS-Target enthält weder MCP- noch CLI-Binary.
- [ ] Direkt- und Store-Funktionen sind über klare Schnittstellen getrennt.
- [ ] **Kein langlebiger Store-Branch; `1.3.4-appstore` ist archiviert oder gelöscht.**
- [ ] **Die Testsuite ist in beiden Build-Konfigurationen grün.**
- [ ] **Der MAS-Build startet tatsächlich** (nicht nur: er baut).
- [ ] Xcode Archive ist reproduzierbar.
- [ ] App Store Validation läuft ohne Fehler und relevante Warnungen.
- [ ] Architekturentscheidung zu Intel-Macs ist dokumentiert.

---

## 7. P0/P1 – Store-inkompatible Komponenten entfernen

### 7.1 Sparkle

Apple verlangt, dass Mac-App-Store-Apps Updates ausschließlich über den Store erhalten.

Für den MAS-Target gilt:

- keine Sparkle-Abhängigkeit,
- kein Sparkle-Framework,
- keine Sparkle-XPC-Komponenten,
- keine Feed-URL,
- kein öffentlicher Sparkle-Schlüssel,
- kein Menüpunkt „Nach Updates suchen“ mit Sparkle-Aktion.

Optional kann ein Menüpunkt „Im App Store nach Updates suchen“ auf den systemüblichen App-Store-Weg verweisen. Er ist aber nicht zwingend notwendig.

### 7.2 MCP und CLI

Im aktuellen Stand existieren:

- ein MCP-Installer,
- CLI-Installation nach `~/.local/bin`,
- Symlink-Verwaltung,
- Bearbeitung von Shell-Konfiguration,
- Claude-Desktop-Konfiguration,
- Start externer Claude-Prozesse,
- IPC zwischen CLI und App.

Diese Funktionen sollten aus dem MAS-Target entfernt werden.

Nicht ausreichend:

- nur den Einstellungsbereich verstecken,
- Installationsbuttons deaktivieren,
- die Binärdateien trotzdem mitliefern.

Erforderlich:

- Quelldateien nicht in den MAS-Target aufnehmen,
- Hilfsbinärdateien nicht bauen oder einbetten,
- keine Startlogik ausführen,
- keine Pfade außerhalb des Containers prüfen oder verändern.

### 7.3 Externe Prozesse

Die REWE-ZIP-Verarbeitung startet `/usr/bin/unzip`. Für den Store-Build sollte eine In-Process-Lösung verwendet werden:

- ZIPFoundation oder vergleichbare geprüfte Swift-Bibliothek,
- Daten nur im App-Container oder temporären Containerpfad verarbeiten,
- Dateinamen und Pfade gegen Traversal absichern,
- Größen- und Dateianzahllimits setzen,
- keine Shell und keinen `Process` verwenden.

#### Abnahmekriterien

- [ ] Suche im finalen Bundle findet keine Sparkle-Komponente.
- [ ] Suche im finalen Bundle findet kein MCP- oder CLI-Binary.
- [ ] MAS-App schreibt keine Shell-Konfiguration.
- [ ] MAS-App erzeugt keine Symlinks außerhalb ihres Containers.
- [ ] MAS-App startet keine externen Programme.
- [ ] ZIP-Verarbeitung funktioniert vollständig innerhalb der App.

---

## 8. P1 – Menü- und Kontextmenü-Umbau

### 8.1 Hintergrund der früheren Ablehnung

**Originaltext von Apple:**

> **Guideline 4 - Design**
>
> **Issue Description**
>
> We noticed issues with the app's user interface that contribute to a lower-quality user experience than App Store users expect:
>
> - Menu items are not visible, except by right-clicking. Users should not have to right click to access menu items.
>
> https://developer.apple.com/app-store/review/guidelines/#4

Der Vorwurf ist damit enger und konkreter als die frühere Umschreibung („Kontextmenü im
Menü"). Beanstandet wurde nicht die Verschachtelung an sich, sondern die
**Erreichbarkeit**: Menüpunkte, an die man nur per Rechtsklick kommt.

**Der Befund ist im Code wörtlich nachvollziehbar.** `BalanceBar.swift:1305` kommentiert
die Konstruktion selbst:

> „Build a menu, but don't assign it to `statusItem.menu`, otherwise left click always opens the menu."

Das Menü wird also bewusst **nicht** an das Statusleistenelement gehängt (`:1306`),
bekommt vier Untermenüs — Ausblenden (`:1369`), Demo (`:1431`), Einstellungen (`:1436`),
Support (`:1498`) — und wird ausschließlich bei `rightMouseUp` aufgeklappt
(`:3185-3187`). Dazu ein `contextMenuProvider` auf einer eigenen View (`:234`).
Linksklick öffnet das Flyout, Doppelklick die Umsatzliste. **Einstellungen, Support,
Demo-Modus und Beenden sind damit ausschließlich per Rechtsklick erreichbar** — exakt
der beanstandete Zustand, unverändert.

Erschwerend: `SimpleBankingApp.swift:20` setzt `.accessory`, es gibt also kein
Dock-Icon und keine sichtbare Menüleiste. `NSApp.mainMenu` wird zwar aufgebaut
(`BalanceBar.swift:2613-2638`), umfasst aber nur App- und Bearbeiten-Menü und ist im
Accessory-Modus praktisch unsichtbar. `build-mas.sh` setzt zusätzlich `LSUIElement` —
die Store-Fassung wäre damit noch strikter menülos als die heutige Direktfassung.

**Zwei dokumentierte Vergleichsfälle** zeigen, wie streng das ausgelegt wird:
- Ein Menüleisten-Werkzeug wurde mit exakt derselben Formulierung abgelehnt; gelöst
  wurde es dort nicht durch eine neue Oberfläche, sondern indem das **Standardverhalten
  des Symbols geändert** und die alte Bedienung als *Einstellung* angeboten wurde
  ([Forum](https://developer.apple.com/forums/thread/764643)).
- Ein zweiter Fall zum Beenden: „**Command-Q is not considered a sufficient means of
  quitting for a stand-alone application.**" Ein sichtbarer Beenden-Weg ist also Pflicht
  ([Forum](https://developer.apple.com/forums/thread/727422)).

Ein Kontextmenü sollte kurz, kontextbezogen und ergänzend sein. Es darf nicht die
vollständige Hauptnavigation der App ersetzen — und keine Funktion darf ausschließlich
darüber erreichbar sein.

### 8.2 Zielverhalten des Menüleistensymbols

#### Linksklick

Öffnet immer das Flyout mit:

- aktuellem Kontostand,
- Kontoauswahl,
- Aktualisieren,
- Umsätze öffnen,
- Geld senden,
- Einstellungen.

#### Rechtsklick

Öffnet ein flaches Kontextmenü ohne Untermenüs:

```text
simplebanking öffnen
Kontostand aktualisieren
Kontostand ausblenden
────────────────────
Einstellungen …
simplebanking beenden
```

Je nach Zustand kann „Kontostand ausblenden“ zu „Kontostand einblenden“ wechseln.

#### Nicht ins Rechtsklickmenü

- Demo-Modus
- Konto hinzufügen
- Bankdiagnose
- Diagnosebericht
- Zurücksetzen
- Auto-Hide-Zeitstufen als Untermenü
- Händlerkonto-Einrichtung
- Lizenzierung
- verschachtelte Einstellungen

### 8.3 Vollständiges macOS-Hauptmenü

Sobald die App aktiv ist oder ein reguläres Fenster zeigt, sollte sie ein vollständiges App-Menü besitzen:

```text
simplebanking
  Über simplebanking
  Einstellungen …
  Konten verwalten …
  Dienste …
  simplebanking ausblenden
  Andere ausblenden
  simplebanking beenden

Ablage
  Umsätze importieren …
  Umsätze exportieren …
  Fenster schließen

Bearbeiten
  Widerrufen
  Wiederholen
  Ausschneiden
  Kopieren
  Einfügen
  Alles auswählen

Konto
  Aktualisieren
  Konto hinzufügen …
  Bank neu verbinden …
  Zugangsdaten ändern …
  Sperren

Fenster
  Übersicht
  Umsätze
  Dashboard
  Einstellungen
  Alles nach vorne bringen

Hilfe
  simplebanking-Hilfe
  Unterstützte Banken
  Datenschutz
  Diagnose …
  Support kontaktieren …
```

Kontextmenü-Befehle sollten zusätzlich in der sichtbaren Oberfläche oder im Hauptmenü erreichbar sein.

### 8.4 Verdeckte Interaktionen vermeiden

Wesentliche Funktionen dürfen nicht ausschließlich erreichbar sein über:

- Rechtsklick,
- Hover,
- Doppelklick,
- Drag-and-drop ohne sichtbaren Hinweis,
- nicht beschriftete Symbole ohne Hilfetext.

Empfehlungen:

- Doppelklick darf eine Beschleunigung sein, aber keine exklusive Funktion.
- Dragbares Flyout mit sichtbarem Drag-Indikator erklären.
- Hover-Schaltflächen zusätzlich per Tastatur fokussierbar machen.
- Symbole mit Accessibility Label und Tooltip versehen.

### 8.5 Desktop-Widget

Das Kontextmenü des herausgezogenen Widgets kann klein bleiben:

```text
Immer im Vordergrund
Schließen
```

Beide Aktionen sollten zusätzlich über sichtbare Widget-Schaltflächen oder das Fenster-Menü erreichbar sein.

#### Abnahmekriterien

- [ ] Rechtsklickmenü besitzt keine Untermenüs.
- [ ] Alle Rechtsklickbefehle sind auch anderweitig erreichbar.
- [ ] Linksklick hat ein eindeutiges, dokumentiertes Verhalten.
- [ ] Wesentliche Funktionen benötigen keinen Doppelklick oder Hover.
- [ ] Hauptfenster besitzt ein vollständiges macOS-Menü.
- [ ] Tastatur und VoiceOver erreichen alle Befehle.
- [ ] Der frühere Ablehnungspunkt wird in den Review Notes ausdrücklich adressiert.

---

## 9. P1/P2 – Hauptfenster und Informationsarchitektur

### 9.1 Warum ein Hauptfenster sinnvoll ist

Eine reine Menüleisten-App ist grundsätzlich zulässig. simplebanking ist inzwischen jedoch wesentlich umfangreicher als ein kleines Statuswerkzeug.

Ein reguläres Hauptfenster verbessert:

- Auffindbarkeit,
- Barrierefreiheit,
- Reviewbarkeit,
- Navigation,
- macOS-Konformität,
- Erklärbarkeit der Funktionen,
- Trennung zwischen Schnellzugriff und vollständiger Anwendung.

### 9.2 Empfohlene Struktur

```text
Menüleisten-Flyout
├── Kontostand
├── Konto wechseln
├── Aktualisieren
├── Geld senden
└── simplebanking öffnen
       │
       ▼
Hauptfenster
├── Übersicht
├── Umsätze
├── Fixkosten
├── Abonnements
├── Einkäufe
├── Konten
└── Einstellungen
```

### 9.3 Navigation

Empfohlen wird eine native Sidebar oder eine klare Toolbar:

- **Übersicht:** Salden, Geldalter, noch offene Kosten, aktuelle Hinweise.
- **Umsätze:** Suche, Filter, Kategorien, Details.
- **Planung:** Fixkosten, Abonnements, Daueraufträge.
- **Einkäufe:** nur wenn Händlerdienste im Store zugelassen sind.
- **Konten:** Bankkonten, Händlerkonten, Verbindungsstatus, Löschen.
- **Einstellungen:** Verhalten, Sicherheit, Datenschutz, Dienste.

### 9.4 Dock-Verhalten

- Der Nutzer darf wählen, ob simplebanking dauerhaft im Dock erscheint.
- Der Erststart sollte trotzdem ein normales Onboarding-Fenster anzeigen.
- Ein Klick auf das Dock-Symbol öffnet zuverlässig das Hauptfenster.
- Das Schließen des letzten Fensters beendet die Menüleisten-App nicht automatisch.
- „Schließen“ und „Beenden“ müssen klar getrennt sein.

#### Abnahmekriterien

- [ ] „simplebanking öffnen“ ist im Flyout und Kontextmenü sichtbar.
- [ ] Hauptfenster funktioniert unabhängig vom Menüleisten-Popover.
- [ ] Navigation ist ohne versteckte Gesten vollständig bedienbar.
- [ ] Dock-Klick öffnet eine vorhersehbare Oberfläche.
- [ ] Schließen und Beenden entsprechen macOS-Konventionen.

---

## 10. P1 – App Sandbox

### 10.1 Grundsatz

Der App-Store-Target muss mit App Sandbox laufen. Die Berechtigungen sollten so klein wie möglich sein.

Der aktuelle MAS-Entitlement-Satz enthält:

- App Sandbox
- ausgehenden Netzwerkzugriff

Das ist ein guter Ausgangspunkt, reicht aber nur dann, wenn alle Funktionen tatsächlich innerhalb dieser Grenzen arbeiten.

### 10.2 Zu prüfende Bereiche

#### Dateisystem

- Application Support
- Caches
- temporäre Dateien
- Logdateien
- Datenbank
- Importe
- Exporte
- benutzerdefinierte Händlerlogos
- Diagnosedateien
- Theme-Dateien

#### Externe Pfade

Im MAS-Build nicht zulässig beziehungsweise zu entfernen:

- `~/.local/bin`
- `.zshrc`
- `.bashrc`
- Claude Desktop Application Support
- fremde App-Daten
- beliebige absolute Pfade

#### Nutzergewählte Dateien

Import und Export sollten über:

- `NSOpenPanel`
- `NSSavePanel`
- Security-Scoped Bookmarks bei dauerhaftem Zugriff

erfolgen.

#### Netzwerk

Alle Ziele inventarisieren:

- YAXI/Routex
- Banken und Redirects
- PayPal
- Anthropic/OpenAI oder andere KI-Anbieter
- REWE
- dm
- Amazon
- Händlerlogo-Dienste
- Support und Dokumentation
- Ticket-Broker
- Lizenzdienst im Direktvertrieb

Diese Liste gilt für **beide** Fassungen. In der Store-Fassung fallen nach den
Entscheidungen in 11.4 und 12.5 weg: PayPal, KI-Anbieter, REWE, dm, Amazon und der
Lizenzdienst. Bleibt ein deutlich kleineres Inventar — was den Datenschutzteil
(Abschnitt 13) und die Store-Deklaration entsprechend verkürzt.

Für jedes Ziel dokumentieren:

- Zweck
- übertragene Daten
- Authentisierung
- Aufbewahrung
- Fehlerverhalten
- Datenschutzgrundlage

#### Erinnerungen und Benachrichtigungen

Wenn die App Erinnerungen anlegt:

- passendes Entitlement im MAS-Target,
- korrekte Usage Description,
- Berechtigung erst im Nutzungskontext anfragen,
- alternative Nutzung ohne Berechtigung ermöglichen.

Unbenutzte Usage Descriptions und Entitlements entfernen.

### 10.3 Testverfahren

1. frischen macOS-Testnutzer anlegen,
2. keine Dateien aus einer Direktinstallation übernehmen,
3. MAS-Build installieren,
4. Sandboxstatus prüfen,
5. jeden Funktionsbereich ausführen,
6. Sandbox-Verweigerungen im Systemlog erfassen,
7. keine Ausnahme durch temporäres Deaktivieren der Sandbox akzeptieren,
8. alle benötigten Rechte dokumentieren.

#### Abnahmekriterien

- [ ] App startet mit aktiver Sandbox.
- [ ] Alle Kernfunktionen laufen mit dem finalen Entitlement-Satz.
- [ ] Keine unerwarteten Sandbox-Verweigerungen.
- [ ] Keine Schreibzugriffe außerhalb des Containers ohne Nutzerwahl.
- [ ] Import/Export verwendet Systemdialoge.
- [ ] Keine unnötigen Entitlements.
- [ ] Berechtigungsdialoge erscheinen erst bei tatsächlicher Nutzung.

---

## 11. P1 – Händlerdienste REWE, dm und Amazon

### 11.1 Risiko

Die Händlerdienste verwenden WebViews, Sitzungsdaten, Cookies oder Tokens und greifen teilweise auf Endpunkte zu, die nicht eindeutig als öffentliche Partner-API dokumentiert sind.

Apple verlangt, dass die App zur Verwendung und Anzeige von Drittanbieterdiensten berechtigt ist.

### 11.2 Pro Dienst zu dokumentieren

- offizielle Nutzungsbedingungen,
- API- oder Partnervereinbarung,
- Erlaubnis für eingebetteten Login,
- Erlaubnis zur Verarbeitung von Sitzungscookies oder Tokens,
- Erlaubnis zum Abruf von Belegen und Einkaufsdaten,
- Erlaubnis zur Nutzung von Name und Logo,
- erlaubte Cachingdauer,
- Logout,
- Token-/Cookie-Löschung,
- Löschung lokaler Einkaufsdaten,
- Verhalten bei API-Änderungen,
- Supportkontakt.

### 11.3 Entscheidungsmatrix

| Zustand | Entscheidung |
|---|---|
| Schriftliche Partnerfreigabe und stabile API | Integration kann in MAS-Version geprüft werden. |
| Öffentliche API mit passenden Bedingungen | Technisch und datenschutzrechtlich integrieren. |
| Nur interne Web-Endpunkte, keine Freigabe | Nicht in MAS 1.0 aufnehmen. |
| Unklare Markennutzung | Logo und Markenbezug entfernen oder Freigabe einholen. |
| Login nur durch Auslesen interner Tokens möglich | Für Store-Version zurückstellen. |

### 11.4 Entscheidung (festgelegt)

**REWE, dm, Amazon und PayPal sind nicht Teil der App-Store-Version.** Die
Entscheidungsmatrix oben ist damit für MAS 1.0 abgeräumt und nur noch für eine spätere
Aktivierung relevant.

PayPal ist streng genommen kein Händlerdienst, sondern ein Konto-Zugang über vom Nutzer
eingetragene API-Credentials. Es fällt aus demselben Grund heraus: eine Integration
weniger, deren Zugangsweg, Markennutzung und Datenfluss im Review erklärt und belegt
werden müssten. Damit entfällt auch die Abgrenzungsfrage aus
[12.5](#125-die-zweite-ablehnung-api-schlüssel-statt-in-app-purchase) — die
Store-Fassung kennt überhaupt keine vom Nutzer eingetragenen API-Schlüssel mehr, weder
für KI noch für PayPal. Das ist die einfachste Antwort auf 3.1.1, die es gibt.

Wie bei der KI gilt: **nicht ausgeblendet, sondern nicht vorhanden** (2.3.1(a), keine
schlafenden Funktionen). Die Konto-Typen, WebViews, Services und Einstellungsbereiche
für diese vier Dienste gehören nicht ins MAS-Target.

Dadurch sinken:

- rechtliches Risiko,
- Review-Komplexität,
- Datenschutzumfang,
- Sandbox-Komplexität,
- Abhängigkeit von fremden Websites,
- Risiko eines Review-Fehlers wegen nicht funktionierender Testkonten.

#### Abnahmekriterien bei späterer Aktivierung

- [ ] Schriftliche Nutzungsberechtigung vorhanden.
- [ ] Review kann einen Testaccount verwenden.
- [ ] Login, Logout und Löschen sind vollständig.
- [ ] Markennutzung ist geklärt.
- [ ] Datenschutztext nennt Dienst und Datenarten.
- [ ] Integration funktioniert ohne externe Prozesse.

---

## 12. P1 – Bezahlmodell und StoreKit

### 12.1 Grundsatz

Werden digitale Funktionen innerhalb der App gegen Geld freigeschaltet, ist im Mac App Store grundsätzlich StoreKit beziehungsweise In-App Purchase zu verwenden.

### 12.2 simplesend: nicht verbrauchbarer In-App-Kauf (festgelegt)

**Entscheidung: simplesend ist Teil der App-Store-Version und wird über einen
nicht verbrauchbaren In-App-Kauf freigeschaltet.** Abonnement und „im Kaufpreis
enthalten" sind damit vom Tisch.

Was daraus folgt:

- **Der externe Lizenzweg entfällt vollständig.** `LicenseManager` und alles, was einen
  Schlüssel entgegennimmt, prüft oder speichert, gehört nicht ins MAS-Target — nicht
  ausgeblendet, sondern nicht vorhanden (2.4.5(vi) verbietet Lizenzschlüssel und eigenen
  Kopierschutz auf macOS ausdrücklich, zusätzlich zu 3.1.1).
- **Der Kaufzustand kommt ausschließlich von StoreKit**, nicht aus UserDefaults oder
  einer eigenen Datei. Ein lokal gesetztes Flag wäre wieder ein eigener
  Freischaltmechanismus.
- **„Käufe wiederherstellen" ist Pflicht** und muss ohne Konto funktionieren
  (siehe 12.4).
- **Die Überweisung selbst ist kein IAP-Fall.** Sie ist eine Leistung außerhalb der App
  (3.1.3(e)/3.1.5): Geld fließt zwischen Bankkonten, nicht an Apple. Gekauft wird die
  *Funktion*, nicht der Zahlungsvorgang. Diese Unterscheidung gehört in die Review Notes,
  sonst liest ein Reviewer den Überweisungsdialog als umgangenen In-App-Kauf.
- **Der Kauf entbindet nicht von 4.1 und 5.4.** Ob simplesend öffentlich angeboten
  werden darf, ist eine Frage der Zahlungsauslösung und der YAXI-Vertragslage — sie
  bleibt ein eigener P0-Punkt und ist mit dem Bezahlmodell nicht beantwortet.
- **Der YAXI-Ticket-Broker (Abschnitt 5) wird dadurch dringender**, nicht weniger
  dringend: Das Transfer-Signiergeheimnis darf nicht im Client liegen, wenn die Funktion
  öffentlich verkauft wird.

### 12.3 Im MAS-Target entfernen

- externe Lizenzschlüssel,
- Polar-/Gumroad-Freischaltung,
- externe Kaufbuttons,
- Gutscheine zur Umgehung von StoreKit,
- Kaufaufforderung beim Start, die auf eine externe Website führt.

### 12.4 Erforderliche StoreKit-UX

- Produkt und Preis klar anzeigen.
- Kein irreführender „kostenlos“-Eindruck.
- Kauf bestätigen lassen.
- „Käufe wiederherstellen“ anbieten.
- Fehler und Abbruch verständlich behandeln.
- Funktion ohne Kauf nachvollziehbar erklären.
- Review Notes beschreiben, wo der Kauf zu finden ist.
- In-App-Produkte gemeinsam mit der App-Version einreichen.

### 12.5 Die zweite Ablehnung: API-Schlüssel statt In-App Purchase

**Originaltext von Apple:**

> **Guideline 3.1.1 - Business - Payments - In-App Purchase**
>
> **Issue Description**
>
> The app unlocks or enables additional functionality with mechanisms other than In-App Purchase, which is not appropriate.
>
> Specifically, the app uses API keys to unlock or enable paid functionality, but some of these API keys are not available for purchase via In-App Purchase in this or the associated apps by the API provider on the App Store.
>
> **Next Steps**
>
> It would be appropriate to remove these features from the app and any other feature that unlocks or enables functionality with mechanisms other than the App Store.
>
> Please note API keys can only be used to unlock content if those API keys can be purchased with In-App Purchase in this or the associated app by the API provider on the App Store.

**Das ist nicht der Lizenzschlüssel für simplesend**, sondern das Muster
„Nutzer trägt seinen eigenen API-Schlüssel ein und schaltet damit eine Funktion frei".
In simplebanking betrifft das die KI-Anbieter-Schlüssel, die in `StoredCredentials`
neben den Bankzugangsdaten liegen (`anthropicApiKey`, `mistralApiKey`, `openaiApiKey`).

**Warum das den Plan an einer Stelle korrigiert:** Abschnitt 13.5 behandelt die
KI-Anbindung ausschließlich als Datenschutzfrage und empfiehlt „KI standardmäßig aus,
Cloud-KI erst nach ausdrücklicher Aktivierung". Gegen 3.1.1 hilft das nicht — dort geht
es nicht um Einwilligung, sondern darum, dass überhaupt eine Funktion an einem
Schlüssel hängt, den Apple nicht als In-App-Kauf sieht. Die Regel ist eng formuliert:
zulässig wären API-Schlüssel nur, wenn sie **in dieser oder der App des Anbieters per
In-App-Kauf erwerbbar** sind. Für Anthropic, Mistral und OpenAI trifft das nicht zu.

**Konsequenz für die Store-Fassung:** Der Eintrag eigener KI-Schlüssel und alles, was
daran hängt, muss aus dem MAS-Target heraus — nicht ausgeblendet, sondern nicht
vorhanden (siehe auch 2.3.1(a), keine schlafenden Funktionen). Die lokalen,
regelbasierten Auswertungen sind davon nicht betroffen: sie schalten nichts frei und
brauchen keinen Schlüssel.

**PayPal war der Grenzfall — er ist inzwischen entschieden.** Die PayPal-Zugangsdaten
(`paypalUser`/`paypalPwd`/`paypalSignature`) sind formal ebenfalls vom Nutzer
eingetragene API-Credentials, schalten aber keine *bezahlte Funktion* frei, sondern
öffnen den Zugang zum **eigenen Konto des Nutzers** — dieselbe Rolle wie
Bankzugangsdaten. Man hätte das im Review erklären müssen. Da PayPal laut 11.4 nicht
Teil der Store-Version ist, entfällt die Diskussion: **die Store-Fassung kennt gar keine
vom Nutzer eingetragenen API-Schlüssel mehr.** Das ist die stärkste Antwort auf 3.1.1,
weil sie nichts zu erklären übriglässt.

#### Abnahmekriterien

- [ ] MAS-Funktionen werden ausschließlich über StoreKit freigeschaltet.
- [ ] Keine externen Kauf- oder Lizenzlinks.
- [ ] **Keine Funktion hängt an einem vom Nutzer eingetragenen API-Schlüssel.**
- [ ] **Die KI-Schlüsselfelder sind im MAS-Target nicht vorhanden, nicht bloß verborgen.**
- [ ] **Review Notes erklären, warum Bank- und PayPal-Zugangsdaten etwas anderes sind als ein freischaltender API-Schlüssel.**
- [ ] Restore Purchases funktioniert.
- [ ] StoreKit-Sandbox wurde getestet.
- [ ] App Review kann das Produkt finden und testen.
- [ ] Geschäftsmodell ist in Metadaten und Review Notes erklärt.

---

## 13. P1 – Datenschutz und Dateninventar

### 13.1 Zu inventarisierende Daten

| Datenart | Beispiele |
|---|---|
| Finanzinformationen | Saldo, Umsätze, Beträge, Kontotyp |
| Identifikatoren | IBAN, Bankkennung, Konto-ID |
| Zugangsdaten | Anmeldename, PIN/Passwort, API-Zugang |
| Zahlung | Empfänger, IBAN, Betrag, Verwendungszweck |
| Einkaufsdaten | Händler, Beleg, Artikel, Preise |
| Nutzereingaben | KI-Fragen, Kategorien, Regeln |
| Diagnose | Logs, Fehlermeldungen, technische Metadaten |
| Drittanbietersitzungen | Cookies, OAuth-, PayPal- oder Händler-Tokens |
| Geräteeinstellungen | Touch ID, Benachrichtigungen, Autostart |
| Kontaktdaten | E-Mail-Adresse für die Update-Liste (freiwillig, siehe 13.7) |

### 13.2 Datenflussmatrix erstellen

Für jede Datenart dokumentieren:

| Frage | Beispiel |
|---|---|
| Wo entsteht sie? | Bankabruf |
| Wo wird sie gespeichert? | lokaler App-Container |
| Ist sie verschlüsselt? | Keychain / verschlüsselte Datei / unverschlüsselte SQLite |
| Wer erhält sie? | YAXI, Bank, KI-Anbieter |
| Warum wird sie übertragen? | Kontostandsabruf |
| Wie lange bleibt sie gespeichert? | bis Konto oder App-Daten gelöscht werden |
| Wie widerruft der Nutzer? | Dienst trennen |
| Wie löscht der Nutzer? | Konto löschen / alle Daten löschen |

### 13.3 Datenschutzoberfläche

Innerhalb der App sollte es einen klaren Bereich geben:

```text
Datenschutz
├── Lokale Daten
│   ├── Umsätze
│   ├── Belege
│   ├── Logos und Cache
│   └── Diagnosedaten
├── Verbundene Dienste
│   ├── YAXI / Routex
│   ├── PayPal
│   ├── Händler
│   └── KI-Anbieter
├── Daten exportieren
├── Einzelnen Dienst trennen
├── Lokale Daten löschen
└── Alle simplebanking-Daten löschen
```

### 13.4 Einwilligung

Einwilligungen sollten:

- verständlich,
- dienstbezogen,
- vor der ersten Übertragung,
- widerrufbar,
- nicht mit unnötigen Funktionen gekoppelt

sein.

Keine pauschale Checkbox „Ich stimme allem zu“ für Bank, Händler, KI und Diagnose.

### 13.5 KI-Dienste

> **Vorrang beachten:** Dieser Abschnitt behandelt die KI-Anbindung als Datenschutzfrage.
> Für den Store kommt sie dort aber gar nicht erst an — sie scheitert vorher an
> **3.1.1**, weil der vom Nutzer eingetragene API-Schlüssel eine Funktion freischaltet
> (siehe [12.5](#125-die-zweite-ablehnung-api-schlüssel-statt-in-app-purchase), mit dem
> Originaltext der Ablehnung). Für MAS 1.0 gilt deshalb nicht „standardmäßig aus",
> sondern **nicht enthalten**. Die Anforderungen unten bleiben für die Direktfassung
> gültig und für den Fall, dass die KI später über einen eigenen, per In-App-Kauf
> bezahlten Dienst angeboten wird.

Die App sendet für freie Fragen mindestens die Nutzerfrage und ausgewählte SQL-Ergebniszeilen an den konfigurierten KI-Anbieter.

Vor der ersten Cloud-KI-Nutzung sollte die App anzeigen:

- Anbieter,
- übertragene Datenarten,
- Beispiel der übertragenen Struktur,
- Hinweis, dass Finanzinhalte enthalten sein können,
- Zweck,
- Link zur Datenschutzerklärung des Anbieters,
- lokale Alternative beziehungsweise Deaktivierung.

Empfehlung für MAS 1.0:

- KI standardmäßig aus,
- regelbasierte lokale Antworten bevorzugen,
- Cloud-KI erst nach ausdrücklicher Aktivierung,
- keine vollständigen Rohumsätze senden,
- Daten minimieren und maskieren.

### 13.6 Diagnoseberichte

Vor dem Versand:

- Inhaltsvorschau anbieten,
- sensible Werte automatisch schwärzen,
- keine PIN, TAN, API-Schlüssel oder vollständige IBAN,
- Nutzer muss den Versand ausdrücklich bestätigen,
- Empfänger und Aufbewahrung erklären.

#### Abnahmekriterien

- [ ] Vollständiges Dateninventar vorhanden.
- [ ] Datenflussmatrix entspricht dem tatsächlichen Netzwerkverkehr.
- [ ] Datenschutzerklärung ist in App und Store erreichbar.
- [ ] Jeder optionale Dienst kann getrennt und gelöscht werden.
- [ ] KI ist standardmäßig aus oder rein lokal.
- [ ] Diagnoseberichte sind transparent und minimiert.
- [ ] App Privacy Angaben stimmen mit App und SDKs überein.

---

### 13.7 Update-Liste (E-Mail)

Seit 2.0.1 kann man sich in der App für Neuigkeiten per Mail eintragen — in der
„Neu in simplebanking"-Sheet und unter Einstellungen → Info. Der Eintrag geht an
Formspree (USA), denselben Endpunkt, den auch die Website nutzt.

Das ist der einzige ausgehende Aufruf der App, der eine Kontaktangabe des Nutzers
verschickt. Für den Store bedeutet das:

- **App Privacy:** „Contact Info → Email Address", Zweck „App Functionality" bzw.
  „Developer's Advertising or Marketing", **nicht** mit der Identität verknüpft und
  **nicht** für Tracking. Die Angabe darf beim Ausfüllen des Fragebogens nicht
  vergessen werden — sie ist heute die einzige Kontaktangabe im Inventar.
- **Freiwilligkeit:** Der Eintrag darf keine Funktion freischalten und keine
  Voraussetzung für die Nutzung sein (Guideline 5.1.1(iv)). Das ist erfüllt: Beide
  Einbauorte sind rein optional, nichts hängt daran.
- **Kein Vorbefüllen:** Die Adresse wird ausschließlich eingetippt. Sie stammt nie aus
  Kontodaten und nie aus dem Adressbuch — Letzteres verlangte sonst eine
  Kontakte-Berechtigung samt Begründung.
- **Datensparsamkeit:** Es gehen genau drei Felder hinaus — Adresse, Herkunft
  (`whatsnew-<version>` bzw. `settings`) und App-Version. Festgehalten in
  `NewsletterSignupTests`, das die Felder aufzählt und bei einem vierten fehlschlägt.
- **Auftragsverarbeitung:** Formspree, Inc. ist bereits in der Datenschutzerklärung
  als Auftragsverarbeiter benannt (Abschnitt 4.2), Rechtsgrundlage Einwilligung nach
  Art. 6 Abs. 1 lit. a DSGVO. Für den Store braucht es zusätzlich den Nachweis der
  Einwilligung, also **Double-Opt-in** — die erste Mail an einen neuen Eintrag muss
  die Bestätigung sein.
- **Sandbox:** Ausgehende Netzverbindung, also `com.apple.security.network.client`.
  Das Recht besteht ohnehin für YAXI, kein zusätzlicher Eintrag nötig.

Offen: Wächst die Liste, ist ein Dienst mit eingebautem Double-Opt-in und
Abmeldelink der saubere Weg. Formspree kann beides nicht von sich aus.

---

## 14. P1 – Privacy Manifest und Drittanbieter-SDKs

### 14.1 Privacy Manifest

Der MAS-Target benötigt ein gültiges:

```text
simplebanking.app/
└── Contents/
    └── Resources/
        └── PrivacyInfo.xcprivacy
```

Das Manifest muss dem tatsächlichen Verhalten entsprechen. Ungültige Schlüssel oder Werte können bereits beim Upload abgelehnt werden.

### 14.2 SDK-Inventar

Mindestens prüfen:

- GRDB
- RoutexClient
- Sparkle – im MAS-Target nicht enthalten
- ArgumentParser – nur CLI, deshalb nicht im MAS-App-Target
- weitere transitive Abhängigkeiten

Für jede Abhängigkeit:

- Version fixieren beziehungsweise kontrolliert aktualisieren.
- Lizenz dokumentieren.
- Privacy Manifest vorhanden?
- Binärsignatur erforderlich?
- Netzwerkzugriffe?
- Telemetrie?
- Required Reason APIs?
- letzte Sicherheitsupdates?

### 14.3 Software Bill of Materials

Für jeden Release eine kleine SBOM beziehungsweise Abhängigkeitsliste erzeugen:

- Paketname
- Version
- Quelle
- Lizenz
- Prüfsumme oder Commit
- Zweck
- im MAS-Bundle enthalten: ja/nein
- Privacy Manifest geprüft: ja/nein

#### Abnahmekriterien

- [ ] `PrivacyInfo.xcprivacy` liegt an der korrekten Stelle.
- [ ] Manifest ist syntaktisch und semantisch gültig.
- [ ] Alle enthaltenen SDKs sind inventarisiert.
- [ ] Keine unnötige Abhängigkeit im MAS-Bundle.
- [ ] Drittanbieter-Lizenzen werden korrekt mitgeliefert.

---

## 15. P2 – Onboarding und Demo-Modus

### 15.1 Review-Anforderung

Apple muss alle wesentlichen Funktionen prüfen können, ohne ein privates Bankkonto des Entwicklers zu verwenden.

### 15.2 Erster Bildschirm

Der Erststart sollte anbieten:

```text
Willkommen bei simplebanking

[ Bankkonto verbinden ]
[ Demo ausprobieren ]

Datenschutz · Unterstützte Banken · Hilfe
```

Der Demo-Modus darf nicht in einem Rechtsklick-Untermenü versteckt sein.

### 15.3 Umfang des Demo-Modus

Der Demo-Modus sollte enthalten:

- Einzelkonto
- mehrere Bankkonten
- unterschiedliche Kontotypen
- positive und negative Salden
- mehrere Monate Umsätze
- Kategorien
- Fixkosten
- Abonnements
- Dauerauftrag
- Dashboard
- Suche und Filter
- Offlinezustand
- abgelaufene Bankfreigabe
- TAN-/SCA-Simulation
- Überweisungsentwurf bis unmittelbar vor echte Ausführung
- Löschung eines Demokontos

### 15.4 Sicherheitsregeln

- Keine echte Bankanfrage.
- Keine echte Überweisung.
- Keine echten Zugangsdaten.
- Keine versehentliche Vermischung mit Produktivslots.
- Gut sichtbare Kennzeichnung „Demo“.
- Demo zurücksetzen möglich.

### 15.5 Review-Skript

Eine klare Klickanleitung vorbereiten:

1. App starten.
2. „Demo ausprobieren“ wählen.
3. Kontenübersicht prüfen.
4. Flyout über Menüleistensymbol öffnen.
5. Umsätze öffnen.
6. Filter und Kategorien testen.
7. Fixkosten öffnen.
8. simplesend-Demo starten.
9. simulierte SCA abbrechen oder bestätigen.
10. Einstellungen und Datenschutz prüfen.
11. Demodaten löschen.

#### Abnahmekriterien

- [ ] Demo ist beim Erststart direkt erreichbar.
- [ ] Demo zeigt den vollständigen Kernumfang.
- [ ] Demo benötigt keine externen Testkonten.
- [ ] Demo kann keine reale Zahlung auslösen.
- [ ] Review-Skript wurde auf einem frischen Mac nachvollzogen.

---

## 16. P2 – Konto-, Dienst- und Datenlöschung

simplebanking erstellt zwar kein eigenes Bankkonto, verwaltet aber lokale Kontoverbindungen und Sitzungen. Apple und Nutzer erwarten eine einfache, vollständige Löschmöglichkeit.

### 16.1 Pro Konto

„Konto entfernen“ sollte transparent nennen, was gelöscht wird:

- lokale Zugangsdaten,
- Keychain-Einträge,
- YAXI-/Routex-Sitzungen,
- Verbindungstokens,
- Umsatzdaten,
- Kategorien und Zuordnungen,
- Belege,
- Konto-Einstellungen,
- Caches.

### 16.2 Pro Drittanbieterdienst

- abmelden,
- Sitzung widerrufen, sofern API vorhanden,
- Cookies/Tokens löschen,
- lokale Daten löschen,
- erklären, ob beim Anbieter weitere Daten bestehen.

### 16.3 Gesamtrücksetzung

Vor Bestätigung eine Zusammenfassung anzeigen:

```text
Alle simplebanking-Daten löschen?

Gelöscht werden:
• alle Bankverbindungen und Zugangsdaten
• alle lokal gespeicherten Umsätze
• alle Händlerverbindungen und Belege
• Kategorien, Regeln und Einstellungen
• Diagnose- und Cache-Daten

Diese Aktion kann nicht rückgängig gemacht werden.
```

Die Löschung muss nach Abschluss bestätigt werden.

#### Abnahmekriterien

- [ ] Einzelkonto vollständig entfernbar.
- [ ] Drittanbieterdienst vollständig trennbar.
- [ ] Gesamtrücksetzung löscht alle dokumentierten Daten.
- [ ] Keychain und App-Container wurden nach Löschung geprüft.
- [ ] Löschtext entspricht dem tatsächlichen Verhalten.

---

## 17. P2 – Barrierefreiheit und macOS-Konformität

### 17.1 Tastatur

- vollständige Tab-Reihenfolge,
- Standardkürzel,
- Escape zum Abbrechen,
- Return für primäre sichere Aktion,
- kein Return für irreversible Zahlung ohne Bestätigung,
- Fokus bleibt bei geöffneten Sheets nachvollziehbar.

### 17.2 VoiceOver

Für alle:

- Menüleistensymbol,
- Kontostand,
- Kontoauswahl,
- Diagramme,
- Kategorieanzeigen,
- Iconbuttons,
- Überweisungsfelder,
- TAN-/SCA-Status

benötigt die App passende Labels, Werte und Hinweise.

### 17.3 Darstellung

- Hell- und Dunkelmodus.
- Erhöhter Kontrast.
- „Bewegung reduzieren“ bei Ripple- und CRT-Effekten berücksichtigen.
- Keine Information nur durch Farbe.
- Skalierbare Texte, soweit unter macOS sinnvoll.
- Finanzbeträge konsistent und zugänglich formatieren.

### 17.4 Fehler

Fehlermeldungen sollten enthalten:

- was fehlgeschlagen ist,
- ob Daten verändert wurden,
- was der Nutzer tun kann,
- ob erneutes Probieren sicher ist,
- Link zu Diagnose nur bei Bedarf.

#### Abnahmekriterien

- [ ] Kernablauf vollständig mit Tastatur bedienbar.
- [ ] VoiceOver-Kernablauf geprüft.
- [ ] Bewegung reduzieren deaktiviert unnötige Effekte.
- [ ] Kontrast und Fokusindikatoren sind ausreichend.
- [ ] Fehlertexte enthalten konkrete nächste Schritte.

---

## 18. P2 – App-Store-Metadaten

### 18.1 Positionierung

simplebanking sollte sich nicht als Bank darstellen.

Mögliche sachliche Kurzbeschreibung:

> Lokaler macOS-Client zur Anzeige und Auswertung der eigenen Kontodaten über unterstützte Banking-Schnittstellen.

### 18.2 Beschreibung

Die Produktbeschreibung sollte nennen:

- unterstützte Banking-Verfahren,
- unterstützte Banken oder Link zur aktuellen Liste,
- dass Banken TAN/SCA verlangen können,
- dass Verfügbarkeit von der Bank abhängt,
- lokale Speicherung,
- optionale Cloudfunktionen,
- Rolle von YAXI/Routex,
- Voraussetzungen und macOS-Mindestversion.

### 18.3 Vermeiden

- „funktioniert mit jeder Bank“,
- „100 % sicher“,
- „simplebanking sieht keine Daten“, wenn die App sie lokal verarbeitet,
- „vollständig lokal“, wenn KI, Logo- oder Banking-Dienste kontaktiert werden,
- Eindruck einer offiziellen Bank-App,
- fremde Marken im App-Namen,
- echte Kundendaten in Screenshots.

### 18.4 Screenshots

Nur fiktive Daten:

- fiktive Namen,
- gültig wirkende, aber nicht reale Kontodaten,
- keine echte IBAN eines Nutzers,
- keine echten Händlerbestellungen,
- keine echten Diagnoseinformationen.

Empfohlene Screenshotfolge:

1. Menüleisten-Flyout
2. Kontenübersicht
3. Umsatzliste
4. Kategorien und Auswertung
5. Fixkosten
6. Datenschutz und lokale Kontrolle

### 18.5 Weitere Angaben

- App-Name und Untertitel
- primäre Kategorie Finance
- Support-URL
- Marketing-URL
- Datenschutz-URL
- Copyright
- Altersfreigabe
- Länder und Regionen
- DSA-Trader-Angaben für EU-Vertrieb
- Verschlüsselungs-/Export-Compliance

#### Abnahmekriterien

- [ ] Beschreibung verspricht nur tatsächlich verfügbare Funktionen.
- [ ] Screenshots enthalten ausschließlich fiktive Daten.
- [ ] Datenschutz- und Support-URL sind öffentlich erreichbar.
- [ ] Finanzrolle wird nicht irreführend dargestellt.
- [ ] Regionen entsprechen den rechtlichen Freigaben.

---

## 19. P2 – Review Notes und Kommunikation mit Apple

### 19.1 Empfohlener Aufbau der Review Notes

```text
1. Zweck der App
2. Rechtliche und technische Rollen
3. Demo-Modus
4. Banking- und SCA-Ablauf
5. simplesend und StoreKit
6. Datenschutz
7. Sandbox und externe Komponenten
8. Behebung der früheren Menü-Ablehnung
9. Ansprechpartner
```

### 19.2 Beispielinhalt

#### Zweck

> simplebanking zeigt und analysiert die eigenen Kontodaten des Nutzers. Die Anwendung ist keine Bank, eröffnet keine Konten und verwahrt keine Gelder.

#### Demo

> Für die Prüfung ist kein reales Bankkonto erforderlich. Bitte wählen Sie beim Erststart „Demo ausprobieren“. Der Demo-Modus enthält mehrere fiktive Konten, Umsätze, Kategorien, Fixkosten und einen simulierten Überweisungsablauf.

#### SCA

> Reale Bankzugriffe können eine TAN- oder App-Freigabe der jeweiligen Bank verlangen. Im Demo-Modus wird dieser Ablauf vollständig simuliert.

#### Frühere Menü-Ablehnung

> Die frühere verschachtelte Kontextmenü-Navigation wurde entfernt. Ein Linksklick öffnet jetzt das sichtbare Flyout. Der Rechtsklick zeigt nur ein kurzes, flaches Kontextmenü ohne Untermenüs. Alle dort enthaltenen Befehle sind zusätzlich im Hauptfenster beziehungsweise im normalen macOS-App-Menü erreichbar.

#### Updates

> Der Mac-App-Store-Build enthält Sparkle nicht und besitzt keinen externen Aktualisierungsmechanismus. Updates erfolgen ausschließlich über den Mac App Store.

#### Externe Werkzeuge

> Der Mac-App-Store-Build enthält keine CLI-, MCP-, Shell- oder Symlink-Installationsfunktionen und startet keine externen Hilfsprogramme.

### 19.3 Anhänge

- Rollen- und Datenflussdiagramm
- YAXI-/Routex-Berechtigung
- gegebenenfalls regulatorische Unterlagen
- Demo-Anleitung
- kurzes Review-Video
- Datenschutzübersicht
- Erklärung zur früheren Ablehnung

#### Abnahmekriterien

- [ ] Review Notes sind vollständig und auf den eingereichten Build abgestimmt.
- [ ] Demo-Schritte wurden exakt mit diesem Build getestet.
- [ ] Alle erwähnten Anhänge sind hochgeladen.
- [ ] Ansprechpartner kann zeitnah reagieren.
- [ ] Frühere Ablehnung wird konkret, nicht defensiv, adressiert.

---

## 20. P3 – Release- und Qualitätssicherung

### 20.1 Testmatrix

| Bereich | Tests |
|---|---|
| Start | Erststart, Wiederholungsstart, beschädigte Einstellungen |
| Demo | Einstieg, Reset, keine echten Requests |
| Banking | Konto hinzufügen, mehrere Konten, Fehler, SCA |
| Sicherheit | Sperren, Entsperren, Touch ID, Keychain |
| Umsätze | leer, groß, mehrere Währungen, Suche |
| Transfer | Validierung, Abbruch, TAN, Wiederholungsschutz |
| Sandbox | Dateizugriff, Import, Export, Logs |
| Netzwerk | offline, Timeout, TLS-Fehler, Dienstausfall |
| StoreKit | Kauf, Abbruch, Restore, ausstehender Kauf |
| Datenschutz | Einwilligung, Widerruf, Löschung |
| UI | Hell/Dunkel, Kontrast, VoiceOver, Tastatur |
| Update | nur App Store, kein Sparkle |

### 20.2 Bundle-Prüfung

Vor jedem Upload:

- Signatur prüfen.
- Entitlements des finalen App-Binary prüfen.
- eingebettete Frameworks prüfen.
- alle ausführbaren Dateien inventarisieren.
- Sparkle-Suche durchführen.
- MCP-/CLI-Suche durchführen.
- Update-URLs suchen.
- private Schlüssel und Secrets suchen.
- Privacy Manifest validieren.
- Lizenzen prüfen.
- App unter frischem Nutzer starten.

### 20.3 TestFlight

Wenn für die macOS-App verfügbar und passend:

- interne Tester,
- externe Tester erst nach interner Stabilität,
- Test auf mehreren macOS-Versionen,
- Test auf Apple Silicon und gegebenenfalls Intel,
- Review-spezifischen Demo-Ablauf testen.

### 20.4 Rollback und Support

- bekannte Probleme dokumentieren,
- Backend-Schalter für riskante Dienste,
- Ticket-Broker widerrufbar,
- Statusseite oder Supporthinweis bei YAXI-Ausfall,
- keine Funktion durch nachgeladenen Code verändern,
- Datenschutzänderungen mit Store-Angaben synchronisieren.

---

## 21. Empfohlene Umsetzungsphasen

### Phase A – Zulassungsentscheidung

**Ziel:** Vor technischen Großumbauten klären, ob und unter welchen Bedingungen Apple die App akzeptieren kann.

#### Aufgaben

- [ ] rechtliche Einheit festlegen
- [ ] YAXI-/Routex-Vertriebsfreigabe einholen
- [ ] simplesend rechtlich klären
- [ ] Händlerdienste bewerten
- [ ] StoreKit-Modell wählen
- [ ] frühere Resolution-Center-Nachricht sichern
- [ ] geplanten Menüumbau mit Apple Developer Support abstimmen
- [ ] Zielregionen festlegen

#### Exit-Kriterium

Schriftliches Go für Banking-Zugriff und eine belastbare Einreichungsstrategie.

---

### Phase B – MAS-Architektur

**Ziel:** Technisch sauberer, reproduzierbarer Store-Build.

#### Aufgaben

- [ ] Xcode Workspace und separaten MAS-Target erstellen
- [ ] gemeinsamen Core abtrennen
- [ ] Sparkle aus MAS-Abhängigkeiten entfernen
- [ ] MCP/CLI/Shell-Integration aus MAS entfernen
- [ ] externe Prozesse ersetzen
- [ ] StoreKit Provider implementieren
- [ ] Ticket-Broker anbinden
- [ ] Privacy Manifest hinzufügen
- [ ] Entitlements minimieren
- [ ] Xcode Archive und Validation einrichten

#### Exit-Kriterium

Ein validierbares MAS-Archive, das ohne Direktvertriebskomponenten startet und den Kernablauf unterstützt.

---

### Phase C – UX-Umbau

**Ziel:** Native, auffindbare und reviewfreundliche macOS-Bedienung.

#### Aufgaben

- [ ] reguläres Hauptfenster
- [ ] eindeutiges Linksklickverhalten
- [ ] flaches Rechtsklickmenü
- [ ] vollständiges Hauptmenü
- [ ] keine wesentlichen Hover-/Doppelklickfunktionen
- [ ] Demo im Erststart
- [ ] Datenschutzbereich
- [ ] Konto- und Datenlöschung
- [ ] Barrierefreiheit

#### Exit-Kriterium

Alle Kernfunktionen sind sichtbar, per Tastatur erreichbar und ohne verschachtelte Kontextnavigation nutzbar.

---

### Phase D – Review-Härtung

**Ziel:** Den exakten Store-Build unter realistischen Reviewbedingungen absichern.

#### Aufgaben

- [ ] frischer Testnutzer
- [ ] Sandbox-Test
- [ ] Offline- und Fehlerfälle
- [ ] Demo-Skript
- [ ] StoreKit-Sandbox
- [ ] Datenfluss gegen Privacy Label prüfen
- [ ] Bundle auf unerlaubte Komponenten scannen
- [ ] Screenshots mit Fakedaten
- [ ] Review Notes finalisieren
- [ ] Anhänge vorbereiten

#### Exit-Kriterium

Eine fremde Testperson kann den gesamten Review-Ablauf nur anhand der Review Notes erfolgreich durchführen.

---

### Phase E – Einreichung

**Ziel:** Kontrollierter Upload und schnelle Reaktion auf App Review.

#### Aufgaben

- [ ] finale Versions- und Buildnummer
- [ ] Xcode Archive
- [ ] Validation
- [ ] Upload
- [ ] In-App-Produkte mit einreichen
- [ ] Metadaten final prüfen
- [ ] Review Notes einfügen
- [ ] Dokumente anhängen
- [ ] Ansprechpartner verfügbar halten
- [ ] Resolution Center zeitnah beantworten

#### Exit-Kriterium

App ist angenommen oder alle neuen Review-Fragen sind vollständig dokumentiert und in einen konkreten Folgeplan überführt.

---

## 22. Empfohlener Umfang für MAS Version 1.0

### Enthalten

- [ ] Kontoabfrage über YAXI/Routex
- [ ] Einrichtung mehrerer Konten
- [ ] Kontostand
- [ ] Umsatzliste
- [ ] Suche und Filter
- [ ] lokale Kategorien
- [ ] Fixkosten
- [ ] Abonnements
- [ ] Dauerauftragsanzeige
- [ ] Dashboard
- [ ] Demo-Modus
- [ ] Datenschutz- und Löschbereich
- [ ] **simplesend als nicht verbrauchbarer In-App-Kauf** (12.2) — rechtliche Klärung
      nach 4.1/5.4 und der Ticket-Broker nach Abschnitt 5 bleiben Voraussetzung

### Nicht enthalten

- [ ] Sparkle
- [ ] MCP
- [ ] CLI
- [ ] Shell-Integration
- [ ] Symlink-Installation
- [ ] externe Lizenzkeys (ersetzt durch StoreKit, 12.2)
- [ ] **REWE** (11.4)
- [ ] **dm** (11.4)
- [ ] **Amazon** (11.4)
- [ ] **PayPal** (11.4)
- [ ] **Cloud-KI und jedes Feld für eigene KI-API-Schlüssel** (12.5) — nicht ausgeblendet,
      sondern nicht vorhanden

Nach diesen Entscheidungen enthält die Store-Fassung **keine einzige Stelle mehr, an der
ein Nutzer einen API-Schlüssel einträgt**, und **keinen eigenen Freischaltmechanismus**.
Beide Ablehnungsgründe von damals sind damit an der Wurzel adressiert — der zweite
vollständig, der erste über den Menü- und Hauptfenster-Umbau aus Abschnitt 8 und 9.

---

## 23. Finale Go/No-Go-Checkliste

### Recht und Anbieter

- [ ] Unternehmens- beziehungsweise Anbieterrolle geklärt
- [ ] YAXI-/Routex-Berechtigung vorhanden
- [ ] Finanz- und Transferrolle dokumentiert
- [ ] Markenrechte geklärt
- [ ] Regionen festgelegt

### Sicherheit

- [ ] kein YAXI-Signiergeheimnis im Client
- [ ] Ticket-Broker produktionsreif
- [ ] Transfer gegen Wiederholung abgesichert
- [ ] keine Secrets im Bundle
- [ ] Keychain- und Löschverhalten geprüft

### Architektur

- [ ] eigener MAS-Target
- [ ] kein Sparkle
- [ ] kein MCP/CLI
- [ ] keine externen Prozesse
- [ ] vollständige Sandbox-Kompatibilität
- [ ] reproduzierbares Xcode Archive

### UX

- [ ] flaches Kontextmenü
- [ ] vollständiges App-Menü
- [ ] reguläres Hauptfenster
- [ ] Demo direkt erreichbar
- [ ] keine versteckten Kernaktionen
- [ ] Barrierefreiheit geprüft

### Geschäft

- [ ] StoreKit für digitale Freischaltungen
- [ ] Restore Purchases
- [ ] keine externen Lizenz- oder Kaufwege
- [ ] Preis und Leistungsumfang verständlich

### Datenschutz

- [ ] Dateninventar
- [ ] Datenflussmatrix
- [ ] Datenschutzerklärung in App und Store
- [ ] App Privacy Label korrekt
- [ ] Privacy Manifest korrekt
- [ ] optionale Dienste widerrufbar
- [ ] Daten vollständig löschbar

### Review

- [ ] vollständiger Demo-Modus
- [ ] Review-Skript
- [ ] Review Notes
- [ ] rechtliche Anhänge
- [ ] fiktive Screenshots
- [ ] frühere Menü-Ablehnung ausdrücklich adressiert
- [ ] finaler Build auf frischem Benutzerkonto geprüft

### Go/No-Go-Regel

**Go** nur, wenn alle P0- und P1-Punkte abgeschlossen sind und keine wesentliche Funktion ausschließlich durch eine Review-Ausnahme erklärbar wird.

**No-Go**, wenn mindestens einer dieser Punkte offen ist:

- YAXI-/Routex-Vertriebsberechtigung unklar
- Finanz-/Transferrolle unklar
- Signiergeheimnis im Client
- Sparkle oder externe Lizenzierung im MAS-Build
- MCP/CLI/Shell-Funktionen im MAS-Build
- Händlerdienst ohne Nutzungsberechtigung
- verschachtelte Kontextmenü-Navigation
- unvollständiger Demo-Modus
- inkorrekte Datenschutzangaben
- Sandbox funktioniert nur mit Ausnahmen oder deaktivierten Schutzmechanismen

---

## 24. Relevante Stellen im aktuellen Repository

### 24.1 Geprüfter Ist-Zustand des MAS-Pfads

Am 26.07.2026 nachgesehen, damit niemand von einem funktionierenden Gerüst ausgeht:

- **`build-mas.sh` existiert und ist grundsätzlich brauchbar** — `codesign` mit
  „3rd Party Mac Developer Application", `productbuild` mit dem Installer-Zertifikat,
  `LSApplicationCategoryType = public.app-category.finance`, und bewusst **keine**
  Sparkle-Schlüssel im Info.plist.
- **Aber veraltet:** `VERSION_BASE` steht auf **1.2.4** (April 2026), gebaut wird
  **nur arm64** (`swift build -c release --arch arm64`) — Intel-Macs blieben außen vor.
- **Die Entitlements sind zu dünn.** `simplebanking-mas.entitlements` enthält
  ausschließlich `app-sandbox`, `network.client`, `application-identifier` und
  `team-identifier`. Für die heutige Funktionsvielfalt fehlen mindestens
  `files.user-selected.read-only` (PDF-Ablage) und eine Prüfung der Keychain-Gruppe.
- **Die Bundle-ID ist dieselbe wie im Direktvertrieb** (`tech.yaxi.simplebanking`).
  Beide Fassungen könnten so nicht nebeneinander bestehen; die Store-Fassung braucht
  eine eigene Kennung (siehe Abschnitt 6).
- **Es gibt kein Xcode-Projekt.** Alles läuft über `swift build` und Shell-Skripte.
  2.4.5(ii) verlangt „packaged and submitted using technologies provided in Xcode";
  die Einreichung braucht Archiv, Provisioning-Profil und ein signiertes `.pkg`.
- **Nützliche Vorarbeit aus 2.0:** `CredentialsStore.appSupportURL()` ist inzwischen die
  **einzige** pfadbildende Stelle für Datenbank, Zugangsdaten und Überweisungsentwürfe.
  Für die Sandbox liefert sie schlicht den Container-Pfad, ohne dass ein einziger
  Aufrufer angefasst werden muss. Übrig bleiben die zweite Wurzel
  `~/Library/Application Support/com.maik.simplebanking/` (Logo-Cache
  `BankLogoStore.swift:16`, Themes `ThemeSupport.swift:238`, `state.json`
  `BalanceBar.swift:813`) und `~/Library/Logs/simplebanking/` (`AppLogger.swift:16`).
- **Carbon-Hotkeys sind unkritisch:** `RegisterEventHotKey` funktioniert in der Sandbox
  ohne eigenes Entitlement.

### 24.2 Dateien

Diese Liste dient als Ausgangspunkt für den späteren Umbau:

| Thema | Stelle |
|---|---|
| aktueller MAS-Build | `build-mas.sh` |
| MAS-Entitlements | `Sources/simplebanking/simplebanking-mas.entitlements` |
| beanstandeter Menüaufbau | `Sources/simplebanking/BalanceBar.swift:1305-1498` (Aufbau), `:3185-3187` (Rechtsklick), `:234` (`contextMenuProvider`), `:2613-2638` (`NSApp.mainMenu`) |
| Aktivierungs-Policy | `Sources/simplebanking/SimpleBankingApp.swift:20` (`.accessory`) |
| KI-Schlüssel (3.1.1-Befund) | `StoredCredentials` in `Sources/simplebanking/CredentialsStore.swift` — `anthropicApiKey`, `mistralApiKey`, `openaiApiKey` |
| Sandbox-Pfadwurzel | `CredentialsStore.appSupportURL()` |
| Haupt-Target und Abhängigkeiten | `Package.swift` |
| App-Lifecycle und Menüleistenlogik | `Sources/simplebanking/BalanceBar.swift` |
| App-Einstieg | `Sources/simplebanking/SimpleBankingApp.swift` |
| Sparkle-Wrapper | `Sources/simplebanking/UpdateChecker.swift` |
| YAXI-Tickets | `Sources/simplebanking/YaxiTicketMaker.swift` |
| YAXI-Banking und Transfer | `Sources/simplebanking/YaxiService.swift` |
| MCP-Installation | `Sources/simplebanking/MCPInstaller.swift` |
| CLI-Installation | `Sources/simplebanking/CLIInstaller.swift` |
| MCP-/CLI-Einstellungen | `Sources/simplebanking/SettingsPanel.swift` |
| KI-Datenfluss | `Sources/simplebanking/LLMService.swift` und `Sources/simplebanking/AIProviderService.swift` |
| REWE-Abruf und ZIP | `Sources/simplebanking/REWEService.swift` |
| dm-Integration | `Sources/simplebanking/DMService.swift` und `Sources/simplebanking/DMAuthWebView.swift` |
| Amazon-Integration | `Sources/simplebanking/AmazonAuthWebView.swift` sowie zugehörige Service-/Store-Dateien |

---

## 25. Schlussfolgerung

Der erfolgversprechendste Weg ist keine möglichst unveränderte Übernahme der Direktversion, sondern eine klar abgegrenzte Mac-App-Store-Ausgabe.

Die Store-Version sollte:

- technisch kleiner,
- rechtlich klarer,
- vollständig sandboxfähig,
- ohne externe Update- und Toolinstallation,
- über StoreKit monetarisiert,
- mit einem sichtbaren Hauptfenster,
- mit einem kurzen, flachen Kontextmenü,
- mit vollständigem Demo-Modus,
- und mit einer belastbaren Datenschutz- und Review-Dokumentation

eingereicht werden.

Die wichtigste Reihenfolge lautet:

1. rechtliche Zulässigkeit und Partnerfreigabe,
2. Entfernung des Client-Secrets,
3. separater MAS-Target,
4. Sandbox- und StoreKit-Umbau, **einschließlich Entfernung aller vom Nutzer
   eingetragenen API-Schlüssel, die Funktionen freischalten** (12.5),
5. Menü- und Hauptfenster-UX,
6. Datenschutz und Demo,
7. Review-Härtung und Einreichung.

Erst wenn die P0- und P1-Punkte abgeschlossen sind, ist eine erneute Einreichung sinnvoll.

**Beide bekannten Ablehnungsgründe sind bis heute unverändert im Code vorhanden** —
das Menü ist weiterhin nur per Rechtsklick erreichbar, und die KI-Schlüsselfelder
liegen weiterhin in `StoredCredentials`. Eine erneute Einreichung ohne diese beiden
Umbauten würde mit denselben zwei Texten zurückkommen.

---

## Nicht belegt / offen

Damit niemand Genauigkeit annimmt, wo keine ist:

- **Ob 5.1.1(ix) mit dem Einzelentwickler-Konto überwindbar ist**, liegt im Ermessen des
  Reviewers. Es gibt einen belegten Gegenfall (4.1), aber keine belastbare Zusage.
- **Die Human-Interface-Guidelines-Seiten** zu Menüleisten-Extras und Kontextmenüs sind
  JavaScript-gerendert und ließen sich nicht automatisiert abrufen. Die Aussagen in
  Abschnitt 8 stützen sich auf den Originaltext der Ablehnung, die App Review Guidelines
  und zwei dokumentierte Vergleichsfälle — nicht auf HIG-Zitate.
- **Die YAXI-Vertragslage** ist ungeprüft: ob der Vertrag App-Store-Vertrieb abdeckt und
  ob YAXI die Lizenzkette gegenüber Apple bestätigt.
- **Die Liste der Sandbox-Verstöße ist nicht erschöpfend.** Ein systematischer
  Code-Audit dazu wurde begonnen, aber abgebrochen. Es fehlt insbesondere eine
  vollständige Suche nach `Process`/`NSTask`, `osascript`, Zugriffen auf fremde
  App-Konfigurationen und weiteren absoluten Pfaden. Vor dem Sandbox-Umbau nachholen.
