import Foundation

// MARK: - LicenseConfig
//
// Konfigurations-Konstanten für das Lizenz-System (Gumroad).
// Die Product-ID ist nicht sensibel — sie steht ohnehin öffentlich auf
// der Gumroad-Verkaufsseite. Daher als Klartext-Konstante; die Datei
// kann (und soll) in Git eingecheckt werden.
//
// Vor dem ersten echten Build muss die `gumroadProductId` durch die
// echte ID ersetzt werden. Bis dahin bleibt der Lizenz-Manager im
// `unlicensed`-Zustand und das Feature ist nicht zugänglich.

enum LicenseConfig {
    /// Master-Switch. Wenn `false`, ist das gesamte Lizenz-System UI-seitig
    /// **deaktiviert**: kein Lizenz-Gate vor TransferSheet, kein UpsellSheet,
    /// keine License-Section in den Einstellungen. „Geld senden" ist für alle
    /// frei zugänglich.
    ///
    /// Auf `true` setzen wenn das Gumroad-Setup komplett ist (Produkt
    /// angelegt, License-Keys aktiviert, Permalink/Product-ID + Preis
    /// im Code unten korrekt). Dann erscheint der Paywall vor dem
    /// TransferSheet automatisch.
    static let licensingEnabled: Bool = false

    /// Gumroad Product Permalink. Die License-Verify-API akzeptiert den
    /// Permalink-String unter dem Schlüssel `product_id`.
    /// Quelle: Gumroad-Dashboard → Product → Custom URL.
    static let gumroadProductId: String = "simplebanking"

    /// Verkaufs-URL, an die das UpsellSheet linkt.
    static let purchaseURL: URL = URL(string: "https://klotzzy2.gumroad.com/l/simplebanking")!

    /// Anzeige-Preis fürs UpsellSheet. Der echte Preis kommt aus Gumroad
    /// (Stripe-Checkout zeigt den live konfigurierten Wert) — hier nur die
    /// Kommunikation an den User.
    static let displayPrice: String = "€14"

    /// Offline-Grace-Period: wie lange darf die App ohne erfolgreiche
    /// Re-Validation als „lizenziert" gelten? Schützt User mit instabiler
    /// Internet-Verbindung und der Server-Wartung.
    static let offlineGracePeriod: TimeInterval = 14 * 24 * 60 * 60   // 14 Tage

    /// Wie oft revalidieren? Nur ein Hint — App ruft bei jedem Launch +
    /// vor jedem TransferSheet-Open eine Validation, aber nicht öfter als
    /// einmal pro Stunde, um Gumroad nicht zu spammen.
    static let revalidationInterval: TimeInterval = 60 * 60   // 1 Stunde

    /// Convenience: ist die Konfig bereit für Production? Wird vom UI
    /// genutzt um eine klare „Bitte konfigurieren"-Meldung statt einem
    /// kryptischen 404 zu zeigen, falls jemand das Setup übersieht.
    static var isConfigured: Bool {
        !gumroadProductId.isEmpty
            && gumroadProductId != "PLACEHOLDER_REPLACE_ME"
    }
}
