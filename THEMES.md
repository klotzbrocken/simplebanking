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

**Die Schrift wirkt auf alle getönten Texte.** Kontostand, Überschriften **und** die
Zeilen der Umsatzliste (Empfänger, Absender, Betrag, Kategorien) nehmen `bodyFont` bzw.
`headingFont`. Die Punktgrade bleiben dabei die der App; nur Themes mit
`lofiTypography=on` (siehe §4.3) bekommen größere Grade, weil Rasterschriften wie VT323
kleiner bauen.

**Die Schrift kann die Geometrie nicht verschieben.** Das war einmal anders: Die
Kontostand-Zeile übernahm die Zeilenhöhe der Theme-Schrift, wodurch Game Boy höhere
Karten bekam als das Default-Theme — und die Höhe zusätzlich mit der Länge des Betrags
wanderte. Die theme-getönten Saldo-Zeilen in Flyout und Umsatzliste haben deshalb eine
**feste Höhe, abgeleitet aus der Systemschrift** ihrer Größe
(`ThemeFonts.lineHeight(forSize:weight:)`), nicht aus der gewählten Familie. Für den
Builder heißt das: Die Schriftwahl ist gefahrlos — eine sehr schmale oder sehr breite
Familie ändert Zeichnung und Laufweite, aber nie die Höhe einer Karte oder eines
Fensters. Ausgenommen ist der Lo-Fi-Modus (siehe §4.3, `lofiTypography=on`), der eigene,
absichtlich größere Metriken setzt.

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
| `bodyFont` | `System` | Fließtext in Flyout + Liste — **einschließlich der Umsatzzeilen** (Empfänger, Absender, Kategorien, Notizen). `ThemeFonts.flyoutBody`/`rowBody`. PostScript-/Familienname; `System` = Systemschrift. |
| `headingFont` | `System` | Saldo-Zahl, Händlernamen, Beträge, Datumsköpfe. `ThemeFonts.flyoutHeading`/`rowHeading`. |
| `logo` | *(leer)* | **Globale Bildmarke** statt der Bankmarke in Flyout- und Listenkopf — für **alle** Konten gleich, auch PayPal und Händler-Slots. Dateiname **relativ zum Theme-Ordner**. Format siehe unten. |
| `logoDark` | *(leer)* | Variante für den Dunkelmodus. Ohne diesen Schlüssel wird `logo` in beiden Modi unverändert gezeigt — es wird **nichts automatisch invertiert**. |
| `wallpaper` | *(leer)* | **Grundbild** für Flyout und Umsatzliste. Ersetzt die flache Theme-Farbe (`cardLight`/`cardDark`). Dateiname relativ zum Theme-Ordner, gleiche Regeln wie `logo`. Format siehe unten. |
| `wallpaperDark` | *(leer)* | Variante für den Dunkelmodus. Ohne diesen Schlüssel gilt `wallpaper` in beiden Modi. |
| `wallpaperFlyout` / `wallpaperFlyoutDark` | *(leer)* | Eigenes Bild nur fürs **Flyout**. Ohne diese Schlüssel gilt `wallpaper`. |
| `wallpaperWide` / `wallpaperWideDark` | *(leer)* | Eigenes Bild nur für die **breite Umsatzliste**. Ohne diese Schlüssel gilt `wallpaper`. |
| `ringImage` / `ringImageDark` | *(leer)* | **Grafik statt Kontoring**, gleiche Fläche (72 × 72). Ring und Grafik schließen einander aus; ist der Schlüssel gesetzt, wird der Schalter „Kontoring anzeigen" in den Einstellungen gesperrt. Getrennt von `logo`, das über dem Kontostand sitzt — sonst stünde dasselbe Bild zweimal im Fenster. |

**Die Schrift ist gefahrlos wählbar.** Zeilenhöhen hängen nicht an ihr (siehe §1), eine
sehr schmale oder breite Familie ändert also das Schriftbild, nie die Höhe einer Karte.

