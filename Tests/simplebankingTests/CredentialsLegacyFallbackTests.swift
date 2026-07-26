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
        addTeardownBlock {
            for url in files { try? FileManager.default.removeItem(at: url) }
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

    func test_migration_removesStaleGlobalWhenSlotFileHasContent() throws {
        try write(globalFile, "ALT")
        try write(legacySlotFile, "AKTUELL")

        CredentialsStore.migrateLegacyFileIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFile.path))
        XCTAssertEqual(try String(contentsOf: legacySlotFile, encoding: .utf8), "AKTUELL",
                       "Der neuere Slot-Stand darf nicht überschrieben werden")
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
