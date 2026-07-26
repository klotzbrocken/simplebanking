import XCTest
@testable import simplebanking

// MARK: - Wächter: Tests dürfen die echten Nutzerdaten nicht anfassen
//
// Bis 2.0 löschte `swift test` die produktive `transactions.db` (fehlender
// `bankId:`-Parameter in `LLMAllPlansSmokeTests`) und hantierte mit den echten
// `credentials*.json`. Beides ist unwiederbringlich: Notizen, Anhänge, Aufrund-Töpfe
// und eBons liefert keine Bank zurück, und gelöschte Zugangsdaten bedeuten im
// schlimmsten Fall eine gesperrte Bankverbindung.
//
// Behoben ist das durch den Redirect in `CredentialsStore.appSupportURL()`. Diese
// Testklasse ist die Versicherung dafür: schlägt sie fehl, ist der Redirect ausgefallen
// UND der nächste Testlauf schreibt wieder in echte Nutzerdaten. Sie ist deshalb
// wertlos, wenn sie je „nur mal eben" deaktiviert wird.

final class AppSupportSandboxGuardTests: XCTestCase {

    /// Der Produktivpfad wird über dieselbe `FileManager`-API neu abgeleitet statt
    /// hartkodiert — genau das ist die Aussage, die der Test treffen soll („nicht dort,
    /// wo macOS Application Support hinlegt"). `create: false`, damit der Test das
    /// Verzeichnis nicht selbst anlegt.
    private func productionDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: false)
            .appendingPathComponent("simplebanking", isDirectory: true)
            .standardizedFileURL
    }

    func test_appSupportURL_zeigtNichtAufDasEchteVerzeichnis() throws {
        let real = try productionDirectory().path
        let used = try CredentialsStore.appSupportURL().standardizedFileURL.path

        XCTAssertNotEqual(used, real,
                          "Der Testprozess arbeitet im echten App-Support-Verzeichnis")
        XCTAssertFalse(used.hasPrefix(real + "/"),
                       "Auch ein Unterverzeichnis des echten Ordners ist nicht erlaubt")
    }

    /// Der eigentlich wertvolle Test: er bricht, sobald jemand eine neue Persistenz an
    /// einer eigenen Pfadwurzel aufhängt, statt sie von `appSupportURL()` abzuleiten.
    func test_alleAbgeleitetenPfadeLiegenUnterhalbDerSandbox() throws {
        let base = try CredentialsStore.appSupportURL().standardizedFileURL.path + "/"

        let derived: [(String, String)] = [
            ("CredentialsStore.defaultURL", try CredentialsStore.defaultURL().standardizedFileURL.path),
            ("TransactionsDatabase.databaseURL(primary)",
             try TransactionsDatabase.databaseURL().standardizedFileURL.path),
            ("TransactionsDatabase.databaseURL(bankId:)",
             try TransactionsDatabase.databaseURL(bankId: "guard-probe").standardizedFileURL.path),
            ("TransferDraftStore.directoryURL",
             try TransferDraftStore.directoryURL().standardizedFileURL.path),
        ]

        for (name, path) in derived {
            XCTAssertTrue(path.hasPrefix(base),
                          "\(name) liegt außerhalb der Sandbox: \(path)")
        }
    }

    /// `databaseURL()` ohne Argument ist der Pfad, den die laufende App benutzt — und
    /// der, den ein vergessener `bankId:`-Parameter trifft. Explizit festhalten.
    func test_defaultBankIdTrifftNichtDieEchteDatenbank() throws {
        let realDB = try productionDirectory()
            .appendingPathComponent("transactions.db").path
        XCTAssertNotEqual(try TransactionsDatabase.databaseURL().standardizedFileURL.path, realDB)
    }
}