**Schriftgrade bleiben die der App.** Ein Theme wählt die Familie, nicht die Größe. Nur
`lofiTypography=on` (§4.3) bringt in den Umsatzzeilen größere Grade — Rasterschriften wie
VT323 bauen kleiner und wären sonst unlesbar. Wer eine ähnlich klein bauende Schrift
verwendet, setzt diesen Schlüssel; einen frei wählbaren Größenfaktor gibt es bewusst
nicht.

#### Format des globalen Logos

| | |
|---|---|
| **Akzeptiert** | PNG, PDF, SVG (geladen über `NSImage(contentsOf:)`) — andere Endungen werden abgelehnt |
| **Dateiname** | Ein **einfacher Name** im Theme-Ordner. Keine Verzeichnisse, kein `..`, keine absoluten Pfade, nichts mit Punkt am Anfang. Auch eine Verknüpfung, die aus dem Ordner herausführt, wird abgelehnt — Themes werden weitergegeben, und ein fremdes darf nicht auf beliebige Bilder des Nutzers zugreifen. |
| **Maße** | Höchstens 8000 px je Kante und 16 MP gesamt, geprüft vor dem Dekodieren. Die Byte-Grenze allein genügt nicht: Ein stark komprimiertes PNG von 300 KB kann 40 000 × 40 000 Pixel groß sein. Bei SVG greift nur die Byte-Grenze — ein Vektorbild hat keine Pixelmaße. |
| **Empfohlen** | Vektor — PDF oder SVG. Bleibt in jeder Größe scharf. |
| **Raster (PNG)** | quadratisch, **mindestens 128 × 128 px**. Gezeichnet wird bei 20 pt (Flyout) bzw. 18 pt (Liste), auf Retina also 40 bzw. 36 px — 128 gibt Reserve. |
| **Hintergrund** | transparent. Die Marke sitzt auf der Theme-Fläche; ein deckendes Rechteck sieht aus wie ein aufgeklebter Sticker. |
| **Seitenverhältnis** | Nicht quadratisches wird eingepasst, nie beschnitten oder verzerrt. |
| **Dateigröße** | höchstens **512 KB**. Größeres wird ignoriert und protokolliert — Theme-Ordner sollen weitergebbar bleiben. |

#### Format des Wallpapers

| | |
|---|---|
| **Akzeptiert** | PNG, PDF, SVG — wie beim Logo |
| **Empfohlene Maße** | Flyout 348 × 140, schmale Liste 348 × 620, breite Liste 840 × 620 — jeweils @2x verdoppelt |
| **Größe** | bis 4 MB (das Logo darf nur 512 KB — ein Wallpaper braucht mehr) |
| **Dateiname** | einfacher Name im Theme-Ordner, dieselben Regeln wie beim Logo |

**Drei Flächen, drei Seitenverhältnisse.** Das ist der Grund für die zusätzlichen
Schlüssel:

| Fläche | Größe | Verhältnis | Schlüssel |
|---|---|---|---|
| Flyout | 348 × 140 (bzw. 178, plus Drawer) | ≈ 2,5 : 1 breit-flach | `wallpaperFlyout` |
| Umsatzliste schmal | 348 × 620 | 0,56 : 1 hochkant | `wallpaper` |
| Umsatzliste breit | 840 × 620 | 1,35 : 1 quer | `wallpaperWide` |

Kantenziehen ist gesperrt, nur der grüne Fensterknopf schaltet die Listenbreite um.

Das Wallpaper wird **flächenfüllend skaliert und oben verankert**, der Überhang
beschnitten. **Was oben im Bild steht, ist immer sichtbar; was unten steht, verschwindet
zuerst** — im Flyout bleibt von einem hochkanten Bild praktisch nur der obere Rand.
Ein Motiv am unteren Bildrand überlebt das nicht.

Eine einzige Datei bleibt gültig: `wallpaperFlyout` und `wallpaperWide` sind optional und
fallen auf `wallpaper` zurück. Für ein ruhiges Muster oder einen Verlauf genügt sie. Wer
ein erkennbares Motiv zeigen will, braucht drei.

> **`wallpaper` ist Pflicht, sobald eines der anderen gesetzt ist.** Ob die Farbflächen
> durchsichtig werden, hängt am Grundbild. Ein `wallpaperFlyout` allein ließe die Liste
> deckend, das Bild läge unsichtbar darunter. Die App lehnt das ab und protokolliert es.

