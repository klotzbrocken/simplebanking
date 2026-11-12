import Foundation

/// Das Zeichen, das in der Menüleiste rechts außen anzeigt, dass sich auf einem
/// Konto etwas getan hat.
///
/// Es ist ausdrücklich **kein Bericht**: kein Betrag, kein Name, keine Anzahl.
/// Es sagt nur, dass etwas passiert ist und in welche Richtung — was genau,
/// schaut der Nutzer selbst nach. Deshalb steht auch bei mehreren ungesehenen
/// Bewegungen immer nur genau ein Zeichen in der Leiste.
enum Kontobewegungszeichen: String, Equatable {
    /// Geldeingang auf dem aktiven Konto.
    case eingang
    /// Abgang vom aktiven Konto.
    case abgang
    /// Bewegung ausschließlich auf einem anderen, gerade nicht aktiven Konto.
    case fremdesKonto

    /// Textzeichen statt SF-Symbol mit Anhang: Ein Glyph im Titel erbt die
    /// Farbe der Menüleiste automatisch und ist damit in Hell wie Dunkel
    /// sichtbar. Ein `NSTextAttachment` mit Template-Bild wird nicht getönt und
    /// wäre auf dunkler Leiste schwarz auf schwarz.
    var glyph: String {
        switch self {
        case .eingang: return "▲"
        case .abgang: return "▼"
        case .fremdesKonto: return "●"
        }
    }

    var hinweis: String {
        switch self {
        case .eingang:
            return L10n.t("Geldeingang seit dem letzten Blick", "Money in since you last looked")
        case .abgang:
            return L10n.t("Abgang seit dem letzten Blick", "Money out since you last looked")
        case .fremdesKonto:
            return L10n.t("Bewegung auf einem anderen Konto", "Activity on another account")
        }
    }
}

/// Was gerade rechts außen in der Menüleiste steht — genau eins oder nichts.
///
/// Zwei Dinge wollen diesen einen Platz: die Kontobewegung und der Hinweis auf
/// eine neue Fassung. Beide nebeneinander wären zwei Zeichen hinter einer Zahl
/// und damit unlesbar, also entscheidet `Leistenzeichenwahl`.
struct Leistenzeichen: Equatable {
    let glyph: String
    /// `true` → Systemakzentfarbe („hier ist etwas zu tun"). `false` → ohne eigene
    /// Farbe, das Zeichen erbt damit die der Menüleiste und bleibt in Hell wie
    /// Dunkel sichtbar.
    let akzent: Bool
    let hinweis: String
}

enum Leistenzeichenwahl {
    /// Glyph des Update-Hinweises. Kein SF-Symbol: siehe die Begründung oben bei
    /// `Kontobewegungszeichen.glyph`.
    static let updateGlyph = "⟳"

    /// **Geld geht vor Software.** Das Bewegungszeichen löscht sich selbst, sobald
    /// der Nutzer hinsieht — es ist am nächsten Tag wieder da. Der Update-Hinweis
    /// bleibt dagegen stehen, bis aktualisiert wurde, und verdeckte damit über Tage
    /// das Signal, für das es die App überhaupt gibt. Also hat die Bewegung Vorrang;
    /// das Update wartet, bis sie weg ist, und steht ohnehin im Flyout.
    static func zeichen(bewegung: Kontobewegungszeichen?, updateVersion: String?) -> Leistenzeichen? {
        if let bewegung {
            return Leistenzeichen(glyph: bewegung.glyph, akzent: false, hinweis: bewegung.hinweis)
        }
        guard let updateVersion, !updateVersion.isEmpty else { return nil }
        return Leistenzeichen(
            glyph: updateGlyph,
            akzent: true,
            hinweis: L10n.t("Version \(updateVersion) ist verfügbar",
                            "Version \(updateVersion) is available"))
    }
}

/// Zuletzt beobachteter Stand eines Kontos aus dem Hintergrund-Abruf.
struct Bewegungsstand: Equatable {
    /// Signatur der neuesten Buchung; leer heißt „noch nichts gesehen".
    var signatur: String
    /// Richtung ebendieser Buchung.
    var istEingang: Bool
    /// Buchungsdatum ebendieser Buchung als sortierbarer ISO-String. Wird nur
    /// gebraucht, um im Unified-Mode über Kontogrenzen hinweg die jüngste
    /// Bewegung zu bestimmen; leer ist zulässig und sortiert nach hinten.
    var zeitpunkt: String = ""
}

enum Saldobewegung {
    /// Entscheidet, ob ein frisch geholter Saldo gegenüber dem zuletzt bekannten
    /// eine Kontobewegung darstellt.
    ///
    /// - Returns: `true` für Eingang, `false` für Abgang, `nil` für „keine
    ///   Bewegung" — das gilt auch für den allerersten bekannten Saldo, denn ohne
    ///   Vorwert gibt es nichts zu vergleichen.
    static func richtung(vorher: Double?, jetzt: Double) -> Bool? {
        guard let vorher else { return nil }
        // Ein halber Cent Toleranz: Salden kommen als Fließkommazahl an, und
        // 1234.56 - 1234.56 ist nicht zwingend exakt 0.
        guard abs(jetzt - vorher) >= 0.005 else { return nil }
        return jetzt > vorher
    }
}

enum Bewegungszeichenrechner {
    /// Entscheidet, welches einzelne Zeichen die Menüleiste zeigt.
    ///
    /// Regel: Das aktive Konto hat Vorrang. Liegt dort etwas Ungesehenes, zeigt
    /// der Pfeil dessen Richtung — bei mehreren Bewegungen die der jüngsten, denn
    /// `stand` trägt immer nur die neueste Buchung je Konto. Erst wenn das aktive
    /// Konto ruhig ist, meldet der Kreis Bewegung auf einem anderen Konto.
    ///
    /// Im Unified-Mode (`alleAktiv`) gibt es kein „anderes, nicht aktives Konto" —
    /// dort sind alle Konten gleichzeitig zu sehen. Ein Kreis wäre gelogen, also
    /// gewinnt schlicht die jüngste ungesehene Bewegung über alle Konten hinweg.
    ///
    /// - Parameter gesehen: Liefert die zuletzt als gesehen markierte Signatur
    ///   eines Kontos (leer, wenn noch nie hingeschaut wurde).
    static func zeichen(stand: [String: Bewegungsstand],
                        aktiverSlot: String?,
                        alleAktiv: Bool = false,
                        gesehen: (String) -> String) -> Kontobewegungszeichen? {
        func istUngesehen(_ slotId: String, _ s: Bewegungsstand) -> Bool {
            !s.signatur.isEmpty && s.signatur != gesehen(slotId)
        }
        let ungesehen = stand.filter(istUngesehen)

        if alleAktiv {
            // Nach Zeitpunkt absteigend, bei Gleichstand nach Slot-ID — sonst
            // entschiede die zufällige Reihenfolge des Dictionary und das Zeichen
            // flackerte zwischen zwei Abrufen ohne neue Buchung.
            let juengste = ungesehen.max { a, b in
                if a.value.zeitpunkt != b.value.zeitpunkt {
                    return a.value.zeitpunkt < b.value.zeitpunkt
                }
                return a.key > b.key   // bei Gleichstand gewinnt die kleinere Slot-ID
            }
            guard let s = juengste?.value else { return nil }
            return s.istEingang ? .eingang : .abgang
        }

        if let aktiv = aktiverSlot, let s = ungesehen[aktiv] {
            return s.istEingang ? .eingang : .abgang
        }
        return ungesehen.isEmpty ? nil : .fremdesKonto
    }
}
