# Kategorie-Pill in der Umsatzzeile (Variante A)

Umsetzungsplan für Claude Code. Ziel: Die Kategorie einer Buchung erscheint als kleine, farbig getönte Kapsel direkt neben dem Händlernamen. Alles andere an der Zeile bleibt, wie es ist.

Referenz-Mockup: Design-Canvas „simplebanking Kategorien“, Artboard **A · Pill neben dem Händler**.

## Ausgangslage im Code

Die Grundlage existiert schon, sie sieht nur anders aus:

- `TransactionsPanelView.swift`, `TransactionRowNew` (ca. Zeile 3428): Bei `showCategories == true` steht unter dem Namen eine graue Kapsel mit `category.rawValue` (ca. Zeile 3595).
- Schalter: `@AppStorage("showTransactionCategories")` in `TransactionsPanelView` (Zeile 28), Toggle über das Tag-Icon in der Symbolleiste (ca. Zeile 1705). Im Sparmodus wird `false` übergeben (ca. Zeile 2250).
- `TransactionCategory` (`TransactionCategorizer.swift`): 14 eingebaute Kategorien plus eigene (`Eigenkategorien.swift`), mit `displayName` und `icon`.
- Vorbild für Kapsel-Styling inkl. Theme/BTX-Fallunterscheidung: die „Vorgemerkt“-Kapsel in derselben Zeile (ca. Zeile 3670).

Bekannter Fehler nebenbei: Die heutige Kapsel zeigt `rawValue`. Dadurch steht dort „Mobilitaet“ statt „Mobilität“, und Umbenennungen aus den Einstellungen werden ignoriert. Richtig ist `displayName`.

## Was sich ändert

1. **Position**
   - Breites Fenster (`isWide == true`): Kapsel in derselben Zeile, zwischen Name und Verwendungszweck. Der Name bleibt einzeilig, der Verwendungszweck rückt nach rechts und kürzt wie bisher mit `lineLimit(1)`.
   - Schmales Flyout (`isWide == false`): Kapsel bleibt unter dem Namen (heutige Position), bekommt aber den neuen Look. Inline wäre dort zu eng.
2. **Look**: farbig getönte Kapsel statt grau (Werte unten).
3. **Text**: `category.displayName` statt `rawValue`.
4. **Schalter**: bleibt `showTransactionCategories` mit dem Tag-Icon. Default unverändert (`false`); ob der Default auf `true` wechselt, ist eine eigene Entscheidung.

Nicht ändern: Zeilenhöhe im Normalfall, Icon/Logo-Slot, Betragsspalte, Unread-Punkt, Auswahlhintergrund, Rückholfrist-Zeile, Kopfbereich, MoneyMood-Farben.

## Farben

Leitregel: **Kein Grün, kein Orange, kein Rot.** Diese drei gehören MoneyMood (Saldo-Stimmung) und den Beträgen (Ausgabe rot, Eingang grün). Die Kategorien nutzen gedämpfte, kühle bzw. erdige Töne mit ähnlicher Sättigung, damit keine einzelne Kapsel heraussticht.

`BTXMosaic.style(for:).hex` ist dafür **nicht** geeignet (enthält Rot und Grün, ist für BTX gedacht). Stattdessen eine eigene Palette anlegen.

### Neue Datei `Sources/simplebanking/Kategoriefarbe.swift`

Pure Funktionen, kein State, damit testbar:

```swift
import SwiftUI

/// Farben der Kategorie-Kapsel in der Umsatzzeile.
///
/// Bewusst ohne Grün, Orange und Rot: Die drei gehören MoneyMood und den Beträgen.
/// Eine Kapsel in Saldo-Farbe läse sich als Warnung.
enum Kategoriefarbe {

    struct Ton: Equatable {
        let hell: String   // Grundfarbe (hex)
        let text: String   // Textfarbe Light Mode (dunkler, ≥ 4.5:1 auf getöntem Grund)
        let textDunkel: String // Textfarbe Dark Mode (heller)
    }

    static let petrol  = Ton(hell: "#2B8A99", text: "#1D6873", textDunkel: "#7CC6D1")
    static let indigo  = Ton(hell: "#5865B8", text: "#434E99", textDunkel: "#A3ACE6")
    static let beere   = Ton(hell: "#A9558A", text: "#8A3B6C", textDunkel: "#DDA0C6")
    static let sand    = Ton(hell: "#8C7550", text: "#6A5634", textDunkel: "#D2BC94")
    static let violett = Ton(hell: "#7E62B5", text: "#634A96", textDunkel: "#C2AEE6")
    static let ozean   = Ton(hell: "#3C7BB0", text: "#2C5F8A", textDunkel: "#93BFE3")
    static let pflaume = Ton(hell: "#8A5A7A", text: "#6E4461", textDunkel: "#CFA6C2")
    static let schiefer = Ton(hell: "#5E6E7E", text: "#495663", textDunkel: "#B4C0CC")
    static let neutral = Ton(hell: "#7A807C", text: "#5F6561", textDunkel: "#B8BDB9")

    /// Rotation für eigene Kategorien (ohne `neutral`).
    static let rotation: [Ton] = [petrol, indigo, beere, sand, violett, ozean, pflaume, schiefer]

    static func ton(fuer kategorie: TransactionCategory) -> Ton {
        switch kategorie {
        case .essenAlltag:    return petrol
        case .gastronomie:    return sand
        case .wohnenKredit:   return indigo
        case .abosDigital:    return ozean
        case .versicherungen: return schiefer
        case .freizeit:       return beere
        case .shopping:       return violett
        case .gesundheit:     return pflaume
        case .mobilitaet:     return sand   // siehe Hinweis unten
        case .sparen:         return schiefer
        case .einkommen, .gehalt, .umbuchung, .sonstiges:
            return neutral
        default:
            return rotation[stabilerIndex(kategorie.rawValue, anzahl: rotation.count)]
        }
    }

    /// Deterministisch über Programmstarts hinweg. NICHT `hashValue` nehmen:
    /// Swift salzt den Hash pro Prozess, die Farbe einer eigenen Kategorie
    /// würde bei jedem Start wechseln.
    static func stabilerIndex(_ text: String, anzahl: Int) -> Int {
        var h: UInt32 = 2166136261                 // FNV-1a
        for b in text.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % UInt32(anzahl))
    }
}
```

Hinweis zur Zuordnung: Gastronomie und Mobilität teilen sich in diesem Entwurf `sand`. Vor dem Umsetzen eine der beiden auf einen eigenen Ton legen (z. B. Mobilität → `ozean`, Abos & Digital → `schiefer`) und die Zuordnung so wählen, dass Kategorien, die häufig nebeneinander stehen, sich auch in der Helligkeit unterscheiden. Die Tabelle ist ein Vorschlag, die Regel „kein Grün/Orange/Rot“ ist fest.

Hex-zu-`Color`: vorhandenes `AppTheme.color(from:fallback:)` nutzen.

### Kapsel-Werte

| Eigenschaft | Light | Dark |
|---|---|---|
| Hintergrund | `hell` mit Opazität 0.14 | `hell` mit Opazität 0.24 |
| Text | `text` | `textDunkel` |
| Schrift | `ThemeFonts.rowBody(size: 10, weight: .semibold, lofiSize: 12)` | gleich |
| Padding | horizontal 7, vertikal 2 | gleich |
| Form | `Capsule()` | gleich |
| Abstand zum Namen | 8 pt (inline) | gleich |

Hell/Dunkel über `@Environment(\.colorScheme)` in der Zeile.

## Themes

Gleiche Fallunterscheidung wie bei der „Vorgemerkt“-Kapsel:

- **Default-Theme**: Farben wie oben.
- **Farb-Themes** (`themed && !lofi`): Kategorie-Ton beibehalten, aber Hintergrund mit Opazität 0.12 auf der Theme-Fläche. Falls es auf einzelnen Themes kollidiert, Fallback auf `Color.themedInk.opacity(0.16)` als Grund und `themedInk` als Text.
- **BTX / Lo-Fi** (`lofi == true`): keine Kapsel, nur Text in `themedInk.opacity(0.85)`, `textCase(ThemeChrome.textCase)`. BTX hat seine eigenen Kategoriefarben im Mosaik-Icon.

## Implementierungsschritte

1. `Kategoriefarbe.swift` wie oben anlegen (Zuordnung vorher entzerren).
2. In `TransactionRowNew` eine private View-Funktion `kategoriePille()` bauen, die alle drei Theme-Fälle abdeckt und `category.displayName` nutzt. Accessibility: `.accessibilityLabel(Text(L10n.t("Kategorie \(category.displayName)", "Category \(category.displayName)")))`.
3. Die bestehende Kapsel unter dem Namen durch `kategoriePille()` ersetzen, aber nur wenn `!isWide`.
4. Im `isWide`-Zweig: Kapsel zwischen Name-Stack und Verwendungszweck einfügen (`.fixedSize()` an der Kapsel, damit sie nie gekürzt wird; gekürzt wird der Verwendungszweck). `padding(.leading, 8)` des Verwendungszwecks beibehalten.
5. Kapsel auch bei ausgewählter Zeile zeigen; der Auswahlgrund (`accentColor.opacity(0.12)`) verträgt die Tönung.
6. Keine Kapsel bei `showCategories == false` und im Sparmodus (wird schon über den Parameter gesteuert).
7. Eigene Kategorien mit bis zu 24 Zeichen (`Eigenkategorien.maximaleLaenge`) testen: Kapsel darf nicht umbrechen (`lineLimit(1)`), im schmalen Flyout notfalls mit `truncationMode(.tail)`.

## Tests

Neue Testklasse `KategoriefarbeTests` (XCTest, keine Mocks, pure Funktionen):

- Jede eingebaute Kategorie liefert einen Ton.
- Kein Ton der Palette liegt im Grün-, Orange- oder Rotbereich (Farbton aus dem Hex berechnen; Grenzen z. B. Rot < 20° oder > 340°, Orange 20–50°, Grün 80–160°).
- `stabilerIndex` ist deterministisch (fester Erwartungswert für einen festen String) und liegt im Bereich.
- Einkommen, Gehalt, Umbuchungen, Sonstiges → `neutral`.
- Text-Kontrast: `text` auf (`hell` 14 % über `#E6EFE8`, also MoneyMood Grün) erreicht mindestens 4.5:1. Dasselbe für die orange und rote Mood-Fläche (`#F3EADC`, `#F3E3E1`).

Danach `swift test` komplett grün (Hard Gate laut CLAUDE.md).

## Manuell prüfen

- Demo-Modus: `defaults write de.klotzbrocken.simplebanking demoMode -bool YES`
- Breites Fenster und schmales Flyout, jeweils mit Kategorien an/aus.
- Saldo-Stimmung Grün, Orange, Rot: Kapseln dürfen in keiner Stimmung wie eine Warnung wirken.
- Light und Dark Mode, ein Farb-Theme, BTX.
- Umbenannte eingebaute Kategorie und eine eigene Kategorie mit langem Namen.
- Ausgewählte Zeile mit Rückholfrist darunter.

## Abschluss

- `CHANGELOG.md` unter `## [Unreleased]` → „Neu“ oder „Verbessert“: Kategorie als farbige Kapsel neben dem Händler; Anzeige nutzt jetzt den (ggf. umbenannten) Anzeigenamen.
- Commit: `feat(transactions): Kategorie als farbige Pill in der Umsatzzeile`
