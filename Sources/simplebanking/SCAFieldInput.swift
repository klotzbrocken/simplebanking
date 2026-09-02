import Foundation
import RoutexClient

// MARK: - SCAFieldInput
//
// Pure-Layer für den SCA-`.field`-Input-Flow: was die Bank verlangt
// (`Spec`) plus Validierung. UI lebt in `SCAFieldInputSheet.swift`,
// der Service-Hook in `YaxiService.handleSCA` (`case .field`).
//
// Hintergrund: das Routex-SDK liefert `DialogInput.field(type, secrecyLevel,
// minLength, maxLength, context)` für TAN/PIN-Eingaben (smsTAN, iTAN-Reste,
// photoTAN-Codes). Vor dieser Implementierung haben wir den Branch mit
// `return nil` abgebrochen — User mit TAN-only-Konten konnten die App
// nicht produktiv nutzen.

enum SCAFieldInput {

    /// Die optische Aufgabe der Bank: chipTAN-QR, Flicker-Grafik oder photoTAN.
    ///
    /// Ohne sie ist ein chipTAN-Dialog wertlos — der Generator erzeugt die TAN aus
    /// dem Bild, nicht aus dem Text. Das SDK liefert sie als `Dialog.image` mit;
    /// bis 02.09.2026 warf `SCACommon` sie beim Übersetzen weg, weshalb das
    /// Eingabefenster nur den Begleittext zeigte.
    struct Aufgabenbild: Sendable, Equatable {
        let mimeType: String
        let daten: Data
        /// Roher HHD\_UC-Datenstrom für die optische Kopplung. Ist er gesetzt,
        /// handelt es sich um eine Flicker-Grafik, und `daten` ist das dazu passende,
        /// bereits gerenderte animierte GIF.
        let hhdUC: Data?

        /// Flicker-Grafiken haben eine vorgeschriebene physische Breite, QR- und
        /// photoTAN-Bilder nicht.
        var istFlicker: Bool { hhdUC != nil }
    }

    /// Vorgeschriebene physische Breite einer Flicker-Grafik in Millimetern.
    static let flickerBreiteMm: Double = 62.5

    /// Anzeigebreite in Punkten für eine Flicker-Grafik.
    ///
    /// Die Grafik muss auf dem Schirm physisch 62,5 mm breit sein, sonst treffen die
    /// hellen Balken die Sensoren des TAN-Generators nicht und er liest nichts. Das
    /// ist keine Stilfrage, sondern steht so in der SDK-Beschreibung.
    ///
    /// Punkte und Millimeter hängen über die **tatsächliche** Bildschirmgröße
    /// zusammen, nicht über die nominellen 72 dpi eines Punkts — deshalb die
    /// Umrechnung über die gemeldete Breite des Bildschirms statt einer festen Zahl.
    ///
    /// - Parameter anpassung: Faktor aus der Feinjustierung. Bildschirme melden ihre
    ///   physische Größe nicht immer richtig (Fernseher und viele externe Monitore
    ///   runden grob), deshalb kann der Nutzer nachregeln — so hält es jede
    ///   chipTAN-Anwendung.
    static func flickerBreite(bildschirmBreitePunkte: Double,
                              bildschirmBreiteMm: Double,
                              anpassung: Double = 1.0) -> Double {
        // Unbekannte Bildschirmgröße: lieber ein brauchbarer Näherungswert als ein
        // Bild der Breite null. Nachregeln kann der Nutzer.
        guard bildschirmBreitePunkte > 0, bildschirmBreiteMm > 0 else { return 240 }
        let breite = flickerBreiteMm * bildschirmBreitePunkte / bildschirmBreiteMm * anpassung
        return min(max(breite, 80), 700)
    }

    /// Was die Bank für den Eingabe-Dialog verlangt.
    struct Spec: Sendable, Equatable {
        let type: InputType
        let secrecyLevel: SecrecyLevel
        // SDK 0.5 begrenzt die Antwort mit `Int?` statt `UInt32?` — die Standard-
        // bibliothek zählt in `Int`, und der Vergleich unten wird dadurch einfacher.
        let minLength: Int?
        let maxLength: Int?
        /// Anzeige im Sheet-Header (z.B. „Sparkasse Siegen") — kommt vom
        /// Aufrufer aus dem aktiven Slot, nicht aus dem SDK.
        let bankDisplayName: String
        /// Optionale Challenge-/Anweisungsnachricht der Bank (z.B. „TAN an ***1234",
        /// photoTAN-Hinweis). `nil`, wenn die Bank keine schickt → Fallback-Text.
        var msg: String? = nil
        /// Snapshot des `MultibankingStore.shared.activeSlotEpoch` zum
        /// Zeitpunkt der Anfrage. Bei Submit prüfen wir, dass der User
        /// nicht zwischenzeitlich die Bank gewechselt hat (sonst wäre der
        /// `InputContext` für eine andere Session).
        let slotEpochAtRequest: Int
        /// Die optische Aufgabe, falls die Bank eine mitschickt (chipTAN, photoTAN).
        var bild: Aufgabenbild? = nil
    }

    /// True, wenn der eingegebene Wert die Constraints der Spec erfüllt.
    /// Wird für Submit-Button-Enable-State + Final-Validierung genutzt.
    static func isValid(_ value: String, spec: Spec) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let len = UInt32(trimmed.count)
        if let min = spec.minLength, len < min { return false }
        if let max = spec.maxLength, len > max { return false }
        switch spec.type {
        case .number:
            return trimmed.allSatisfy(\.isNumber)
        case .email:
            return trimmed.contains("@") && trimmed.contains(".")
        case .phone:
            return trimmed.allSatisfy { $0.isNumber || "+-/ ".contains($0) }
        case .date, .text:
            return true
        }
    }

    /// Hint-Text unter dem Eingabefeld („6 bis 8 Zeichen" / „6 Zeichen" / …).
    static func hint(for spec: Spec) -> String {
        switch (spec.minLength, spec.maxLength) {
        case let (min?, max?) where min == max:
            return L10n.t("\(min) Zeichen", "\(min) characters")
        case let (min?, max?):
            return L10n.t("\(min) bis \(max) Zeichen", "\(min) to \(max) characters")
        case let (min?, nil):
            return L10n.t("mindestens \(min) Zeichen", "at least \(min) characters")
        case let (nil, max?):
            return L10n.t("max. \(max) Zeichen", "max. \(max) characters")
        default:
            return ""
        }
    }
}
