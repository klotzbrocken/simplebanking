import Foundation
import Security

// MARK: - LicenseManager
//
// Verwaltet die Lizenz-Aktivierung über die Polar.sh License-Verify-API.
// Der License-Key wird im Keychain abgelegt; ein 14-Tage-Offline-Grace
// erlaubt App-Nutzung auch ohne Netzwerk falls die letzte Validation
// erfolgreich war.
//
// Singleton + ObservableObject damit SwiftUI-Settings-Sektion + Upsell-
// Sheet reaktiv darauf reagieren können.
//
// Polar-Doku:
//   https://docs.polar.sh/features/benefits/license-keys
//   https://docs.polar.sh/api-reference/customer-portal/license-keys/validate

@MainActor
final class LicenseManager: ObservableObject {

    static let shared = LicenseManager()

    // MARK: - Status

    enum Status: Equatable {
        /// Noch nicht geprüft (App-Start vor erstem revalidate-Call).
        case unknown
        /// Aktiv, online verifiziert. `lastValidatedAt` zeigt wann
        /// zuletzt mit Polar gesprochen wurde.
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

    /// Berechnet den Start-Status synchron aus dem persistierten Cache.
    /// Wird vom Init aufgerufen — niemals `.licensed`, weil das eine
    /// erfolgreiche Server-Revalidation voraussetzt. Innerhalb des
    /// Grace-Fensters → `.offlineGrace`, sonst → `.unlicensed`.
    ///
    /// Why: bug 2026-05-11 — der alte Init setzte `.licensed` sofort, womit
    /// `isLicensed == true` selbst bei längst abgelaufener Grace blieb, bis
    /// `revalidate()` async fertig war. Im Fenster konnte `sendMoney()`
    /// einen Transfer mit dem Transfer-Pair signieren.
    static func initialStatusFromCache(
        hasKey: Bool,
        lastValidatedAt: Date?,
        now: Date = Date(),
        gracePeriod: TimeInterval = LicenseConfig.offlineGracePeriod
    ) -> Status {
        guard hasKey, let lastValidated = lastValidatedAt else { return .unlicensed }
        let age = now.timeIntervalSince(lastValidated)
        // age < 0 = lastValidatedAt in der Zukunft (Clock-Skew, Datums-Reset).
        // Behandeln wie „abgelaufen", nicht wie „frisch".
        if age >= 0, age < gracePeriod {
            return .offlineGrace(lastValidatedAt: lastValidated)
        }
        return .unlicensed
    }

    var isLicensed: Bool {
        switch status {
        case .licensed, .offlineGrace: return true
        default: return false
        }
    }

    /// True, sobald ein Lizenz-Key im Keychain liegt — unabhängig davon,
    /// ob er gerade vom Server bestätigt wurde. Genutzt vom Voucher-Trigger,
    /// um die Race zwischen Init-Status (sync) und revalidate (async) zu
    /// umgehen: wer schon mal eine Lizenz hatte, soll keinen Voucher mehr sehen.
    var hasStoredLicenseKey: Bool {
        #if DEBUG
        if isMasterCodeActive { return true }
        #endif
        return readKeychain() != nil
    }

    /// Demo-Mode-Convenience: in Demo darf TransferSheet ohne Lizenz auf,
    /// damit der User das Feature visuell antesten kann (mock-Sends).
    var isLicensedOrDemo: Bool {
        if UserDefaults.standard.bool(forKey: "demoMode") { return true }
        return isLicensed
    }

    // MARK: - Keychain & cache keys

    private static let kcService = "tech.yaxi.simplebanking"
    /// Keychain-Account-Schlüssel für den License-Key. Bewusst provider-neutral
    /// benannt, damit ein späterer Provider-Wechsel migrationsfrei wäre.
    private static let kcAccount = "license.providerKey"
    private static let lastValidatedKey = "license.lastValidatedAt"
    #if DEBUG
    /// Gesetzt wenn der Master-Code (Test-Key) aktiviert wurde. Bypassed
    /// Polar komplett. Nur in DEBUG-Builds — im Release ist die Konstante
    /// (und damit der ganze Code-Pfad) durch `#if DEBUG` weg-compiliert.
    private static let masterCodeFlag = "license.masterCodeActive"
    #endif

    private var lastNetworkAttempt: Date?

    // MARK: - Init

    private init() {
        // Beim Start: was aus dem Keychain laden, Status grob setzen,
        // dann fire-and-forget revalidieren.
        guard LicenseConfig.isConfigured else {
            status = .notConfigured
            return
        }
        #if DEBUG
        // Master-Code-Bypass hat Vorrang. Wenn der Flag gesetzt ist, sind wir
        // lizenziert, ohne Polar zu kontaktieren. Nur in DEBUG.
        if isMasterCodeActive {
            status = .licensed(lastValidatedAt: Date())
            return
        }
        #endif
        let hasKey = readKeychain() != nil
        let lastValidated = UserDefaults.standard.object(forKey: Self.lastValidatedKey) as? Date
        // Sync korrekt anhand des Grace-Fensters — niemals direkt `.licensed`.
        // `revalidate()` promoviert anschließend bei Server-OK auf `.licensed`.
        status = Self.initialStatusFromCache(hasKey: hasKey, lastValidatedAt: lastValidated)
        if hasKey {
            Task { await revalidate() }
        }
    }

    #if DEBUG
    private var isMasterCodeActive: Bool {
        UserDefaults.standard.bool(forKey: Self.masterCodeFlag)
    }
    #endif

    // MARK: - Public API