Bei aktivem Wallpaper entfällt der Money-Heat-Verlauf (wie bei jedem Theme) und die
Karten- und Kopfflächen werden durchsichtig, damit das Bild durchscheint. Die Nase der
Flyout-Sprechblase bekommt die Durchschnittsfarbe der oberen Bildkante — dort lässt sich
kein Bild zeichnen.

> **Falle: Ink bei aktivem Wallpaper.** Bleiben `inkLight`/`inkDark` leer, rechnet die App
> den Schwarz/Weiß-Kontrast gegen die **Surface-Farbe** (`cardLight`/`cardDark`) — nicht
> gegen das Bild. Ein weißes `cardLight` mit dunklem Wallpaper ergibt damit dunkle Schrift
> auf dunklem Grund. **Mit Wallpaper deshalb `inkLight`/`inkDark` immer ausdrücklich
> setzen**, oder `cardLight`/`cardDark` so wählen, dass ihre Helligkeit zum Bild passt.
> Letzteres ist ohnehin sinnvoll: Diese Farben sind der Rückfall, wenn das Bild fehlt.

#### Format des Ringbilds

| | |
|---|---|
| **Akzeptiert** | PNG, PDF, SVG — wie Logo und Wallpaper |
| **Sollmaß** | **72 × 72** (als @2x: 144 × 144), quadratisch |
| **Größe** | bis 512 KB (wie das Logo) |
| **Dateiname** | einfacher Name im Theme-Ordner, dieselben Regeln wie beim Logo |

Das Bild wird seitenverhältnistreu in die 72 × 72 des Kontorings eingepasst — ein nicht
quadratisches Bild wird also nicht verzerrt, sondern bekommt Rand. Ist `ringImage`
gesetzt, erscheint es **immer** auf dieser Fläche, unabhängig vom Schalter „Kontoring
anzeigen"; der wird in den Einstellungen gesperrt. Das Theme gewinnt, weil es die Fläche
gestaltet und der Nutzer sonst einen Schalter ohne Wirkung sähe.

**Vorrang:** `bankLogos` entscheidet, **ob** überhaupt eine Bildmarke erscheint, `logo`
nur **womit**. Bei `bankLogos=off` bleibt es also beim Mosaik-Block, auch wenn ein Logo
hinterlegt ist. Fehlt die Datei oder lässt sie sich nicht laden, erscheint still wieder
die Bankmarke — ein vergessenes Bild hinterlässt keine leere Fläche.

**Noch nicht erfasst:** Die Konto-Pillen der Umsatzliste und das Menüleisten-Symbol
zeigen weiterhin die Bankmarke.

Schriften müssen im System installiert oder im App-Bundle registriert sein
(`ThemeFonts.registerBundledFonts()` lädt `.ttf` aus `Contents/Resources`, Rückfall
`Bundle.module`). **Unbekannte Namen fallen still auf die Systemschrift zurück** — das
Theme bricht nicht, sieht nur unauffälliger aus. Mitgelieferte Schrift ⇒ Lizenz
beachten (VT323: OFL-1.1, Lizenztext muss mit ausgeliefert werden).

### 4.2 Farben

