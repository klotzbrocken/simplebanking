import Foundation

// MARK: - LicenseConfig
//
// Konfigurations-Konstanten für das Lizenz-System (Polar.sh).
// Die organization_id und productId sind nicht sensibel — sie sind Teil der
// öffentlichen Polar-Checkout-URL ohnehin sichtbar. Daher als Klartext-
// Konstanten; die Datei kann (und soll) in Git eingecheckt werden.
//
// Polar-Doku:
//   https://docs.polar.sh/features/benefits/license-keys
//   https://docs.polar.sh/api-reference/customer-portal/license-keys/validate

enum LicenseConfig {
    /// Master-Switch. Wenn `false`, ist das gesamte Lizenz-System UI-seitig
    /// **deaktiviert**: kein Lizenz-Gate vor TransferSheet, kein UpsellSheet,
    /// keine License-Section in den Einstellungen. „Geld senden" ist für alle
    /// frei zugänglich.
    static let licensingEnabled: Bool = true

    /// Universeller Test-Key, der ohne Polar-Call als gültig akzeptiert wird.
    /// Im Release-Build per `#if DEBUG` komplett aus dem Binary gestrippt —
    /// `strings simplebanking | grep Maik` liefert leere Ausgabe.
    /// Im Debug-Build (`swift build` ohne `-c release`) bleibt der Bypass.
    #if DEBUG
    static let masterCode: String? = "REDACTED_DEBUG_BYPASS"
    #else
    static let masterCode: String? = nil
    #endif

    /// Polar Organization-ID (UUID4). Wird beim Validate-Call mitgeschickt.
    /// Quelle: Polar-Dashboard → Organization Settings.
    static let polarOrganizationId: String = "2f70b809-473d-4d9b-9be6-8209fcd45973"

    /// Polar Product-ID (UUID4). Aktuell informativ — die Validate-API
    /// braucht sie nicht zwingend, kann aber via `benefit_id`/Webhook-
    /// Filterung in Zukunft genutzt werden.
    static let polarProductId: String = "d515bd79-04b0-4bfb-b4f3-4902828c5f36"

    /// Polar Benefit-ID (UUID4) für den License-Keys-Benefit. Aktuell rein
    /// informativ — könnte später bei Validate als `benefit_id` mitgeschickt
    /// werden, falls die App mehrere Polar-Benefits unterscheiden muss.
    static let polarBenefitId: String = "61be8931-30e1-462b-bd46-af590ebc19e3"

    /// Polar API-Base. Wenn auf Sandbox geschaltet, läuft die Validation
    /// gegen `sandbox-api.polar.sh` — nützlich für Tester-Builds, ohne
    /// echte Lizenzen zu „verbrauchen". Default: Production.
    static let useSandbox: Bool = false

    static var apiBaseURL: URL {
        URL(string: useSandbox
            ? "https://sandbox-api.polar.sh"
            : "https://api.polar.sh")!
    }

    /// Verkaufs-URL, an die das UpsellSheet linkt (Polar-Checkout).
    static let purchaseURL: URL = URL(string:
        "https://buy.polar.sh/polar_cl_UF20B6EMnpGU7j2j1XOJ1bDtbnGKrJdc4vOIN1VwIfR")!

    /// Anzeige-Preis fürs UpsellSheet. Der echte Preis kommt aus Polar
    /// (Stripe-Checkout zeigt den live konfigurierten Wert) — hier nur die
    /// Kommunikation an den User.
    static let displayPrice: String = "€14"

    /// Offline-Grace-Period: wie lange darf die App ohne erfolgreiche
    /// Re-Validation als „lizenziert" gelten? Schützt User mit instabiler
    /// Internet-Verbindung und der Server-Wartung.
    static let offlineGracePeriod: TimeInterval = 14 * 24 * 60 * 60   // 14 Tage

    /// Wie oft revalidieren? Nur ein Hint — App ruft bei jedem Launch +
    /// vor jedem TransferSheet-Open eine Validation, aber nicht öfter als
    /// einmal pro Stunde, um Polar nicht zu spammen.
    static let revalidationInterval: TimeInterval = 60 * 60   // 1 Stunde

    /// Convenience: ist die Konfig bereit für Production? Wird vom UI
    /// genutzt um eine klare „Bitte konfigurieren"-Meldung statt einem
    /// kryptischen 404 zu zeigen, falls jemand das Setup übersieht.
    static var isConfigured: Bool {
        !polarOrganizationId.isEmpty
            && polarOrganizationId != "PLACEHOLDER_REPLACE_ME"
    }
}
