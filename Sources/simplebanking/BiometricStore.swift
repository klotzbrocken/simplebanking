import LocalAuthentication
import Security
import Foundation

/// Speichert das Master-Passwort im Keychain, gesichert durch Touch ID beim Lesen.
///
/// Idealer Schutz wäre kSecAttrAccessControl + .userPresence beim Speichern,
/// damit der Keychain selbst die Authentifizierung erzwingt. Das scheitert jedoch
/// bei ad-hoc signierten Apps (SecItemAdd liefert errSecMissingEntitlement /
/// errSecAuthFailed), da macOS für access-controlled Items ein gültiges
/// Team-Identifier im Code Signing voraussetzt.
///
/// Daher: Item ohne Access Control speichern; der biometrische Schutz wird
/// ausschließlich über LAContext.evaluatePolicy vor dem Lesen durchgesetzt
/// (Soft Gate). Für echten Keychain-Level-Schutz wäre Developer ID Signing nötig.
enum BiometricStore {
    private static let service = "tech.yaxi.simplebanking"
    private static let account = "master-password"

    // MARK: - Availability

    /// Touch ID ist auf diesem Gerät verfügbar.
    static var isAvailable: Bool {
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            return true
        }
        // Fallback für bestimmte Signing-Konfigurationen: biometryType auslesen
        let ctx2 = LAContext()
        var err2: NSError?
        ctx2.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err2)
        return ctx2.biometryType == .touchID
    }

    // MARK: - Existence check

    /// Prüft ob ein Passwort gespeichert ist, ohne einen Auth-Dialog zu zeigen.
    static var hasSavedPassword: Bool {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: false,
            kSecUseAuthenticationContext: ctx
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecSuccess:               Item existiert, keine Auth nötig
        // errSecInteractionNotAllowed: Item existiert, Auth erforderlich (access-controlled)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: - Save

    /// Speichert das Passwort im Keychain (nur auf diesem Gerät, nur wenn entsperrt).
    /// Ohne kSecAttrAccessControl — Soft Gate via evaluatePolicy beim Lesen.
    static func save(password: String) throws {
        guard let data = password.data(using: .utf8) else { return }

        // Vorhandenen Eintrag erst löschen
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    // MARK: - Load

    /// Zeigt Touch ID / Passwort-Dialog und gibt das gespeicherte Passwort zurück.
    /// Verwendet .deviceOwnerAuthentication (Touch ID mit Passwort-Fallback).
    static func loadPassword(reason: String) async throws -> String {
        let ctx = LAContext()
        try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: CFTypeRef?
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service,
                    kSecAttrAccount: account,
                    kSecReturnData: true,
                    kSecUseAuthenticationContext: ctx
                ]
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecSuccess,
                   let data = result as? Data,
                   let password = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: password)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: NSOSStatusErrorDomain,
                        code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Passwort konnte nicht aus Keychain gelesen werden (status: \(status))."]
                    ))
                }
            }
        }
    }

    // MARK: - Clear

    /// Löscht das gespeicherte Passwort (z.B. bei Security-Reset).
    static func clear() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
    }
}