    /// Aktiviert eine Lizenz: Polar Validate-Call. Bei Erfolg wird der Key
    /// im Keychain abgelegt und der Status auf `licensed` gesetzt.
    func activate(licenseKey: String) async throws {
        guard LicenseConfig.isConfigured else {
            throw LicenseError.notConfigured
        }
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LicenseError.invalid(message: L10n.t("Lizenz-Key fehlt.", "License key is missing."))
        }
        #if DEBUG
        // Master-Code überspringt Polar komplett. Nur in DEBUG.
        if let master = LicenseConfig.masterCode, trimmed == master {
            UserDefaults.standard.set(true, forKey: Self.masterCodeFlag)
            status = .licensed(lastValidatedAt: Date())
            AppLogger.log("license: master code activated (DEBUG only)", category: "License")
            return
        }
        #endif
        let response = try await verifyOnPolar(key: trimmed)
        try ensureValid(response)
        // Erfolgreich → speichern
        writeKeychain(trimmed)
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.lastValidatedKey)
        status = .licensed(lastValidatedAt: now)
        AppLogger.log("license: activated, status=\(response.status.rawValue) usage=\(response.usage)", category: "License")
    }

    /// Re-validiert eine bereits aktivierte Lizenz im Hintergrund.
    /// Nicht-blockierend: bei Netzwerk-Fehler greift die Offline-Grace,
    /// bei expliziter Server-Ablehnung wird der lokale Cache verworfen.
    func revalidate() async {
        guard LicenseConfig.isConfigured else {
            status = .notConfigured
            return
        }
        #if DEBUG
        // Master-Code skippt Re-Validation. Nur in DEBUG.
        if isMasterCodeActive {
            status = .licensed(lastValidatedAt: Date())
            return
        }
        #endif
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
            let response = try await verifyOnPolar(key: key)
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
    /// und setzt den Status zurück. Die Polar-Seite zählt den Use-Count
    /// nicht zurück (das müsste der User manuell im Polar-Dashboard tun
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
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: Self.masterCodeFlag)
        #endif
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

    private func ensureValid(_ response: PolarValidateResponse) throws {
        switch response.status {
        case .granted:
            break  // ok
        case .revoked:
            throw LicenseError.invalid(
                message: L10n.t("Lizenz wurde widerrufen.", "License has been revoked.")
            )
        case .disabled:
            throw LicenseError.invalid(
                message: L10n.t("Lizenz ist deaktiviert.", "License is disabled.")
            )
        }
        // Hard-Expiry: wenn Polar ein expires_at liefert und das in der
        // Vergangenheit liegt, ist die Lizenz tot. (Wir konfigurieren
        // expiry=unendlich, der Check ist also defensiv.)
        if let expires = response.expiresAt, expires < Date() {
            throw LicenseError.invalid(
                message: L10n.t("Lizenz ist abgelaufen.", "License has expired.")
            )
        }
    }

    // MARK: - Polar HTTP

    /// POST /v1/customer-portal/license-keys/validate
    /// Auth: keine — der Endpoint ist customer-facing, key+org_id sind die
    /// Authentifikation. Body ist JSON.
    private func verifyOnPolar(key: String) async throws -> PolarValidateResponse {
        let url = LicenseConfig.apiBaseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("customer-portal")
            .appendingPathComponent("license-keys")
            .appendingPathComponent("validate")

        struct Body: Encodable {
            let key: String
            let organization_id: String
        }
        let body = Body(key: key, organization_id: LicenseConfig.polarOrganizationId)
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(body)
        } catch {
            throw LicenseError.network(error)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData
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
        // 404 = Key/org-Combination existiert nicht
        if http.statusCode == 404 {
            throw LicenseError.invalid(
                message: L10n.t("Lizenz-Key nicht gefunden — bitte prüfen.",
                                "License key not found — please verify.")
            )
        }
        // 422 = Validation-Fehler (z.B. Conditions stimmen nicht); Polar
        // liefert ein detail-Feld zurück
        if http.statusCode == 422 {
            let detail = (try? JSONDecoder().decode(PolarErrorResponse.self, from: data))?.detail
                .map { $0.msg }.joined(separator: " · ")
            throw LicenseError.invalid(
                message: detail?.nilIfEmpty ?? L10n.t("Lizenz-Validierung fehlgeschlagen.",
                                                       "License validation failed.")
            )
        }
        guard (200...299).contains(http.statusCode) else {
            throw LicenseError.network(NSError(domain: "License", code: http.statusCode,
                                               userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(PolarValidateResponse.self, from: data)
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

// MARK: - Polar response models

/// Subset von Polars 200-Response für `/customer-portal/license-keys/validate`.
/// Wir lesen nur was wir tatsächlich auswerten — alles andere (customer,
/// activation, modified_at, …) wird ignoriert.
private struct PolarValidateResponse: Decodable {
    let id: String
    let status: PolarLicenseStatus
    let usage: Int
    let validations: Int
    let lastValidatedAt: Date?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status, usage, validations
        case lastValidatedAt = "last_validated_at"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.status = try c.decode(PolarLicenseStatus.self, forKey: .status)
        self.usage = try c.decode(Int.self, forKey: .usage)
        self.validations = try c.decode(Int.self, forKey: .validations)
        self.lastValidatedAt = try c.decodeIfPresent(String.self, forKey: .lastValidatedAt)
            .flatMap(Self.iso8601.date(from:))
        self.expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
            .flatMap(Self.iso8601.date(from:))
    }

    /// ISO8601DateFormatter ist laut Apple-Doku thread-safe, das Strict-
    /// Concurrency-Model erkennt das aber nicht — daher `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private enum PolarLicenseStatus: String, Decodable {
    case granted
    case revoked
    case disabled
}

/// Polars 422-Validation-Error-Format (FastAPI-Style).
private struct PolarErrorResponse: Decodable {
    let detail: [Item]
    struct Item: Decodable {
        let msg: String
    }
}
