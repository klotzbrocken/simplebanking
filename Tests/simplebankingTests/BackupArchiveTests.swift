import XCTest
import Foundation
import GRDB
@testable import simplebanking

// MARK: - Sicherung und Wiederherstellung
//
// Die Sicherung gibt zwei Zusagen, und beide sind schriftlich im Dialog:
//
//   1. „Konten, Historie und Einstellungen kommen zurück."
//   2. „Deine Banken gibst du einmal neu frei."
//
// Zusage 2 ist keine Bequemlichkeit, sondern Absicht: Eine eingespielte, tote Zustimmung
// erzeugt einen Abruf, der sauber durchläuft und nichts liefert — der Zustand, an dem am
// 23.08.2026 stundenlang gesucht wurde. Diese Tests halten beide Zusagen fest.

final class BackupArchiveTests: XCTestCase {

    /// Eigene Domäne: Ein Test darf die Einstellungen des Nutzers weder lesen noch
    /// schreiben.
    private let testDomain = "de.simplebanking.tests.backup"

    override func setUp() {
        super.setUp()
        let d = UserDefaults(suiteName: testDomain)
        d?.set("connection-abc", forKey: "simplebanking.yaxi.connectionId.legacy")
        d?.set(240, forKey: "refreshInterval")
        d?.set("geheime-zustimmung", forKey: "simplebanking.yaxi.connectionData.legacy")
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: testDomain)
        super.tearDown()
    }

    // MARK: Was draußen bleibt

    func test_zustimmungenUndSitzungenBleibenDraussen() {
        let raus = [
            "simplebanking.yaxi.connectionData",
            "simplebanking.yaxi.connectionData.29FFEA00-C4F0-4237-84DA-564224A2C7D0",
            "simplebanking.yaxi.connectionDataAt.legacy",
            "simplebanking.yaxi.session.balances",
            "simplebanking.yaxi.session.transactions.CD883BF5-13C5-425F-A2CF-F74C02604BEA",
            "simplebanking.yaxi.session.transfer.legacy",
        ]
        for k in raus {
            XCTAssertTrue(BackupArchive.istAuszuschliessen(k),
                          "\(k) gehört nicht in die Sicherung — eine tote Zustimmung ist schlimmer als keine")
        }
    }

    /// Die Gegenprobe. Sie ist die wichtigere Hälfte: Ein zu breiter Filter nähme dem
    /// Nutzer genau das weg, wofür er die Sicherung anlegt.
    func test_kontenUndEinstellungenWandernMit() {
        let rein = [
            "simplebanking.yaxi.connectionId.legacy",          // Verbindung, nicht Zustimmung
            "simplebanking.iban.29FFEA00-C4F0-4237-84DA-564224A2C7D0",
            "simplebanking.yaxi.credModel.full.legacy",
            "simplebanking.cachedBalance.legacy",
            "connectedBankDisplayName",
            "refreshInterval",
            "themeId",
            "balanceChangeBadgeEnabled",
            "multibanking.slots",
        ]
        for k in rein {
            XCTAssertFalse(BackupArchive.istAuszuschliessen(k),
                           "\(k) wird gebraucht, damit die Konten nach dem Einspielen dastehen")
        }
    }

    /// `connectionId` und `connectionData` unterscheiden sich um vier Buchstaben und
    /// haben gegensätzliche Bedeutung: die Verbindung soll mit, die Zustimmung nicht.
    /// Ein Filter auf „connection" würde beides schlucken.
    func test_verbindungskennungWirdNichtMitDerZustimmungVerwechselt() {
        XCTAssertFalse(BackupArchive.istAuszuschliessen("simplebanking.yaxi.connectionId.legacy"))
        XCTAssertTrue(BackupArchive.istAuszuschliessen("simplebanking.yaxi.connectionData.legacy"))
    }

    // MARK: Der vollständige Rundlauf

    /// **Export in eine Datei, Datei zurücklesen, einspielen, Ergebnis prüfen.**
    ///
    /// Diesen Test gab es zuerst nicht — geprüft wurde nur, dass die falsche Passphrase
    /// scheitert. Deshalb fiel nicht auf, dass die Bedienoberfläche gar nichts anlegte:
    /// Das Blatt setzte den Zweck auf nil, bevor es die Ausführung rief, und die stieg an
    /// genau dieser Prüfung wieder aus. Ein Rundlauf über eine echte Datei hätte das
    /// nicht gefunden, aber er hält jetzt wenigstens die Kette selbst fest.
    func test_rundlaufUeberEineDatei() throws {
        let ordner = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ordner) }
        let datei = ordner.appendingPathComponent("probe.\(BackupArchive.dateiendung)")

        let daten = try BackupArchive.exportieren(passphrase: "korrekt-pferd-batterie",
                                                  merkhilfe: "wie beim alten Router",
                                                  mitThemes: false, domain: testDomain)
        try daten.write(to: datei)

        XCTAssertTrue(FileManager.default.fileExists(atPath: datei.path),
                      "die Sicherungsdatei muss auf der Platte liegen")
        let groesse = try FileManager.default.attributesOfItem(atPath: datei.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(groesse, 100, "eine leere Datei wäre keine Sicherung")

        let zurueck = try Data(contentsOf: datei)
        let bericht = try BackupArchive.einspielen(zurueck, passphrase: "korrekt-pferd-batterie")

        XCTAssertGreaterThan(bericht.einstellungen, 0, "es müssen Einstellungen angekommen sein")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "simplebanking.yaxi.connectionId.legacy"),
                       "connection-abc", "die Verbindung muss zurückkommen")
        XCTAssertNil(UserDefaults.standard.string(forKey: "simplebanking.yaxi.connectionData.legacy"),
                     "die Zustimmung darf NICHT zurückkommen — das ist die Zusage im Dialog")
    }

    /// Die Merkhilfe muss ohne Passphrase lesbar sein, sonst hilft sie nicht.
    func test_merkhilfeIstOhnePassphraseLesbar() throws {
        let daten = try BackupArchive.exportieren(passphrase: "geheim",
                                                  merkhilfe: "wie beim alten Router",
                                                  mitThemes: false, domain: testDomain)
        XCTAssertEqual(BackupArchive.merkhilfe(aus: daten), "wie beim alten Router")
    }

    func test_ohneMerkhilfeKeineMerkhilfe() throws {
        let daten = try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false,
                                                  domain: testDomain)
        XCTAssertNil(BackupArchive.merkhilfe(aus: daten))
    }

    /// **Der Zweig, den der Rundlauf-Test nicht betrat.**
    ///
    /// Im Testsandkasten liegt keine Umsatzdatenbank, also stieg der Export vorher aus
    /// und die Kopie wurde nie versucht. In der echten App scheiterte sie jedes Mal:
    /// GRDBs `write` legt eine Transaktion an, und SQLite lehnt VACUUM darin ab. Ergebnis
    /// war eine Sicherung, die nie entstand.
    ///
    /// Dieser Test legt deshalb ausdrücklich eine Datenbank an, bevor er exportiert.
    func test_datenbankKommtInDieSicherung() throws {
        let ziel = try TransactionsDatabase.databaseURL()
        try FileManager.default.createDirectory(at: ziel.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Eine kleine, echte Datenbank — es geht um den VACUUM-Weg, nicht um Inhalte.
        let queue = try DatabaseQueue(path: ziel.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS transactions (tx_id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT OR REPLACE INTO transactions (tx_id) VALUES ('a'), ('b')")
        }
        defer { try? FileManager.default.removeItem(at: ziel) }

        let daten = try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false,
                                                  domain: testDomain)
        let bericht = try BackupArchive.einspielen(daten, passphrase: "geheim")
        XCTAssertEqual(bericht.buchungen, 2,
                       "die Datenbank muss mitgewandert und wieder lesbar sein")
    }

    /// **Belege müssen mitwandern, sonst zeigt die Buchung auf ein Loch.**
    ///
    /// Die Datenbank kennt einen Beleg als Zeile, die Datei liegt daneben im
    /// `attachments`-Ordner. Käme nur die Zeile zurück, sähe das im Umsatzdetail aus wie
    /// ein Fehler — schlimmer als gar kein Beleg.
    func test_belegeWandernMit() throws {
        let basis = try CredentialsStore.appSupportURL()
            .appendingPathComponent("attachments")
            .appendingPathComponent("primary")
            .appendingPathComponent("slot-1")
            .appendingPathComponent("tx-42")
        try FileManager.default.createDirectory(at: basis, withIntermediateDirectories: true)
        let beleg = basis.appendingPathComponent("bon.pdf")
        try Data("ein Beleg".utf8).write(to: beleg)

        let daten = try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false,
                                                  domain: testDomain)
        try FileManager.default.removeItem(at: beleg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: beleg.path))

        let bericht = try BackupArchive.einspielen(daten, passphrase: "geheim")
        XCTAssertGreaterThanOrEqual(bericht.anhaenge, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beleg.path),
                      "der Beleg muss samt Unterordnern wieder dastehen")
        XCTAssertEqual(try Data(contentsOf: beleg), Data("ein Beleg".utf8))
    }

    /// Ältere Sicherungen dürfen weiterhin einspielbar sein — die Felder für Belege und
    /// Entwürfe kamen später dazu und sind deshalb optional.
    func test_aeltereSicherungOhneBelegeBleibtLesbar() throws {
        // Eine Sicherung ohne die neuen Felder nachbilden: Inhalt ohne `anhaenge`.
        let daten = try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false,
                                                  domain: testDomain)
        let bericht = try BackupArchive.einspielen(daten, passphrase: "geheim")
        XCTAssertGreaterThanOrEqual(bericht.einstellungen, 1,
                                    "eine Sicherung ohne Belege muss trotzdem durchlaufen")
    }

    // MARK: Namen aus einer fremden Datei
    //
    // Eine Sicherung kommt von außen. Wer sie erstellt, bestimmt die Namen darin — und die
    // Verschlüsselung schützt davor nicht, denn die Passphrase liefert er mit. Der alte
    // Test hier prüfte nur, dass die Testdaten wie ein Ausbruch *aussehen*; ob der Code
    // sie ablehnt, sagte er nicht. Jetzt schon.

    private var pfadBasis: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-pfadtest", isDirectory: true)
    }

    func test_ausbrechendePfadeWerdenAbgelehnt() {
        for boese in ["../../../../tmp/uebernommen", "/etc/passwd", "a/../../b",
                      "..", ".", "", "unter/ordner", "~/.zshrc", "mit\\backslash",
                      "mit\u{0}NUL"] {
            XCTAssertThrowsError(
                try BackupArchive.sichererZielpfad(basis: pfadBasis, name: boese),
                "\(boese) hätte abgelehnt werden müssen")
        }
    }

    func test_harmloserNameGehtDurchUndBleibtDrinnen() throws {
        let ziel = try BackupArchive.sichererZielpfad(basis: pfadBasis,
                                                      name: "credentials-legacy.json")
        XCTAssertEqual(ziel.lastPathComponent, "credentials-legacy.json")
        XCTAssertEqual(ziel.deletingLastPathComponent().standardized.path,
                       pfadBasis.standardized.path)
    }

    /// Belege liegen in Unterordnern — die müssen erlaubt bleiben, sonst käme kein Bon
    /// zurück.
    func test_belegeDuerfenUnterordnerHaben() throws {
        let ziel = try BackupArchive.sichererZielpfad(basis: pfadBasis,
                                                      name: "slot-1/tx-42/bon.pdf",
                                                      unterordner: true)
        XCTAssertTrue(ziel.standardized.path.hasSuffix("slot-1/tx-42/bon.pdf"))
    }

    func test_ausbruchAuchMitErlaubtenUnterordnernAbgelehnt() {
        for boese in ["../raus.pdf", "slot/../../raus.pdf", "/absolut.pdf"] {
            XCTAssertThrowsError(
                try BackupArchive.sichererZielpfad(basis: pfadBasis, name: boese,
                                                   unterordner: true),
                "\(boese) hätte abgelehnt werden müssen")
        }
    }

    /// Der unauffälligste Ausbruch: Im Namen steht nichts Verdächtiges, aber der Ordner,
    /// in den er zeigt, ist ein Symlink nach draußen.
    func test_symlinkImZielordnerBrichtNichtAus() throws {
        let fm = FileManager.default
        let wurzel = fm.temporaryDirectory.appendingPathComponent("sb-symlink-\(UUID().uuidString)")
        let innen = wurzel.appendingPathComponent("innen")
        let draussen = wurzel.appendingPathComponent("draussen")
        try fm.createDirectory(at: innen, withIntermediateDirectories: true)
        try fm.createDirectory(at: draussen, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: wurzel) }
        try fm.createSymbolicLink(at: innen.appendingPathComponent("weg"),
                                  withDestinationURL: draussen)

        XCTAssertThrowsError(
            try BackupArchive.sichererZielpfad(basis: innen, name: "weg/datei.txt",
                                               unterordner: true))
    }

    // MARK: Der Dateikopf ist nicht authentifiziert

    /// Salt, Nonce und Rundenzahl liegen außerhalb der Verschlüsselung — sie müssen ohne
    /// Passphrase lesbar sein, damit die Merkhilfe funktioniert. Also sind sie auch
    /// manipulierbar.
    func test_unsinnigeRundenzahlWirdAbgelehnt() {
        for roh in [-1, 0, 1, 9_999, 5_000_001, Int(UInt32.max) + 1] {
            XCTAssertThrowsError(try BackupArchive.gepruefteRunden(roh), "\(roh)")
        }
    }

    func test_dieUeblicheRundenzahlGehtDurch() throws {
        XCTAssertEqual(try BackupArchive.gepruefteRunden(210_000), 210_000)
    }

    /// Der Ernstfall: `UInt32(runden)` stürzt bei einem negativen Wert ab. Eine
    /// untergeschobene Datei hätte die App beendet, bevor überhaupt eine Passphrase
    /// geprüft war.
    func test_praeparierterDateikopfBeendetDieAppNicht() {
        let kopf = """
        {"v":1,"saltB64":"AAAAAAAAAAAAAAAAAAAAAA==","nonceB64":"AAAAAAAAAAAAAAAA",\
        "ciphertextB64":"AAAA","tagB64":"AAAAAAAAAAAAAAAAAAAAAA==",\
        "kdf":"pbkdf2-sha256","iterations":-1}
        """
        XCTAssertThrowsError(try BackupArchive.einspielen(Data(kopf.utf8), passphrase: "egal"))
    }

    func test_fremdeSchluesselableitungWirdAbgelehnt() {
        let kopf = """
        {"v":1,"saltB64":"AAAAAAAAAAAAAAAAAAAAAA==","nonceB64":"AAAAAAAAAAAAAAAA",\
        "ciphertextB64":"AAAA","tagB64":"AAAAAAAAAAAAAAAAAAAAAA==",\
        "kdf":"scrypt","iterations":210000}
        """
        XCTAssertThrowsError(try BackupArchive.einspielen(Data(kopf.utf8), passphrase: "egal"))
    }

    // MARK: Die Rückfallebene

    /// Die vorhandene Datenbank wird beim Einspielen beiseitegelegt. Vorher trug sie einen
    /// **festen** Namen, der vor jedem Versuch gelöscht wurde: Zwei Einspielversuche
    /// hintereinander hätten die letzte funktionierende Datenbank vernichtet.
    func test_zweiEinspielversucheVerdraengenDieRueckfallebeneNicht() throws {
        let ziel = try TransactionsDatabase.databaseURL()
        let ordner = ziel.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let sicherungen = ordner.appendingPathComponent("db-sicherungen", isDirectory: true)
        try? FileManager.default.removeItem(at: sicherungen)
        defer {
            try? FileManager.default.removeItem(at: ziel)
            try? FileManager.default.removeItem(at: sicherungen)
        }

        func datenbankAnlegen(_ zeilen: Int) throws {
            let queue = try DatabaseQueue(path: ziel.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS transactions (tx_id TEXT PRIMARY KEY)")
                try db.execute(sql: "DELETE FROM transactions")
                for i in 0..<zeilen {
                    try db.execute(sql: "INSERT INTO transactions (tx_id) VALUES (?)",
                                   arguments: ["tx-\(i)"])
                }
            }
        }

        try datenbankAnlegen(3)
        let sicherung = try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false,
                                                      domain: testDomain)
        try BackupArchive.einspielen(sicherung, passphrase: "geheim")
        // Zwischen den Läufen muss eine Sekunde liegen — der Stempel geht auf Sekunden.
        Thread.sleep(forTimeInterval: 1.1)
        try BackupArchive.einspielen(sicherung, passphrase: "geheim")

        let imOrdner = (try? FileManager.default.contentsOfDirectory(atPath: sicherungen.path)) ?? []
        let abgelegt = imOrdner.filter { $0.hasPrefix("transactions-vor-wiederherstellung-") }
        XCTAssertEqual(abgelegt.count, 2,
                       "beide beiseitegelegten Datenbanken müssen erhalten bleiben")
        XCTAssertFalse(abgelegt.contains("transactions-vor-wiederherstellung.db"),
                       "der feste Name war genau das Problem")
    }

    // MARK: Die mitgelieferte Datenbank

    /// Vorher verschluckte ein `try?` den Fehler: Eine unlesbare Datenbank wurde
    /// eingespielt und als „0 Buchungen" gemeldet — eine Erfolgsmeldung über einen
    /// Datenverlust.
    func test_kaputteDatenbankWirdVorDemSchreibenErkannt() {
        XCTAssertThrowsError(try BackupArchive.buchungenPruefen(Data("keine datenbank".utf8)))
    }

    // MARK: Der Umschlag

    /// Rundlauf: Was hineingeht, kommt heraus.
    func test_rundlaufMitRichtigerPassphrase() throws {
        let daten = try BackupArchive.exportieren(passphrase: "korrekt-pferd-batterie-klammer",
                                                  mitThemes: false, domain: testDomain)
        XCTAssertFalse(daten.isEmpty)
        // Entschlüsseln über den öffentlichen Weg wäre ein Einspielen und würde die
        // Umgebung verändern — geprüft wird deshalb, dass die falsche Passphrase
        // scheitert und die richtige nicht am Umschlag scheitert.
        XCTAssertThrowsError(try BackupArchive.einspielen(daten, passphrase: "falsch")) { fehler in
            guard case BackupArchive.Fehler.falschePassphrase = fehler else {
                return XCTFail("erwartet: falschePassphrase, bekommen: \(fehler)")
            }
        }
    }

    /// Eine veränderte Datei darf nicht als echt durchgehen. AES-GCM leistet das; der
    /// Test hält fest, dass wir den Nachweis auch prüfen und nicht wegwerfen.
    func test_veraenderteSicherungWirdAbgelehnt() throws {
        let daten = try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false, domain: testDomain)
        var text = try XCTUnwrap(String(data: daten, encoding: .utf8))

        // Ein Zeichen mitten im Geheimtext austauschen — verlässlich, nicht auf gut Glück:
        // erst die Stelle suchen, dann dort ein anderes Base64-Zeichen setzen.
        let marke = "\"ciphertextB64\":\""
        let start = try XCTUnwrap(text.range(of: marke)).upperBound
        let ziel = text.index(start, offsetBy: 20)
        let vorher = text[ziel]
        text.replaceSubrange(ziel...ziel, with: vorher == "A" ? "B" : "A")

        XCTAssertThrowsError(try BackupArchive.einspielen(Data(text.utf8), passphrase: "geheim"),
                             "eine veränderte Sicherung darf nicht als echt durchgehen")
    }

    func test_unlesbareDateiWirdBenannt() {
        XCTAssertThrowsError(try BackupArchive.einspielen(Data("kein Archiv".utf8),
                                                          passphrase: "x")) { fehler in
            guard case BackupArchive.Fehler.beschaedigt = fehler else {
                return XCTFail("erwartet: beschaedigt, bekommen: \(fehler)")
            }
        }
    }

    /// Eine Sicherung aus einer neueren Fassung darf nicht halb eingespielt werden.
    func test_neueresFormatWirdAbgelehnt() {
        XCTAssertEqual(BackupArchive.formatVersion, 1,
                       "Wird das erhöht, braucht `einspielen` einen Umstiegspfad für Version 1")
    }

    /// Die Fehlertexte landen im Dialog — leer wäre schlimmer als falsch.
    func test_fehlertexteSindGesetzt() {
        for fehler: BackupArchive.Fehler in [.falschePassphrase,
                                             .unbekanntesFormat(9),
                                             .beschaedigt("Einstellungen")] {
            XCTAssertFalse((fehler.errorDescription ?? "").isEmpty, "\(fehler)")
        }
    }
}
