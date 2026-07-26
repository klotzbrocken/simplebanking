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
    // PayPal (NVP-API-Signatur) — nur für PayPal-Slots gesetzt.
    var paypalUser: String? = nil
    var paypalPwd: String? = nil
    var paypalSignature: String? = nil
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

    // MARK: - Basisverzeichnis (und warum es umlenkbar sein MUSS)
    //
    // `appSupportURL()` ist der einzige pfadbildende Einstieg für das
    // Finanzdaten-Verzeichnis: daran hängen `defaultURL()`, die Migration, `save()`,
    // sämtliche Löschpfade, `TransactionsDatabase.databaseURL(bankId:)` und
    // `TransferDraftStore.directoryURL()`.
    //
    // Genau das war bis 2.0 ein Datenverlust-Risiko: `TransactionsDatabase`-Defaults
    // lauten überall `bankId: "primary"`, und ein Test, der den Parameter vergisst
    // (`LLMAllPlansSmokeTests`), löschte damit die ECHTE `transactions.db` des Nutzers —
    // samt Notizen, Anhängen, Aufrund-Töpfen und eBons, die keine Bank je zurückliefert.
    // Credential-Tests sicherten die echten `credentials*.json` weg und stellten sie im
    // `tearDown` wieder her; ein Abbruch dazwischen ließ den Nutzer ohne Zugangsdaten
    // zurück (und drei Fehlversuche bei der Bank bedeuten eine gesperrte Verbindung).
    //
    // Die Antwort darauf ist NICHT, in jedem Test an einen Parameter zu denken, sondern
    // dem Testprozess den Produktivpfad gar nicht erst zu geben. Ein Redirect an dieser
    // einen Stelle isoliert alle abgeleiteten Pfade auf einmal — jetzige wie künftige
    // Tests, ohne dass jemand daran denken muss.
    //
    // NICHT abgedeckt: `~/Library/Application Support/com.maik.simplebanking/`
    // (Logo-Cache, Themes, `state.json`), `.cachesDirectory` und `~/Library/Logs/`.
    // Dort liegen keine Finanzdaten. Wer dort neue Persistenz aufhängt, hat sie nicht
    // isoliert — der Wächter-Test `AppSupportSandboxGuardTests` deckt nur diese Wurzel.

    private static let _baseDirLock = NSLock()
    nonisolated(unsafe) private static var _baseDirectoryOverride: URL?

    /// Setzt das Basisverzeichnis prozessweit um. Für Tests, die einen definierten
    /// Startzustand brauchen; im Normalfall genügt der automatische Test-Redirect.
    static var baseDirectoryOverride: URL? {
        get { _baseDirLock.lock(); defer { _baseDirLock.unlock() }; return _baseDirectoryOverride }
        set { _baseDirLock.lock(); defer { _baseDirLock.unlock() }; _baseDirectoryOverride = newValue }
    }

    /// Läuft dieser Prozess unter XCTest?
    ///
    /// `NSClassFromString("XCTestCase")` ist keine Heuristik, sondern eine
    /// Linker-Garantie: das Test-Bundle linkt `libXCTestSwiftSupport.dylib` → `XCTestCore`
    /// HART (nicht weak), dyld lädt die Klasse also vor `main`. Umgekehrt linkt keines der
    /// ausgelieferten Executables XCTest — im Produktions-Binary kann das nie anschlagen.
    /// Die Bundle-ID des SwiftPM-Runners ist das zweite unabhängige Signal (sie ist auch
    /// der Grund, warum `UserDefaults.standard` im Test nicht in der App-Domain landet).
    /// Die Env-Variable ist ein drittes Extra — dass SwiftPM sie setzt, ist NICHT belegt,
    /// also darf sie nie allein tragen.
    ///
    /// Bewusst kein `#if DEBUG`: `swift test -c release` liefe sonst ohne Redirect und
    /// würde die Produktiv-DB genauso zerlegen wie vorher.
    private static var isRunningUnderTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        if Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool" { return true }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Einmal pro Prozess ausgewertet (`static let` = lazy + thread-safe).
    /// In Produktion `nil` — der Redirect existiert dort nicht.
    ///
    /// PID + UUID im Namen, kein fester Pfad: `swift test --parallel` startet mehrere
    /// `xctest`-Prozesse, die sich sonst gegenseitig die Sandbox zerlegen würden.
    private static let processSandboxURL: URL? = {
        guard isRunningUnderTests else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simplebanking-tests", isDirectory: true)
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        // Wenn diese Zeile je in einem KUNDEN-Log auftaucht, ist der Redirect
        // fälschlich aktiv und die App sieht leer aus — dann ist es wenigstens sichtbar
        // statt still.
        AppLogger.log("Test-Sandbox aktiv: App-Support umgeleitet nach \(url.path)",
                      category: "Credentials", level: "WARN")
        return url
    }()

    static func appSupportURL() throws -> URL {
        let fm = FileManager.default
        let appDir: URL
        if let override = baseDirectoryOverride {
            appDir = override
        } else if let envPath = ProcessInfo.processInfo.environment["SIMPLEBANKING_APP_SUPPORT_DIR"],
                  !envPath.isEmpty {
            appDir = URL(fileURLWithPath: envPath, isDirectory: true)
        } else if let sandbox = processSandboxURL {
            appDir = sandbox
        } else {
            let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
            appDir = dir.appendingPathComponent("simplebanking", isDirectory: true)
        }
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }

    /// Dateiname der globalen Credentials aus der Zeit vor Multibanking.
    private static let legacyGlobalFileName = "credentials.json"

    static func defaultURL() throws -> URL {
        let appDir = try appSupportURL()
        let slotFile = appDir.appendingPathComponent("credentials-\(activeSlotId).json")
        // Legacy-Fallback NUR für den Legacy-Slot selbst.
        //
        // Vorher galt er für JEDEN Slot ohne eigene Datei — ein frisch angelegtes
        // Konto meldete dadurch `exists() == true`, und `load()` lieferte die
        // Zugangsdaten des ALTEN Kontos (das Master-Passwort ist global, die
        // Entschlüsselung gelang). In einer Multibanking-App heißt das: Anmeldung
        // bei der falschen Bank — und mit drei Fehlversuchen ein gesperrter Zugang.
        // `delete()` traf im selben Fall die globale statt der Slot-Datei.
        //
        // `migrateLegacyFileIfNeeded()` räumt die globale Datei beim Start weg;
        // dieser Zweig ist nur noch die Brücke für den Moment davor.
        if activeSlotId == "legacy", !FileManager.default.fileExists(atPath: slotFile.path) {
            let legacyFile = appDir.appendingPathComponent(legacyGlobalFileName)
            if FileManager.default.fileExists(atPath: legacyFile.path) {
                return legacyFile
            }
        }
        return slotFile
    }

    /// Unterverzeichnis für beiseitegelegte Credential-Dateien. Verzeichnis statt
    /// Namenssuffix, damit `anyExists()` (listet nur die oberste Ebene) den
    /// Onboarding-Trigger nicht fälschlich unterdrückt — und damit `deleteAllData()`
    /// es mit einem `removeItem` erwischt.
    private static let quarantineDirName = "quarantine"

    /// Strukturelle Prüfung OHNE Master-Passwort: spiegelt genau die Bedingungen, an
    /// denen `load()` scheitern würde, bevor es überhaupt zur Entschlüsselung kommt.
    /// Die festen Längen stammen aus `save()` (Salt 16, `AES.GCM.Nonce` 12, GCM-Tag 16).
    private static func isUsableEnvelope(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.v == 1 || env.v == currentVersion,
              let salt = Data(base64Encoded: env.saltB64),
              let nonce = Data(base64Encoded: env.nonceB64),
              let ciphertext = Data(base64Encoded: env.ciphertextB64),
              let tag = Data(base64Encoded: env.tagB64)
        else { return false }
        return salt.count == 16 && nonce.count == 12 && tag.count == 16 && !ciphertext.isEmpty
    }

    /// Verschiebt eine Datei in die Quarantäne, statt sie zu löschen.
    private static func quarantine(_ url: URL, reason: String) {
        guard let appDir = try? appSupportURL() else { return }
        let fm = FileManager.default
        let dir = appDir.appendingPathComponent(quarantineDirName, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: url, to: target)
            AppLogger.log("Credentials: \(url.lastPathComponent) → quarantine/ (\(reason))",
                          category: "Credentials")
        } catch {
            AppLogger.log("Credentials: Quarantäne für \(url.lastPathComponent) fehlgeschlagen: \(error.localizedDescription)",
                          category: "Credentials", level: "WARN")
        }
    }

    /// Einmalige Migration `credentials.json` → `credentials-legacy.json`.
    ///
    /// Beseitigt die Quelle des slot-übergreifenden Fallbacks (siehe `defaultURL`).
    /// Idempotent: ohne globale Datei passiert nichts.
    ///
    /// **Entschieden wird nach Inhalt, nicht nach Alter.** Die frühere Fassung löschte
    /// die globale Datei, sobald die Slot-Datei `size > 0` hatte — eine abgeschnittene
    /// oder korrupte Datei erfüllt das. Und sie shadowt die gültige globale, weil
    /// `defaultURL()` nur `fileExists` prüft: der Nutzer sah „Zugangsdaten beschädigt"
    /// und hatte danach keine zweite Kopie mehr. Die frühere Begründung („die globale
    /// ist der ältere Stand, weil `save()` seit jeher slot-spezifisch schreibt") stimmt
    /// außerdem nicht: bis zum Multibanking-Umbau schrieb `save()` nach `defaultURL()`,
    /// also nach `credentials.json`.
    static func migrateLegacyFileIfNeeded() {
        guard let appDir = try? appSupportURL() else { return }
        let fm = FileManager.default
        let globalFile = appDir.appendingPathComponent(legacyGlobalFileName)
        guard fm.fileExists(atPath: globalFile.path) else { return }
        let slotFile = appDir.appendingPathComponent("credentials-legacy.json")

        guard fm.fileExists(atPath: slotFile.path) else {
            // Normalfall: umbenennen, damit der Inhalt erhalten bleibt. Hier wird
            // bewusst NICHT validiert — es gibt keine Alternative, und eine kaputte
            // Datei zu behalten ist besser, als sie wegzuwerfen.
            do {
                try fm.moveItem(at: globalFile, to: slotFile)
                AppLogger.log("Credentials: credentials.json → credentials-legacy.json migriert",
                              category: "Credentials")
            } catch {
                AppLogger.log("Credentials-Migration fehlgeschlagen: \(error.localizedDescription)",
                              category: "Credentials", level: "WARN")
            }
            return
        }

        switch (isUsableEnvelope(at: slotFile), isUsableEnvelope(at: globalFile)) {
        case (true, _):
            // Slot-Datei trägt — die globale ist nur noch eine Fehlerquelle.
            quarantine(globalFile, reason: "Slot-Datei ist gültig")

        case (false, true):
            // Rettung. Reihenfolge ist ZWINGEND: erst die kaputte Slot-Datei beiseite,
            // dann die gültige globale an ihren Platz. Beide Schritte sind einzelne
            // `rename(2)` auf demselben Volume, also je atomar — und das Fenster
            // dazwischen ist von selbst korrekt, weil `defaultURL()` für `legacy` genau
            // dann auf `credentials.json` zurückfällt. Ein Absturz dazwischen
            // hinterlässt einen funktionierenden Zustand, der nächste Start wiederholt
            // die Migration.
            AppLogger.log("Credentials: credentials-legacy.json ist unbrauchbar, stelle aus credentials.json wieder her",
                          category: "Credentials", level: "WARN")
            quarantine(slotFile, reason: "unbrauchbarer Envelope")
            guard !fm.fileExists(atPath: slotFile.path) else { return }
            do {
                try fm.moveItem(at: globalFile, to: slotFile)
            } catch {
                AppLogger.log("Credentials: Wiederherstellung fehlgeschlagen: \(error.localizedDescription)",
                              category: "Credentials", level: "WARN")
            }

        case (false, false):
            // Nichts anfassen. Beide behalten ist die einzige Chance, dass der Nutzer
            // (oder ein Backup) daraus noch etwas rettet.
            AppLogger.log("Credentials: weder credentials-legacy.json noch credentials.json sind lesbare Envelopes — beide bleiben unverändert",
                          category: "Credentials", level: "WARN")
        }
    }

    static func exists() -> Bool {
        (try? defaultURL()).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// True, wenn IRGENDEIN Slot Credentials hat (inkl. Legacy-`credentials.json`).
    /// Für den Onboarding-Trigger: ein aktiver Slot OHNE eigene Credentials-Datei
    /// (z. B. ein REWE-eBon-Slot) darf NICHT die Ersteinrichtung auslösen, solange
    /// ein Bank-Slot bereits eingerichtet ist (`exists()` prüft nur den aktiven Slot).
    static func anyExists() -> Bool {
        guard let appDir = try? appSupportURL(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: appDir.path) else { return false }
        return names.contains { $0.hasPrefix("credentials") && $0.hasSuffix(".json") }
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
        // Quarantäne mitnehmen — dort liegen verschlüsselte Credential-Kopien, die die
        // Migration beiseitegelegt hat. Ohne diese Zeile überlebte eine davon das
        // vollständige Zurücksetzen.
        try? fm.removeItem(at: appDir.appendingPathComponent(quarantineDirName))
    }

    /// Wie mit dem Legacy-Slot zu verfahren ist.
    ///
    /// Bewusst **ohne Default-Wert**: der Unterschied zwischen den beiden Fällen ist
    /// „Zugangsdaten bleiben" und „Zugangsdaten sind weg". Ein neuer Aufrufer soll das
    /// hinschreiben müssen, statt die scharfe Variante versehentlich zu erben.
    enum LegacySlotPolicy {
        /// Legacy-Dateien nicht anfassen — für alles, was keine ausdrückliche
        /// Nutzerentscheidung ist (Migrationen, Aufräumarbeiten, Demo-Wechsel).
        case protect
        /// Legacy-Dateien mitlöschen — nur, wenn der Nutzer das Entfernen des Kontos
        /// im Dialog bestätigt hat.
        case delete
    }

    /// Löscht die `credentials-<slotId>.json` für einen entfernten Slot.
    /// Best-effort: Fehler werden ignoriert (Datei könnte schon weg sein).
    static func deleteSlotFile(slotId: String, legacyPolicy: LegacySlotPolicy) {
        guard let appDir = try? appSupportURL() else { return }
        let fm = FileManager.default

        guard slotId == "legacy" else {
            try? fm.removeItem(at: appDir.appendingPathComponent("credentials-\(slotId).json"))
            return
        }

        guard case .delete = legacyPolicy else { return }

        // BEIDE Dateien — sonst steht das Konto nach dem Entfernen wieder da:
        // `defaultURL()` fällt für `legacy` auf die globale `credentials.json` zurück,
        // sobald die Slot-Datei fehlt (:79-84). Liegt die globale noch herum, weil die
        // Migration nie lief oder ihr `moveItem` fehlschlug, meldet `exists()` danach
        // wieder `true` und `load()` entschlüsselt die alten Zugangsdaten — während der
        // Dialog „unwiderruflich gelöscht" versprochen hat.
        try? fm.removeItem(at: appDir.appendingPathComponent("credentials-legacy.json"))
        try? fm.removeItem(at: appDir.appendingPathComponent(legacyGlobalFileName))
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
