import XCTest
@testable import simplebanking

// MARK: - Slot-Removal Cleanup tests
//
// Schützt P3.2 + P3.3: nach removeSlot() müssen alle slot-suffixed
// Persistenz-Spuren weg sein. Sonst leakt der entfernte Slot:
//  - cachedBalance.<id> + lastSeenTxSig.<id> als UserDefaults-Bloat
//  - credentials-<id>.json als dead file auf Platte (encrypted, aber dead)
//  - YAXI session/connectionData (sensitive!)

@MainActor
final class SlotRemovalCleanupTests: XCTestCase {

    // MARK: - UserDefaults cleanup

    func test_purgePerSlotData_removesCachedBalance() {
        let slotId = "test-purge-\(UUID().uuidString.prefix(6))"
        let key = "simplebanking.cachedBalance.\(slotId)"
        UserDefaults.standard.set(1234.56, forKey: key)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key),
            "Sanity: balance war gesetzt")

        MultibankingStore.purgePerSlotData(slotId: slotId)

        XCTAssertNil(UserDefaults.standard.object(forKey: key),
            "cachedBalance.\(slotId) muss nach Purge weg sein — sonst Bloat-Leak")
    }

    func test_purgePerSlotData_removesLastSeenTxSig() {
        let slotId = "test-purge-\(UUID().uuidString.prefix(6))"
        let key = "simplebanking.lastSeenTxSig.\(slotId)"
        UserDefaults.standard.set("some-fingerprint", forKey: key)

        MultibankingStore.purgePerSlotData(slotId: slotId)

        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func test_purgePerSlotData_doesNotTouchOtherSlots() {
        // Räumt slot A auf, slot B bleibt unberührt — kritisch, sonst kann
        // ein Slot-Remove versehentlich nachbar-slots löschen.
        let slotA = "test-purge-A-\(UUID().uuidString.prefix(4))"
        let slotB = "test-purge-B-\(UUID().uuidString.prefix(4))"
        UserDefaults.standard.set(100.0, forKey: "simplebanking.cachedBalance.\(slotA)")
        UserDefaults.standard.set(200.0, forKey: "simplebanking.cachedBalance.\(slotB)")

        MultibankingStore.purgePerSlotData(slotId: slotA)

        XCTAssertNil(UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slotA)"))
        XCTAssertNotNil(UserDefaults.standard.object(forKey: "simplebanking.cachedBalance.\(slotB)"),
            "Slot B darf vom Slot-A-Purge unberührt bleiben")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "simplebanking.cachedBalance.\(slotB)")
    }

    // MARK: - CredentialsStore.deleteSlotFile

    /// Legt beide Legacy-Dateien an und räumt sie hinterher weg. Ein Backup der echten
    /// Dateien braucht es nicht mehr — der Redirect in `appSupportURL()` hält uns von
    /// den Nutzerdaten fern; aufgeräumt wird trotzdem, weil die Sandbox pro PROZESS
    /// gilt und die Dateien sonst in andere Testklassen lecken.
    private func makeLegacyFiles() throws -> (slot: URL, global: URL) {
        let appDir = try CredentialsStore.appSupportURL()
        // Fremde Credential-Dateien aus der Sandbox räumen, damit `anyExists()`
        // (verzeichnisweit) nicht an Rückständen anderer Testklassen hängt.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: appDir.path)) ?? []
        where name.hasPrefix("credentials") && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: appDir.appendingPathComponent(name))
        }
        let slot = appDir.appendingPathComponent("credentials-legacy.json")
        let global = appDir.appendingPathComponent("credentials.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: slot)
            try? FileManager.default.removeItem(at: global)
            CredentialsStore.activeSlotId = "legacy"
        }
        try Data("SCHUETZENSWERT".utf8).write(to: slot)
        try Data("AUCH-SCHUETZENSWERT".utf8).write(to: global)
        return (slot, global)
    }

    /// Der Schutz muss an der DATEI nachweisbar sein, nicht nur „kein Absturz".
    /// Die alte Fassung dieses Tests war grün, während `SettingsPanel.deleteSlot`
    /// die Datei per `removeItem` an der Schutzklausel vorbei löschte.
    func test_deleteSlotFile_protect_laesstLegacyDateienStehen() throws {
        let (slot, global) = try makeLegacyFiles()

        CredentialsStore.deleteSlotFile(slotId: "legacy", legacyPolicy: .protect)

        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.path),
                      "Ohne ausdrückliche Nutzerentscheidung bleibt die Legacy-Datei")
        XCTAssertTrue(FileManager.default.fileExists(atPath: global.path))
    }

    /// Die globale Altdatei muss mit — sonst holt der Legacy-Fallback in `defaultURL()`
    /// das entfernte Konto zurück, sobald die Slot-Datei fehlt.
    func test_deleteSlotFile_delete_loeschtBeideLegacyDateien() throws {
        let (slot, global) = try makeLegacyFiles()

        CredentialsStore.deleteSlotFile(slotId: "legacy", legacyPolicy: .delete)

        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: global.path),
                       "Bleibt credentials.json liegen, ist das Konto über den Fallback wieder da")
    }

    func test_deleteSlotFile_removesNonLegacyFile() throws {
        let slotId = "test-del-\(UUID().uuidString.prefix(6))"
        let appDir = try CredentialsStore.appSupportURL()
        let file = appDir.appendingPathComponent("credentials-\(slotId).json")
        try Data("WEG-DAMIT".utf8).write(to: file)

        CredentialsStore.deleteSlotFile(slotId: slotId, legacyPolicy: .protect)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Die Aussage, die der Nutzer im Dialog liest

    /// Der Bestätigungsdialog verspricht „und alle zugehörigen Daten werden
    /// unwiderruflich gelöscht". Diese Assertion prüft genau das — und nicht bloß, ob
    /// eine bestimmte Datei verschwunden ist: `exists()` geht durch `defaultURL()` und
    /// fällt damit auch über die globale Altdatei wieder auf ein Konto zurück.
    func test_purgePerSlotData_legacy_kontoIstDanachWirklichWeg() throws {
        _ = try makeLegacyFiles()

        MultibankingStore.purgePerSlotData(slotId: "legacy")

        CredentialsStore.activeSlotId = "legacy"
        XCTAssertFalse(CredentialsStore.exists(),
                       "Nach dem Entfernen darf kein Weg mehr zu Zugangsdaten führen")
        XCTAssertFalse(CredentialsStore.anyExists())
    }

    /// Gegenprobe: das Entfernen eines anderen Kontos lässt Legacy in Ruhe.
    func test_purgePerSlotData_fremderSlot_laesstLegacyUnberuehrt() throws {
        let (slot, global) = try makeLegacyFiles()

        MultibankingStore.purgePerSlotData(slotId: "test-fremd-\(UUID().uuidString.prefix(6))")

        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: global.path))
    }

    // MARK: - Zentrales Aufräumen (nach Zusammenführung der Löschpfade)

    /// `SettingsPanel.deleteSlot` löschte diese Keys früher selbst — mit einer
    /// hartkodierten Liste, die für `legacy` fälschlich `.legacy` anhängte, während
    /// `YaxiService` dort gar kein Suffix nutzt. Jetzt bilden beide Seiten die Keys
    /// über dieselben Builder.
    func test_purgePerSlotData_removesYaxiKeys_normalSlot() {
        let slotId = "test-keys-\(UUID().uuidString.prefix(6))"
        let keys = [
            YaxiService.ibanKey(for: slotId),
            YaxiService.connectionIdKey(for: slotId),
            YaxiService.credModelFullKey(for: slotId),
            YaxiService.credModelUserIdKey(for: slotId),
            YaxiService.credModelNoneKey(for: slotId),
        ]
        for key in keys { UserDefaults.standard.set("x", forKey: key) }

        MultibankingStore.purgePerSlotData(slotId: slotId)

        for key in keys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "übrig geblieben: \(key)")
        }
    }

    /// Der Legacy-Slot nutzt suffixlose Keys — genau der Fall, den die alte
    /// hartkodierte Liste verfehlte.
    func test_purgePerSlotData_removesYaxiKeys_legacySlotUsesUnsuffixedNames() {
        let key = YaxiService.connectionIdKey(for: "legacy")
        XCTAssertEqual(key, "simplebanking.yaxi.connectionId",
                       "Legacy-Keys tragen kein Suffix — daran scheiterte die alte Liste")
        let backup = UserDefaults.standard.string(forKey: key)
        defer { if let backup { UserDefaults.standard.set(backup, forKey: key) } }
        UserDefaults.standard.set("conn-123", forKey: key)

        MultibankingStore.purgePerSlotData(slotId: "legacy")

        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    func test_purgePerSlotData_removesSlotSettings() {
        let slotId = "test-settings-\(UUID().uuidString.prefix(6))"
        var settings = BankSlotSettingsStore.load(slotId: slotId)
        settings.fetchDays = 42
        BankSlotSettingsStore.save(settings, slotId: slotId)
        XCTAssertEqual(BankSlotSettingsStore.load(slotId: slotId).fetchDays, 42, "Sanity")

        MultibankingStore.purgePerSlotData(slotId: slotId)

        XCTAssertNotEqual(BankSlotSettingsStore.load(slotId: slotId).fetchDays, 42,
                          "Slot-Einstellungen müssen mit weg — sie hingen vorher nur am Settings-Pfad")
    }
}