| Schlüssel | Default (Fallback) | Wirkung |
|---|---|---|
| `accent` | `#4E79A7` | **Leitfarbe** aktiver Bedienelemente: aktive Konto-Umschalter, gefüllte Filter-Blöcke, aktive Textkommandos, „Weiter"-Button, Ungelesen-Marker, Aufrunden-Button. |
| `positive` / `positiveLight` / `positiveDark` | `#4F8A6A` | Einnahmen-Beträge, „verfügbar"-Zeile, Sparbeträge, grüner Anteil der Blockleiste — **und der grüne Bereich des Kontorings**. `positive` gilt für beide Appearances, die `…Light/Dark`-Varianten überschreiben je Modus. |
| `negative` / `negativeLight` / `negativeDark` | `#C65A5A` | Ausgaben-Beträge, Datumsköpfe (Theme), Dispo-Warnzeile, **negativer Kontostand**, roter Anteil der Blockleiste — **und Dispo sowie der knappe Bereich des Kontorings**. |
| `cardLight` / `cardDark` | `#FFFFFF` / `#1F1F1F` | **Surface**: vollflächige Kartenfarbe von Flyout-Karte und Listen-Kopf; bei aktivem Theme zugleich Hintergrund der gesamten Liste und des Flyouts (flach, kein Money-Heat). Auch Textfarbe AUF gefüllten Accent-Flächen. **Mit `wallpaper` wird diese Fläche durchsichtig** — die Farbe bleibt dann nur der Rückfall, wenn das Bild fehlt oder abgelehnt wird. |
| `panelLight` / `panelDark` | `#F9F9F9` / `#171717` | Panel-Hintergrund — wird bei aktivem Theme praktisch von Surface überdeckt; relevant v. a. für das Default-Theme. |
| `inkLight` / `inkDark` | *(leer)* | **Ink**: Vordergrund (große Saldo-Zahl, Namen, Fließtext) auf der Surface. Leer ⇒ automatischer Schwarz/Weiß-Kontrast per Luminanz (Schwelle 0,55, WCAG-nah — `AppTheme.contrastingInk`). |
| `screenBorder` | *(leer)* | Farbe der **CRT-Blende** um Flyout + Liste (außen bis zur Fensterkante gefüllt, innen gerundet ausgestanzt; 5–6 pt stark). Leer = keine Blende. |

#### Kontoring (Ampel)

Der Ring im Flyout und in der Liste hat vier Zustände. Er nimmt seine Farben aus der
Palette, sobald ein Theme aktiv ist:

| Zustand | Farbe |
|---|---|
| Dispo (Kontostand negativ) | `negative…` |
| knapp (unter 34 % des Bezugseinkommens) | `negative…` |
| mittel (34–67 %) | **Mischung** aus `negative…` und `positive…` zu gleichen Teilen |
| gut (ab 67 %) | `positive…` |

Für das Mittelband gibt es **keinen eigenen Schlüssel** und soll keiner dazukommen: Eine
Farbe, die zwischen zwei vorhandenen liegt, lässt sich ausrechnen. Bei einer rot/grünen
Palette wird daraus Olivgelb, bei einer blau/violetten entsprechend anderes.

**Folge für den Builder:** Wer `positive`/`negative` weit von Rot/Grün wegzieht, verändert
damit auch den Ring. Das ist gewollt — eine Ampel in Fremdfarben ist stimmiger als eine,
die aus dem Theme herausfällt. Die Preview sollte den Ring deshalb zeigen, sonst überrascht
es später.

Abgeleitete Töne (nicht konfigurierbar): gedämpfte Ink-Stufen `0.45` (Platzhalter),
`0.6–0.75` (Sekundärtext, inaktive Kommandos), `0.85–0.9` (Labels); Feld-Füllung
Weiß 65 % mit 2-pt-Ink-Rahmen; Money-Heat bleibt exklusiv dem Default-Theme.

### 4.2a Darstellungs-Modi

Zwei Schlüssel mit mehr als An/Aus. Unbekannte Werte fallen still auf den Standard
zurück — dieselbe Haltung wie bei `parseBool` und den Icon-Namen.

| Schlüssel | Werte | Standard | Wirkung |
|---|---|---|---|
| `categoryIconStyle` | `auto` · `ink` · `color` | `auto` | Einfärbung der Kategorie-Symbole in den Umsatzzeilen. `auto`: ohne Theme Systemgrau wie bisher, **mit Theme die Ink-Farbe**. `ink` erzwingt die Ink-Farbe, `color` nimmt die Farbe der Kategorie (dieselbe wie Mosaik-Blöcke und Ringe). |
| `bankLogoStyle` | `color` · `mono` | `color` | Bank-Icons im **Konto-Umschalter**: die Pillen in Flyout und Listenkopf, mit denen man zwischen den Konten wechselt. `mono` zeichnet sie einfarbig in der Ink-Farbe und passt sich damit Hell/Dunkel von selbst an. **Nicht betroffen:** die große Bildmarke über dem Kontostand — die setzt ein Theme mit `logo`, und die bleibt farbig. |

