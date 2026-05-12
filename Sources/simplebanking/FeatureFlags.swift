import Foundation

// MARK: - FeatureFlags
//
// Compile-time toggles für Features, die noch nicht öffentlich angekündigt
// sind. Anders als `LicenseConfig` geht's hier NICHT um Bezahl-Gating, sondern
// um Sichtbarkeit — Tester-Builds vs. interne Builds.

enum FeatureFlags {
    /// Schaltet „Geld senden" (TransferSheet) komplett aus:
    /// - Menü-Eintrag im Mehr-Menü wird nicht hinzugefügt
    /// - NotificationCenter-Handler ignoriert die Open-Notifications
    ///
    /// `true` schaltet das Feature wieder sichtbar — dann gilt das normale
    /// Lizenz-Gate aus `LicenseConfig.licensingEnabled`.
    static let transferMoneyEnabled: Bool = true
}
