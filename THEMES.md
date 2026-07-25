# simplebanking · Theme-Spezifikation

Grundlage für **(a)** den separaten Theme-Builder und **(b)** das Erstellen neuer
Themes von Hand. Beschreibt den vollständigen Vertrag: Dateiformat, alle Schlüssel,
ihre Wirkung in der App, die Invarianten — und die Anforderungen an den Builder.

Stand: App 2.0.0. Maßgebliche Implementierung: `Sources/simplebanking/ThemeSupport.swift`
(`AppTheme`, `ThemeManager`, `ThemeChrome`, `ThemeFonts`).

---

## 1. Was ein Theme ist — und was nicht

Ein Theme ist eine **`.cfg`-Textdatei**, die Farben, zwei Schriftnamen und eine Reihe
von Ja/Nein-Schaltern deklariert. Es wirkt ausschließlich auf **Flyout** (Popover,
zentriertes Overlay, freigestelltes Widget) und **Umsatzliste** — Einstellungen,
Überweisungsfenster, Dashboard und alle übrigen Fenster bleiben immer im Default-Look.

**Harte Invariante:** Ein Theme verändert nie Anordnung, Abstände oder Reihenfolge von
Elementen. Es bestimmt nur, *welche* Farbe/Schrift ein Element trägt, *ob* ein Element
gezeichnet wird und *womit* ein vorhandener Platz gefüllt ist (z. B. Mosaik-Block im
20×20-Logo-Platz). Der Builder braucht deshalb keine Layout-Werkzeuge.

---

## 2. Ablage, Laden, Auswahl

| Aspekt | Verhalten |
|---|---|
| Ablageort | `~/Library/Application Support/com.maik.simplebanking/themes/*.cfg` |
| Built-in-Themes | `default.cfg`, `sunrise.cfg`, `gameboy.cfg`, `btx.cfg` — werden **bei jedem App-Start überschrieben**. Eigene Themes dürfen diese Dateinamen nicht verwenden. |
| Ausgemustert | `ocean.cfg`, `norton-commander.cfg` — werden beim Start **gelöscht**. Auch diese Namen sind tabu. |
| Laden | Beim App-Start und beim Öffnen der Theme-Einstellungen (`ThemeManager.reloadThemes()`). Eine neu abgelegte Datei erscheint also nach App-Neustart oder erneutem Öffnen der Einstellungen. |
| Auswahl | UserDefaults-Schlüssel `themeId` in der Domain `tech.yaxi.simplebanking`. Zeigt die `id` aus der `.cfg`. Unbekannte id → Rückfall auf `default`. |
| Sortierung | Theme-Liste alphabetisch nach `name`. |

Ein externer Builder installiert ein Theme, indem er die `.cfg` in den Ablageort
schreibt. Aktivieren kann er es über `defaults write tech.yaxi.simplebanking themeId
-string <id>` — sichtbar wird das in einer laufenden App erst nach Neustart oder
Theme-Wechsel in den Einstellungen (die App lauscht nicht auf externe Defaults-Writes).

---

## 3. Dateisyntax

```
# Kommentar (auch ; am Zeilenanfang)
schlüssel=wert
```

- Eine Deklaration pro Zeile, Trennzeichen `=`.
- **Schlüssel sind case-insensitiv** (werden lowercased); Werte werden getrimmt.
- Unbekannte Schlüssel werden **ignoriert** → vorwärtskompatibel; alte App-Versionen
  können neue Themes laden.
- Fehlt `id`/`name`, wird der Dateiname (ohne `.cfg`) verwendet.
- Farbwerte: `#RRGGBB` oder `#AARRGGBB` (Alpha vorangestellt); ungültige Werte fallen
  still auf den Default-Wert des jeweiligen Schlüssels zurück.

### Bool-Grammatik

`on / true / yes / 1` = an · `off / false / no / 0` = aus (case-insensitiv).
**Jeder andere Wert — auch Tippfehler — fällt auf den Default des Schlüssels zurück**;
ein vertipptes `ripple=offf` schaltet also nichts ab. (`ThemeManager.parseBool`)

---

## 4. Schlüsselreferenz

### 4.1 Identität & Schrift