**Warum `auto` und nicht einfach immer Ink:** Die Symbole standen auf Systemgrau. Auf
einer hellen Fläche ist das richtig, auf einer dunklen Theme-Fläche oder einem dunklen
Wallpaper verschwinden sie. `auto` löst genau das, ohne dass ein Theme etwas setzen muss.

**Zwei Bildmarken, die man auseinanderhalten muss** — sie sehen ähnlich aus, gehorchen
aber verschiedenen Schlüsseln:

| Wo | Größe | Woher | `bankLogoStyle`? |
|---|---|---|---|
| Über dem Kontostand | 18–20 pt | `logo` des Themes, sonst die Marke der aktiven Bank | **nein** — bleibt farbig |
| Konto-Umschalter (Pillen) | 15–16 pt | immer die Marke des jeweiligen Kontos | **ja** |

Das ist die Trennung, die der Schlüssel meint: Die Pillen zeigen **mehrere** Konten
nebeneinander und gewinnen durch eine einheitliche Anmutung. Die Marke über dem
Kontostand ist dagegen die eine Stelle, an der ein Theme bewusst ein eigenes, farbiges
Bild setzen darf — dort wäre es widersinnig, es anschließend zu entfärben.

**Reihenfolge über dem Kontostand** — wichtig, weil sich die Schlüssel dort gegenseitig
verdecken:

1. `bankLogos=off` → Mosaik-Block, alles Weitere entfällt.
2. `logo` gesetzt → das globale Theme-Logo, für **alle** Konten gleich; die Bankmarke
   erscheint dann nirgends mehr.
3. sonst → die Marke der Bank aus dem YAXI-Katalog.

**Warum `color` der Standard bleibt:** YAXI liefert nur für 43 der 192 Banken eine echte
einfarbige Maske. Für die übrigen wird das Farblogo über seinen Alphakanal geplättet —
bei detailreichen Marken wird daraus ein Fleck. `mono` passt zu Themes mit strenger
Farbwelt; wer bunte Marken erwartet, lässt es bei `color`. Im Konto-Umschalter fällt das
milder aus als anderswo, weil die Pillen mit 15 bis 16 Punkt ohnehin klein sind und die
Marke dort eher als Wiedererkennungszeichen dient denn als Bild.

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
| `glyphControls` | `on` | `off`: Bedien-**Icons werden Text** — „FILTER", „KAT.", „SPAREN", „SENDEN", „AUSWERTUNG", „INBOX (n)", „X" zum Leeren, `>`-Pfeile; der Konto-Umschalter wird zu unterstrichenen Textkommandos statt Pillen; Segmented-Controls werden Text-Paare. **Nur die Bedienelemente** — Schriftgrade und Metriken bleiben unberührt. |
| `lofiTypography` | `off` | `on`: die **Rasterschrift-Gestaltung** — größere Schriftgrade in den Umsatzzeilen, „double height"-Kontostand, Eingabefelder als helle Blöcke mit hartem Rahmen, Konto- und Kategorien-**Ringe werden Mosaik-Blockleisten**, Flächentausch im Sparmodus, bündige Zeilen ohne Gutter, blinkendes ☎ im Kopf. |

**Die beiden gehörten bis 2.0.2 zusammen.** `glyphControls=off` schaltete auch die
Typografie um — eine Abkürzung aus der BTX-Arbeit, als es genau ein Theme gab, das beides
wollte. Für jedes andere war es eine Falle: Wer nur Textkommandos statt Icons wollte,
bekam ungefragt andere Schriftgrade dazu und konnte sie nicht abwählen. Jetzt zwei
Schlüssel.

**Was das für bestehende Themes heißt:** Ein Theme mit `glyphControls=off`, das die
Lo-Fi-Typografie behalten will, muss `lofiTypography=on` ergänzen — sonst behält es seine
Textkommandos, bekommt aber die normalen Schriftgrade. Das mitgelieferte BTX setzt beides
und sieht unverändert aus.

