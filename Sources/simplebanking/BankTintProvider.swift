import SwiftUI
import AppKit

// MARK: - BankTintProvider
//
// Liefert die UI-Tönung der aktiven Bank für Umsatzpanel + BalanceBar.
// Trennung von BankLogoAssets bewusst: dort = Brand-Identität, hier = UI-Tinting-Policy.
//
// Priorität: Freeze > globalToggle > UnifiedMode > slotOverride > slot.customColor > logoId
// MoneyMood (Amount-Farben, PaycheckRing) wird bewusst NICHT angefasst.

enum BankTintProvider {

    // MARK: Keys
    static let globalKey = "transactionListBankTintEnabled"
    static let intensityKey = "bankTintIntensity"
    /// Default-Tönungsstärke (30%) wenn kein Slider-Wert gespeichert.
    static let defaultIntensity: Double = 0.30
    static func perSlotKey(_ slotId: String) -> String {
        "simplebanking.bankTintEnabled.\(slotId)"
    }

    /// Aktuelle Sättigung 0.0–1.0 (Slider in Settings).
    static func currentIntensity() -> Double {
        let stored = UserDefaults.standard.object(forKey: intensityKey) as? Double
        return max(0.0, min(1.0, stored ?? defaultIntensity))
    }

    // MARK: Public API (Production — MainActor-bound)

    /// Soft-Variante der Bank-Primärfarbe als Panel-Background-Tint.
    /// Gibt nil zurück wenn deaktiviert, Freeze aktiv, Unified-Mode oder Bank unbekannt.
    @MainActor
    static func resolveListTint(freezeActive: Bool) -> Color? {
        guard let hex = activeTintHex(freezeActive: freezeActive) else { return nil }
        return softColor(fromHex: hex)
    }

    /// NSColor-Bridge der Soft-Variante. Für BalanceBar-Background-Layer (AppKit).
    @MainActor
    static func currentTintNSColor() -> NSColor? {
        guard let hex = activeTintHex(freezeActive: false) else { return nil }
        return softNSColor(fromHex: hex)
    }

    /// Liefert den Hex der aktiven Bank-Tönung oder nil.
    @MainActor
    static func activeTintHex(freezeActive: Bool) -> String? {
        let store = MultibankingStore.shared
        return resolveHex(
            freezeActive: freezeActive,
            globalEnabled: globalEnabled(),
            unifiedActive: isUnifiedActive(),
            activeSlot: store.activeSlot,
            slotOverrideEnabled: store.activeSlot.map { slotEnabled(slotId: $0.id) } ?? true
        )
    }

    // MARK: Pure Resolver (kein State-Zugriff — alles via Parameter, voll testbar)

    /// Pure-Funktion: berechnet die zu nutzende Bankfarbe als Hex-String, oder nil.
    /// Vor jedem Aufruf werden globalEnabled / unifiedActive / slotOverrideEnabled
    /// aus den jeweiligen Sources gelesen und übergeben — keine Singletons hier.
    static func resolveHex(
        freezeActive: Bool,
        globalEnabled: Bool,
        unifiedActive: Bool,
        activeSlot: BankSlot?,
        slotOverrideEnabled: Bool
    ) -> String? {
        if freezeActive { return nil }
        if !globalEnabled { return nil }
        if unifiedActive { return nil }
        guard let slot = activeSlot else { return nil }
        if !slotOverrideEnabled { return nil }
        return hex(for: slot)
    }

    /// Custom-Color hat Vorrang vor Bank-Primärfarbe (User hat manuell überschrieben).
    static func hex(for slot: BankSlot) -> String? {
        if let custom = slot.customColor, !custom.isEmpty { return custom }
        if let logoId = slot.logoId, let hex = BankLogoAssets.primaryColor(forLogoId: logoId) {
            return hex
        }
        return nil
    }

    // MARK: Toggle-Status (UserDefaults — Default ON wenn kein Eintrag)

    static func globalEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: globalKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: globalKey)
    }

    static func slotEnabled(slotId: String) -> Bool {
        let key = perSlotKey(slotId)
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    @MainActor
    static func isUnifiedActive() -> Bool {
        guard UserDefaults.standard.bool(forKey: "unifiedModeEnabled") else { return false }
        return MultibankingStore.shared.slots.count > 1
    }

    // MARK: Color-Math (pure)

    /// Soft-Color aus Hex — Sättigung über Slider gesteuert (Default 30%).
    /// Dark-Mode erhält 30% Boost für Lesbarkeit auf dunklem Untergrund.
    static func softColor(fromHex hex: String) -> Color {
        Color(nsColor: softNSColor(fromHex: hex))
    }

    static func softNSColor(fromHex hex: String) -> NSColor {
        let intensity = currentIntensity()
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let base = AppTheme.color(from: hex, fallback: .controlBackgroundColor)
            // sbBackground-Werte aus ThemeSupport: Light #F9F9F9, Dark #171717
            let bg: NSColor = isDark
                ? NSColor(srgbRed: 0.090, green: 0.090, blue: 0.090, alpha: 1.0)
                : NSColor(srgbRed: 0.976, green: 0.976, blue: 0.976, alpha: 1.0)
            // Slider-Intensity = direkter Blend-Anteil der Bankfarbe.
            // Dark-Mode bekommt +30% Sichtbarkeits-Boost (capped bei 1.0).
            let raw = isDark ? min(1.0, intensity * 1.3) : intensity
            return bg.blended(withFraction: CGFloat(raw), of: base) ?? base
        }
    }
}

extension Notification.Name {
    static let bankTintChanged = Notification.Name("simplebanking.bankTintChanged")
}