| Schlüssel | Default | Wirkung |
|---|---|---|
| `id` | Dateiname | Stabile Kennung; landet in `themeId`. Kebab-case, keine Built-in-/Retired-Namen. |
| `name` | Dateiname kapitalisiert | Anzeigename in den Einstellungen. |
| `bodyFont` | `System` | Fließtext in Flyout + Liste (`ThemeFonts.flyoutBody`). PostScript-/Familienname; `System` = Systemschrift. |
| `headingFont` | `System` | Saldo-Zahl, Händlernamen, Beträge, Datumsköpfe (`ThemeFonts.flyoutHeading`). |

Schriften müssen im System installiert oder im App-Bundle registriert sein
(`ThemeFonts.registerBundledFonts()` lädt `.ttf` aus `Contents/Resources`, Rückfall
`Bundle.module`). **Unbekannte Namen fallen still auf die Systemschrift zurück** — das
Theme bricht nicht, sieht nur unauffälliger aus. Mitgelieferte Schrift ⇒ Lizenz
beachten (VT323: OFL-1.1, Lizenztext muss mit ausgeliefert werden).

### 4.2 Farben

| Schlüssel | Default (Fallback) | Wirkung |
|---|---|---|
| `accent` | `#4E79A7` | **Leitfarbe** aktiver Bedienelemente: aktive Konto-Umschalter, gefüllte Filter-Blöcke, aktive Textkommandos, „Weiter"-Button, Ungelesen-Marker, Aufrunden-Button. |
| `positive` / `positiveLight` / `positiveDark` | `#4F8A6A` | Einnahmen-Beträge, „verfügbar"-Zeile, Sparbeträge, grüner Anteil der Blockleiste. `positive` gilt für beide Appearances, die `…Light/Dark`-Varianten überschreiben je Modus. |
| `negative` / `negativeLight` / `negativeDark` | `#C65A5A` | Ausgaben-Beträge, Datumsköpfe (Theme), Dispo-Warnzeile, **negativer Kontostand**, roter Anteil der Blockleiste. |
| `cardLight` / `cardDark` | `#FFFFFF` / `#1F1F1F` | **Surface**: vollflächige Kartenfarbe von Flyout-Karte und Listen-Kopf; bei aktivem Theme zugleich Hintergrund der gesamten Liste und des Flyouts (flach, kein Money-Heat). Auch Textfarbe AUF gefüllten Accent-Flächen. |
| `panelLight` / `panelDark` | `#F9F9F9` / `#171717` | Panel-Hintergrund — wird bei aktivem Theme praktisch von Surface überdeckt; relevant v. a. für das Default-Theme. |
| `inkLight` / `inkDark` | *(leer)* | **Ink**: Vordergrund (große Saldo-Zahl, Namen, Fließtext) auf der Surface. Leer ⇒ automatischer Schwarz/Weiß-Kontrast per Luminanz (Schwelle 0,55, WCAG-nah — `AppTheme.contrastingInk`). |
| `screenBorder` | *(leer)* | Farbe der **CRT-Blende** um Flyout + Liste (außen bis zur Fensterkante gefüllt, innen gerundet ausgestanzt; 5–6 pt stark). Leer = keine Blende. |

Abgeleitete Töne (nicht konfigurierbar): gedämpfte Ink-Stufen `0.45` (Platzhalter),
`0.6–0.75` (Sekundärtext, inaktive Kommandos), `0.85–0.9` (Labels); Feld-Füllung
Weiß 65 % mit 2-pt-Ink-Rahmen; Money-Heat bleibt exklusiv dem Default-Theme.

### 4.3 Chrome-Schalter

Alle Defaults = Bestandsverhalten; ein leeres Theme sieht aus wie bisher.

| Schlüssel | Default | `off`/`on` bedeutet |
|---|---|---|
| `ripple` | `on` | `off`: Wasser-Effekt (Klick + neue Einnahmen) komplett aus — der Shader wird gar nicht erst angehängt. |
| `merchantLogos` | `on` | `off`: Händler-Logos in Zeilen/Karten werden durch **Mosaik-Blöcke** ersetzt (gleicher 20×20-Platz, Kategorie bestimmt Muster+Farbe; Muster siehe `BTXMosaic.Shape`). |
| `bankLogos` | `on` | `off`: Bankmarke im Flyout-/Listen-Kopf → neutraler Mosaik-Block. |
| `categoryIcons` | `on` | `off`: SF-Symbol-Fallback der Zeilen → Mosaik; Kategorie-Symbole der Händler-Auswertung → Farbblock. |
| `uppercase` | `off` | `on`: alle getönten Texte in Großbuchstaben (`ThemeChrome.textCase`). |
| `dottedLeaders` | `off` | `on`: gepunktete Führungslinie zwischen Name und Betrag statt Leerraum. |
| `squareControls` | `off` | `on`: Eckenradius aller getönten Bedienelemente = 0 (`ThemeChrome.cornerRadius(_:)`) — Suchfeld, Filter-Blöcke, Buttons, Eingabefelder. |
| `glyphControls` | `on` | `off`: Bedien-**Icons werden Text** — „FILTER", „KAT.", „SPAREN", „SENDEN", „AUSWERTUNG", „INBOX (n)", „X" zum Leeren, `>`-Pfeile; Konto-Umschalter werden unterstrichene Textkommandos statt Pillen; Konto-/Kategorien-**Ringe werden Mosaik-Blockleisten**; blinkendes ☎ erscheint im Kopf; Segmented-Controls werden Text-Paare. |

