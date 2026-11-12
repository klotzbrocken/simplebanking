import XCTest
import MoneyMoneyForm
@testable import simplebanking

/// Der Swift-Weg zum Helfer: Prozess starten, Kennwort über stdin, Auszug über
/// stdout zurücklesen.
///
/// **Warum es diese Tests gibt.** Der Helfer war gegen die echte Datenbank geprüft —
/// aber aus `bash`, mit einer Pipe. `MoneyMoneyLesepfad.auszug` ist etwas anderes:
/// `Process`, drei `Pipe`s, `readDataToEndOfFile` und `waitUntilExit` in einer
/// Reihenfolge, die genau dann stimmen muss, wenn der Auszug größer ist als der
/// Rohrpuffer. Diese Strecke lief nie, und genau dort blieb der Assistent am
/// 11.11.2026 mit drehendem Rad stehen.
///
/// Gearbeitet wird mit einer **Wegwerf-Datenbank**: `sqlcipher` legt sie an, das
/// Kennwort steht hier im Quelltext, Umsätze sind erfunden. Die echten Daten des
/// Nutzers kommen nicht vor.
final class MoneyMoneyProzessTests: XCTestCase {

    private var ordner: URL!

    override func setUpWithError() throws {
        ordner = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-prozess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: ordner)
    }

    // MARK: - Hilfen

    private func sqlcipherPfad() throws -> String {
        for pfad in ["/opt/homebrew/bin/sqlcipher", "/usr/local/bin/sqlcipher"]
        where FileManager.default.isExecutableFile(atPath: pfad) { return pfad }
        throw XCTSkip("sqlcipher nicht installiert (brew install sqlcipher)")
    }

    /// Über `#filePath` zur Projektwurzel, nicht über `Bundle.main`.
    ///
    /// `Bundle.main` ist im Testlauf die **XCTest-Hülle** aus Xcode, nicht das
    /// Testpaket — von dort führt kein Weg zum Bauordner. Das kostete den ersten
    /// Lauf dieser Datei: fünf Tests, alle an derselben Stelle vorbei am
    /// eigentlichen Gegenstand.
    private func helfer() throws -> URL {
        let wurzel = URL(fileURLWithPath: #filePath)      // …/Tests/simplebankingTests/<Datei>
            .deletingLastPathComponent()                   // …/Tests/simplebankingTests
            .deletingLastPathComponent()                   // …/Tests
            .deletingLastPathComponent()                   // Projektwurzel
        let orte = [
            ".build/out/Products/Debug/simplebanking-mmimport",
            ".build/debug/simplebanking-mmimport",
            ".build/arm64-apple-macosx/debug/simplebanking-mmimport",
            ".build/arm64-apple-macosx/release/simplebanking-mmimport",
        ]
        for ort in orte {
            let kandidat = wurzel.appendingPathComponent(ort)
            if FileManager.default.isExecutableFile(atPath: kandidat.path) { return kandidat }
        }
        throw XCTSkip("simplebanking-mmimport nicht gebaut — `swift build --product simplebanking-mmimport`")
    }

    /// Eine MoneyMoney-ähnliche Datenbank mit `anzahl` Umsätzen.
    ///
    /// Die Spalten kommen aus `benoetigteSpalten` — wächst die Liste, scheitert hier
    /// die Schemaprüfung des Helfers und nicht erst der Nutzer.
    private func datenbank(kennwort: String, umsaetze anzahl: Int) throws -> URL {
        let werkzeug = try sqlcipherPfad()
        let datei = ordner.appendingPathComponent("MoneyMoney.sqlite")

        var sql = """
        PRAGMA key = '\(kennwort)';
        CREATE TABLE accounts (iban TEXT, bic TEXT, currency TEXT, name TEXT,
                               owner TEXT, portfolio INTEGER);
        CREATE TABLE category_groups (name TEXT, group_key INTEGER);
        CREATE TABLE categories (name TEXT, group_key INTEGER);
        CREATE TABLE transactions (local_account_key INTEGER, account TEXT, bankcode TEXT,
                                   amount REAL, currency TEXT, timestamp INTEGER,
                                   value_timestamp INTEGER, name TEXT, unformatted_purpose TEXT,
                                   unformatted_type TEXT, eref TEXT, mref TEXT, cred TEXT,
                                   rtrn TEXT, category_key INTEGER, booked INTEGER,
                                   splitted INTEGER);
        INSERT INTO accounts VALUES ('DE83460500010001808336','WELADED1SIE','EUR',
                                     'Girokonto','M. K.',0);
        INSERT INTO category_groups VALUES ('Alltag', 0);
        INSERT INTO categories VALUES ('Lebensmittel', 1);
        BEGIN;

        """
        for i in 0..<anzahl {
            // Der Zweck ist absichtlich lang: Der Auszug muss den Rohrpuffer (64 KB)
            // überschreiten, sonst prüft der Test die interessante Hälfte nicht.
            let zweck = "Einkauf Nummer \(i) " + String(repeating: "x", count: 120)
            sql += """
            INSERT INTO transactions VALUES (1,'','',-\(i % 90 + 1).50,'EUR',\
            \(1_700_000_000 + i * 86_400),\(1_700_000_000 + i * 86_400),\
            'Testladen GmbH','\(zweck)','Lastschrift','','','','',1,1,0);

            """
        }
        sql += "COMMIT;\n"

        let prozess = Process()
        prozess.executableURL = URL(fileURLWithPath: werkzeug)
        prozess.arguments = [datei.path]
        let eingabe = Pipe()
        prozess.standardInput = eingabe
        prozess.standardOutput = FileHandle.nullDevice
        prozess.standardError = FileHandle.nullDevice
        try prozess.run()
        eingabe.fileHandleForWriting.write(Data(sql.utf8))
        try? eingabe.fileHandleForWriting.close()
        prozess.waitUntilExit()
        XCTAssertEqual(prozess.terminationStatus, 0, "sqlcipher konnte die Testdatenbank nicht anlegen")
        return datei
    }

    // MARK: - Die Strecke

    func testKleinerAuszugKommtAn() throws {
        let kennwort = "testkennwort"
        let datei = try datenbank(kennwort: kennwort, umsaetze: 3)
        let auszug = try MoneyMoneyLesepfad.auszug(datenbank: datei, kennwort: kennwort,
                                                   helferPfad: try helfer())
        XCTAssertEqual(auszug.konten.count, 1)
        XCTAssertEqual(auszug.konten.first?.iban, "DE83460500010001808336")
        XCTAssertEqual(auszug.umsaetze.count, 3)
        XCTAssertEqual(auszug.kategorien.count, 1)
    }

    /// **Der eigentliche Test.** 2.000 Umsätze mit langem Zweck sind weit über dem
    /// 64-KB-Rohrpuffer. Wird in der falschen Reihenfolge gelesen und gewartet,
    /// blockiert der Helfer beim Schreiben und die App beim Warten — und genau so
    /// sieht ein Assistent aus, der sich nicht mehr rührt.
    func testGrosserAuszugLaeuftNichtInDenRohrpuffer() throws {
        let kennwort = "testkennwort"
        let datei = try datenbank(kennwort: kennwort, umsaetze: 2_000)
        XCTAssertGreaterThan(
            try FileManager.default.attributesOfItem(atPath: datei.path)[.size] as? Int ?? 0,
            200_000, "Die Testdatenbank ist zu klein, um den Puffer zu füllen")

        let auszug = try MoneyMoneyLesepfad.auszug(datenbank: datei, kennwort: kennwort,
                                                   helferPfad: try helfer())
        XCTAssertEqual(auszug.umsaetze.count, 2_000)
        // Reihenfolge und Inhalt müssen stimmen, nicht nur die Zahl: Der Helfer
        // sortiert nach `timestamp ASC, rowid ASC`.
        XCTAssertEqual(auszug.umsaetze.first?.zweck?.hasPrefix("Einkauf Nummer 0 "), true)
        XCTAssertEqual(auszug.umsaetze.last?.zweck?.hasPrefix("Einkauf Nummer 1999 "), true)
        XCTAssertEqual(auszug.umsaetze.last?.gegenseiteName, "Testladen GmbH")
    }

    func testFalschesKennwortMeldetSichAlsSolches() throws {
        let datei = try datenbank(kennwort: "richtig", umsaetze: 2)
        XCTAssertThrowsError(try MoneyMoneyLesepfad.auszug(datenbank: datei,
                                                           kennwort: "falsch",
                                                           helferPfad: try helfer())) { fehler in
            XCTAssertEqual(fehler as? MoneyMoneyFehler, .kennwortFalsch)
        }
    }

    func testFehlendeDateiMeldetSichAlsSolche() throws {
        XCTAssertThrowsError(try MoneyMoneyLesepfad.auszug(
            datenbank: ordner.appendingPathComponent("gibtesnicht.sqlite"),
            kennwort: "egal", helferPfad: try helfer())) { fehler in
            XCTAssertEqual(fehler as? MoneyMoneyFehler, .keineDatei)
        }
    }

    func testFehlendeSpalteWirdErkanntStattHalbGelesen() throws {
        let werkzeug = try sqlcipherPfad()
        let datei = ordner.appendingPathComponent("alt.sqlite")
        let prozess = Process()
        prozess.executableURL = URL(fileURLWithPath: werkzeug)
        prozess.arguments = [datei.path]
        let eingabe = Pipe()
        prozess.standardInput = eingabe
        prozess.standardOutput = FileHandle.nullDevice
        prozess.standardError = FileHandle.nullDevice
        try prozess.run()
        // `accounts` ohne `portfolio` — so sähe eine ältere MoneyMoney-Fassung aus.
        eingabe.fileHandleForWriting.write(Data("""
        PRAGMA key = 'k';
        CREATE TABLE accounts (iban TEXT, bic TEXT, currency TEXT, name TEXT, owner TEXT);
        CREATE TABLE category_groups (name TEXT, group_key INTEGER);
        CREATE TABLE categories (name TEXT, group_key INTEGER);
        CREATE TABLE transactions (local_account_key INTEGER);
        """.utf8))
        try? eingabe.fileHandleForWriting.close()
        prozess.waitUntilExit()

        XCTAssertThrowsError(try MoneyMoneyLesepfad.auszug(datenbank: datei, kennwort: "k",
                                                           helferPfad: try helfer())) { fehler in
            XCTAssertEqual(fehler as? MoneyMoneyFehler, .schemaUnbekannt,
                           "Eine fehlende Spalte muss als Schemafehler ankommen, nicht als Lesefehler")
        }
    }
}
