import LocalAuthentication
import Security
import Foundation

/// Speichert das Master-Passwort im Keychain, geschützt durch Touch ID beim Lesen.
/// Auf macOS erfordert kSecAttrAccessControl + .userPresence eine Systemauthentifizierung
/// bereits beim Speichern (SecItemAdd), was in signierten Apps regelmäßig fehlschlägt.
/// Stattdessen: Eintrag ohne Access Control speichern; biometrische Schranke wird
/// ausschließlich beim Lesen über LAContext.evaluatePolicy durchgesetzt.
enum BiometricStore {
    private static let service = "tech.yaxi.simplebanking"
    private static let account = "master-password"

    /// Touch ID ist auf diesem Gerät verfügbar und eingerichtet.
    static var isAvailable: Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// Ein Passwort ist im Keychain hinterlegt.
    static var hasSavedPassword: Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Speichert das Passwort im Keychain (nur auf diesem Gerät, nur wenn entsperrt).
    /// Die biometrische Schranke wird beim Lesen über LAContext.evaluatePolicy erzwungen.
    static func save(password: String) throws {
        guard let data = password.data(using: .utf8) else { return }

        // Vorhandenen Eintrag erst löschen
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

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

    /// Zeigt Touch ID-Prompt und gibt das gespeicherte Passwort zurück.
    static func loadPassword(reason: String) async throws -> String {
        let ctx = LAContext()
        // Nutzer authentifizieren → Touch ID-Dialog
        try await ctx.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )

        // Passwort nach erfolgreicher Authentifizierung aus Keychain lesen
        return try await withCheckedThrowingContinuation { continuation in
            var result: CFTypeRef?
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true
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
                    userInfo: [NSLocalizedDescriptionKey: "Passwort konnte nicht aus Keychain gelesen werden."]
                ))
            }
        }
    }

    /// Löscht das gespeicherte Passwort (z.B. bei Security-Reset).
    static func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
