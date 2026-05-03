import Foundation
import Security

// MARK: - LicenseManager
//
// Verwaltet die Lizenz-Aktivierung über die Gumroad License-Verify-API.
// Der License-Key wird im Keychain abgelegt; ein 14-Tage-Offline-Grace
// erlaubt App-Nutzung auch ohne Netzwerk falls die letzte Validation
// erfolgreich war.
//
// Singleton + ObservableObject damit SwiftUI-Settings-Sektion + Upsell-
// Sheet reaktiv darauf reagieren können.
//
// Gumroad-API-Doku: https://app.gumroad.com/api#licenses

@MainActor
final class LicenseManager: ObservableObject {

    static let shared = LicenseManager()

    // MARK: - Status

    enum Status: Equatable {
        /// Noch nicht geprüft (App-Start vor erstem revalidate-Call).
        case unknown
        /// Aktiv, online verifiziert. `lastValidatedAt` zeigt wann
        /// zuletzt mit Gumroad gesprochen wurde.
        case licensed(lastValidatedAt: Date)
        /// Kein Key gespeichert, oder Key vom Server abgelehnt.
        case unlicensed
        /// Cache gilt — Online-Check fehlgeschlagen, aber letzter
        /// erfolgreicher Check liegt < 14 Tage zurück.
        case offlineGrace(lastValidatedAt: Date)
        /// Konfig fehlt (`PLACEHOLDER_REPLACE_ME`-ID).
        case notConfigured
    }

    @Published private(set) var status: Status = .unknown

    var isLicensed: Bool {
        switch status {
        case .licensed, .offlineGrace: return true
        default: return false
        }
    }

    /// Demo-Mode-Convenience: in Demo darf TransferSheet ohne Lizenz auf,
    /// damit der User das Feature visuell antesten kann (mock-Sends).
    var isLicensedOrDemo: Bool {
        if UserDefaults.standard.bool(forKey: "demoMode") { return true }
        return isLicensed
    }

    // MARK: - Keychain & cache keys

    private static let kcService = "tech.yaxi.simplebanking"
    private static let kcAccount = "license.gumroadKey"
    private static let lastValidatedKey = "license.lastValidatedAt"

    private var lastNetworkAttempt: Date?

    // MARK: - Init

    private init() {
        // Beim Start: was aus dem Keychain laden, Status grob setzen,
        // dann fire-and-forget revalidieren.
        guard LicenseConfig.isConfigured else {
            status = .notConfigured
            return
        }
        if readKeychain() != nil,
           let lastValidated = UserDefaults.standard.object(forKey: Self.lastValidatedKey) as? Date {
            // Cache vorhanden → optimistisch lizenziert annehmen, async re-validate
            status = .licensed(lastValidatedAt: lastValidated)
            Task { await revalidate() }
        } else {
            status = .unlicensed
        }
    }

    // MARK: - Public API

