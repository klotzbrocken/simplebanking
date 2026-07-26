import XCTest
@testable import simplebanking

// MARK: - Legacy-Credential-Fallback
//
// `defaultURL()` fiel früher für JEDEN Slot ohne eigene Datei auf die globale
// `credentials.json` zurück. Folge: ein frisch angelegtes Konto meldete
// `exists() == true` und `load()` lieferte die Zugangsdaten des ALTEN Kontos —
// in einer Multibanking-App die Anmeldung bei der falschen Bank.
//
// Die Tests hantieren mit echten Credential-Dateien. Dass das gefahrlos ist, hängt
// vollständig am Test-Redirect in `CredentialsStore.appSupportURL()` — vorher sicherten
// sie die produktiven Dateien weg und stellten sie im `tearDown` wieder her, was bei
// jedem Abbruch die Zugangsdaten des Nutzers verloren hätte. Fällt der Redirect aus,
// schlägt `AppSupportSandboxGuardTests` fehl; darauf verlässt sich diese Datei.

final class CredentialsLegacyFallbackTests: XCTestCase {

    private var appDir: URL!
    private var globalFile: URL!
    private var legacySlotFile: URL!
    private var otherSlotFile: URL!
    private let otherSlot = "slot-test-fallback"

    override func setUpWithError() throws {
        appDir = try CredentialsStore.appSupportURL()
        globalFile = appDir.appendingPathComponent("credentials.json")
        legacySlotFile = appDir.appendingPathComponent("credentials-legacy.json")
        otherSlotFile = appDir.appendingPathComponent("credentials-\(otherSlot).json")

        // Die Sandbox gilt pro PROZESS, nicht pro Testklasse: Rückstände anderer
        // Klassen (die dieselben Dateinamen benutzen) würden sonst hereinlecken.
        let files = [globalFile!, legacySlotFile!, otherSlotFile!]
        for url in files { try? FileManager.default.removeItem(at: url) }

        // `addTeardownBlock` statt `tearDownWithError`: läuft auch, wenn oberhalb
        // etwas wirft.
        let quarantine = appDir.appendingPathComponent("quarantine", isDirectory: true)
        try? FileManager.default.removeItem(at: quarantine)

        addTeardownBlock {
            for url in files { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: quarantine)
            CredentialsStore.activeSlotId = "legacy"
        }
    }

    private func write(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    // MARK: defaultURL

    func test_foreignSlot_doesNotFallBackToGlobalFile() throws {
        try write(globalFile, "ALTES-KONTO")
        CredentialsStore.activeSlotId = otherSlot

        let url = try CredentialsStore.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "credentials-\(otherSlot).json",
                       "Ein fremder Slot darf NIE auf credentials.json zeigen")
        XCTAssertFalse(CredentialsStore.exists(),
                       "Ein Slot ohne eigene Datei hat keine Credentials")
    }

