import Foundation
import CryptoKit
import CommonCrypto

struct StoredCredentials: Codable {
    var iban: String
    var userId: String
    var password: String
    var anthropicApiKey: String? = nil
    var mistralApiKey: String? = nil
    var openaiApiKey: String? = nil
}

enum CredentialsStoreError: Error, LocalizedError {
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            return "Sicherer Zufallsgenerator nicht verfügbar (OSStatus \(status))."
        }
    }
}

/// Password-based encrypted file store (AES.GCM).
/// Note: this is a convenience feature; security depends on the master password.
enum CredentialsStore {

    // MARK: - Active slot ID (set by BalanceBar when switching accounts)

    private static let _slotLock = NSLock()
    nonisolated(unsafe) private static var _activeSlotId: String = "legacy"
    static var activeSlotId: String {
        get { _slotLock.lock(); defer { _slotLock.unlock() }; return _activeSlotId }
        set { _slotLock.lock(); defer { _slotLock.unlock() }; _activeSlotId = newValue }
    }
    struct Envelope: Codable {
        var v: Int
        var saltB64: String
        var nonceB64: String
        var ciphertextB64: String
        var tagB64: String
        var kdf: String?
        var iterations: Int?
    }

    private static let currentVersion = 2
    private static let pbkdf2Iterations = 210_000

    static func appSupportURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appDir = dir.appendingPathComponent("simplebanking", isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }

    static func defaultURL() throws -> URL {
        let appDir = try appSupportURL()
        let slotFile = appDir.appendingPathComponent("credentials-\(activeSlotId).json")
        // Legacy fallback: if the slot-specific file doesn't exist but credentials.json does,
        // return the legacy path so existing installs continue to work on first launch.
        if !FileManager.default.fileExists(atPath: slotFile.path) {
            let legacyFile = appDir.appendingPathComponent("credentials.json")
            if FileManager.default.fileExists(atPath: legacyFile.path) {
                return legacyFile
            }
        }
        return slotFile
    }

