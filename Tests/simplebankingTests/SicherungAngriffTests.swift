import XCTest
import Foundation
import GRDB
@testable import simplebanking

// MARK: - Eine Sicherung ist eine Datei von außen
//
// Wer sie erstellt, bestimmt jeden Namen darin. Die Verschlüsselung schützt davor nicht:
// Er liefert die Passphrase mit („hier, spiel das ein, das Kennwort ist X"). Genau diese
// Lage bauen diese Tests nach — mit einer echten, korrekt verschlüsselten Datei, nicht
// mit Bruchstücken.
//
// Die entscheidende Zusage steht nicht in der Fehlermeldung, sondern daneben: Wird eine
// Sicherung abgewiesen, darf **nichts** geschrieben worden sein. Vorher schrieb das
// Einspielen zuerst die Einstellungen und stolperte erst danach.

final class SicherungAngriffTests: XCTestCase {

    private let passphrase = "der-angreifer-kennt-sie"
    /// Wird beim Einspielen als Erstes geschrieben — taucht er auf, wurde angefasst.
    private let markierung = "de.simplebanking.tests.angriffsmarkierung"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: markierung)
        try? FileManager.default.removeItem(at: try! TransactionsDatabase.databaseURL())
        try? FileManager.default.removeItem(at: sicherungsOrdner)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: markierung)
        try? FileManager.default.removeItem(at: try! TransactionsDatabase.databaseURL())
        try? FileManager.default.removeItem(at: sicherungsOrdner)
        super.tearDown()
    }

    private var sicherungsOrdner: URL {
        (try! TransactionsDatabase.databaseURL())
            .deletingLastPathComponent()
            .appendingPathComponent("db-sicherungen", isDirectory: true)
    }

    // MARK: Werkzeug

    /// Baut eine echte, korrekt verschlüsselte Sicherung mit frei wählbarem Inhalt —
    /// genau das, was ein Angreifer auch bauen kann.
    private func sicherung(zugangsdaten: [String: String] = [:],
                           themes: [String: String] = [:],
                           anhaenge: [String: String] = [:],
                           datenbank: Data? = nil) throws -> Data {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [markierung: "eingespielt"], format: .binary, options: 0)
        let inhalt = BackupArchive.Inhalt(
            version: BackupArchive.formatVersion,
            erstelltAm: Date(),
            appVersion: "test",
            einstellungenPlistB64: plist.base64EncodedString(),
            zugangsdaten: zugangsdaten,
            datenbankB64: datenbank?.base64EncodedString(),
            themes: themes,
            anhaenge: anhaenge,
            entwuerfe: [:])
        return try BackupArchive.verschluesseln(try JSONEncoder().encode(inhalt),
                                                passphrase: passphrase, merkhilfe: nil)
    }

    private func nutzlast(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// Eine kleine, echte SQLite-Datei mit der erwarteten Tabelle.
    private func datenbank(zeilen: Int) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-quelle-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = try DatabaseQueue(path: tmp.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS transactions (tx_id TEXT PRIMARY KEY)")
            for i in 0..<zeilen {
                try db.execute(sql: "INSERT INTO transactions (tx_id) VALUES (?)", arguments: ["tx-\(i)"])
            }
        }
        return try Data(contentsOf: tmp)
    }

    @discardableResult
    private func vorhandeneDatenbank(zeilen: Int) throws -> Data {
        let ziel = try TransactionsDatabase.databaseURL()
        try FileManager.default.createDirectory(at: ziel.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try datenbank(zeilen: zeilen).write(to: ziel)
        return try Data(contentsOf: ziel)
    }

    /// Die Zusage nach einer Abweisung: nichts angefasst.
    private func nichtsWurdeGeschrieben(_ vorher: Data?, datei: StaticString = #filePath,
                                        zeile: UInt = #line) throws {
        XCTAssertNil(UserDefaults.standard.string(forKey: markierung),
                     "Einstellungen wurden trotz Abweisung geschrieben", file: datei, line: zeile)
        let ziel = try TransactionsDatabase.databaseURL()
        if let vorher {
            XCTAssertEqual(try Data(contentsOf: ziel), vorher,
                           "die vorhandene Datenbank wurde verändert", file: datei, line: zeile)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: ziel.path),
                           "es wurde eine Datenbank angelegt", file: datei, line: zeile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sicherungsOrdner.path),
                       "es wurde eine Rückfallebene angelegt, obwohl nichts geschah",
                       file: datei, line: zeile)
    }

    private func erwarteAbgelehntenPfad<T>(_ block: @autoclosure () throws -> T) {
        XCTAssertThrowsError(try block()) { fehler in
            guard case BackupArchive.Fehler.abgelehnterPfad = fehler else {
                return XCTFail("erwartet: abgelehnterPfad, bekommen: \(fehler)")
            }
        }
    }

    // MARK: Der Angriff

    func test_ausbrechenderZugangsdatenNameSchreibtNichts() throws {
        let ausbruch = try CredentialsStore.appSupportURL()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uebernommen.json")
        try? FileManager.default.removeItem(at: ausbruch)

        let archiv = try sicherung(zugangsdaten: ["../../uebernommen.json": nutzlast("boese")])
        erwarteAbgelehntenPfad(try BackupArchive.einspielen(archiv, passphrase: passphrase))

        XCTAssertFalse(FileManager.default.fileExists(atPath: ausbruch.path),
                       "die Datei landete außerhalb des Datenordners")
        try nichtsWurdeGeschrieben(nil)
    }

    func test_absoluterThemePfadSchreibtNichts() throws {
        let ausbruch = "/tmp/sb-uebernommen-\(UUID().uuidString).css"
        let archiv = try sicherung(themes: [ausbruch: nutzlast("boese")])
        erwarteAbgelehntenPfad(try BackupArchive.einspielen(archiv, passphrase: passphrase))

        XCTAssertFalse(FileManager.default.fileExists(atPath: ausbruch))
        try nichtsWurdeGeschrieben(nil)
    }

    func test_ausbrechenderBelegpfadSchreibtNichts() throws {
        let archiv = try sicherung(anhaenge: ["../../raus.pdf": nutzlast("boese")])
        erwarteAbgelehntenPfad(try BackupArchive.einspielen(archiv, passphrase: passphrase))
        try nichtsWurdeGeschrieben(nil)
    }

    /// Der Fall, der vorher als Erfolg gemeldet wurde: unlesbare Datenbank, „0 Buchungen".
    func test_kaputteDatenbankLaesstDieVorhandeneInRuhe() throws {
        let vorher = try vorhandeneDatenbank(zeilen: 5)
        let archiv = try sicherung(datenbank: Data("das ist keine Datenbank".utf8))

        XCTAssertThrowsError(try BackupArchive.einspielen(archiv, passphrase: passphrase))
        try nichtsWurdeGeschrieben(vorher)
    }

    /// `UInt32(runden)` stürzte bei einem negativen Wert ab — noch bevor irgendeine
    /// Passphrase geprüft war. Läuft dieser Test durch, ist er nicht abgestürzt.
    func test_manipulierteRundenzahlStuerztNichtAbUndSchreibtNichts() throws {
        let kopf = """
        {"v":1,"saltB64":"AAAAAAAAAAAAAAAAAAAAAA==","nonceB64":"AAAAAAAAAAAAAAAA",\
        "ciphertextB64":"AAAA","tagB64":"AAAAAAAAAAAAAAAAAAAAAA==",\
        "kdf":"pbkdf2-sha256","iterations":-1}
        """
        XCTAssertThrowsError(try BackupArchive.einspielen(Data(kopf.utf8), passphrase: "egal"))
        try nichtsWurdeGeschrieben(nil)
    }

    // MARK: Der gute Fall darf nicht kaputtgehen

    func test_guteSicherungLaeuftDurchUndZaehltEhrlich() throws {
        try vorhandeneDatenbank(zeilen: 2)
        let archiv = try sicherung(
            zugangsdaten: ["credentials-legacy.json": nutzlast("{}"),
                           "credentials-zweite.json": nutzlast("{}")],
            themes: ["mein-theme.json": nutzlast("{}")],
            anhaenge: ["slot-1/tx-42/bon.pdf": nutzlast("%PDF")],
            datenbank: try datenbank(zeilen: 3))

        let bericht = try BackupArchive.einspielen(archiv, passphrase: passphrase)

        XCTAssertEqual(bericht.konten, 2, "gezählt wird, was geschrieben wurde")
        XCTAssertEqual(bericht.buchungen, 3)
        XCTAssertEqual(bericht.themes, 1)
        XCTAssertEqual(bericht.anhaenge, 1)
        XCTAssertEqual(UserDefaults.standard.string(forKey: markierung), "eingespielt")

        let ziel = try TransactionsDatabase.databaseURL()
        let queue = try DatabaseQueue(path: ziel.path)
        let zeilen = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions") }
        XCTAssertEqual(zeilen, 3, "die eingespielte Datenbank muss die neue sein")

        // Und die alte liegt datiert daneben, mit ihren zwei Zeilen.
        let abgelegt = ((try? FileManager.default.contentsOfDirectory(atPath: sicherungsOrdner.path)) ?? [])
            .filter { $0.hasPrefix("transactions-vor-wiederherstellung-") }
        XCTAssertEqual(abgelegt.count, 1)
        let alte = try DatabaseQueue(path: sicherungsOrdner.appendingPathComponent(abgelegt[0]).path)
        let alteZeilen = try alte.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions") }
        XCTAssertEqual(alteZeilen, 2, "die beiseitegelegte Datenbank ist die vorherige")
    }

    /// Es bleiben drei Rückfallebenen — ältere werden abgeräumt, nicht alle behalten.
    func test_esBleibenDreiRueckfallebenen() throws {
        try FileManager.default.createDirectory(at: sicherungsOrdner, withIntermediateDirectories: true)
        for i in 0..<4 {
            let alt = sicherungsOrdner
                .appendingPathComponent("transactions-vor-wiederherstellung-2020-01-0\(i)-000000.db")
            try Data("alt".utf8).write(to: alt)
        }
        try vorhandeneDatenbank(zeilen: 1)

        let archiv = try sicherung(datenbank: try datenbank(zeilen: 1))
        try BackupArchive.einspielen(archiv, passphrase: passphrase)

        let abgelegt = ((try? FileManager.default.contentsOfDirectory(atPath: sicherungsOrdner.path)) ?? [])
            .filter { $0.hasPrefix("transactions-vor-wiederherstellung-") }
        XCTAssertEqual(abgelegt.count, BackupArchive.rueckfallebenen,
                       "es müssen genau \(BackupArchive.rueckfallebenen) bleiben")
    }
}
