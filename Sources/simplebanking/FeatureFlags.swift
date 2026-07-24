import Foundation

// MARK: - FeatureFlags
//
// Compile-time toggles für Features, die noch nicht öffentlich angekündigt
// sind. Anders als `LicenseConfig` geht's hier NICHT um Bezahl-Gating, sondern
// um Sichtbarkeit — Tester-Builds vs. interne Builds.

enum FeatureFlags {
    /// Schaltet „Geld senden" (TransferSheet + Flyout-Schnellüberweisung) sichtbar:
    /// - Menü-Eintrag im Mehr-Menü
    /// - NotificationCenter-Open-Handler
    /// - Papierflieger/Quick-Send im Flyout, Vorlagen-Editor in den Einstellungen
    ///
    /// `true` → sichtbar; darüber greift weiterhin das normale Lizenz-Gate aus
    /// `LicenseConfig.licensingEnabled` (simplesend-Lizenz).
    ///
    /// Zahlungsauslösung: `YaxiTicketMaker.issueTransferTicket()` signiert mit dem
    /// **Transfer-Key-Paar** (`Secrets.yaxiTransferKeyId/Secret`), sobald
    /// `LicenseManager.shared.isLicensedOrDemo` gilt — die Lizenz-Aktivierung schaltet
    /// den Transfer-Scope also frei (unlizenziert wird mit dem Lese-Paar signiert).
    static let transferMoneyEnabled: Bool = true
}
