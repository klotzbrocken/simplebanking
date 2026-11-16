import XCTest
@testable import simplebanking

/// Kein Em-Dash („—", U+2014) in Texten, die die App ausgibt.
///
/// Im Deutschen ist der Gedankenstrich der Halbgeviertstrich „–" (U+2013);
/// „—" ist die englische Konvention. Maik will ihn in keinem Text, der unter
/// seinem Namen rausgeht, und das gilt auch für die, die die App selbst
/// schreibt: Am 16.11.2026 ist aufgefallen, dass der Betreff jeder
/// Fehlerreport-Mail („simplebanking — Unerwarteter Fehler …") einen trug,
/// also bekam ihn jeder Nutzer, der je einen Fehler gemeldet hat.
///
/// Geprüft werden nur Zeichenketten-Literale. Kommentare dürfen das Zeichen
/// behalten, die liest niemand außer uns.
final class KeinEmDashTests: XCTestCase {

    private static let emDash: Character = "\u{2014}"

    /// Eine Ausnahme, und sie ist das Gegenteil des Fehlers: `Barrierefreiheit`
    /// **erkennt** den alten Strich wieder, damit ein in den Einstellungen
    /// zwischengespeicherter Leistentitel aus einer Fassung bis 2.2.2 nicht
    /// stumm als Strich vorgelesen wird. Geschrieben wird er dort nicht.
    private static let erlaubt: [String: [String]] = [
        "Barrierefreiheit.swift": ["text.contains("]
    ]

    func testKeinEmDashInZeichenkettenliteralen() throws {
        let wurzel = Quelltext.paketwurzel.appendingPathComponent("Sources")
        guard let lauf = FileManager.default.enumerator(
            at: wurzel,
            includingPropertiesForKeys: nil
        ) else {
            return XCTFail("Sources nicht lesbar unter \(wurzel.path)")
        }

        var treffer: [String] = []
        var geprueft = 0

        for fall in lauf {
            guard let url = fall as? URL, url.pathExtension == "swift" else { continue }
            geprueft += 1
            let quelle = try String(contentsOf: url, encoding: .utf8)
            guard quelle.contains(Self.emDash) else { continue }

            // `ohneKommentare` entfernt `//` und `/* */`. Was danach noch ein
            // Em-Dash ist, steht in einem Literal: außerhalb von Literalen ist
            // das Zeichen kein gültiges Swift.
            for (nr, zeile) in Quelltext.ohneKommentare(quelle)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() where zeile.contains(Self.emDash) {
                let ausnahmen = Self.erlaubt[url.lastPathComponent] ?? []
                guard !ausnahmen.contains(where: { zeile.contains($0) }) else { continue }
                treffer.append("\(url.lastPathComponent):\(nr + 1)  \(zeile.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertGreaterThan(geprueft, 100, "Suche hat fast nichts gelesen, Pfad prüfen")
        XCTAssertTrue(
            treffer.isEmpty,
            "Em-Dash in ausgegebenem Text, bitte \u{201E}\u{2013}\u{201C} (U+2013) nehmen:\n"
                + treffer.joined(separator: "\n")
        )
    }
}