**Faustregel für Retro-Themes:** `uppercase`, `dottedLeaders`, `squareControls`,
`lofiTypography` an, `glyphControls`, Logos, Icons, `ripple` aus — dann trägt Text die
Bedienung, wie es Terminals und BTX taten.

### 4.4 Bedien-Icons einzeln austauschen

Jede Funktion in Fußzeile, Steuerzeile und Titelleiste hat einen Namen und lässt sich
einzeln auf ein anderes SF-Symbol legen:

```
icon.filter        = slider.horizontal.3
icon.filter.active = slider.horizontal.3
```

| Name | Ruhezustand | Aktiv | Textkürzel bei `glyphControls=off` |
|---|---|---|---|
| `filter` | `line.3.horizontal.decrease` | `line.3.horizontal.decrease.circle.fill` | Filter |
| `categories` | `tag` | `tag.fill` | Kat. |
| `savings` | `centsign.circle` | `centsign.circle.fill` | Sparen |
| `send` | `paperplane` | — | Senden |
| `dashboard` | `square.grid.2x2` | — | Auswertung |
| `inbox` | `bell` | `bell.fill` | Inbox |
| `refresh` | `arrow.clockwise` | — | Neu |
| `pin` | `pin` | `pin.fill` | Pin |
| `settings` | `gearshape` | — | Optionen |
| `clear` | `xmark.circle.fill` | — | X |

- `icon.<name>` setzt den Ruhezustand, `icon.<name>.active` die hervorgehobene Variante.
  Beide sind unabhängig — es wird **kein** `.fill` angehängt, weil die Paare im Bestand
  nicht durchgängig so gebaut sind (der Filter bekommt im aktiven Zustand zusätzlich
  einen Kreis).
- Funktionen ohne eigenen Aktiv-Zustand ignorieren `…​.active`.
- **Ein unbekanntes Symbol fällt auf den Standard zurück**, statt eine leere Fläche zu
  hinterlassen. Ein Tippfehler macht also keine Bedienung unsichtbar.
- Bei `glyphControls=off` gelten weiter die Textkürzel; `icon.*` bleibt dann wirkungslos.

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
| Fläche des Flyouts | `wallpaperFlyout…` → sonst `wallpaper…` → sonst `cardLight` / `cardDark` |
| Fläche der schmalen Liste | `wallpaper…` → sonst `cardLight` / `cardDark` |
| Fläche der breiten Liste | `wallpaperWide…` → sonst `wallpaper…` → sonst `cardLight` / `cardDark` |
| Kontoring (Ampel) | `negative*` für Dispo und knapp, `positive*` für den grünen Bereich, das Mittelband ist die Mischung aus beiden — oder `ringImage` statt des Rings |
| Kategorie-Symbol der Zeile | `categoryIconStyle` (§4.2a) |
| Bank-Icons im Konto-Umschalter | `bankLogoStyle` (§4.2a) — die Marke über dem Kontostand bleibt farbig |
| Suchfeld | Ink 10 % Füllung, Ink 30 % Rahmen — bei `squareControls` ohne Rundung |
| Kapsel „Vorgemerkt" | Ink 16 % Füllung, Ink 85 % Text. Abschaltbar in den Einstellungen (Nutzersache, kein Theme-Schlüssel) |
| Bildmarke über dem Kontostand | `logo` / `logoDark` — sonst die Bankmarke, bei `bankLogos=off` ein Mosaik-Block |
| Icons in Fuß-, Steuer- und Titelzeile | `icon.<name>` / `icon.<name>.active` (§4.4) |
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
lofiTypography=on
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

**Arbeitsteilung.** Schrift, Logo und Wallpaper sind Teil der Gestaltung, die ein Theme
mitbringt — die App bietet dafür **keine Einstellung** und soll auch keine bekommen. Der
Nutzer wählt ein Theme, die Bilder kommen mit. Wer eigene will, baut ein Theme. Der
Builder ist damit der einzige Ort, an dem diese Dinge gesetzt werden; was er nicht
anbietet, existiert für den Nutzer praktisch nicht.