    /// Aktiviert eine Lizenz: Gumroad-Verify-Call mit
    /// `increment_uses_count=true`. Bei Erfolg wird der Key im Keychain
    /// abgelegt und der Status auf `licensed` gesetzt.
    func activate(licenseKey: String) async throws {
        guard LicenseConfig.isConfigured else {
            throw LicenseError.notConfigured
        }
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LicenseError.invalid(message: L10n.t("Lizenz-Key fehlt.", "License key is missing."))
        }
        let response = try await verifyOnGumroad(key: trimmed, incrementUses: true)
        try ensureValid(response)
        // Erfolgreich → speichern
        writeKeychain(trimmed)
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.lastValidatedKey)
        status = .licensed(lastValidatedAt: now)
        AppLogger.log("license: activated, uses=\(response.uses ?? -1)", category: "License")
    }

    /// Re-validiert eine bereits aktivierte Lizenz im Hintergrund.
    /// Nicht-blockierend: bei Netzwerk-Fehler greift die Offline-Grace,
    /// bei expliziter Server-Ablehnung wird der lokale Cache verworfen.
    func revalidate() async {
        guard LicenseConfig.isConfigured else {
            status = .notConfigured
            return
        }
        guard let key = readKeychain() else {
            status = .unlicensed
            return
        }
        // Rate-Limit: max 1 Call/Stunde, außer bei explizitem Aufruf
        if let last = lastNetworkAttempt,
           Date().timeIntervalSince(last) < LicenseConfig.revalidationInterval {
            return
        }
        lastNetworkAttempt = Date()
        do {
            let response = try await verifyOnGumroad(key: key, incrementUses: false)
            try ensureValid(response)
            let now = Date()
            UserDefaults.standard.set(now, forKey: Self.lastValidatedKey)
            status = .licensed(lastValidatedAt: now)
        } catch let error as LicenseError {
            switch error {
            case .invalid:
                // Server hat klar gesagt: Lizenz ungültig. Lokal aufräumen.
                AppLogger.log("license: invalidated by server: \(error)", category: "License", level: "WARN")
                deactivateLocally()
                status = .unlicensed
            case .network, .notConfigured:
                applyOfflineGrace()
            }
        } catch {
            applyOfflineGrace()
        }
    }

    /// Deaktiviert die Lizenz lokal — entfernt den Key aus dem Keychain
    /// und setzt den Status zurück. Die Gumroad-Seite zählt den Use-Count
    /// nicht zurück (das müsste der User manuell im Gumroad-Dashboard tun
    /// oder Du als Verkäufer per Refund/Disable).
    func deactivate() {
        deactivateLocally()
        status = .unlicensed
        AppLogger.log("license: deactivated locally", category: "License")
    }

    // MARK: - Internals

    private func deactivateLocally() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.kcService,
            kSecAttrAccount: Self.kcAccount
        ] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.lastValidatedKey)
    }

    private func applyOfflineGrace() {
        if let lastValidated = UserDefaults.standard.object(forKey: Self.lastValidatedKey) as? Date,
           Date().timeIntervalSince(lastValidated) < LicenseConfig.offlineGracePeriod {
            status = .offlineGrace(lastValidatedAt: lastValidated)
            AppLogger.log("license: offline grace (last=\(lastValidated))", category: "License")
        } else {
            status = .unlicensed
            AppLogger.log("license: offline grace expired", category: "License", level: "WARN")
        }
    }

    private func ensureValid(_ response: GumroadVerifyResponse) throws {
        guard response.success else {
            throw LicenseError.invalid(
                message: response.message ?? L10n.t("Lizenz ungültig.", "License invalid.")
            )
        }
        let purchase = response.purchase
        if purchase?.licenseDisabled == true {
            throw LicenseError.invalid(
                message: L10n.t("Lizenz wurde deaktiviert.", "License has been disabled.")
            )
        }
        if purchase?.refunded == true {
            throw LicenseError.invalid(
                message: L10n.t("Bezahlung wurde zurückerstattet.", "Payment was refunded.")
            )
        }
        if purchase?.chargebacked == true {
            throw LicenseError.invalid(
                message: L10n.t("Bezahlung wurde zurückgebucht.", "Payment was charged back.")
            )
        }
    }

    // MARK: - Gumroad HTTP

    private func verifyOnGumroad(key: String, incrementUses: Bool) async throws -> GumroadVerifyResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "product_id", value: LicenseConfig.gumroadProductId),
            URLQueryItem(name: "license_key", value: key),
            URLQueryItem(name: "increment_uses_count", value: incrementUses ? "true" : "false"),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw LicenseError.network(NSError(domain: "License", code: -1))
        }
        var req = URLRequest(url: URL(string: "https://api.gumroad.com/v2/licenses/verify")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LicenseError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LicenseError.network(NSError(domain: "License", code: -2))
        }
        // Gumroad gibt 404 für ungültigen Product-ID, 200 für valid/invalid License
        if http.statusCode == 404 {
            throw LicenseError.invalid(
                message: L10n.t("Produkt nicht gefunden — bitte Konfig prüfen.",
                                "Product not found — please check config.")
            )
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(GumroadVerifyResponse.self, from: data)
        } catch {
            throw LicenseError.network(error)
        }
    }

    // MARK: - Keychain

    private func readKeychain() -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.kcService,
            kSecAttrAccount: Self.kcAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    private func writeKeychain(_ key: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.kcService,
            kSecAttrAccount: Self.kcAccount
        ] as CFDictionary)
        let data = Data(key.utf8)
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.kcService,
            kSecAttrAccount: Self.kcAccount,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.log("license: kcWrite failed status=\(status)", category: "License", level: "WARN")
        }
    }
}

// MARK: - Errors

enum LicenseError: Error {
    case invalid(message: String)
    case network(Error)
    case notConfigured
}

// MARK: - Gumroad response model

private struct GumroadVerifyResponse: Decodable {
    let success: Bool
    let uses: Int?
    let message: String?
    let purchase: Purchase?

    struct Purchase: Decodable {
        let licenseKey: String?
        let licenseDisabled: Bool?
        let refunded: Bool?
        let chargebacked: Bool?
        let subscriptionCancelledAt: String?
        let subscriptionFailedAt: String?

        enum CodingKeys: String, CodingKey {
            case licenseKey = "license_key"
            case licenseDisabled = "license_disabled"
            case refunded
            case chargebacked
            case subscriptionCancelledAt = "subscription_cancelled_at"
            case subscriptionFailedAt = "subscription_failed_at"
        }
    }
}
