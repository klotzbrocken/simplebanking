import XCTest
import Foundation
@testable import simplebanking

// MARK: - Zugang zum MCP-Server
//
// Der Server war Alles-oder-nichts: Wer ihn starten konnte, konnte jedes Werkzeug
// aufrufen — einschließlich `prepare_transfer`. Bei einem Agenten, der Kontotexte liest,
// ist das die falsche Voreinstellung: In einem Verwendungszweck kann eine Anweisung
// stehen.
//
// Zwei Zusagen hängen an diesen Tests, und beide stehen im Einstellungsdialog:
// Der Token existiert nur einmal, und Überweisungsentwürfe sind standardmäßig aus.

final class MCPZugangTests: XCTestCase {

    private var gesichert: Data?

    override func setUp() {
        super.setUp()
        gesichert = try? Data(contentsOf: MCPClientStore.dateiURL)
        try? FileManager.default.removeItem(at: MCPClientStore.dateiURL)
    }

    override func tearDown() {
        // Die Registrierung des Nutzers wiederherstellen — ein Test darf sie nicht
        // verlieren, sonst hört sein Claude Desktop nach dem Testlauf auf zu arbeiten.
        if let gesichert {
            try? gesichert.write(to: MCPClientStore.dateiURL)
        } else {
            try? FileManager.default.removeItem(at: MCPClientStore.dateiURL)
        }
        super.tearDown()
    }

    // MARK: Voreinstellungen

    /// Überweisungsentwürfe sind der einzige Bereich, mit dem sich Schaden anrichten
    /// lässt. Er darf nicht versehentlich mitkommen.
    func test_ueberweisungIstNichtStandard() {
        for bereich in MCPClientStore.Zugangsbereich.allCases {
            XCTAssertEqual(bereich.standardmaessigAn, bereich != .ueberweisung,
                           "\(bereich.rawValue)")
        }
    }

    /// Jeder Bereich braucht einen Hinweis — der Nutzer hakt sonst etwas ab, dessen
    /// Tragweite er nicht kennt.
    func test_jederBereichIstErklaert() {
        for b in MCPClientStore.Zugangsbereich.allCases {
            XCTAssertFalse(b.titel.isEmpty, b.rawValue)
            XCTAssertFalse(b.hinweis.isEmpty, b.rawValue)
        }
    }

    /// Beim gefährlichsten Bereich muss der Hinweis benennen, was ohne Rückfrage
    /// passiert — nicht nur, was mit Rückfrage passiert.
    func test_hinweisZurUeberweisungIstEhrlich() {
        let text = MCPClientStore.Zugangsbereich.ueberweisung.hinweis
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Entwurf")
                      || text.localizedCaseInsensitiveContains("draft"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("ohne dass du gefragt")
                      || text.localizedCaseInsensitiveContains("without asking"),
                      "der Hinweis verschweigt, dass ein Entwurf ungefragt entsteht: \(text)")
    }

    // MARK: Anlegen und Widerrufen

    func test_tokenStehtNichtInDerDatei() throws {
        let (_, token) = try MCPClientStore.anlegen(
            name: "Claude Desktop", bereiche: [.konten], gueltigTage: nil)
        let inhalt = try String(contentsOf: MCPClientStore.dateiURL, encoding: .utf8)
        XCTAssertFalse(inhalt.contains(token),
                       "Der Token darf nicht in der Registrierung stehen — die Datei wäre sonst selbst der Zugang")
        XCTAssertTrue(inhalt.contains(MCPClientStore.hash(token)))
    }

    func test_widerrufBleibtErhalten() throws {
        let (client, _) = try MCPClientStore.anlegen(
            name: "Test", bereiche: [.konten], gueltigTage: nil)
        try MCPClientStore.widerrufen(id: client.id)
        let neu = try XCTUnwrap(MCPClientStore.laden().first { $0.id == client.id })
        XCTAssertTrue(neu.widerrufen)
        XCTAssertFalse(neu.aktiv)
    }

    /// Ein zweiter Client darf den Hash des ersten nicht verlieren — sonst hört ein
    /// funktionierender Zugang beim Anlegen des nächsten auf zu arbeiten.
    func test_zweiterClientVerliertDenErstenNicht() throws {
        let (a, tokenA) = try MCPClientStore.anlegen(name: "A", bereiche: [.konten], gueltigTage: nil)
        _ = try MCPClientStore.anlegen(name: "B", bereiche: [.umsaetze], gueltigTage: nil)
        let inhalt = try String(contentsOf: MCPClientStore.dateiURL, encoding: .utf8)
        XCTAssertTrue(inhalt.contains(MCPClientStore.hash(tokenA)),
                      "Hash von \(a.name) ist beim Schreiben verlorengegangen")
    }

    func test_ablaufWirdGesetztUndErkannt() throws {
        let (abgelaufen, _) = try MCPClientStore.anlegen(
            name: "alt", bereiche: [.konten], gueltigTage: nil)
        XCTAssertFalse(abgelaufen.abgelaufen, "ohne Frist läuft nichts ab")

        var kunstlich = abgelaufen
        kunstlich.laeuftAbAm = Date().addingTimeInterval(-60)
        XCTAssertTrue(kunstlich.abgelaufen)
        XCTAssertFalse(kunstlich.aktiv)
    }

    /// Zwei Tokens dürfen nie gleich sein.
    func test_tokensSindVerschieden() throws {
        let (_, a) = try MCPClientStore.anlegen(name: "A", bereiche: [.konten], gueltigTage: nil)
        let (_, b) = try MCPClientStore.anlegen(name: "B", bereiche: [.konten], gueltigTage: nil)
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThan(a.count, 32, "zu kurz, um zu raten zu widerstehen")
    }
}
