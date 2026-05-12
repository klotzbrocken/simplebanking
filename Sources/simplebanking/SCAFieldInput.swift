import Foundation
import Routex

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

    /// Was die Bank für den Eingabe-Dialog verlangt.
    struct Spec: Sendable, Equatable {
        let type: InputType
        let secrecyLevel: SecrecyLevel
        let minLength: UInt32?
        let maxLength: UInt32?
        /// Anzeige im Sheet-Header (z.B. „Sparkasse Siegen") — kommt vom
        /// Aufrufer aus dem aktiven Slot, nicht aus dem SDK.
        let bankDisplayName: String
        /// Snapshot des `MultibankingStore.shared.activeSlotEpoch` zum
        /// Zeitpunkt der Anfrage. Bei Submit prüfen wir, dass der User
        /// nicht zwischenzeitlich die Bank gewechselt hat (sonst wäre der
        /// `InputContext` für eine andere Session).
        let slotEpochAtRequest: Int
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