**Faustregel für Retro-Themes:** `uppercase`, `dottedLeaders`, `squareControls` an,
`glyphControls`, Logos, Icons, `ripple` aus — dann trägt Text die Bedienung, wie es
Terminals und BTX taten.

---

## 5. Wirkungs-Landkarte (für die Builder-Preview)

Welcher Schlüssel färbt was — die Preview des Builders sollte mindestens diese
Bereiche zeigen (Flyout-Karte 348 pt breit + ein Listen-Ausschnitt, Light und Dark):

| Preview-Bereich | Schlüssel |
|---|---|
| Kartenfläche + Listenhintergrund | `cardLight/Dark` |
| Große Saldo-Zahl (positiv) | `inkLight/Dark` (bzw. Auto-Kontrast), `headingFont` |
| Große Saldo-Zahl (negativ) | `negative…` |
| Kopfzeile „Bank · Uhrzeit" | Ink 0,9 · `bodyFont` |
| „X € bis zum … verfügbar" | `positive…` · `bodyFont` |
| Dispo-Warnzeile | `negative…` |
| Datumskopf „HEUTE" | `negative…` · `headingFont` |
| Umsatzzeile Name/Betrag | Ink · `headingFont`; Betrag `positive/negative` |
| Aktiver Konto-Umschalter / Filter | `accent` (Text auf Füllung: Surface-Farbe) |
| Suchfeld/Eingabefelder | Weiß 65 % + 2-pt-Ink-Rahmen, Radius via `squareControls` |
| Blende um alles | `screenBorder` |
| Mosaik-Blöcke | Muster fix, Farben fix je Kategorie (nicht konfigurierbar) |

