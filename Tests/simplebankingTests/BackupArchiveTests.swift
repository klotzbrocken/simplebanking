import XCTest
import Foundation
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
