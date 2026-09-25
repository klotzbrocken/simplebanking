import XCTest
@testable import simplebanking

// MARK: - Kein `MainActor.run` im Bankweg
//
// Der Einrichtungsassistent läuft unter `NSApp.runModal`. Ein `await MainActor.run`
// reiht sich in die Main-Dispatch-Queue ein und kommt dort nicht rechtzeitig an — er
// wartet, bis die modale Sitzung endet. Für den Nutzer sieht das aus wie ein Programm,
// das steht: kein Fenster, keine Meldung, kein Fortschritt.
//
// Zweimal getroffen hat es genau das:
//
//   * HypoVereinsbank, Tipp-TAN: Das TAN-Feld erschien erst beim Abbruch, 17 bis 60
//     Sekunden zu spät. Dafür wurde `onMainRunLoop` gebaut.
//   * ING, gemeldet am 25.09.2026: Die Ersteinrichtung blieb bei
//     „SCA RedirectHandle: registering redirect URI" stehen, ohne dass ein Browser
//     aufging. Ursache war eine einzige mit 2.0.5 hinzugekommene Zeile,
//     `await MainActor.run { Freigabefenster.aktiv }`, die den Schalter für das eigene
//     Freigabe-Fenster abfragte.
//
// In `YaxiService` stand die Regel als Kommentar („Ab hier NUR noch `onMainRunLoop`").
// Ein Kommentar hat sie nicht gehalten. Dieser Test hält sie.
final class ModalHopRegelTests: XCTestCase {

    private func quelle(_ datei: String) throws -> String {
        let wurzel = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // simplebankingTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Repo-Wurzel
        return try String(contentsOf: wurzel.appendingPathComponent("Sources/simplebanking/\(datei)"),
                          encoding: .utf8)
    }

    /// Zeilen mit echtem Code, Kommentarzeilen fallen raus — in denen steht die Regel
    /// ja gerade beschrieben.
    private func codezeilen(_ text: String) -> [(nr: Int, inhalt: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (nr: $0.offset + 1, inhalt: String($0.element)) }
            .filter { zeile in
                let getrimmt = zeile.inhalt.trimmingCharacters(in: .whitespaces)
                return !getrimmt.hasPrefix("//") && !getrimmt.hasPrefix("///") && !getrimmt.hasPrefix("*")
            }
    }

    func test_yaxiService_nutztKeinMainActorRun() throws {
        let treffer = codezeilen(try quelle("YaxiService.swift"))
            .filter { $0.inhalt.contains("MainActor.run") }

        XCTAssertTrue(treffer.isEmpty,
                      "MainActor.run in YaxiService.swift, Zeile(n) "
                      + treffer.map { "\($0.nr)" }.joined(separator: ", ")
                      + " — während der modalen Ersteinrichtung bleibt so ein Hop liegen. "
                      + "Stattdessen `onMainRunLoop` verwenden.")
    }

    /// Dasselbe für die zweite Datei, die während der modalen Sitzung arbeitet.
    func test_freigabefenster_nutztKeinMainActorRun() throws {
        let treffer = codezeilen(try quelle("Freigabefenster.swift"))
            .filter { $0.inhalt.contains("MainActor.run") }
        XCTAssertTrue(treffer.isEmpty,
                      "MainActor.run in Freigabefenster.swift, Zeile(n) "
                      + treffer.map { "\($0.nr)" }.joined(separator: ", "))
    }

    /// Gegenprobe: Der Ersatz ist auch wirklich im Einsatz. Ohne diese Prüfung bestünde
    /// der Test oben auch dann, wenn jemand die Aufrufe ersatzlos strichen hätte.
    func test_onMainRunLoop_wirdBenutzt() throws {
        let text = try quelle("YaxiService.swift")
        let aufrufe = codezeilen(text).filter { $0.inhalt.contains("onMainRunLoop {") }
        XCTAssertGreaterThanOrEqual(aufrufe.count, 5,
                                    "Die Hops auf den Hauptthread sind verschwunden statt umgestellt.")
    }
}