Bei aktivem Theme skaliert die Saldo-Zahl auf 50 pt (Liste) / 42 pt (Flyout) mit
vertikaler Streckung 1,15 („double height") — die Preview sollte das nachbilden.

---

## 6. Appearance (Hell/Dunkel)

Jede Farbfamilie hat Light/Dark-Varianten. Zwei gültige Strategien:

1. **Adaptiv** (wie Default/Sunrise): unterschiedliche Werte je Modus.
2. **Appearance-unabhängig** (wie Game Boy/BTX): identische Werte für Light und Dark —
   ein Röhrenschirm sah immer gleich aus. Dann müssen **alle** Varianten explizit
   gesetzt sein (`positiveLight` = `positiveDark` usw.), sonst mischen sich
   Default-Darkwerte hinein.

Achtung Dark-Mode-Falle: Systemfarben (`.primary`, Platzhalter) folgen dem Modus —
die App ersetzt sie an allen getönten Stellen durch Theme-Farben, damit auf einer
hellen Theme-Fläche im Dark-Mode kein weißer Text landet. Ein Builder muss beide
Modi previewen.

---

## 7. Referenz-Themes

Die vier Built-ins in `ThemeManager.builtInThemes` sind die maßgeblichen Beispiele:

- **`default.cfg`** — minimal: nur Farben/`System`-Schrift, alle Schalter auf Default.
  Money-Heat, Logos, Icons, Ringe: alles an.
- **`sunrise.cfg`** — Farb-Theme mit eigener Schrift (Avenir Next), keine Schalter.
- **`gameboy.cfg`** — appearance-unabhängig, monochrome Beträge (`positive` =
  `negative` = dunkelstes Grün: das Vorzeichen trägt die Information), Menlo.
- **`btx.cfg`** — Vollausbau des Vertrags (alle Schalter, `screenBorder`, VT323):

```
id=btx
name=BTX revisited
bodyFont=VT323
headingFont=VT323
accent=#0018a8
positive=#0a7a24        # + Light/Dark identisch gesetzt
negative=#b0061f        # + Light/Dark identisch gesetzt
cardLight=#cfcfcf
cardDark=#cfcfcf
panelLight=#cfcfcf
panelDark=#cfcfcf
inkLight=#0018a8
inkDark=#0018a8
ripple=off
merchantLogos=off
categoryIcons=off
bankLogos=off
uppercase=on
dottedLeaders=on
squareControls=on
glyphControls=off
screenBorder=#e8b200
```

### Easter-Egg (nicht Teil des Vertrags)

Exklusiv bei `id == "btx"`: Doppelklick auf das blinkende ☎ toggelt einen
CRT-Shader (Scanlines, Lochmaske, Tonnen-Verzerrung, Vignette, Flicker —
`BTXCRT.metal`) auf Umsatzliste und freigestelltem Flyout-Widget. Persistiert in
`btxCrtEnabled`. Andere Themes können das **nicht** aktivieren — bewusst kein
`.cfg`-Schlüssel.

---

## 8. Anforderungen an den Theme-Builder

**Ziel:** eigenständiges Werkzeug, das valide `.cfg`-Dateien erzeugt, installiert und
bestehende bearbeitet — ohne die App zu verändern.

### Muss

1. **Formular für alle Schlüssel aus Abschnitt 4** — Farb-Picker paarweise
   (Light/Dark, mit „identisch"-Kopplung für appearance-unabhängige Themes),
   Font-Auswahl aus den installierten Schriften (Familienname), Schalter als Toggles
   mit den Erklärtexten aus 4.3.
2. **Live-Preview** nach der Wirkungs-Landkarte (Abschnitt 5): Flyout-Karte +
   Listen-Ausschnitt mit Beispieldaten, umschaltbar Hell/Dunkel. Die Preview muss die
   Schalter-Effekte zeigen (Mosaik statt Logo, Textkommandos, Punktlinien, Blende,
   Blockleiste, eckige Felder).
3. **Validierung:**
   - Hex-Format (`#RRGGBB`/`#AARRGGBB`), sonst Feld-Fehler;
   - `id`: kebab-case, nicht in {`default`, `sunrise`, `gameboy`, `btx`, `ocean`,
     `norton-commander`} (Built-ins werden überschrieben, Retired gelöscht);
   - Kontrast-Warnung, wenn Ink (bzw. Auto-Ink) gegen Surface unter ~4,5:1 fällt
     (WCAG AA) — Warnung, kein Blocker;
   - Hinweis, wenn eine gewählte Schrift nicht installiert ist (App fiele still auf
     System zurück).
4. **Export/Install:** `.cfg` nach
   `~/Library/Application Support/com.maik.simplebanking/themes/<id>.cfg` schreiben;
   Bool-Werte als `on`/`off`, Kommentar-Kopf mit Name/Datum. Hinweistext: Aktivierung
   in der App über Einstellungen → Theme (oder App-Neustart).
5. **Import/Round-trip:** bestehende `.cfg` öffnen (Parser-Regeln aus Abschnitt 3:
   lowercase-Keys, Kommentare, Bool-Grammatik, unbekannte Keys **erhalten** und beim
   Export unverändert zurückschreiben).

### Soll

- Vorlagen: „Leer (Default-Verhalten)", „Retro-Preset" (Faustregel aus 4.3), die vier
  Built-ins als Startpunkte.
- Duplizieren eines bestehenden Themes.
- Vorschau-Export als PNG (zum Teilen).

### Nicht-Ziele

- Keine Layout-Optionen (Invariante aus Abschnitt 1).
- Keine neuen Schlüssel erfinden — der Vertrag wird nur in der App erweitert; der
  Builder erhält Unbekanntes beim Round-trip.
- Kein Schreiben von `themeId`/`btxCrtEnabled` ohne ausdrückliche Nutzeraktion.

---

## 9. Kompatibilität

- Unbekannte Schlüssel ignoriert die App; neue Schalter defaulten immer auf
  Bestandsverhalten → alte Themes bleiben gültig, neue Themes funktionieren
  (reduziert) in alten App-Versionen.
- Der Vertrag ist **additiv**: Schlüssel werden nie umbenannt oder entfernt.
- Tests, die den Vertrag absichern: `Tests/simplebankingTests/BTXThemeTests.swift`
  (Bool-Grammatik, Defaults, btx.cfg, Mosaik-Muster, Schrift-Registrierung) und
  `ThemeWashTests.swift` (Surface/Ink-Ableitung).
