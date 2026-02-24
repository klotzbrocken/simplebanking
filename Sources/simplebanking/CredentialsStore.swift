import Foundation
import CryptoKit
import CommonCrypto

struct StoredCredentials: Codable {
    var iban: String
    var userId: String
    var password: String
    var anthropicApiKey: String? = nil
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

    static func defaultURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appDir = dir.appendingPathComponent("simplebanking", isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("credentials.json")
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

    static func save(_ creds: StoredCredentials, masterPassword: String) throws {
        let url = try defaultURL()
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
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(StoredCredentials.self, from: plaintext)
    }

    static func loadAPIKey(masterPassword: String) throws -> String? {
        let credentials = try load(masterPassword: masterPassword)
        let key = credentials.anthropicApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { return nil }
        return key
    }

    static func saveAPIKey(_ apiKey: String?, masterPassword: String) throws {
        var credentials = try load(masterPassword: masterPassword)
        let normalized = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials.anthropicApiKey = (normalized?.isEmpty == false) ? normalized : nil
        try save(credentials, masterPassword: masterPassword)
    }

    static func hasAPIKey(masterPassword: String) throws -> Bool {
        try loadAPIKey(masterPassword: masterPassword) != nil
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
        let pw = Array(password.utf8)
        var data = Data(pw + salt)
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