    func test_legacySlot_stillFallsBackUntilMigrated() throws {
        try write(globalFile, "ALTES-KONTO")
        CredentialsStore.activeSlotId = "legacy"

        let url = try CredentialsStore.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "credentials.json",
                       "Übergangsfall: der Legacy-Slot findet seine Altdatei weiter")
        XCTAssertTrue(CredentialsStore.exists())
    }

    func test_slotFileWins_whenBothExist() throws {
        try write(globalFile, "ALT")
        try write(legacySlotFile, "NEU")
        CredentialsStore.activeSlotId = "legacy"

        XCTAssertEqual(try CredentialsStore.defaultURL().lastPathComponent,
                       "credentials-legacy.json")
    }

    // MARK: Migration

    func test_migration_renamesGlobalToSlotFile() throws {
        try write(globalFile, "INHALT-BLEIBT")

        CredentialsStore.migrateLegacyFileIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFile.path),
                       "Die globale Datei ist danach weg — sonst bleibt der Fallback-Pfad offen")
        XCTAssertEqual(try String(contentsOf: legacySlotFile, encoding: .utf8), "INHALT-BLEIBT",
                       "Der Inhalt muss erhalten bleiben (Umbenennen, nicht Löschen)")
    }

    // MARK: Migration bei zwei vorhandenen Dateien
    //
    // Hier wird nach INHALT entschieden, nicht nach Alter: die frühere Fassung löschte
    // die globale Datei, sobald die Slot-Datei `size > 0` hatte — was eine
    // abgeschnittene oder korrupte Datei ebenfalls erfüllt. Da `defaultURL()` nur
    // `fileExists` prüft, shadowt so eine Datei die gültige globale, und mit deren
    // Löschung war der Zustand unrettbar. Die Fixtures sind deshalb echte Envelopes
    // aus der Produktions-API, kein Klartext.

    private let masterPassword = "test-master-pw"

    /// Erzeugt über `save()` einen echten Envelope und liefert seinen Inhalt.
    private func makeEnvelopeData(iban: String) throws -> Data {
        CredentialsStore.activeSlotId = "legacy"
        try CredentialsStore.save(
            StoredCredentials(iban: iban, userId: "user-\(iban.suffix(4))", password: "pw"),
            masterPassword: masterPassword)
        let data = try Data(contentsOf: legacySlotFile)
        try FileManager.default.removeItem(at: legacySlotFile)
        return data
    }

    private var quarantineDir: URL { appDir.appendingPathComponent("quarantine", isDirectory: true) }

    func test_migration_gueltigeSlotDatei_globaleWandertInQuarantaene() throws {
        let slotData = try makeEnvelopeData(iban: "DE02120300000000202051")
        let globalData = try makeEnvelopeData(iban: "DE02100500000054540402")
        try slotData.write(to: legacySlotFile)
        try globalData.write(to: globalFile)

        CredentialsStore.migrateLegacyFileIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFile.path),
                       "Die globale Datei darf den Fallback-Pfad nicht offen halten")
        XCTAssertEqual(try Data(contentsOf: legacySlotFile), slotData,
                       "Der Slot-Stand darf nicht überschrieben werden")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: quarantineDir.appendingPathComponent("credentials.json").path),
                      "Gelöscht wird nichts — beiseitegelegt")
    }

    /// Die tragende Assertion dieses Pakets: nach der Migration müssen die Zugangsdaten
    /// wieder ENTSCHLÜSSELBAR sein, nicht bloß irgendeine Datei vorhanden.
    func test_migration_kaputteSlotDatei_gueltigeGlobale_wirdGerettet() throws {
        let globalData = try makeEnvelopeData(iban: "DE02100500000054540402")
        try globalData.write(to: globalFile)
        // Abgeschnittener Envelope: nicht leer (die alte Größenprüfung hätte ihn
        // durchgewinkt), aber kein dekodierbares JSON.
        try globalData.prefix(40).write(to: legacySlotFile)

        CredentialsStore.migrateLegacyFileIfNeeded()

        CredentialsStore.activeSlotId = "legacy"
        XCTAssertEqual(try CredentialsStore.defaultURL().lastPathComponent,
                       "credentials-legacy.json")
        let restored = try CredentialsStore.load(masterPassword: masterPassword)
        XCTAssertEqual(restored.iban, "DE02100500000054540402",
                       "Die brauchbare Kopie muss den Platz der kaputten eingenommen haben")
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFile.path))
    }

    func test_migration_beideKaputt_laesstAllesUnveraendert() throws {
        try write(globalFile, "MUELL-1")
        try write(legacySlotFile, "MUELL-2")

        CredentialsStore.migrateLegacyFileIfNeeded()

        XCTAssertEqual(try String(contentsOf: globalFile, encoding: .utf8), "MUELL-1",
                       "Ohne brauchbare Alternative wird nichts weggeworfen")
        XCTAssertEqual(try String(contentsOf: legacySlotFile, encoding: .utf8), "MUELL-2")
    }

    /// Die Envelope-Prüfung selbst ist privat — getestet wird sie über das Verhalten,
    /// das sie steuert: bei einer unbrauchbaren Slot-Datei muss die gültige globale
    /// gewinnen. Jede Zeile hier wäre an der alten Größenprüfung (`size > 0`)
    /// vorbeigekommen.
    func test_migration_erkenntUnbrauchbareSlotDateien() throws {
        let globalData = try makeEnvelopeData(iban: "DE02100500000054540402")
        let env = try XCTUnwrap(try? JSONSerialization.jsonObject(with: globalData) as? [String: Any])

        func mutated(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var copy = env
            change(&copy)
            return try JSONSerialization.data(withJSONObject: copy)
        }

        let kaputt: [(String, Data)] = [
            ("kein JSON",            Data("nicht mal JSON".utf8)),
            ("JSON ohne Felder",     Data("{}".utf8)),
            ("unbekannte Version",   try mutated { $0["v"] = 99 }),
            ("Base64-Müll",          try mutated { $0["ciphertextB64"] = "!!!kein-base64!!!" }),
            ("leerer Ciphertext",    try mutated { $0["ciphertextB64"] = "" }),
            ("Nonce zu kurz",        try mutated { $0["nonceB64"] = Data(repeating: 0, count: 11).base64EncodedString() }),
        ]

        for (label, data) in kaputt {
            try data.write(to: legacySlotFile)
            try globalData.write(to: globalFile)

            CredentialsStore.migrateLegacyFileIfNeeded()

            CredentialsStore.activeSlotId = "legacy"
            XCTAssertEqual(try? CredentialsStore.load(masterPassword: masterPassword).iban,
                           "DE02100500000054540402",
                           "\(label): die gültige Kopie hätte gewinnen müssen")
            try? FileManager.default.removeItem(at: quarantineDir)
        }
    }

    /// Sonst überlebte eine verschlüsselte Credentials-Kopie das „alles löschen".
    func test_deleteAllData_raeumtDieQuarantaene() throws {
        let slotData = try makeEnvelopeData(iban: "DE02120300000000202051")
        try slotData.write(to: legacySlotFile)
        try slotData.write(to: globalFile)
        CredentialsStore.migrateLegacyFileIfNeeded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineDir.path),
                      "Vorbedingung: die Quarantäne existiert")

        CredentialsStore.deleteAllData()

        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineDir.path))
    }

    func test_migration_isIdempotentAndSafeWithoutGlobalFile() throws {
        XCTAssertNoThrow(CredentialsStore.migrateLegacyFileIfNeeded())
        try write(globalFile, "X")
        CredentialsStore.migrateLegacyFileIfNeeded()
        CredentialsStore.migrateLegacyFileIfNeeded()   // zweiter Lauf: no-op
        XCTAssertEqual(try String(contentsOf: legacySlotFile, encoding: .utf8), "X")
    }

    /// Nach der Migration greift der Fallback auch für den Legacy-Slot nicht mehr —
    /// es gibt schlicht keine globale Datei mehr.
    func test_afterMigration_noSlotSeesGlobalFile() throws {
        try write(globalFile, "ALT")
        CredentialsStore.migrateLegacyFileIfNeeded()

        CredentialsStore.activeSlotId = otherSlot
        XCTAssertEqual(try CredentialsStore.defaultURL().lastPathComponent,
                       "credentials-\(otherSlot).json")
        XCTAssertFalse(CredentialsStore.exists())
    }
}
