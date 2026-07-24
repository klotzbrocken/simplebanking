import LocalAuthentication
import Security
import Foundation

/// Speichert das Master-Passwort im Keychain, gesichert durch Touch ID beim Lesen.
///
/// `save` versucht ZUERST den echten Keychain-Schutz (kSecAttrAccessControl +
/// .userPresence) — das funktioniert im **Developer-ID-signierten** Build und ist
/// robuster als der frühere Soft-Gate-only-Ansatz (dort schlug das Lesen in der
/// Release reproduzierbar fehl). Schlägt der ACL-Save fehl (ad-hoc-Signing →
/// errSecMissingEntitlement/authFailed), fällt er auf das ACL-freie Item zurück,
/// dessen biometrischer Schutz nur über LAContext.evaluatePolicy beim Lesen läuft
/// (Soft Gate). `loadPassword` liest beide Varianten.
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
    /// Bevorzugt mit echtem Biometrie-ACL; Fallback ohne ACL (Soft Gate).
    static func save(password: String) throws {
        guard let data = password.data(using: .utf8) else { return }

        // Vorhandenen Eintrag erst löschen (egal welcher Typ).
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)

        // 1) Echter Keychain-Biometrie-Gate (signierter Build). .userPresence =
        //    Touch ID mit Passwort-Fallback, passend zu evaluatePolicy beim Lesen.
        //    NICHT im Demo-Modus: dort prüft `verifyPasswordDirectly` das Item ohne
        //    Prompt — ein ACL-Item wäre so nicht lesbar.
        let allowACL = !UserDefaults.standard.bool(forKey: "demoMode")
        var acError: Unmanaged<CFError>?
        if allowACL {
            if let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &acError) {
                let aclQuery: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service,
                    kSecAttrAccount: account,
                    kSecAttrAccessControl: access,
                    kSecValueData: data,
                    kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
                ]
                let aclStatus = SecItemAdd(aclQuery as CFDictionary, nil)
                if aclStatus == errSecSuccess { return }
                // macOS legt biometrische SecAccessControl-Items nur in der
                // Data-Protection-Keychain an; in der Legacy-Keychain liefert der Add
                // errSecParam (-50). Bewusster, funktionierender Fallback: Soft Gate
                // (ACL-frei, Schutz via evaluatePolicy beim Lesen).
                AppLogger.log("Touch ID ACL save fell back (status \(aclStatus)) → soft gate", category: "Biometric")
            } else {
                AppLogger.log("Touch ID SecAccessControlCreateWithFlags failed → soft gate", category: "Biometric", level: "WARN")
            }
        }

        // 2) Fallback: ACL-frei (z.B. ad-hoc-Builds). Schutz nur via evaluatePolicy.
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

    /// True, wenn das gespeicherte Item ACL-geschützt ist (echter Biometrie-Gate,
    /// `kSecAttrAccessControl`). Probe ohne Auth-Dialog: ein ACL-Item liefert bei
    /// `interactionNotAllowed` `errSecInteractionNotAllowed`, ein Soft-Gate-Item
    /// `errSecSuccess`.
    private static func isACLProtected() -> Bool {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: false,
            kSecUseAuthenticationContext: ctx
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecInteractionNotAllowed
    }

    /// Zeigt Touch ID / Passwort-Dialog und gibt das gespeicherte Passwort zurück.
    ///
    /// **ACL-Item** (signierter Build): der Keychain-Read SELBST löst den Touch-ID-
    /// Prompt aus (LAContext in der Query). KEIN separates `evaluatePolicy` davor —
    /// das war der fragile Teil, der auf der notarisierten Release den Prompt
    /// manchmal verschluckt hat. **Soft-Gate-Item** (ad-hoc): kein ACL → Read würde
    /// ungeschützt lesen, daher hier weiterhin `evaluatePolicy` als Gate vorschalten.
    static func loadPassword(reason: String) async throws -> String {
        if isACLProtected() {
            let ctx = LAContext()
            ctx.localizedReason = reason
            return try await readPassword(context: ctx, prompt: reason)
        } else {
            let ctx = LAContext()
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return try await readPassword(context: ctx, prompt: nil)
        }
    }

    /// Liest das Passwort-Item. `context` bindet die (für ACL-Items prompt-auslösende)
    /// Authentifizierung, `prompt` setzt den Operation-Prompt-Text.
    private static func readPassword(context ctx: LAContext, prompt: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: CFTypeRef?
                var query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service,
                    kSecAttrAccount: account,
                    kSecReturnData: true,
                    kSecUseAuthenticationContext: ctx
                ]
                if let prompt { query[kSecUseOperationPrompt] = prompt }
                var status = SecItemCopyMatching(query as CFDictionary, &result)
                // Soft-Gate-Items brauchen den Context nicht — Fallback ohne ihn.
                if status != errSecSuccess && status != errSecUserCanceled {
                    query.removeValue(forKey: kSecUseAuthenticationContext)
                    query.removeValue(forKey: kSecUseOperationPrompt)
                    result = nil
                    status = SecItemCopyMatching(query as CFDictionary, &result)
                }
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

    // MARK: - Password Verification (kein biometrischer Prompt)

    /// Verifies a candidate password against the stored master password without
    /// showing a biometric prompt. Used in demo mode where CredentialsStore has no
    /// credentials file to decrypt.
    static func verifyPasswordDirectly(_ candidate: String) -> Bool {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let stored = String(data: data, encoding: .utf8) else { return false }
        return stored == candidate
    }

    // MARK: - Auto-Unlock (kein biometrischer Prompt beim Lesen)

    private static let autoUnlockAccount = "master-password-auto"

    /// Prüft ob ein Auto-Unlock-Passwort gespeichert ist (kein Prompt).
    static var hasAutoUnlockPassword: Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: autoUnlockAccount,
            kSecReturnData: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Speichert das Passwort für Auto-Unlock (lesbar ohne biometrischen Prompt).
    static func saveForAutoUnlock(password: String) throws {
        guard let data = password.data(using: .utf8) else { return }
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: autoUnlockAccount
        ] as CFDictionary)
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: autoUnlockAccount,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Lädt das Auto-Unlock-Passwort ohne Nutzer-Prompt.
    static func loadAutoUnlockPassword() -> String? {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: autoUnlockAccount,
            kSecReturnData: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Entfernt das Auto-Unlock-Passwort.
    static func clearAutoUnlock() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: autoUnlockAccount
        ] as CFDictionary)
    }
}