    static func exists() -> Bool {
        (try? defaultURL()).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static func delete() throws {
        let url = try defaultURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes ALL credentials files, DB files and attachments — used by full reset.
    static func deleteAllData() {
        guard let appDir = try? appSupportURL() else { return }
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil) {
            for file in contents {
                let name = file.lastPathComponent
                if (name.hasPrefix("credentials") && name.hasSuffix(".json"))
                    || name.hasPrefix("transactions") {
                    try? fm.removeItem(at: file)
                }
            }
        }
        try? fm.removeItem(at: appDir.appendingPathComponent("attachments"))
    }

    /// Löscht die credentials-<slotId>.json Datei für einen entfernten Slot.
    /// Best-effort: Fehler werden ignoriert (Datei könnte schon weg sein).
    /// Der "legacy"-Slot ist geschützt (default-Slot, niemals gelöscht).
    static func deleteSlotFile(slotId: String) {
        guard slotId != "legacy" else { return }
        guard let appDir = try? appSupportURL() else { return }
        let url = appDir.appendingPathComponent("credentials-\(slotId).json")
        try? FileManager.default.removeItem(at: url)
    }

    static func save(_ creds: StoredCredentials, masterPassword: String) throws {
        // Always save to the slot-specific file (never the legacy path)
        let appDir = try appSupportURL()
        let url = appDir.appendingPathComponent("credentials-\(activeSlotId).json")
        let plaintext = try JSONEncoder().encode(creds)

        let salt = try randomBytes(count: 16)
        let key = try derivePBKDF2Key(password: masterPassword, salt: salt, iterations: pbkdf2Iterations)

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        let env = Envelope(
            v: currentVersion,
            saltB64: Data(salt).base64EncodedString(),
            nonceB64: Data(nonce).base64EncodedString(),
            ciphertextB64: sealed.ciphertext.base64EncodedString(),
            tagB64: sealed.tag.base64EncodedString(),
            kdf: "pbkdf2-sha256",
            iterations: pbkdf2Iterations
        )

        let data = try JSONEncoder().encode(env)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(masterPassword: String) throws -> StoredCredentials {
        let url = try defaultURL()
        let data = try Data(contentsOf: url)
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard env.v == 1 || env.v == currentVersion else {
            throw NSError(
                domain: "simplebanking",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported credential format"]
            )
        }

        guard let salt = Data(base64Encoded: env.saltB64),
              let nonceData = Data(base64Encoded: env.nonceB64),
              let ciphertext = Data(base64Encoded: env.ciphertextB64),
              let tag = Data(base64Encoded: env.tagB64)
        else {
            throw NSError(
                domain: "simplebanking",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Corrupt credential file"]
            )
        }

        let key = try deriveKeyForEnvelope(password: masterPassword, salt: [UInt8](salt), envelope: env)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        var plaintext = try AES.GCM.open(box, using: key)
        // Plaintext-JSON enthält Bank-User-ID + Passwort. Nach Decode in das
        // StoredCredentials-Struct wird der Roh-Buffer zeroized — das Struct
        // selbst lebt als String-Properties weiter (nicht wipe-bar in Swift),
        // aber der zweite Heap-Buffer mit demselben Klartext geht weg.
        defer { MemoryWipe.zeroize(&plaintext) }
        return try JSONDecoder().decode(StoredCredentials.self, from: plaintext)
    }

    static func loadAPIKey(masterPassword: String) throws -> String? {
        try loadAPIKey(forProvider: .anthropic, masterPassword: masterPassword)
    }

    static func loadAPIKey(forProvider provider: AIProvider, masterPassword: String) throws -> String? {
        let creds = try load(masterPassword: masterPassword)
        let raw: String?
        switch provider {
        case .anthropic: raw = creds.anthropicApiKey
        case .mistral:   raw = creds.mistralApiKey
        case .openai:    raw = creds.openaiApiKey
        }
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { return nil }
        return key
    }

    static func saveAPIKey(_ apiKey: String?, masterPassword: String) throws {
        try saveAPIKey(apiKey, forProvider: .anthropic, masterPassword: masterPassword)
    }

    static func saveAPIKey(_ apiKey: String?, forProvider provider: AIProvider, masterPassword: String) throws {
        var creds = try load(masterPassword: masterPassword)
        let normalized = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty == false) ? normalized : nil
        switch provider {
        case .anthropic: creds.anthropicApiKey = value
        case .mistral:   creds.mistralApiKey   = value
        case .openai:    creds.openaiApiKey    = value
        }
        try save(creds, masterPassword: masterPassword)
    }

    static func hasAPIKey(masterPassword: String) throws -> Bool {
        try loadAPIKey(masterPassword: masterPassword) != nil
    }

    /// Returns true if the active provider has a key stored.
    static func hasActiveProviderKey(masterPassword: String) throws -> Bool {
        try loadAPIKey(forProvider: AIProvider.active, masterPassword: masterPassword) != nil
    }

    // MARK: - KDF

    private static func deriveKeyForEnvelope(password: String, salt: [UInt8], envelope: Envelope) throws -> SymmetricKey {
        if envelope.v == 1 {
            return deriveLegacyKey(password: password, salt: salt)
        }

        let iterations = envelope.iterations ?? pbkdf2Iterations
        return try derivePBKDF2Key(password: password, salt: salt, iterations: iterations)
    }

    private static func derivePBKDF2Key(password: String, salt: [UInt8], iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        // Defer zeroizes the derived key bytes nach SymmetricKey-Wrap, sodass das
        // 32-Byte-Schlüsselmaterial nicht im Heap liegen bleibt. CryptoKit ist
        // für sein eigenes Backing-Storage zuständig.
        defer { MemoryWipe.zeroize(&derived) }
        let passwordLength = password.lengthOfBytes(using: .utf8)

        let status: Int32 = password.withCString { passwordPtr in
            salt.withUnsafeBytes { saltBytes in
                guard let saltBase = saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPtr,
                    passwordLength,
                    saltBase,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    derived.count
                )
            }
        }

        guard status == kCCSuccess else {
            throw NSError(
                domain: "simplebanking",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "PBKDF2 key derivation failed (status \(status))"]
            )
        }

        return SymmetricKey(data: Data(derived))
    }

    // Backward compatibility for existing v1 envelopes.
    private static func deriveLegacyKey(password: String, salt: [UInt8]) -> SymmetricKey {
        var pw = Array(password.utf8)
        var data = Data(pw + salt)
        // Pre-image (Passwort-Bytes + Salt + jede Iteration) wird nach SHA256-Loop
        // explizit zeroized — sonst lebt das letzte Hash-Result als plain Data im Heap
        // bis ARC es discardet.
        defer {
            MemoryWipe.zeroize(&pw)
            MemoryWipe.zeroize(&data)
        }
        for _ in 0..<100_000 {
            data = Data(SHA256.hash(data: data))
        }
        return SymmetricKey(data: data)
    }

    private static func randomBytes(count: Int) throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &b)
        guard status == errSecSuccess else {
            throw CredentialsStoreError.randomGenerationFailed(status)
        }
        return b
    }
}