**Die Gegenprobe** gehört dazu, damit die Grenze nicht ausfranst: „Vorgemerkt als Pille
anzeigen" ist **keine** Theme-Sache und steht in den Einstellungen. Der Unterschied ist
nicht die Optik, sondern die Frage: Bestimmt es, **wie** etwas aussieht (Theme), oder
**ob** eine Information überhaupt erscheint (Nutzer)? Nach derselben Regel ist der
Kontoring eine Nutzereinstellung — bis ein Theme mit `ringImage` die Fläche beansprucht
und den Schalter sperrt.

### Muss

1. **Formular für alle Schlüssel aus Abschnitt 4** — Farb-Picker paarweise
   (Light/Dark, mit „identisch"-Kopplung für appearance-unabhängige Themes),
   Font-Auswahl aus den installierten Schriften (Familienname), Schalter als Toggles
   mit den Erklärtexten aus 4.3. Dazu:
   - **Logo-Ablage** (4.1): Bild per Auswahl oder Drag & Drop, Prüfung auf Format,
     Quadratmaß und die 512-KB-Grenze, Kopieren in den Theme-Ordner, optional eine
     zweite Datei für den Dunkelmodus. Die Schriftwahl gehört **hier** hin und nicht
     in die App — sie ist Teil der Gestaltung, die ein Theme mitbringt.
   - **Wallpaper-Ablage** (4.1): **drei Felder** — Flyout, schmale Liste (Grundbild),
     breite Liste —, je optional mit zweiter Datei für den Dunkelmodus. Prüfung auf
     Format und die 4-MB-Grenze, Kopieren in den Theme-Ordner. Je Feld das Sollmaß
     anzeigen (348 × 140, 348 × 620, 840 × 620) und einen Hinweis, wenn das gewählte
     Bild stark davon abweicht — erzwingen aber nicht. Die Vorschau muss **oben
     verankert** zuschneiden, nicht zentriert, sonst zeigt der Builder etwas anderes als
     die App. Ist eines der Sonderfelder gefüllt und das Grundbild leer: **Fehler**, denn
     dann bleibt überall die Farbe.
   - **Ringbild-Ablage** (4.1): ein Feld plus optionale Dunkel-Variante, Sollmaß
     72 × 72, 512-KB-Grenze. Der Builder muss dazu sichtbar machen, was der Schlüssel
     auslöst: **Er sperrt eine Einstellung in der App.** Wer das Feld füllt, nimmt dem
     Nutzer den Kontoring — das gehört an die Oberfläche, nicht in die Dokumentation.
   - **`glyphControls` und `lofiTypography` als zwei getrennte Schalter** (4.3), nicht
     als einen. Sie waren bis 2.0.2 gekoppelt, und ein Builder, der sie wieder
     zusammenfasst, baut die Falle nach. Wer das Retro-Preset anbietet, setzt beide —
     aber sichtbar, damit man einen davon wieder ausschalten kann.
   - **Zwei Auswahlfelder für die Darstellungs-Modi** (4.2a): `categoryIconStyle` mit
     `auto`/`ink`/`color` und `bankLogoStyle` mit `color`/`mono`. Beim Mono-Modus zwei
     Hinweise zeigen: dass er nur die Pillen des Konto-Umschalters betrifft und nicht die
     Marke über dem Kontostand, und dass nur rund ein Viertel der Banken eine echte Maske
     hat — sonst wundert sich der Theme-Bauer über Flecken statt Logos, oder sucht die
     Wirkung an der falschen Stelle.
   - **Icon-Tabelle** (4.4): je Zeile Funktion, Ruhe- und Aktiv-Symbol, mit
     SF-Symbol-Suche und Vorschau. Ein unbekannter Name muss im Builder auffallen —
     die App fällt still auf den Standard zurück, was beim Bauen niemand merkt.
2. **Live-Preview** nach der Wirkungs-Landkarte (Abschnitt 5): Flyout-Karte +
   Listen-Ausschnitt mit Beispieldaten, umschaltbar Hell/Dunkel. Die Preview muss die
   Schalter-Effekte zeigen (Mosaik statt Logo, Textkommandos, Punktlinien, Blende,
   Blockleiste, eckige Felder). Dazu drei Dinge, die man sonst erst in der App merkt:
   - **Alle drei Flächen** (Flyout 348 × 140, Liste 348 × 620, Liste 840 × 620), und zwar
     mit dem Bild, das dort tatsächlich greift — einschließlich des Rückfalls aufs
     Grundbild, wenn ein Sonderfeld leer ist. Wer nur eine Fläche zeigt, baut Themes, die
     in den anderen nicht aufgehen; das ist der Fehler, der die drei Schlüssel überhaupt
     nötig gemacht hat. Die Flyout-Höhe zusätzlich mit offenem Schnellüberweisungs-Drawer,
     weil sie dort wächst.
   - **Den Kontoring** in allen vier Zuständen (§4.2) — oder das Ringbild, wenn eines
     gesetzt ist. Sonst überrascht die Ampel in Fremdfarben später.
   - **Kategorie-Symbole und Bankmarke** in den gewählten Modi (§4.2a). Beim Mono-Modus
     mit einer Marke ohne Maske, damit die Silhouette zu sehen ist, bevor sie im Betrieb
     auffällt.
   - **Die Umsatzzeilen mit der Theme-Schrift** — sie sind der größte Textanteil und
     zugleich der, den man beim Bauen am ehesten übersieht.
3. **Validierung:**
   - Hex-Format (`#RRGGBB`/`#AARRGGBB`), sonst Feld-Fehler;
   - `id`: kebab-case, nicht in {`default`, `sunrise`, `gameboy`, `btx`, `ocean`,
     `norton-commander`} (Built-ins werden überschrieben, Retired gelöscht);
   - Kontrast-Warnung, wenn Ink (bzw. Auto-Ink) gegen Surface unter ~4,5:1 fällt
     (WCAG AA) — Warnung, kein Blocker;
   - Hinweis, wenn eine gewählte Schrift nicht installiert ist (App fiele still auf
     System zurück).
   - **Bei gesetztem Wallpaper und leerem Ink: Warnung.** Der Auto-Kontrast rechnet gegen
     die Surface-Farbe, nicht gegen das Bild (§4.1) — das ist die wahrscheinlichste
     Ursache für unlesbare Schrift und im Builder billig zu verhindern.
   - Dateinamen für `logo`/`wallpaper`: **einfacher Name**, keine Verzeichnisse, kein
     `..`, keine absoluten Pfade. Die App lehnt solche Namen ab und protokolliert es;
     der Builder darf sie gar nicht erst erzeugen (§4.1).
4. **Export/Install:** `.cfg` nach
   `~/Library/Application Support/com.maik.simplebanking/themes/<id>.cfg` schreiben;
   Bool-Werte als `on`/`off`, Kommentar-Kopf mit Name/Datum. Hinweistext: Aktivierung
   in der App über Einstellungen → Theme (oder App-Neustart).
5. **Import/Round-trip:** bestehende `.cfg` öffnen (Parser-Regeln aus Abschnitt 3:
   lowercase-Keys, Kommentare, Bool-Grammatik, unbekannte Keys **erhalten** und beim
   Export unverändert zurückschreiben).

### Soll

- **Sonderbilder aus dem Grundbild ableiten.** Aus einem Bild die beiden anderen
  Seitenverhältnisse erzeugen: Ausschnitt wählen, auf 348 × 140 bzw. 840 × 620 setzen,
  Randfarbe aus dem Original übernehmen. Das ist der häufigste Fall — jemand hat *ein*
  Bild und braucht drei. Von Hand ist es fummelig, im Builder sind es zwei Schieberegler.
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
- Tests, die den Vertrag absichern: `BTXThemeTests.swift` (Bool-Grammatik, Defaults,
  btx.cfg, Mosaik-Muster, Schrift-Registrierung), `ThemeWashTests.swift` (Surface/Ink-
  Ableitung), `ThemeContractV2Tests.swift` (Logo, Icons, Zeilenhöhen-Zusage aus §1),
  `ThemeTypografieTests.swift` (Schrift in den Zeilentexten, Ink, Ringfarben, Wallpaper
  samt Flächen, Darstellungs-Modi und Ringbild) und
  `PruefungsbefundeTests.swift` (Pfad- und Maßprüfung der Bilddateien).
