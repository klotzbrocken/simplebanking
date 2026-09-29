import XCTest
import Foundation
@testable import simplebanking

/// Aus einem Audit, 29.09.2026: Eine Sicherung konnte Dateien auslassen und trotzdem
/// „Sicherung abgelegt" melden. Nach einem Rechnerwechsel fehlten dann Belege, deren
/// Datenbankzeilen sehr wohl mitgekommen waren — es sah aus wie ein Fehler der App.
///
/// Die Wiederherstellung zählt seit `e7a7519`, was sie nicht schreiben konnte. Das
/// Erstellen zählte gar nichts. Diese Tests halten die andere Richtung fest.
///
/// Eigenes Basisverzeichnis: Ein Test darf weder die Belege noch die Zugangsdaten des
/// Nutzers anfassen.
final class SicherungVollstaendigkeitTests: XCTestCase {

    private let testDomain = "de.simplebanking.tests.vollstaendigkeit"
    private var basis: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        basis = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sicherung-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: basis, withIntermediateDirectories: true)
        CredentialsStore.baseDirectoryOverride = basis
        UserDefaults(suiteName: testDomain)?.set(1, forKey: "refreshInterval")
    }

    override func tearDown() {
        CredentialsStore.baseDirectoryOverride = nil
        UserDefaults.standard.removePersistentDomain(forName: testDomain)
        try? FileManager.default.removeItem(at: basis)
        super.tearDown()
    }

    private func beleg(_ name: String, groesse: Int) throws -> URL {
        let ordner = basis.appendingPathComponent("attachments").appendingPathComponent("slot-1")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let datei = ordner.appendingPathComponent(name)
        try Data(repeating: 0x41, count: groesse).write(to: datei)
        return datei
    }

    private func exportieren() throws -> BackupArchive.Exportbericht {
        try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false,
                                      domain: testDomain).bericht
    }

    // MARK: - Der Normalfall darf nicht anschlagen

    func test_kleineBelege_gehenVollstaendigMit() throws {
        _ = try beleg("bon.pdf", groesse: 1_000)
        _ = try beleg("rechnung.pdf", groesse: 2_000)

        let bericht = try exportieren()
        XCTAssertTrue(bericht.istVollstaendig)
        XCTAssertEqual(bericht.ausgelassen, 0)
    }

    // MARK: - Was gezählt werden muss

    /// Einzelne sehr große Dateien bleiben bewusst draußen, damit ein versehentlich
    /// abgelegtes Video die Sicherung nicht sprengt. Sie dürfen nur nicht unsichtbar
    /// fehlen.
    func test_zuGrosseDatei_wirdGezaehlt() throws {
        _ = try beleg("video.mov", groesse: 21_000_000)
        _ = try beleg("bon.pdf", groesse: 1_000)

        let bericht = try exportieren()
        XCTAssertEqual(bericht.zuGross, 1)
        XCTAssertEqual(bericht.budgetErschoepft, 0)
        XCTAssertEqual(bericht.unlesbar, 0)
        XCTAssertFalse(bericht.istVollstaendig)
    }

    /// Der Fall, den das Audit meinte: Eine Datei, die sich nicht lesen lässt, fiel bis
    /// dahin **ohne Protokolleintrag und ohne Zähler** heraus — als Einzige von allen
    /// drei Auslassungsgründen.
    func test_unlesbareDatei_wirdGezaehlt() throws {
        let datei = try beleg("gesperrt.pdf", groesse: 500)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: datei.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: datei.path) }

        // Als root ist alles lesbar; dann prüft dieser Test nichts und sagt es.
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: datei.path),
                      "Datei trotz 000 lesbar — vermutlich als root ausgeführt")

        let bericht = try exportieren()
        XCTAssertEqual(bericht.unlesbar, 1)
        XCTAssertFalse(bericht.istVollstaendig)
    }

    // MARK: - Ein Konto ist kein Beleg

    /// Ein Beleg darf fehlen und gezählt werden. Eine Bankverbindung nicht: Die fällt
    /// erst auf dem neuen Rechner auf, und dann ist sie weg. Deshalb bricht das Erstellen
    /// hier ab, statt weiterzuzählen.
    func test_unlesbareZugangsdaten_brechenDieSicherungAb() throws {
        let datei = basis.appendingPathComponent("credentials-legacy.json")
        try Data("{}".utf8).write(to: datei)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: datei.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: datei.path) }

        try XCTSkipIf(FileManager.default.isReadableFile(atPath: datei.path),
                      "Datei trotz 000 lesbar — vermutlich als root ausgeführt")

        XCTAssertThrowsError(try exportieren()) { fehler in
            guard case BackupArchive.Fehler.zugangsdatenUnlesbar(let name) = fehler else {
                return XCTFail("erwartet wurde zugangsdatenUnlesbar, kam: \(fehler)")
            }
            XCTAssertEqual(name, "credentials-legacy.json")
        }
    }

    /// Gegenprobe: Lesbare Zugangsdaten dürfen das Erstellen nicht stören.
    func test_lesbareZugangsdaten_stoerenNicht() throws {
        try Data("{}".utf8).write(to: basis.appendingPathComponent("credentials-legacy.json"))
        let bericht = try exportieren()
        XCTAssertTrue(bericht.istVollstaendig)
    }

    // MARK: - Der Rückweg beim Einspielen

    /// Die Zugangsdaten waren das einzige Stück, das ein gescheitertes Einspielen
    /// unwiederbringlich überschrieb: Die Datenbank wandert nach `db-sicherungen`, die
    /// Einstellungen stehen in der Sicherung — die Umschläge waren weg.
    func test_alteZugangsdaten_liegenNachDemEinspielenBeiseite() throws {
        let alt = basis.appendingPathComponent("credentials-legacy.json")
        try Data("alter Umschlag".utf8).write(to: alt)

        let (daten, _) = try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false,
                                                      domain: testDomain)
        // Stand von vor der Sicherung verändern, damit erkennbar ist, was zurückkommt.
        try Data("inzwischen geändert".utf8).write(to: alt)

        _ = try BackupArchive.einspielen(daten, passphrase: "geheim")

        let ablage = basis.appendingPathComponent("db-sicherungen")
        let ordner = (try? FileManager.default.contentsOfDirectory(atPath: ablage.path)) ?? []
        let zugangsordner = ordner.filter { $0.hasPrefix("zugangsdaten-vor-wiederherstellung-") }
        XCTAssertEqual(zugangsordner.count, 1, "der Stand von vorher muss beiseiteliegen")

        let kopie = ablage.appendingPathComponent(zugangsordner[0])
            .appendingPathComponent("credentials-legacy.json")
        XCTAssertEqual(try Data(contentsOf: kopie), Data("inzwischen geändert".utf8),
                       "beiseite gehört der Stand von unmittelbar vor dem Einspielen")
        XCTAssertEqual(try Data(contentsOf: alt), Data("alter Umschlag".utf8),
                       "an Ort und Stelle steht der Stand aus der Sicherung")
    }

    /// Gegenprobe: Ohne vorhandene Zugangsdaten entsteht auch kein leerer Ordner.
    func test_ohneAlteZugangsdaten_entstehtKeineAblage() throws {
        let (daten, _) = try BackupArchive.exportieren(passphrase: "geheim", mitThemes: false,
                                                      domain: testDomain)
        _ = try BackupArchive.einspielen(daten, passphrase: "geheim")

        let ablage = basis.appendingPathComponent("db-sicherungen")
        let ordner = (try? FileManager.default.contentsOfDirectory(atPath: ablage.path)) ?? []
        XCTAssertTrue(ordner.filter { $0.hasPrefix("zugangsdaten-vor-") }.isEmpty)
    }
}
